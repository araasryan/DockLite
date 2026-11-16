import Foundation

/// Cancels a long-running streaming request (logs, events, pulls).
final class StreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: HTTPConnection?
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    fileprivate func attach(_ conn: HTTPConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        connection = conn
        return true
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        connection?.socket.shutdown()
    }
}

/// Talks to the Docker Engine REST API over a unix socket.
final class DockerClient: @unchecked Sendable {
    let socketPath: String

    init(socketPath: String) { self.socketPath = socketPath }

    // MARK: Transport

    func requestSync(_ method: String, _ path: String, body: Data? = nil) throws -> Data {
        let conn = try HTTPConnection(socketPath: socketPath)
        defer { conn.close() }
        try conn.send(method: method, path: path, body: body)
        let (status, headers) = try conn.readHead()
        var data = Data()
        try conn.readBody(headers: headers) { data.append($0) }
        if status >= 400 { throw DockerError(Self.errorMessage(data) ?? "Docker returned HTTP \(status)") }
        return data
    }

    func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try self.requestSync(method, path, body: body)
        }.value
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        let data = try await request("GET", path)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Runs a streaming request on its own thread. `onData` and `onEnd` are called on that thread.
    @discardableResult
    func stream(_ method: String = "GET", _ path: String,
                onData: @escaping (Data) -> Void,
                onEnd: @escaping (Error?) -> Void) -> StreamHandle {
        let handle = StreamHandle()
        let socketPath = socketPath
        Thread.detachNewThread {
            do {
                let conn = try HTTPConnection(socketPath: socketPath)
                defer { conn.close() }
                guard handle.attach(conn) else { onEnd(nil); return }
                try conn.send(method: method, path: path, body: nil)
                let (status, headers) = try conn.readHead()
                if status >= 400 {
                    var data = Data()
                    try conn.readBody(headers: headers) { data.append($0) }
                    throw DockerError(Self.errorMessage(data) ?? "Docker returned HTTP \(status)")
                }
                try conn.readBody(headers: headers) { chunk in
                    if !handle.isCancelled { onData(chunk) }
                }
                onEnd(nil)
            } catch {
                onEnd(handle.isCancelled ? nil : error)
            }
        }
        return handle
    }

    static func errorMessage(_ data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["message"] as? String { return msg }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func q(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: API

    func ping() async -> Bool {
        guard let data = try? await request("GET", "/_ping") else { return false }
        return String(decoding: data, as: UTF8.self) == "OK"
    }

    func info() async throws -> DockerInfo { try await get(DockerInfo.self, "/info") }

    func containers() async throws -> [ContainerSummary] {
        try await get([ContainerSummary].self, "/containers/json?all=1")
    }

    func images() async throws -> [ImageSummary] {
        try await get([ImageSummary].self, "/images/json")
    }

    /// action: start | stop | restart | pause | unpause | kill
    func containerAction(_ id: String, _ action: String) async throws {
        _ = try await request("POST", "/containers/\(id)/\(action)")
    }

    func removeContainer(_ id: String, force: Bool) async throws {
        _ = try await request("DELETE", "/containers/\(id)?force=\(force)")
    }

    func removeImage(_ ref: String) async throws {
        _ = try await request("DELETE", "/images/\(ref)")
    }

    func pruneContainers() async throws -> PruneResult {
        try JSONDecoder().decode(PruneResult.self, from: try await request("POST", "/containers/prune"))
    }

    func pruneImages(allUnused: Bool) async throws -> PruneResult {
        let filters = allUnused ? "?filters=" + Self.q(#"{"dangling":["false"]}"#) : ""
        return try JSONDecoder().decode(PruneResult.self, from: try await request("POST", "/images/prune\(filters)"))
    }

    func diskUsage() async throws -> DiskUsage {
        let data = try await request("GET", "/system/df")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return DiskUsage() }
        func sum(_ key: String, _ size: ([String: Any]) -> Int64?) -> Int64 {
            ((obj[key] as? [[String: Any]]) ?? []).reduce(0) { $0 + max(size($1) ?? 0, 0) }
        }
        var usage = DiskUsage()
        usage.images = (obj["LayersSize"] as? NSNumber)?.int64Value ?? sum("Images") { ($0["Size"] as? NSNumber)?.int64Value }
        usage.containers = sum("Containers") { ($0["SizeRw"] as? NSNumber)?.int64Value }
        usage.volumes = sum("Volumes") { (($0["UsageData"] as? [String: Any])?["Size"] as? NSNumber)?.int64Value }
        usage.buildCache = sum("BuildCache") { ($0["Size"] as? NSNumber)?.int64Value }
        return usage
    }

    func isTTY(_ id: String) async throws -> Bool {
        let data = try await request("GET", "/containers/\(id)/json")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((obj?["Config"] as? [String: Any])?["Tty"] as? Bool) ?? false
    }

    /// Splits "repo[:tag|@digest]" into the API's fromImage / tag parameters.
    static func splitReference(_ ref: String) -> (image: String, tag: String) {
        if let at = ref.firstIndex(of: "@") {
            return (String(ref[..<at]), String(ref[ref.index(after: at)...]))
        }
        let lastSlash = ref.lastIndex(of: "/") ?? ref.startIndex
        if let colon = ref[lastSlash...].lastIndex(of: ":") {
            return (String(ref[..<colon]), String(ref[ref.index(after: colon)...]))
        }
        return (ref, "latest")
    }

    func pull(_ reference: String, onProgress: @escaping (String) -> Void) async throws {
        let (image, tag) = Self.splitReference(reference.trimmingCharacters(in: .whitespaces))
        let path = "/images/create?fromImage=\(Self.q(image))&tag=\(Self.q(tag))"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var lines = Data()
            var pullError: String?
            stream("POST", path, onData: { data in
                lines.append(data)
                while let nl = lines.firstIndex(of: 0x0A) {
                    let line = lines.subdata(in: lines.startIndex..<nl)
                    lines.removeSubrange(lines.startIndex...nl)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if let err = obj["error"] as? String { pullError = err; continue }
                    let status = obj["status"] as? String ?? ""
                    let id = obj["id"] as? String
                    let progress = obj["progress"] as? String ?? ""
                    onProgress([id.map { "\($0): " } ?? "", status, " ", progress].joined())
                }
            }, onEnd: { error in
                if let error { cont.resume(throwing: error) }
                else if let pullError { cont.resume(throwing: DockerError(pullError)) }
                else { cont.resume() }
            })
        }
    }
}

enum SocketLocator {
    static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var list: [String] = []
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            list.append(String(host.dropFirst(7)))
        }
        list += [
            "\(home)/.colima/default/docker.sock",
            "\(home)/.colima/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/.docker/run/docker.sock",
            "/var/run/docker.sock",
        ]
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    static var existing: [String] {
        candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static var colimaDefault: String {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.colima/default/docker.sock"
    }

    static func preferred() -> String { existing.first ?? colimaDefault }
}
