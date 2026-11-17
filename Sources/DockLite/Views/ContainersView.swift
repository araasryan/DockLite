import SwiftUI

struct ContainerGroup: Identifiable {
    let id: String
    let title: String
    let kind: ContainerSummary.StackKind
    let containers: [ContainerSummary]
}

struct ContainersView: View {
    @Environment(Store.self) private var store
    @State private var selection = Set<String>()
    @State private var search = ""
    /// Containers waiting for a name in the "New Group" prompt.
    @State private var newGroupMembers: [ContainerSummary]?
    @State private var renaming: String?
    @State private var groupName = ""
    @AppStorage("showStopped") private var showStopped = true
    /// Newline-separated ids of collapsed groups (persisted across launches).
    @AppStorage("collapsedGroups") private var collapsedRaw = ""

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: "\n").map(String.init))
    }

    private func setCollapsed(_ ids: Set<String>) {
        collapsedRaw = ids.sorted().joined(separator: "\n")
    }

    /// Searching always shows matches, regardless of collapse state.
    private func isExpanded(_ group: ContainerGroup) -> Bool {
        !search.isEmpty || !collapsed.contains(group.id)
    }

    private func toggle(_ group: ContainerGroup) {
        var ids = collapsed
        if ids.contains(group.id) { ids.remove(group.id) } else { ids.insert(group.id) }
        withAnimation(.easeInOut(duration: 0.18)) { setCollapsed(ids) }
    }

    private var filtered: [ContainerSummary] {
        store.containers.filter { c in
            (showStopped || c.isRunning) &&
            (search.isEmpty || c.name.localizedCaseInsensitiveContains(search)
                || c.image.localizedCaseInsensitiveContains(search)
                || (store.stack(for: c)?.title.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    /// Manual groups, Compose projects and Aspire apps, sorted by name.
    private var groups: [ContainerGroup] {
        Dictionary(grouping: filtered.compactMap { c in store.stack(for: c).map { ($0, c) } }) { $0.0 }
            .mapValues { $0.map(\.1) }
            .map { stack, list in ContainerGroup(id: stack.id, title: stack.title, kind: stack.kind, containers: list) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Containers that belong to no app are listed on their own, without a group header.
    private var ungrouped: [ContainerSummary] { filtered.filter { store.stack(for: $0) == nil } }

    private var selected: ContainerSummary? {
        guard selection.count == 1 else { return nil }
        return store.containers.first { selection.contains($0.id) }
    }

    /// Ids of rows currently on screen (filtered, in expanded groups).
    private var visibleIDs: Set<String> {
        var ids = Set(ungrouped.map(\.id))
        for g in groups where isExpanded(g) { ids.formUnion(g.containers.map(\.id)) }
        return ids
    }

    private func containers(_ ids: Set<String>) -> [ContainerSummary] {
        store.containers.filter { ids.contains($0.id) }
    }

    private func startNewGroup(_ members: [ContainerSummary]) {
        groupName = ""
        newGroupMembers = members
    }

    private func startRename(_ group: String) {
        groupName = group
        renaming = group
    }

    var body: some View {
        Group {
            if store.containers.isEmpty {
                ContentUnavailableView("No containers", systemImage: "shippingbox",
                                       description: Text("Run one with docker run or docker compose up."))
            } else {
                List(selection: $selection) {
                    ForEach(groups) { group in
                        Section {
                            if isExpanded(group) {
                                ForEach(group.containers) { c in
                                    ContainerRow(container: c).tag(c.id)
                                }
                            }
                        } header: {
                            GroupHeader(group: group, expanded: isExpanded(group)) { toggle(group) }
                                .contextMenu {
                                    if group.kind == .custom {
                                        Button("Rename Group…") { startRename(group.title) }
                                        Button("Ungroup") { store.ungroup(group.title) }
                                    } else {
                                        Button("Move All to New Group…") { startNewGroup(group.containers) }
                                    }
                                }
                        }
                    }
                    if !ungrouped.isEmpty {
                        Section {
                            ForEach(ungrouped) { c in
                                ContainerRow(container: c).tag(c.id)
                            }
                        } header: {
                            if !groups.isEmpty { Divider().padding(.vertical, 4) }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    SelectionMenu(containers: containers(ids), onNewGroup: startNewGroup)
                }
                .onExitCommand { selection = [] }
                // Never keep rows selected that you can't see (collapsed, filtered out, removed).
                .onChange(of: visibleIDs) { _, visible in
                    if !selection.isSubset(of: visible) { selection.formIntersection(visible) }
                }
            }
        }
        .alert("New Group", isPresented: Binding(get: { newGroupMembers != nil }, set: { if !$0 { newGroupMembers = nil } })) {
            TextField("Group name", text: $groupName)
            Button("Create") {
                if let members = newGroupMembers { store.assign(members, to: groupName) }
                newGroupMembers = nil
            }
            .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { newGroupMembers = nil }
        } message: {
            let n = newGroupMembers?.count ?? 0
            Text("Move \(n) container\(n == 1 ? "" : "s") into a new group.")
        }
        .alert("Rename Group", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Group name", text: $groupName)
            Button("Rename") {
                if let old = renaming { store.renameGroup(old, to: groupName) }
                renaming = nil
            }
            .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .navigationTitle("Containers")
        .navigationSubtitle("\(store.runningCount) running · \(store.containers.count) total")
        .searchable(text: $search, placement: .toolbar, prompt: "Filter containers")
        .toolbar {
            ToolbarItemGroup {
                let allCollapsed = !groups.isEmpty && groups.allSatisfy { collapsed.contains($0.id) }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        setCollapsed(allCollapsed ? [] : Set(groups.map(\.id)))
                    }
                } label: {
                    Label(allCollapsed ? "Expand all" : "Collapse all",
                          systemImage: allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                }
                .help(allCollapsed ? "Expand all groups (⇧⌘E)" : "Collapse all groups (⇧⌘E)")
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(groups.isEmpty || !search.isEmpty)
                Toggle(isOn: $showStopped) {
                    Label("Show stopped", systemImage: "eye")
                }
                .help(showStopped ? "Hide stopped containers" : "Show stopped containers")
                Button {
                    store.pruneContainers()
                } label: {
                    Label("Remove stopped", systemImage: "trash.slash")
                }
                .help("Remove all stopped containers")
                .disabled(store.busy.contains("prune"))
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")
                .keyboardShortcut("r")
            }
        }
        // Driven only by the selection. The setter is a no-op on purpose: SwiftUI writes `false` while
        // the panel animates, and clearing the selection there broke ⌘/⇧-click multi-selection.
        .inspector(isPresented: Binding(get: { !selection.isEmpty }, set: { _ in })) {
            Group {
                if let c = selected {
                    ContainerDetail(container: c)
                } else {
                    MultiSelectionPanel(containers: containers(selection),
                                        onNewGroup: startNewGroup,
                                        onClear: { selection = [] })
                }
            }
            .inspectorColumnWidth(min: 380, ideal: 560, max: 1000)
        }
    }
}

struct GroupHeader: View {
    @Environment(Store.self) private var store
    let group: ContainerGroup
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        let running = group.containers.filter(\.isRunning).count
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                Image(systemName: group.kind == .custom ? "folder" : "square.stack.3d.down.right")
                    .foregroundStyle(.secondary)
                Text(group.title).font(.headline)
                Text(group.kind == .compose ? "Compose" : group.kind == .aspire ? "Aspire" : "Group")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                Text("\(running)/\(group.containers.count) running").font(.caption).foregroundStyle(.secondary)
                if !expanded {
                    // Compact status summary while collapsed.
                    HStack(spacing: 3) {
                        ForEach(group.containers.prefix(16)) { c in
                            Circle().fill(c.stateColor).frame(width: 6, height: 6).help("\(c.displayName): \(c.state)")
                        }
                    }
                    .padding(.leading, 4)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(group.title), \(expanded ? "expanded" : "collapsed")")
            if running > 0 {
                Button("Stop all") { store.stopAll(group.containers) }
            } else {
                Button("Start all") { store.startAll(group.containers) }
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

struct ContainerRow: View {
    @Environment(Store.self) private var store
    let container: ContainerSummary

    /// Picks the fullest layout that fits the row width: all ports, then one port + "+N",
    /// then a ports menu, and finally drops the status text. Names always get priority.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(ports: .all, showStatus: true)
            content(ports: .first, showStatus: true)
            content(ports: .menu, showStatus: true)
            content(ports: .menu, showStatus: false)
        }
        .padding(.vertical, 3)
    }

    private func content(ports mode: PortLinks.Mode, showStatus: Bool) -> some View {
        let c = container
        return HStack(spacing: 10) {
            Circle().fill(c.stateColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: c.displayName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(verbatim: c.image).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .help(c.name == c.displayName ? c.name : "\(c.name) (\(c.displayName))")
            Spacer(minLength: 12)
            PortLinks(ports: c.publishedPorts, mode: mode)
            if showStatus {
                Text(verbatim: c.status).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                    .frame(minWidth: 80, alignment: .trailing)
            }
            actions(c).frame(width: 52)
        }
    }

    @ViewBuilder
    private func actions(_ c: ContainerSummary) -> some View {
        if store.busy.contains(c.id) {
            ProgressView().controlSize(.small)
        } else {
            HStack(spacing: 6) {
                if c.isRunning {
                    Button { store.stop(c) } label: { Image(systemName: "stop.fill") }.help("Stop")
                    Button { store.restart(c) } label: { Image(systemName: "arrow.clockwise") }.help("Restart")
                } else {
                    Button { store.start(c) } label: { Image(systemName: "play.fill") }.help("Start")
                    Button { store.pendingRemoval = c } label: { Image(systemName: "trash") }.help("Remove")
                }
            }
            .buttonStyle(.borderless)
        }
    }
}

extension PortBinding {
    /// "8080→80", "6379", "1434→1434/udp". Built as a plain String so SwiftUI never applies
    /// locale digit grouping (which turned 10000 into "10 000" and made labels wrap).
    var label: String {
        guard let pub = publicPort else { return "" }
        let base = pub == privatePort ? String(pub) : String(pub) + "→" + String(privatePort)
        return type == "tcp" ? base : base + "/" + type
    }

    var url: URL? {
        guard type == "tcp", let pub = publicPort else { return nil }
        return URL(string: "http://localhost:" + String(pub))
    }
}

struct PortLinks: View {
    enum Mode { case all, first, menu }

    let ports: [PortBinding]
    var mode: Mode = .all

    var body: some View {
        if ports.isEmpty {
            EmptyView()
        } else {
            switch mode {
            case .all:
                HStack(spacing: 8) { ForEach(ports, id: \.self, content: link) }
            case .first:
                HStack(spacing: 6) {
                    link(ports[0])
                    if ports.count > 1 { more(ports.count - 1) }
                }
            case .menu:
                more(ports.count, icon: true)
            }
        }
    }

    @ViewBuilder
    private func link(_ p: PortBinding) -> some View {
        if let url = p.url {
            Link(destination: url) { Text(verbatim: p.label) }
                .font(.caption.monospacedDigit())
                .lineLimit(1).fixedSize()
                .help("Open " + url.absoluteString)
        } else {
            Text(verbatim: p.label)
                .font(.caption.monospacedDigit())
                .lineLimit(1).fixedSize()
        }
    }

    /// Compact menu listing every port, used when there isn't room to show them inline.
    private func more(_ n: Int, icon: Bool = false) -> some View {
        Menu {
            ForEach(ports, id: \.self) { p in
                if let url = p.url {
                    Button("Open " + p.label) { NSWorkspace.shared.open(url) }
                } else {
                    Text(verbatim: p.label)
                }
            }
        } label: {
            if icon {
                Label(String(n) + (n == 1 ? " port" : " ports"), systemImage: "network")
            } else {
                Text(verbatim: "+" + String(n))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .font(.caption)
        .fixedSize()
        .help(ports.map(\.label).joined(separator: ", "))
    }
}

/// Inspector content when several containers are selected.
struct MultiSelectionPanel: View {
    @Environment(Store.self) private var store
    let containers: [ContainerSummary]
    let onNewGroup: ([ContainerSummary]) -> Void
    let onClear: () -> Void

    var body: some View {
        let running = containers.filter(\.isRunning)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(containers.count) containers selected").font(.title3.bold())
                    Spacer()
                    Button("Clear", action: onClear).buttonStyle(.link)
                }
                Text("\(running.count) running · \(containers.count - running.count) stopped")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button { store.startAll(containers) } label: { Label("Start", systemImage: "play.fill") }
                        .disabled(running.count == containers.count)
                    Button { store.stopAll(containers) } label: { Label("Stop", systemImage: "stop.fill") }
                        .disabled(running.isEmpty)
                    Button { running.forEach(store.restart) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        .disabled(running.isEmpty)
                    Spacer()
                    Menu {
                        ForEach(store.customGroupNames, id: \.self) { name in
                            Button(name) { store.assign(containers, to: name) }
                        }
                        if !store.customGroupNames.isEmpty { Divider() }
                        Button("New Group…") { onNewGroup(containers) }
                        if containers.contains(where: { store.customGroups[$0.name] != nil }) {
                            Divider()
                            Button("Remove from Group") { store.assign(containers, to: nil) }
                        }
                    } label: {
                        Label("Group", systemImage: "folder")
                    }
                    .fixedSize()
                }
                .controlSize(.small)
            }
            .padding(14)
            Divider()
            List(containers) { c in
                HStack(spacing: 8) {
                    Circle().fill(c.stateColor).frame(width: 7, height: 7)
                    Text(c.name).lineLimit(1)
                    Spacer()
                    if let stack = store.stack(for: c) {
                        Text(stack.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

/// Right-click menu for the selected container(s).
struct SelectionMenu: View {
    @Environment(Store.self) private var store
    let containers: [ContainerSummary]
    let onNewGroup: ([ContainerSummary]) -> Void

    var body: some View {
        if containers.count == 1, let c = containers.first {
            ContainerMenu(container: c)
        } else if containers.count > 1 {
            Button("Start \(containers.count) Containers") { store.startAll(containers) }
            Button("Stop \(containers.count) Containers") { store.stopAll(containers) }
            Button("Restart \(containers.count) Containers") { containers.filter(\.isRunning).forEach(store.restart) }
        }
        if !containers.isEmpty {
            Divider()
            Menu("Move to Group") {
                ForEach(store.customGroupNames, id: \.self) { name in
                    Button(name) { store.assign(containers, to: name) }
                        .disabled(containers.allSatisfy { store.customGroups[$0.name] == name })
                }
                if !store.customGroupNames.isEmpty { Divider() }
                Button("New Group…") { onNewGroup(containers) }
            }
            if containers.contains(where: { store.customGroups[$0.name] != nil }) {
                Button("Remove from Group") { store.assign(containers, to: nil) }
            }
        }
    }
}

struct ContainerMenu: View {
    @Environment(Store.self) private var store
    let container: ContainerSummary

    var body: some View {
        let c = container
        if c.isRunning {
            Button("Stop") { store.stop(c) }
            Button("Restart") { store.restart(c) }
            Button("Pause") { store.pause(c) }
            Button("Open Shell in Terminal") { store.openShell(c) }
        } else {
            Button(c.isPaused ? "Resume" : "Start") { store.start(c) }
        }
        Divider()
        Button("Copy Container ID") { copy(c.id) }
        Button("Copy Name") { copy(c.name) }
        Divider()
        Button("Remove…", role: .destructive) { store.pendingRemoval = c }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct ContainerDetail: View {
    @Environment(Store.self) private var store
    let container: ContainerSummary

    var body: some View {
        let c = container
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(c.stateColor).frame(width: 10, height: 10)
                    Text(c.name).font(.title3.bold()).lineLimit(1).textSelection(.enabled)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow { Text("Image").foregroundStyle(.secondary); Text(c.image).textSelection(.enabled) }
                    GridRow { Text("Status").foregroundStyle(.secondary); Text(c.status) }
                    GridRow { Text("ID").foregroundStyle(.secondary); Text(String(c.id.prefix(12))).monospaced().textSelection(.enabled) }
                    if let stack = store.stack(for: c) {
                        GridRow {
                            Text(stack.kind == .compose ? "Compose" : stack.kind == .aspire ? "Aspire" : "Group").foregroundStyle(.secondary)
                            Text(stack.kind == .compose ? "\(stack.title) / \(c.composeService ?? "")" : stack.title)
                        }
                    }
                    if !c.publishedPorts.isEmpty {
                        GridRow {
                            Text("Ports").foregroundStyle(.secondary)
                            ViewThatFits(in: .horizontal) {
                                PortLinks(ports: c.publishedPorts)
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(c.publishedPorts, id: \.self) { PortLinks(ports: [$0]) }
                                }
                            }
                        }
                    }
                }
                .font(.callout)

                HStack {
                    if c.isRunning {
                        Button { store.stop(c) } label: { Label("Stop", systemImage: "stop.fill") }
                        Button { store.restart(c) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        Button { store.openShell(c) } label: { Label("Shell", systemImage: "terminal") }
                    } else {
                        Button { store.start(c) } label: { Label("Start", systemImage: "play.fill") }
                    }
                    Spacer()
                    Button(role: .destructive) { store.pendingRemoval = c } label: { Label("Remove", systemImage: "trash") }
                }
                .disabled(store.busy.contains(c.id))
                .controlSize(.small)
            }
            .padding(14)
            Divider()
            LogsView(containerID: c.id, isRunning: c.isRunning)
        }
    }
}
