import Foundation
import Observation

struct Component: Identifiable, Equatable {
    enum Kind: Equatable {
        case engine          // Docker Engine inside the Colima VM, updated with `colima update`
        case brew(String)    // Homebrew formula
        case external        // installed by something else (e.g. Docker Desktop); shown, not updated
    }

    let id: String
    let name: String
    var kind: Kind
    var installed: String?
    var latest: String?
    var detail: String?
    var note: String?

    var updateAvailable: Bool {
        if case .external = kind { return false }
        guard let installed, let latest else { return false }
        return installed != latest
    }
}

@MainActor
@Observable
final class Updater {
    private(set) var components: [Component] = [
        Component(id: "engine", name: "Docker Engine", kind: .engine),
        Component(id: "colima", name: "Colima", kind: .brew("colima")),
        Component(id: "lima", name: "Lima", kind: .brew("lima")),
        Component(id: "docker", name: "Docker CLI", kind: .external),
        Component(id: "compose", name: "Docker Compose", kind: .external),
    ]
    private(set) var checking = false
    private(set) var lastChecked: Date?
    private(set) var updating: String?
    var error: String?
    var needsColimaRestart = false

    var pending: [Component] { components.filter(\.updateAvailable) }

    private func set(_ id: String, _ change: (inout Component) -> Void) {
        guard let i = components.firstIndex(where: { $0.id == id }) else { return }
        change(&components[i])
    }

    // MARK: Checking

    func check(store: Store) async {
        guard !checking else { return }
        checking = true
        error = nil
        let connected = store.connected
        async let engine = Self.engineVersions(connected: connected)
        async let brew = Self.brewVersions(["colima", "lima", "docker", "docker-compose"])
        async let cli = Self.cliInfo()
        let (e, b, c) = await (engine, brew, cli)

        set("engine") {
            $0.installed = e.docker?.installed ?? store.info?.serverVersion
            $0.latest = e.docker?.candidate
            $0.detail = "Runs inside the Colima VM" + (e.containerd.map { c in
                " · containerd \(c.installed)" + (c.installed != c.candidate ? " → \(c.candidate)" : "")
            } ?? "")
            $0.note = connected ? (e.docker == nil ? "Couldn't reach the VM's package index" : nil)
                                : "Start Colima to check"
        }
        for name in ["colima", "lima"] {
            set(name) {
                $0.installed = b[name]?.installed
                $0.latest = b[name]?.stable
                $0.detail = "Homebrew"
                $0.note = Brew.binary == nil ? "Homebrew not found" : (b[name]?.installed == nil ? "Not installed with Homebrew" : nil)
            }
        }
        for (id, formula, version) in [("docker", "docker", c.cli), ("compose", "docker-compose", c.compose)] {
            set(id) {
                $0.installed = version
                let viaBrew = c.source == .brew && b[formula]?.installed != nil
                $0.kind = viaBrew ? .brew(formula) : .external
                $0.latest = viaBrew ? b[formula]?.stable : nil
                switch c.source {
                case .brew: $0.detail = "Homebrew"
                case .dockerDesktop: $0.detail = "Docker Desktop"
                case .other(let path): $0.detail = path
                case .missing: $0.detail = nil
                }
                $0.note = switch c.source {
                case .dockerDesktop: "Updated by Docker Desktop. To manage it here: brew install docker docker-compose"
                case .missing: "Not installed. Run: brew install docker docker-compose"
                default: nil
                }
            }
        }
        lastChecked = Date()
        checking = false
    }

    struct PackageVersion { let installed: String; let candidate: String }

    /// Asks apt inside the VM which docker-ce / containerd versions are installed and available.
    static func engineVersions(connected: Bool) async -> (docker: PackageVersion?, containerd: PackageVersion?) {
        guard connected, let out = try? await Colima.run([
            "ssh", "--", "sh", "-c",
            "sudo apt-get update -qq >/dev/null 2>&1; apt-cache policy docker-ce containerd.io",
        ]) else { return (nil, nil) }

        var result: [String: (installed: String?, candidate: String?)] = [:]
        var current: String?
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !raw.hasPrefix(" "), line.hasSuffix(":") { current = String(line.dropLast()); continue }
            guard let pkg = current else { continue }
            if line.hasPrefix("Installed:") { result[pkg, default: (nil, nil)].installed = debVersion(line) }
            if line.hasPrefix("Candidate:") { result[pkg, default: (nil, nil)].candidate = debVersion(line) }
        }
        func pv(_ name: String) -> PackageVersion? {
            guard let r = result[name], let i = r.installed, let c = r.candidate else { return nil }
            return PackageVersion(installed: i, candidate: c)
        }
        return (pv("docker-ce"), pv("containerd.io"))
    }

    /// "Installed: 5:29.5.2-1~ubuntu.24.04~noble" -> "29.5.2"
    nonisolated static func debVersion(_ line: String) -> String? {
        var v = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if v == "(none)" || v.isEmpty { return nil }
        if let colon = v.firstIndex(of: ":") { v = String(v[v.index(after: colon)...]) }
        if let dash = v.firstIndex(of: "-") { v = String(v[..<dash]) }
        return v
    }

    static func brewVersions(_ names: [String]) async -> [String: (installed: String?, stable: String?)] {
        guard let out = try? await Brew.run(["info", "--json=v2"] + names),
              let start = out.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any],
              let formulae = obj["formulae"] as? [[String: Any]]
        else { return [:] }
        var result: [String: (installed: String?, stable: String?)] = [:]
        for f in formulae {
            guard let name = f["name"] as? String else { continue }
            let stable = (f["versions"] as? [String: Any])?["stable"] as? String
            let installed = (f["installed"] as? [[String: Any]])?.last?["version"] as? String
            result[name] = (installed, stable)
        }
        return result
    }

    enum CLISource: Equatable { case brew, dockerDesktop, other(String), missing }

    /// Resolves `docker` the way the user's login shell would.
    static func cliInfo() async -> (source: CLISource, cli: String?, compose: String?) {
        let script = """
        printf 'path=%s\\n' "$(command -v docker)"
        printf 'cli=%s\\n' "$(docker version --format '{{.Client.Version}}' 2>/dev/null)"
        printf 'compose=%s\\n' "$(docker compose version --short 2>/dev/null)"
        """
        guard let out = try? await Shell.run("/bin/zsh", ["-lc", script]) else { return (.missing, nil, nil) }
        var values: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            if ["path", "cli", "compose"].contains(key) {
                let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { values[key] = v }
            }
        }
        guard let path = values["path"] else { return (.missing, nil, nil) }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let source: CLISource =
            resolved.contains("/Docker.app/") ? .dockerDesktop :
            (resolved.contains("/Cellar/") || resolved.hasPrefix("/opt/homebrew/")) ? .brew : .other(path)
        let compose = values["compose"].map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
        return (source, values["cli"], compose)
    }

    // MARK: Updating

    func update(_ id: String, store: Store) async {
        guard updating == nil, let c = components.first(where: { $0.id == id }) else { return }
        updating = id
        error = nil
        do {
            switch c.kind {
            case .engine:
                try await store.updateEngine()
                store.show("Docker Engine updated")
            case .brew(let formula):
                try await Brew.run(["upgrade", formula])
                if (formula == "colima" || formula == "lima") && store.connected { needsColimaRestart = true }
                store.show("\(c.name) updated")
            case .external:
                break
            }
        } catch {
            self.error = error.localizedDescription
        }
        updating = nil
        await check(store: store)
    }

    /// Homebrew packages first, then the engine (which restarts Docker).
    func updateAll(store: Store) async {
        let ids = pending.sorted { a, _ in a.kind != .engine }.map(\.id)
        for id in ids {
            await update(id, store: store)
            if error != nil { break }
        }
    }

    func restartColima(store: Store) async {
        if let err = await store.restartColima() { error = err } else { needsColimaRestart = false }
    }
}
