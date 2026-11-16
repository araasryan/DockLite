import SwiftUI

struct LogsView: View {
    @Environment(Store.self) private var store
    let containerID: String
    let isRunning: Bool

    @State private var logs = LogStream()
    @State private var follow = true
    @State private var filter = ""
    @AppStorage(Prefs.logTail) private var logTail = 500

    private var visible: [LogStream.Line] {
        filter.isEmpty ? logs.lines : logs.lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Filter logs", text: $filter).textFieldStyle(.plain)
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).controlSize(.small)
                Button { copyAll() } label: { Image(systemName: "doc.on.doc") }.help("Copy visible logs")
                Button { logs.clear() } label: { Image(systemName: "clear") }.help("Clear")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.isError ? Color.red : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                        if logs.ended {
                            Text(logs.error.map { "— \($0) —" } ?? (isRunning ? "— stream ended —" : "— container is not running —"))
                                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(10)
                }
                .onChange(of: logs.lines.last?.id) { _, id in
                    if follow, let id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: follow) { _, on in
                    if on, let id = visible.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                if logs.lines.isEmpty && !logs.ended {
                    ProgressView().controlSize(.small)
                } else if logs.lines.isEmpty {
                    Text("No logs").foregroundStyle(.secondary)
                }
            }
        }
        // Restart the stream when the container changes or (re)starts.
        .task(id: "\(containerID)-\(isRunning)") {
            logs.start(client: store.client, containerID: containerID, tail: logTail)
        }
        .onDisappear { logs.stop() }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visible.map(\.text).joined(separator: "\n"), forType: .string)
    }
}
