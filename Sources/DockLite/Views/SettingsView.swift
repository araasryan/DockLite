import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @State private var colima = ColimaSettings()
    @State private var updater = Updater()

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ResourcesSettings(model: colima)
                .tabItem { Label("Resources", systemImage: "cpu") }
            EngineSettings(model: colima)
                .tabItem { Label("Docker Engine", systemImage: "shippingbox") }
            UpdatesSettings(updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 640, height: 580)
        .task { await colima.load(store: store) }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(Store.self) private var store
    @AppStorage(Prefs.autoStartColima) private var autoStartColima = false
    @AppStorage(Prefs.showMenuBar) private var showMenuBar = true
    @AppStorage(Prefs.logTail) private var logTail = 500
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open DockLite at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Start Colima when DockLite opens", isOn: $autoStartColima)
                    .disabled(Colima.binary == nil)
                Toggle("Show DockLite in the menu bar", isOn: $showMenuBar)
            }

            Section("Docker connection") {
                Picker("Socket", selection: Binding(get: { store.socketPath }, set: { store.useSocket($0) })) {
                    ForEach(socketOptions, id: \.self) { Text(shortPath($0)).tag($0) }
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(store.connected ? Color.green : Color.red).frame(width: 7, height: 7)
                        Text(store.connected ? "Connected · Docker \(store.info?.serverVersion ?? "")" : "Not connected")
                    }
                }
            }

            Section("Logs") {
                Picker("Lines to load when opening logs", selection: $logTail) {
                    ForEach([100, 500, 1000, 5000], id: \.self) { Text("\($0)").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var socketOptions: [String] {
        var list = SocketLocator.existing
        if !list.contains(store.socketPath) { list.insert(store.socketPath, at: 0) }
        return list
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

func shortPath(_ p: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}

// MARK: - Shared pieces

/// Shown instead of Colima-specific tabs when Colima isn't installed or its config can't be read.
struct ColimaUnavailable: View {
    let model: ColimaSettings

    var body: some View {
        if Colima.binary == nil {
            ContentUnavailableView("Colima isn't installed", systemImage: "shippingbox",
                                   description: Text("These settings manage Colima.\nInstall it with: brew install colima"))
        } else if let error = model.loadError {
            ContentUnavailableView("Couldn't load Colima settings", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else {
            ProgressView()
        }
    }
}

/// Bottom bar with Revert / Apply & Restart, shared by Resources and Docker Engine.
struct ApplyBar: View {
    @Environment(Store.self) private var store
    @Bindable var model: ColimaSettings
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.applyError {
                Text(error)
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if model.applying {
                    ProgressView().controlSize(.small)
                    Text("Restarting Colima…").font(.caption).foregroundStyle(.secondary)
                } else if model.hasChanges {
                    Text("Applying restarts Colima. Containers stop; ones with a restart policy start again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { model.revert() }
                    .disabled(!model.hasChanges || model.applying)
                Button("Apply & Restart") {
                    if store.runningCount > 0 { confirm = true } else { apply() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasChanges || !model.engineValid || model.applying || store.colimaBusy)
            }
        }
        .padding(12)
        .background(.bar)
        .confirmationDialog("Restart Colima to apply?", isPresented: $confirm) {
            Button("Apply & Restart") { apply() }
        } message: {
            Text("\(store.runningCount) running container\(store.runningCount == 1 ? "" : "s") will be stopped.")
        }
    }

    private func apply() { Task { await model.apply(store: store) } }
}

// MARK: - Resources

struct ResourcesSettings: View {
    @Environment(Store.self) private var store
    @Bindable var model: ColimaSettings

    var body: some View {
        if !model.loaded {
            ColimaUnavailable(model: model)
        } else {
            Form {
                Section {
                    Stepper(value: $model.resources.cpu, in: 1...max(model.hostCPUs, model.resources.cpu)) {
                        LabeledContent("CPUs", value: "\(model.resources.cpu) of \(model.hostCPUs)")
                    }
                    LabeledContent("Memory") {
                        HStack {
                            Slider(value: $model.resources.memoryGB,
                                   in: 1...Double(max(model.hostMemoryGB, Int(model.resources.memoryGB))), step: 1)
                            Text("\(Int(model.resources.memoryGB)) GB").monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                    Stepper(value: $model.resources.diskGB, in: model.originalResources.diskGB...4096, step: 10) {
                        LabeledContent("Disk", value: "\(model.resources.diskGB) GB")
                    }
                } header: {
                    Text("Virtual machine")
                } footer: {
                    Text("This Mac has \(model.hostCPUs) CPUs and \(model.hostMemoryGB) GB of memory. Disk size can only grow.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Use Rosetta for Intel (amd64) images", isOn: $model.resources.rosetta)
                        .disabled(!model.rosettaSupported || (!model.rosettaInstalled && !model.resources.rosetta))
                } header: {
                    Text("Emulation")
                } footer: {
                    Group {
                        if !model.rosettaSupported {
                            Text("Rosetta needs Colima's vz VM type (this profile uses \(model.vmType)).")
                        } else if !model.rosettaInstalled {
                            Text("Rosetta isn't installed. Run: softwareupdate --install-rosetta --agree-to-license")
                                .textSelection(.enabled)
                        } else {
                            Text("Runs linux/amd64 containers through Rosetta instead of QEMU, which is much faster.")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }

                Section("Kubernetes") {
                    Toggle("Enable Kubernetes (k3s)", isOn: $model.resources.kubernetes)
                }

                if let du = model.diskUsage {
                    Section("Docker disk usage") {
                        LabeledContent("Images", value: Format.bytes(du.images))
                        LabeledContent("Containers", value: Format.bytes(du.containers))
                        LabeledContent("Volumes", value: Format.bytes(du.volumes))
                        LabeledContent("Build cache", value: Format.bytes(du.buildCache))
                        LabeledContent("Total") { Text(Format.bytes(du.total)).fontWeight(.semibold) }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.applying)
            .safeAreaInset(edge: .bottom, spacing: 0) { ApplyBar(model: model) }
        }
    }
}

// MARK: - Docker Engine

struct EngineSettings: View {
    @Bindable var model: ColimaSettings

    var body: some View {
        if !model.loaded {
            ColimaUnavailable(model: model)
        } else {
            Form {
                if model.engineFromVM {
                    Section {
                        Label("colima.yaml sets docker: as block YAML, which DockLite can't edit in place. It loaded the live configuration instead; applying rewrites that key as JSON.",
                              systemImage: "info.circle")
                            .font(.callout)
                    }
                }

                Group {
                    Section {
                        ListField(title: "Registry mirrors", key: "registry-mirrors", prompt: "https://mirror.example.com", model: model)
                        ListField(title: "Insecure registries", key: "insecure-registries", prompt: "registry.local:5000", model: model)
                    } header: {
                        Text("Registries")
                    } footer: {
                        Text("Separate multiple values with commas.").font(.caption).foregroundStyle(.secondary)
                    }

                    Section {
                        Picker("Max log file size", selection: logOption("max-size")) {
                            Text("Unlimited").tag("")
                            ForEach(["10m", "50m", "100m", "500m"], id: \.self) { Text($0).tag($0) }
                        }
                        Picker("Log files kept", selection: logOption("max-file")) {
                            Text("Default").tag("")
                            ForEach(["1", "3", "5", "10"], id: \.self) { Text($0).tag($0) }
                        }
                    } header: {
                        Text("Container logs")
                    } footer: {
                        Text("Applies to containers created after the change. Log files kept requires a max size.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section("Engine") {
                        Toggle("BuildKit", isOn: featureFlag("buildkit", default: true))
                        Toggle("Debug logging", isOn: boolKey("debug"))
                    }
                }
                .disabled(!model.engineValid)

                Section {
                    TextEditor(text: $model.engineText)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                } header: {
                    Text("daemon.json overrides")
                } footer: {
                    if model.engineValid {
                        Text("Merged with Colima's defaults when Docker starts.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Not valid JSON", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                    }
                }

                if let effective = model.effectiveEngine {
                    Section {
                        DisclosureGroup("Live configuration in the VM") {
                            Text(effective)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.applying)
            .safeAreaInset(edge: .bottom, spacing: 0) { ApplyBar(model: model) }
        }
    }

    private func setKey(_ key: String, _ value: Any?) {
        var obj = model.engineObject ?? [:]
        obj[key] = value
        model.engineText = ColimaConfigFile.pretty(obj)
    }

    private func logOption(_ name: String) -> Binding<String> {
        Binding {
            ((model.engineObject?["log-opts"] as? [String: Any])?[name] as? String) ?? ""
        } set: { value in
            var opts = (model.engineObject?["log-opts"] as? [String: Any]) ?? [:]
            opts[name] = value.isEmpty ? nil : value
            setKey("log-opts", opts.isEmpty ? nil : opts)
        }
    }

    private func boolKey(_ key: String) -> Binding<Bool> {
        Binding {
            (model.engineObject?[key] as? Bool) ?? false
        } set: { on in
            setKey(key, on ? true : nil)
        }
    }

    private func featureFlag(_ name: String, default def: Bool) -> Binding<Bool> {
        Binding {
            ((model.engineObject?["features"] as? [String: Any])?[name] as? Bool) ?? def
        } set: { on in
            var features = (model.engineObject?["features"] as? [String: Any]) ?? [:]
            features[name] = on == def ? nil : on
            setKey("features", features.isEmpty ? nil : features)
        }
    }
}

/// Comma-separated editor for a string-array key. Keeps its own text so typing isn't reformatted mid-edit.
struct ListField: View {
    let title: String
    let key: String
    let prompt: String
    @Bindable var model: ColimaSettings
    @State private var text = ""

    private var stored: [String] { (model.engineObject?[key] as? [String]) ?? [] }

    private func parse(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .onAppear { text = stored.joined(separator: ", ") }
            .onChange(of: text) { _, new in
                let values = parse(new)
                guard values != stored, var obj = model.engineObject else { return }
                obj[key] = values.isEmpty ? nil : values
                model.engineText = ColimaConfigFile.pretty(obj)
            }
            .onChange(of: model.engineText) { _, _ in
                // External edits (JSON editor, Revert) win.
                if parse(text) != stored { text = stored.joined(separator: ", ") }
            }
    }
}

// MARK: - Updates

struct UpdatesSettings: View {
    @Environment(Store.self) private var store
    let updater: Updater
    @State private var confirmEngine = false

    var body: some View {
        Form {
            Section {
                ForEach(updater.components) { c in
                    ComponentRow(component: c, updater: updater) {
                        if c.kind == .engine { confirmEngine = true }
                        else { Task { await updater.update(c.id, store: store) } }
                    }
                }
            } header: {
                HStack {
                    Text("Components")
                    Spacer()
                    if updater.checking {
                        ProgressView().controlSize(.small)
                        Text("Checking…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Check Now") { Task { await updater.check(store: store) } }
                            .buttonStyle(.link)
                            .disabled(updater.updating != nil)
                    }
                }
            } footer: {
                if let date = updater.lastChecked {
                    Text("Last checked \(date.formatted(date: .omitted, time: .shortened)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if updater.needsColimaRestart {
                Section {
                    HStack {
                        Label("Restart Colima to start using the new version.", systemImage: "arrow.clockwise.circle")
                        Spacer()
                        Button("Restart Colima") { Task { await updater.restartColima(store: store) } }
                            .disabled(store.colimaBusy)
                    }
                }
            }

            if let error = updater.error {
                Section {
                    Text(error)
                        .font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Update All") { Task { await updater.updateAll(store: store) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.pending.isEmpty || updater.updating != nil || updater.checking)
            }
            .padding(12)
            .background(.bar)
        }
        .confirmationDialog("Update Docker Engine?", isPresented: $confirmEngine) {
            Button("Update & Restart Docker") { Task { await updater.update("engine", store: store) } }
        } message: {
            Text("Docker restarts inside the VM. Running containers stop; ones with a restart policy start again.")
        }
        .task {
            if updater.lastChecked == nil { await updater.check(store: store) }
        }
    }

    private var summary: String {
        if updater.lastChecked == nil { return "" }
        let n = updater.pending.count
        return n == 0 ? "Everything is up to date." : "\(n) update\(n == 1 ? "" : "s") available."
    }
}

struct ComponentRow: View {
    let component: Component
    let updater: Updater
    let onUpdate: () -> Void

    var body: some View {
        let c = component
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(c.name).fontWeight(.medium)
                if let detail = c.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let note = c.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            versionLabel(c)
            Group {
                if updater.updating == c.id {
                    ProgressView().controlSize(.small)
                } else if c.updateAvailable {
                    Button("Update", action: onUpdate)
                        .disabled(updater.updating != nil || updater.checking)
                }
            }
            .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func versionLabel(_ c: Component) -> some View {
        if let installed = c.installed {
            if c.updateAvailable, let latest = c.latest {
                HStack(spacing: 4) {
                    Text(installed).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    Text(latest).fontWeight(.semibold).foregroundStyle(Color.accentColor)
                }
                .monospacedDigit()
            } else {
                HStack(spacing: 4) {
                    Text(installed).monospacedDigit()
                    if c.latest != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Up to date")
                    }
                }
            }
        } else if !updater.checking && updater.lastChecked != nil {
            Text("—").foregroundStyle(.secondary)
        }
    }
}
