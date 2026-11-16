import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable {
    case containers = "Containers"
    case images = "Images"

    var icon: String { self == .containers ? "shippingbox" : "square.stack.3d.up" }
}

struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var section: SidebarItem = .containers

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $section) {
                ForEach(SidebarItem.allCases, id: \.self) { s in
                    Label(s.rawValue, systemImage: s.icon)
                        .badge(s == .containers ? store.runningCount : store.images.count)
                        .tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { EngineStatus().padding(10) }
        } detail: {
            if store.connected {
                switch section {
                case .containers: ContainersView()
                case .images: ImagesView()
                }
            } else if store.checkedOnce {
                DisconnectedView()
            } else {
                ProgressView("Connecting to Docker…")
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                Text(notice)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.notice)
        .alert("Something went wrong", isPresented: Binding(
            get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alert ?? "")
        }
        .confirmationDialog(
            "Remove container “\(store.pendingRemoval?.name ?? "")”?",
            isPresented: Binding(get: { store.pendingRemoval != nil }, set: { if !$0 { store.pendingRemoval = nil } }),
            presenting: store.pendingRemoval
        ) { c in
            Button("Remove", role: .destructive) { store.remove(c) }
        } message: { c in
            Text(c.isRunning ? "It is running and will be stopped. Its filesystem changes will be lost." :
                 "Its filesystem changes will be lost. Volumes are kept.")
        }
    }
}

struct EngineStatus: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(store.connected ? Color.green : Color.red).frame(width: 7, height: 7)
                Text(store.connected ? "Engine running" : "Engine stopped").font(.caption.weight(.medium))
                Spacer()
                Menu {
                    Section("Docker socket") {
                        ForEach(SocketLocator.existing, id: \.self) { path in
                            Button {
                                store.useSocket(path)
                            } label: {
                                if path == store.socketPath { Label(shortPath(path), systemImage: "checkmark") }
                                else { Text(shortPath(path)) }
                            }
                        }
                    }
                    Divider()
                    SettingsLink { Text("Settings…") }
                    if Colima.binary != nil {
                        Divider()
                        if store.connected {
                            Button("Stop Colima", action: store.stopColima).disabled(store.colimaBusy)
                        } else {
                            Button("Start Colima", action: store.startColima).disabled(store.colimaBusy)
                        }
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if let info = store.info {
                Text("Docker \(info.serverVersion ?? "?") · \(info.ncpu ?? 0) CPU · \(Format.bytes(info.memTotal ?? 0))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(shortPath(store.socketPath)).font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

struct DisconnectedView: View {
    @Environment(Store.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("Docker isn't running", systemImage: "shippingbox")
        } description: {
            Text("No Docker engine is answering at\n\(store.socketPath)")
        } actions: {
            if Colima.binary != nil {
                Button {
                    store.startColima()
                } label: {
                    if store.colimaBusy {
                        HStack { ProgressView().controlSize(.small); Text("Starting Colima…") }
                    } else {
                        Text("Start Colima")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.colimaBusy)
            } else {
                Text("Install Colima first:\nbrew install colima docker").font(.callout.monospaced())
            }
        }
    }
}
