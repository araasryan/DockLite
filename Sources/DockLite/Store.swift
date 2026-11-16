import AppKit
import Foundation
import Observation

enum Prefs {
    static let autoStartColima = "autoStartColima"
    static let showMenuBar = "showMenuBar"
    static let logTail = "logTail"
}

@MainActor
@Observable
final class Store {
    private(set) var socketPath: String
    private(set) var client: DockerClient
    private(set) var connected = false
    private(set) var checkedOnce = false

    private(set) var info: DockerInfo?
    private(set) var containers: [ContainerSummary] = []
    private(set) var images: [ImageSummary] = []

    var busy: Set<String> = []
    var alert: String?
    var notice: String?
    var pendingRemoval: ContainerSummary?
    var colimaBusy = false

    @ObservationIgnored private var userChoseSocket = false
    @ObservationIgnored private var events: StreamHandle?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    var runningCount: Int { containers.filter(\.isRunning).count }

    // MARK: Manual groups

    /// Container name -> group name. Keyed by name (not id) so assignments survive
    /// Compose/Aspire re-creating a container.
    var customGroups: [String: String] = UserDefaults.standard.dictionary(forKey: "customGroups") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(customGroups, forKey: "customGroups") }
    }

    var customGroupNames: [String] {
        Set(customGroups.values).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The group a container is shown in: a manual group first, then its Compose project / Aspire app.
    func stack(for c: ContainerSummary) -> ContainerSummary.Stack? {
        if let group = customGroups[c.name] {
            return ContainerSummary.Stack(id: "custom:\(group)", title: group, kind: .custom)
        }
        return c.stack
    }

    /// Moves containers into a manual group, or back to automatic grouping when `group` is nil.
    func assign(_ list: [ContainerSummary], to group: String?) {
        let name = group?.trimmingCharacters(in: .whitespaces)
        for c in list { customGroups[c.name] = (name?.isEmpty ?? true) ? nil : name }
    }

    func renameGroup(_ old: String, to new: String) {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return }
        customGroups = customGroups.mapValues { $0 == old ? new : $0 }
    }

    func ungroup(_ group: String) {
        customGroups = customGroups.filter { $0.value != group }
    }

    init() {
        let path = SocketLocator.preferred()
        socketPath = path
        client = DockerClient(socketPath: path)
        Task { [weak self] in await self?.monitorLoop() }
    }

    // MARK: Connection

    private func monitorLoop() async {
        while !Task.isCancelled {
            if connected {
                await refresh()
            } else {
                await connect()
            }
            try? await Task.sleep(for: .seconds(connected ? 20 : 3))
        }
    }

    func connect() async {
        if !userChoseSocket {
            let preferred = SocketLocator.preferred()
            if preferred != socketPath { setClient(preferred) }
        }
        let ok = await client.ping()
        let firstCheck = !checkedOnce
        checkedOnce = true
        if ok {
            connected = true
            await refresh()
            startEvents()
        } else {
            markDisconnected()
            if firstCheck && UserDefaults.standard.bool(forKey: Prefs.autoStartColima) && Colima.binary != nil {
                startColima()
            }
        }
    }

    func useSocket(_ path: String) {
        userChoseSocket = true
        setClient(path)
        markDisconnected()
        Task { await connect() }
    }

    private func setClient(_ path: String) {
        events?.cancel()
        events = nil
        socketPath = path
        client = DockerClient(socketPath: path)
    }

    private func markDisconnected() {
        events?.cancel()
        events = nil
        connected = false
        info = nil
        containers = []
        images = []
    }

    private func startEvents() {
        events?.cancel()
        let filters = DockerClient.q(#"{"type":["container","image"]}"#)
        events = client.stream("GET", "/events?filters=\(filters)", onData: { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleRefresh() } }
        }, onEnd: { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.eventsEnded() } }
        })
    }

    private func eventsEnded() {
        guard events != nil else { return } // cancelled on purpose
        events = nil
        Task {
            try? await Task.sleep(for: .seconds(1))
            if await client.ping() { startEvents() } else { markDisconnected() }
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func refresh() async {
        let client = client
        do {
            async let c = client.containers()
            async let i = client.images()
            async let inf = client.info()
            let (newContainers, newImages, newInfo) = try await (c, i, inf)
            guard client === self.client else { return }
            containers = newContainers.sorted {
                $0.isRunning != $1.isRunning ? $0.isRunning : $0.name < $1.name
            }
            images = newImages
            info = newInfo
        } catch {
            if await !client.ping() { markDisconnected() }
        }
    }

    // MARK: Actions

    private func perform(_ key: String, _ work: @escaping () async throws -> Void) {
        Task {
            busy.insert(key)
            do { try await work() } catch { alert = error.localizedDescription }
            busy.remove(key)
            await refresh()
        }
    }

    func start(_ c: ContainerSummary) {
        let action = c.isPaused ? "unpause" : "start"
        perform(c.id) { try await self.client.containerAction(c.id, action) }
    }
    func stop(_ c: ContainerSummary) { perform(c.id) { try await self.client.containerAction(c.id, "stop") } }
    func restart(_ c: ContainerSummary) { perform(c.id) { try await self.client.containerAction(c.id, "restart") } }
    func pause(_ c: ContainerSummary) { perform(c.id) { try await self.client.containerAction(c.id, "pause") } }
    func remove(_ c: ContainerSummary) { perform(c.id) { try await self.client.removeContainer(c.id, force: true) } }

    func startAll(_ list: [ContainerSummary]) { list.filter { !$0.isRunning }.forEach(start) }
    func stopAll(_ list: [ContainerSummary]) { list.filter(\.isRunning).forEach(stop) }

    func removeImage(_ ref: String) { perform(ref) { try await self.client.removeImage(ref) } }

    func pruneContainers() {
        perform("prune") {
            let r = try await self.client.pruneContainers()
            self.show("Removed stopped containers · reclaimed \(Format.bytes(r.spaceReclaimed ?? 0))")
        }
    }

    func pruneImages(allUnused: Bool) {
        perform("prune") {
            let r = try await self.client.pruneImages(allUnused: allUnused)
            self.show("Pruned images · reclaimed \(Format.bytes(r.spaceReclaimed ?? 0))")
        }
    }

    func openShell(_ c: ContainerSummary) {
        do { try TerminalLauncher.openShell(container: c, socketPath: socketPath) }
        catch { alert = error.localizedDescription }
    }

    func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
        }
    }

    // MARK: Colima

    func startColima() {
        guard !colimaBusy else { return }
        colimaBusy = true
        Task {
            do {
                try await Colima.run(["start"])
                userChoseSocket = false
                await connect()
            } catch {
                alert = error.localizedDescription
            }
            colimaBusy = false
        }
    }

    /// Writes a new colima.yaml and restarts Colima. If Colima fails to start with it, the previous
    /// config is restored and started again. Returns an error message, or nil on success.
    func applyColimaConfig(_ newText: String) async -> String? {
        guard !colimaBusy else { return "Colima is busy, try again in a moment." }
        let url = ColimaConfigFile.url
        let backup: String
        do { backup = try String(contentsOf: url, encoding: .utf8) }
        catch { return "Couldn't read \(url.path): \(error.localizedDescription)" }

        colimaBusy = true
        markDisconnected()
        defer { colimaBusy = false }
        do {
            try newText.write(to: url, atomically: true, encoding: .utf8)
            try await Colima.run(["stop"])
            try await Colima.run(["start"])
            // Colima can report success while dockerd is crash-looping on a bad daemon.json.
            guard await waitForEngine() else {
                throw DockerError("Docker Engine didn't come up after the restart (check the daemon.json overrides).")
            }
            userChoseSocket = false
            await connect()
            return nil
        } catch {
            let failure = error.localizedDescription
            try? backup.write(to: url, atomically: true, encoding: .utf8)
            try? await Colima.run(["stop"])
            let restored = (try? await Colima.run(["start"])) != nil
            await connect()
            return """
            Colima didn't start with the new settings, so the previous settings were restored\
            \(restored ? " and Colima is running again" : ", but Colima still failed to start").

            \(failure)
            """
        }
    }

    /// Polls Colima's socket until Docker answers, up to ~30s.
    private func waitForEngine() async -> Bool {
        let probe = DockerClient(socketPath: SocketLocator.colimaDefault)
        for _ in 0..<15 {
            if await probe.ping() { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    /// Upgrades Docker Engine / containerd inside the VM (`colima update`). Docker restarts.
    func updateEngine() async throws {
        guard !colimaBusy else { throw DockerError("Colima is busy, try again in a moment.") }
        colimaBusy = true
        markDisconnected()
        defer { colimaBusy = false }
        do {
            try await Colima.run(["update"])
        } catch {
            await connect()
            throw error
        }
        await connect()
    }

    func restartColima() async -> String? {
        guard !colimaBusy else { return "Colima is busy, try again in a moment." }
        colimaBusy = true
        markDisconnected()
        defer { colimaBusy = false }
        do {
            try await Colima.run(["stop"])
            try await Colima.run(["start"])
        } catch {
            await connect()
            return error.localizedDescription
        }
        await connect()
        return nil
    }

    func stopColima() {
        guard !colimaBusy else { return }
        colimaBusy = true
        markDisconnected()
        Task {
            do { try await Colima.run(["stop"]) } catch { alert = error.localizedDescription }
            colimaBusy = false
        }
    }
}
