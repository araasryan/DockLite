import Darwin
import Foundation

struct DockerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func errnoString() -> String { String(cString: strerror(errno)) }

/// A blocking, connected AF_UNIX stream socket.
final class UnixSocket: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(path: String) throws {
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw DockerError("socket() failed: \(errnoString())") }

        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(s)
            throw DockerError("Socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let msg = errnoString()
            Darwin.close(s)
            throw DockerError("Cannot connect to \(path): \(msg)")
        }
        fd = s
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw DockerError("Write failed: \(errnoString())")
                }
                offset += n
            }
        }
    }

    /// Returns nil on EOF or error.
    func read(maxLength: Int = 64 * 1024) -> Data? {
        var buf = [UInt8](repeating: 0, count: maxLength)
        while true {
            let n = Darwin.recv(fd, &buf, maxLength, 0)
            if n > 0 { return Data(buf[0..<n]) }
            if n < 0 && errno == EINTR { continue }
            return nil
        }
    }

    /// Unblocks a reader on another thread.
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if !closed { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if !closed { closed = true; Darwin.close(fd) }
    }
}

/// Minimal HTTP/1.1 client over a unix socket (one request per connection).
final class HTTPConnection: @unchecked Sendable {
    let socket: UnixSocket
    private var buffer = Data()

    init(socketPath: String) throws {
        socket = try UnixSocket(path: socketPath)
    }

    func close() { socket.close() }

    func send(method: String, path: String, body: Data?) throws {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nUser-Agent: DockLite/0.1\r\nConnection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        } else if method == "POST" || method == "PUT" {
            head += "Content-Length: 0\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        try socket.write(data)
    }

    private func fill() -> Bool {
        guard let d = socket.read() else { return false }
        buffer.append(d)
        return true
    }

    func readHead() throws -> (status: Int, headers: [String: String]) {
        let sep = Data("\r\n\r\n".utf8)
        while true {
            if let r = buffer.range(of: sep) {
                let headData = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                let text = String(decoding: headData, as: UTF8.self)
                var lines = text.components(separatedBy: "\r\n")
                let parts = lines.removeFirst().split(separator: " ")
                guard parts.count >= 2, let status = Int(parts[1]) else {
                    throw DockerError("Malformed HTTP response")
                }
                var headers: [String: String] = [:]
                for line in lines {
                    guard let idx = line.firstIndex(of: ":") else { continue }
                    headers[line[..<idx].lowercased()] =
                        line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                }
                return (status, headers)
            }
            guard fill() else { throw DockerError("Connection closed before a response was received") }
        }
    }

    /// Streams the decoded body to `onChunk` until the response ends.
    func readBody(headers: [String: String], onChunk: (Data) -> Void) throws {
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            let crlf = Data("\r\n".utf8)
            while true {
                var lineRange = buffer.range(of: crlf)
                while lineRange == nil {
                    guard fill() else { return }
                    lineRange = buffer.range(of: crlf)
                }
                let sizeLine = String(decoding: buffer.subdata(in: buffer.startIndex..<lineRange!.lowerBound), as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<lineRange!.upperBound)
                let hex = sizeLine.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(hex, radix: 16) else { throw DockerError("Bad chunk size '\(hex)'") }
                if size == 0 { return }
                while buffer.count < size + 2 {
                    guard fill() else {
                        if !buffer.isEmpty { onChunk(buffer) }
                        return
                    }
                }
                let start = buffer.startIndex
                onChunk(buffer.subdata(in: start..<start + size))
                buffer.removeSubrange(start..<start + size + 2)
            }
        } else if let len = headers["content-length"].flatMap({ Int($0) }) {
            while buffer.count < len { guard fill() else { break } }
            if len > 0 { onChunk(Data(buffer.prefix(len))) }
            buffer = Data()
        } else {
            if !buffer.isEmpty { onChunk(buffer); buffer = Data() }
            while let d = socket.read() { onChunk(d) }
        }
    }
}
