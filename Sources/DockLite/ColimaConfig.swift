import Foundation
import Observation

/// Reads and edits Colima's profile config (~/.colima/default/colima.yaml) line by line,
/// so comments and every key DockLite doesn't manage stay exactly as they were.
struct ColimaConfigFile {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".colima/default/colima.yaml")
    }

    var lines: [String]

    init(text: String) { lines = text.components(separatedBy: "\n") }
    static func load() throws -> ColimaConfigFile {
        ColimaConfigFile(text: try String(contentsOf: url, encoding: .utf8))
    }
    var text: String { lines.joined(separator: "\n") }

    // MARK: Top-level scalars

    private func topLevelIndex(_ key: String) -> Int? {
        lines.firstIndex { $0.hasPrefix("\(key):") }
    }

    private static func value(of line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        var v = String(line[line.index(after: colon)...])
        if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]) }
        return v.trimmingCharacters(in: .whitespaces)
    }

    func scalar(_ key: String) -> String? { topLevelIndex(key).map { Self.value(of: lines[$0]) } }

    mutating func setScalar(_ key: String, _ value: String) {
        if let i = topLevelIndex(key) { lines[i] = "\(key): \(value)" } else { lines.append("\(key): \(value)") }
    }

    // MARK: kubernetes.enabled

    private func kubernetesEnabledIndex() -> Int? {
        guard let k = topLevelIndex("kubernetes") else { return nil }
        var i = k + 1
        while i < lines.count {
            let line = lines[i]
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("#") { return nil }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("enabled:") { return i }
            i += 1
        }
        return nil
    }

    var kubernetesEnabled: Bool {
        kubernetesEnabledIndex().map { Self.value(of: lines[$0]) == "true" } ?? false
    }

    mutating func setKubernetesEnabled(_ on: Bool) {
        if let i = kubernetesEnabledIndex() {
            let indent = lines[i].prefix { $0 == " " || $0 == "\t" }
            lines[i] = "\(indent)enabled: \(on)"
        } else if let k = topLevelIndex("kubernetes") {
            lines.insert("  enabled: \(on)", at: k + 1)
        } else {
            lines.append("kubernetes:\n  enabled: \(on)")
        }
    }

    // MARK: docker (daemon.json overrides)

    /// The `docker:` value as JSON text, or nil if it is written as block YAML we can't read.
    var dockerJSON: String? {
        guard let i = topLevelIndex("docker") else { return "{}" }
        let inline = Self.value(of: lines[i])
        if inline.isEmpty {
            // Block YAML. Treat an empty block as {}.
            let next = lines.indices.dropFirst(i + 1).first { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
            if let next, lines[next].hasPrefix(" ") || lines[next].hasPrefix("\t") { return nil }
            return "{}"
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(inline.utf8)) as? [String: Any] else { return nil }
        return Self.pretty(obj)
    }

    /// Replaces the `docker:` key (inline or block) with a single-line JSON value. JSON is valid YAML.
    mutating func setDocker(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let line = "docker: " + String(decoding: data, as: UTF8.self)
        guard let i = topLevelIndex("docker") else { lines.append(line); return }
        var end = i + 1
        while end < lines.count, lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t") { end += 1 }
        lines.replaceSubrange(i..<end, with: [line])
    }

    static func pretty(_ obj: Any) -> String {
        if let dict = obj as? [String: Any], dict.isEmpty { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct VMResources: Equatable {
    var cpu: Int
    var memoryGB: Double
    var diskGB: Int
    var kubernetes: Bool
    var rosetta: Bool = false
}

struct DiskUsage {
    var images: Int64 = 0
    var containers: Int64 = 0
    var volumes: Int64 = 0
    var buildCache: Int64 = 0
    var total: Int64 { images + containers + volumes + buildCache }
}

/// State behind the Resources and Docker Engine settings tabs.
@MainActor
@Observable
final class ColimaSettings {
    private(set) var loaded = false
    private(set) var loadError: String?

    private(set) var originalResources = VMResources(cpu: 2, memoryGB: 2, diskGB: 100, kubernetes: false)
    var resources = VMResources(cpu: 2, memoryGB: 2, diskGB: 100, kubernetes: false)

    private(set) var originalEngine = "{}"
    var engineText = "{}"
    /// True when `docker:` was block YAML we couldn't parse; we started from the VM's daemon.json instead.
    private(set) var engineFromVM = false
    private(set) var effectiveEngine: String?
    private(set) var diskUsage: DiskUsage?

    private(set) var applying = false
    var applyError: String?

    /// Rosetta needs Apple's Virtualization.framework VM ("vz").
    private(set) var vmType = "vz"
    var rosettaSupported: Bool { vmType == "vz" }
    var rosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    var hostCPUs: Int { ProcessInfo.processInfo.processorCount }
    var hostMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }

    var engineObject: [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(engineText.utf8)) as? [String: Any]
    }
    var engineValid: Bool { engineObject != nil }

    var resourcesChanged: Bool { resources != originalResources }
    var engineChanged: Bool {
        guard let a = engineObject,
              let b = try? JSONSerialization.jsonObject(with: Data(originalEngine.utf8)) as? [String: Any]
        else { return engineText != originalEngine }
        return !NSDictionary(dictionary: a).isEqual(to: b)
    }
    var hasChanges: Bool { resourcesChanged || engineChanged }

    func load(store: Store) async {
        do {
            let file = try ColimaConfigFile.load()
            originalResources = VMResources(
                cpu: Int(file.scalar("cpu") ?? "") ?? 2,
                memoryGB: Double(file.scalar("memory") ?? "") ?? 2,
                diskGB: Int(file.scalar("disk") ?? "") ?? 100,
                kubernetes: file.kubernetesEnabled,
                rosetta: file.scalar("rosetta") == "true")
            vmType = file.scalar("vmType") ?? "vz"
            resources = originalResources
            loadError = nil
            effectiveEngine = await Self.readEffectiveDaemonJSON()
            if let json = file.dockerJSON {
                originalEngine = json
                engineFromVM = false
            } else {
                originalEngine = effectiveEngine ?? "{}"
                engineFromVM = true
            }
            engineText = originalEngine
            loaded = true
        } catch {
            loadError = "Couldn't read \(ColimaConfigFile.url.path): \(error.localizedDescription)"
        }
        diskUsage = try? await store.client.diskUsage()
    }

    func revert() {
        resources = originalResources
        engineText = originalEngine
        applyError = nil
    }

    func apply(store: Store) async {
        guard let engine = engineObject else { applyError = "daemon.json is not valid JSON."; return }
        applying = true
        applyError = nil
        do {
            var file = try ColimaConfigFile.load()
            if resourcesChanged {
                file.setScalar("cpu", "\(resources.cpu)")
                let mem = resources.memoryGB
                file.setScalar("memory", mem == mem.rounded() ? "\(Int(mem))" : "\(mem)")
                file.setScalar("disk", "\(resources.diskGB)")
                file.setKubernetesEnabled(resources.kubernetes)
                file.setScalar("rosetta", resources.rosetta ? "true" : "false")
            }
            if engineChanged { try file.setDocker(engine) }
            if let error = await store.applyColimaConfig(file.text) {
                applyError = error
            } else {
                store.show("Colima restarted with the new settings")
            }
        } catch {
            applyError = error.localizedDescription
        }
        applying = false
        await load(store: store)
    }

    static func readEffectiveDaemonJSON() async -> String? {
        guard let out = try? await Colima.run(["ssh", "--", "cat", "/etc/docker/daemon.json"]),
              let start = out.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8))
        else { return nil }
        return ColimaConfigFile.pretty(obj)
    }
}
