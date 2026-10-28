import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @Binding var selection: AppModel.View?
    @Environment(\.theme) private var theme
    @State private var creating = false
    @State private var renaming: Playlist?
    @State private var name = ""
    @State private var importing = false

    var body: some View {
        List(selection: $selection) {
            Section {
                row("Library", icon: "music.note.house", count: model.tunes.count).tag(AppModel.View.all)
                row("Favorites", icon: "heart", count: model.favorites.count).tag(AppModel.View.favorites)
                row("History", icon: "clock", count: model.history.count).tag(AppModel.View.history)
            }
            Section {
                ForEach(model.playlists) { p in
                    row(p.name, icon: "music.note.list", count: p.paths.count)
                        .tag(AppModel.View.playlist(p.id))
                        .contextMenu {
                            Button { model.playPaths(p.paths) } label: { Label("Play", systemImage: "play") }
                            Button {
                                name = p.name
                                renaming = p
                            } label: { Label("Rename…", systemImage: "pencil") }
                            Button(role: .destructive) { model.deletePlaylist(p.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions {
                            Button(role: .destructive) { model.deletePlaylist(p.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                }
                Button {
                    name = ""
                    creating = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                        .foregroundStyle(theme.accentStrong)
                }
            } header: {
                Text("Playlists").appFont(.caption)
            }
            Section {
                Button { importing = true } label: { Label("Add folder, files or zip…", systemImage: "folder.badge.plus") }
                    .disabled(model.importProgress != nil)
                if let p = model.importProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.total > 0 ? "Importing \(p.done.formatted()) of \(p.total.formatted())…" : "Reading files…").appFont(.footnote)
                        ProgressView(value: p.total > 0 ? Double(p.done) / Double(p.total) : 0)
                    }
                }
                if model.hvscStatus.state != .off {
                    HStack(spacing: 8) {
                        if model.hvscStatus.state == .loading { ProgressView().controlSize(.small) }
                        Text(model.hvscStatus.text)
                            .appFont(.footnote)
                            .foregroundStyle(model.hvscStatus.state == .error ? .red : theme.muted)
                    }
                }
                Button { model.settingsOpen = true } label: { Label("Settings", systemImage: "gearshape") }
                Button { model.helpOpen = true } label: { Label("Help", systemImage: "questionmark.circle") }
                Button { model.aboutOpen = true } label: { Label("About SIDtune", systemImage: "info.circle") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.bg2)
        .navigationTitle("SIDtune")
        .fileImporter(isPresented: $importing, allowedContentTypes: TrackListView.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importItems(urls) }
        }
        .alert("New playlist", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Create") { selection = .playlist(model.createPlaylist(name).id) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Rename") { if let p = renaming { model.renamePlaylist(p.id, name: name) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ title: String, icon: String, count: Int) -> some View {
        Label {
            HStack {
                Text(title).appFont(.body).lineLimit(1)
                Spacer()
                Text(count.formatted()).appFont(.footnote).monospacedDigit().foregroundStyle(theme.muted)
            }
        } icon: {
            Image(systemName: icon)
        }
    }
}
