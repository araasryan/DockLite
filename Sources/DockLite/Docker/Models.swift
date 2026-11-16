import Foundation
import SwiftUI

struct PortBinding: Decodable, Hashable {
    let ip: String?
    let privatePort: Int
    let publicPort: Int?
    let type: String

    enum CodingKeys: String, CodingKey {
        case ip = "IP", privatePort = "PrivatePort", publicPort = "PublicPort", type = "Type"
    }
}

struct ContainerSummary: Decodable, Identifiable, Hashable {
    let id: String
    let names: [String]
    let image: String
    let imageID: String
    let state: String
    let status: String
    let ports: [PortBinding]
    let labels: [String: String]
    let created: Date
    let networks: [String]

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", imageID = "ImageID", state = "State",
             status = "Status", ports = "Ports", labels = "Labels", created = "Created",
             networkSettings = "NetworkSettings"
    }

    private struct Ignored: Decodable { init(from decoder: Decoder) throws {} }
    private struct NetworkSettings: Decodable {
        let networks: [String: Ignored]?
        enum CodingKeys: String, CodingKey { case networks = "Networks" }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        imageID = try c.decodeIfPresent(String.self, forKey: .imageID) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        ports = try c.decodeIfPresent([PortBinding].self, forKey: .ports) ?? []
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        created = Date(timeIntervalSince1970: TimeInterval(try c.decodeIfPresent(Int.self, forKey: .created) ?? 0))
        let settings = try? c.decodeIfPresent(NetworkSettings.self, forKey: .networkSettings)
        networks = (settings?.networks?.keys).map { Array($0).sorted() } ?? []
    }

    enum StackKind: Hashable { case compose, aspire, custom }

    struct Stack: Hashable {
        let id: String
        let title: String
        let kind: StackKind
    }

    private static let aspireNetwork = try! NSRegularExpression(
        pattern: "^aspire-(?:persistent|session)-network-[0-9A-Za-z]+-(.+)$")

    /// The app this container belongs to, like Docker Desktop's grouping: a Compose project, or a
    /// .NET Aspire AppHost (its containers carry usvc-dev labels and join `aspire-*-network-<hash>-<AppHost>`).
    var stack: Stack? {
        if let project = composeProject {
            return Stack(id: "compose:\(project)", title: project, kind: .compose)
        }
        if labels.keys.contains(where: { $0.hasPrefix("com.microsoft.developer.usvc-dev.") }) {
            for net in networks {
                let range = NSRange(net.startIndex..., in: net)
                if let m = Self.aspireNetwork.firstMatch(in: net, range: range),
                   let r = Range(m.range(at: 1), in: net) {
                    return Stack(id: "aspire:\(net)", title: String(net[r]), kind: .aspire)
                }
            }
            return Stack(id: "aspire", title: "Aspire", kind: .aspire)
        }
        return nil
    }

    var name: String {
        guard let n = names.first else { return String(id.prefix(12)) }
        return n.hasPrefix("/") ? String(n.dropFirst()) : n
    }

    var composeProject: String? { labels["com.docker.compose.project"] }
    var composeService: String? { labels["com.docker.compose.service"] }
    var displayName: String { composeService ?? name }

    var isRunning: Bool { state == "running" }
    var isPaused: Bool { state == "paused" }

    var stateColor: Color {
        switch state {
        case "running": .green
        case "paused": .yellow
        case "restarting": .orange
        case "dead": .red
        default: .gray
        }
    }

    /// Host-published ports, de-duplicated (IPv4 + IPv6 bindings appear twice).
    var publishedPorts: [PortBinding] {
        var seen = Set<String>()
        return ports
            .filter { $0.publicPort != nil }
            .sorted { ($0.publicPort ?? 0) < ($1.publicPort ?? 0) }
            .filter { seen.insert("\($0.publicPort!)/\($0.privatePort)/\($0.type)").inserted }
    }
}

struct ImageSummary: Decodable, Identifiable, Hashable {
    let id: String
    let repoTags: [String]
    let size: Int64
    let created: Date

    enum CodingKeys: String, CodingKey {
        case id = "Id", repoTags = "RepoTags", size = "Size", created = "Created"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repoTags = (try c.decodeIfPresent([String].self, forKey: .repoTags) ?? []).filter { $0 != "<none>:<none>" }
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        created = Date(timeIntervalSince1970: TimeInterval(try c.decodeIfPresent(Int.self, forKey: .created) ?? 0))
    }

    var shortID: String {
        let raw = id.hasPrefix("sha256:") ? String(id.dropFirst(7)) : id
        return String(raw.prefix(12))
    }
}

struct DockerInfo: Decodable {
    let serverVersion: String?
    let operatingSystem: String?
    let ncpu: Int?
    let memTotal: Int64?
    let containersRunning: Int?

    enum CodingKeys: String, CodingKey {
        case serverVersion = "ServerVersion", operatingSystem = "OperatingSystem", ncpu = "NCPU",
             memTotal = "MemTotal", containersRunning = "ContainersRunning"
    }
}

struct PruneResult: Decodable {
    let spaceReclaimed: Int64?
    enum CodingKeys: String, CodingKey { case spaceReclaimed = "SpaceReclaimed" }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
