import SwiftUI

struct ImageRow: Identifiable, Hashable {
    let id: String          // tag reference, or image id when untagged
    let imageID: String
    let shortID: String
    let repository: String
    let tag: String
    let size: Int64
    let created: Date
    let usedBy: Int
}

struct ImagesView: View {
    @Environment(Store.self) private var store
    @State private var selection = Set<ImageRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\ImageRow.created, order: .reverse)]
    @State private var search = ""
    @State private var showPull = false

    private var rows: [ImageRow] {
        let usage = Dictionary(grouping: store.containers, by: \.imageID).mapValues(\.count)
        let all = store.images.flatMap { img -> [ImageRow] in
            let used = usage[img.id] ?? 0
            if img.repoTags.isEmpty {
                return [ImageRow(id: img.id, imageID: img.id, shortID: img.shortID, repository: "<none>",
                                 tag: "<none>", size: img.size, created: img.created, usedBy: used)]
            }
            return img.repoTags.map { ref in
                let (repo, tag) = DockerClient.splitReference(ref)
                return ImageRow(id: ref, imageID: img.id, shortID: img.shortID, repository: repo,
                                tag: tag, size: img.size, created: img.created, usedBy: used)
            }
        }
        let filtered = search.isEmpty ? all : all.filter {
            $0.repository.localizedCaseInsensitiveContains(search) || $0.tag.localizedCaseInsensitiveContains(search)
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = rows
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Repository", value: \.repository) { r in
                Text(r.repository).foregroundStyle(r.repository == "<none>" ? .secondary : .primary)
            }
            TableColumn("Tag", value: \.tag)
                .width(min: 60, ideal: 110)
            TableColumn("Image ID") { r in
                Text(r.shortID).monospaced().foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Created", value: \.created) { r in
                Text(Format.relative(r.created))
            }
            .width(min: 70, ideal: 100)
            TableColumn("Size", value: \.size) { r in
                Text(Format.bytes(r.size)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Used by", value: \.usedBy) { r in
                Text(r.usedBy > 0 ? "\(r.usedBy) container\(r.usedBy == 1 ? "" : "s")" : "—")
                    .foregroundStyle(r.usedBy > 0 ? .primary : .secondary)
            }
            .width(min: 70, ideal: 100)
        }
        .contextMenu(forSelectionType: ImageRow.ID.self) { ids in
            if !ids.isEmpty {
                Button("Remove \(ids.count == 1 ? "Image" : "\(ids.count) Images")", role: .destructive) { remove(ids) }
                if ids.count == 1, let id = ids.first {
                    Button("Copy Name") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(id, forType: .string)
                    }
                }
            }
        }
        .onDeleteCommand { remove(selection) }
        .overlay {
            if store.images.isEmpty {
                ContentUnavailableView("No images", systemImage: "square.stack.3d.up",
                                       description: Text("Pull one with the + button."))
            }
        }
        .navigationTitle("Images")
        .navigationSubtitle("\(store.images.count) images · \(Format.bytes(store.images.reduce(0) { $0 + $1.size }))")
        .searchable(text: $search, placement: .toolbar, prompt: "Filter images")
        .toolbar {
            ToolbarItemGroup {
                Button { showPull = true } label: { Label("Pull image", systemImage: "plus") }
                    .help("Pull an image")
                Button { remove(selection) } label: { Label("Remove", systemImage: "trash") }
                    .disabled(selection.isEmpty)
                    .help("Remove selected images")
                Menu {
                    Button("Remove dangling images") { store.pruneImages(allUnused: false) }
                    Button("Remove all unused images") { store.pruneImages(allUnused: true) }
                } label: {
                    Label("Prune", systemImage: "wand.and.sparkles")
                }
                .help("Prune images")
                .disabled(store.busy.contains("prune"))
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
            }
        }
        .sheet(isPresented: $showPull) { PullSheet() }
    }

    private func remove(_ ids: Set<ImageRow.ID>) {
        ids.forEach(store.removeImage)
        selection.subtract(ids)
    }
}

struct PullSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""
    @State private var progress = ""
    @State private var pulling = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pull image").font(.headline)
            TextField("e.g. nginx:alpine or ghcr.io/org/app:1.2", text: $reference)
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)
                .disabled(pulling)
                .onSubmit(pull)
            if pulling || !progress.isEmpty {
                HStack(spacing: 8) {
                    if pulling { ProgressView().controlSize(.small) }
                    Text(progress).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(pulling)
                Button("Pull", action: pull).keyboardShortcut(.defaultAction)
                    .disabled(pulling || reference.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func pull() {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty, !pulling else { return }
        pulling = true
        error = nil
        Task {
            do {
                try await store.client.pull(ref) { line in
                    DispatchQueue.main.async { progress = line }
                }
                await store.refresh()
                store.show("Pulled \(ref)")
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            pulling = false
        }
    }
}
