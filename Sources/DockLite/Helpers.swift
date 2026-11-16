import AppKit
import Foundation

enum Shell {
    /// GUI apps don't inherit the shell's PATH. Colima needs `docker` on PATH, which may come from
    /// Homebrew, Docker Desktop (~/.docker/bin) or OrbStack.
    static let path: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.docker/bin", "/Applications/Docker.app/Contents/Resources/bin", "\(home)/.orbstack/bin"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        return (["/opt/homebrew/bin", "/usr/local/bin"] + extra + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .joined(separator: ":")
    }()

    /// Runs a command, returns its output, and throws with the output tail on failure.
    /// Output goes to a file, not a pipe: colima's VM daemon can inherit a pipe and keep it open.
    @discardableResult
    static func run(_ executable: String, _ args: [String], env extra: [String: String] = [:]) async throws -> String {
        try await Task.detached {
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("docklite-\(UUID().uuidString).log")
            defer { try? FileManager.default.removeItem(at: log) }
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            env.merge(extra) { $1 }
            p.environment = env
            p.standardOutput = handle
            p.standardError = handle
            p.standardInput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()

            let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if p.terminationStatus != 0 {
                var seen = Set<Substring>()
                let unique = output.split(separator: "\n").reversed().filter { seen.insert($0).inserted }.reversed()
                let tail = unique.suffix(6).joined(separator: "\n")
                let name = URL(fileURLWithPath: executable).lastPathComponent
                throw DockerError("\(name) \(args.joined(separator: " ")) failed:\n\(tail)")
            }
            return output
        }.value
    }
}

enum Colima {
    static var binary: String? {
        ["/opt/homebrew/bin/colima", "/usr/local/bin/colima"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ args: [String]) async throws -> String {
        guard let bin = binary else { throw DockerError("Colima is not installed. Run: brew install colima") }
        return try await Shell.run(bin, args)
    }
}

enum Brew {
    static var binary: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ args: [String]) async throws -> String {
        guard let bin = binary else { throw DockerError("Homebrew is not installed.") }
        return try await Shell.run(bin, args, env: ["HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1"])
    }
}

enum TerminalLauncher {
    /// Opens Terminal.app with an interactive shell in the container.
    static func openShell(container: ContainerSummary, socketPath: String) throws {
        let script = """
        #!/bin/zsh -l
        export DOCKER_HOST='unix://\(socketPath)'
        clear
        if ! command -v docker >/dev/null 2>&1; then
          echo "docker CLI not found on PATH. Install it with: brew install docker"
          exit 1
        fi
        echo "Shell in \(container.name) (exit to close)"
        exec docker exec -it \(container.id) sh -c 'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi'
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("docklite-shell-\(container.id.prefix(12)).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}
