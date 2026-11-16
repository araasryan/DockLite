import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Keep running in the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct DockLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store()
    @AppStorage(Prefs.showMenuBar) private var showMenuBar = true

    var body: some Scene {
        Window("DockLite", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 720)

        Settings {
            SettingsView().environment(store)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent().environment(store)
        } label: {
            MenuBarLabel().environment(store)
        }
    }
}
