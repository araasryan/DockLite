import SwiftUI

struct MenuBarLabel: View {
    @Environment(Store.self) private var store

    var body: some View {
        let running = store.runningCount
        HStack(spacing: 3) {
            Image(systemName: store.connected ? "shippingbox.fill" : "shippingbox")
            if running > 0 { Text("\(running)") }
        }
    }
}

struct MenuBarContent: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.connected {
            Text("\(store.runningCount) running · Docker \(store.info?.serverVersion ?? "")")
            Divider()
            ForEach(store.containers.prefix(25)) { c in
                Menu((c.isRunning ? "● " : "○ ") + c.name) {
                    if c.isRunning {
                        Button("Stop") { store.stop(c) }
                        Button("Restart") { store.restart(c) }
                        Button("Open Shell") { store.openShell(c) }
                        ForEach(c.publishedPorts.filter { $0.url != nil }, id: \.self) { p in
                            Button("Open localhost:" + String(p.publicPort ?? 0)) { NSWorkspace.shared.open(p.url!) }
                        }
                    } else {
                        Button("Start") { store.start(c) }
                    }
                }
            }
            if store.containers.isEmpty { Text("No containers") }
        } else {
            Text("Docker engine is not running")
        }

        Divider()
        Button("Open DockLite") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        if Colima.binary != nil {
            if store.connected {
                Button("Stop Colima", action: store.stopColima).disabled(store.colimaBusy)
            } else {
                Button(store.colimaBusy ? "Starting Colima…" : "Start Colima", action: store.startColima)
                    .disabled(store.colimaBusy)
            }
        }
        Divider()
        Button("Quit DockLite") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
