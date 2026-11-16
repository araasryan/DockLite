import Foundation
import Observation

/// Splits Docker's log stream into lines. Handles the 8-byte multiplexed frame
/// format used for non-TTY containers. Used only on the streaming thread.
final class LogParser {
    private let tty: Bool
    private var frames = Data()
    private var partial: [Bool: Data] = [:]

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    init(tty: Bool) { self.tty = tty }

    func feed(_ data: Data) -> [(String, Bool)] {
        if tty { return split(data, isErr: false) }
        frames.append(data)
        var out: [(String, Bool)] = []
        while frames.count >= 8 {
            let s = frames.startIndex
            let size = Int(frames[s + 4]) << 24 | Int(frames[s + 5]) << 16 | Int(frames[s + 6]) << 8 | Int(frames[s + 7])
            guard frames.count >= 8 + size else { break }
            let isErr = frames[s] == 2
            let payload = frames.subdata(in: (s + 8)..<(s + 8 + size))
            frames.removeSubrange(s..<(s + 8 + size))
            out += split(payload, isErr: isErr)
        }
        return out
    }

    func flush() -> [(String, Bool)] {
        let rest = partial.compactMap { isErr, data in data.isEmpty ? nil : (Self.clean(data), isErr) }
        partial = [:]
        return rest
    }

    private func split(_ data: Data, isErr: Bool) -> [(String, Bool)] {
        var buf = partial[isErr, default: Data()]
        buf.append(data)
        var result: [(String, Bool)] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            result.append((Self.clean(buf.subdata(in: buf.startIndex..<nl)), isErr))
            buf.removeSubrange(buf.startIndex...nl)
        }
        partial[isErr] = buf
        return result
    }

    private static func clean(_ data: Data) -> String {
        var s = String(decoding: data, as: UTF8.self)
        if s.hasSuffix("\r") { s.removeLast() }
        guard s.contains("\u{1B}") else { return s }
        return ansi.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
}

@MainActor
@Observable
final class LogStream {
    struct Line: Identifiable {
        let id: Int
        let text: String
        let isError: Bool
    }

    private(set) var lines: [Line] = []
    private(set) var ended = false
    private(set) var error: String?

    @ObservationIgnored private var handle: StreamHandle?
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var generation = 0
    private let maxLines = 5000

    func start(client: DockerClient, containerID: String, tail: Int = 500) {
        stop()
        lines = []
        ended = false
        error = nil
        generation += 1
        let gen = generation
        Task {
            let tty = (try? await client.isTTY(containerID)) ?? false
            guard gen == generation else { return }
            let parser = LogParser(tty: tty)
            handle = client.stream(
                "GET", "/containers/\(containerID)/logs?follow=1&stdout=1&stderr=1&tail=\(tail)",
                onData: { [weak self] data in
                    let new = parser.feed(data)
                    guard !new.isEmpty else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(new, gen: gen) } }
                },
                onEnd: { [weak self] err in
                    let rest = parser.flush()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, gen == self.generation else { return }
                            self.append(rest, gen: gen)
                            self.ended = true
                            self.error = err?.localizedDescription
                        }
                    }
                })
        }
    }

    func stop() {
        generation += 1
        handle?.cancel()
        handle = nil
    }

    func clear() { lines = [] }

    private func append(_ new: [(String, Bool)], gen: Int) {
        guard gen == generation, !new.isEmpty else { return }
        for (text, isErr) in new {
            lines.append(Line(id: nextID, text: text, isError: isErr))
            nextID += 1
        }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }
}
