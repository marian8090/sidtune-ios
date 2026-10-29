import SIDLibrary
import SwiftUI
import UniformTypeIdentifiers

struct TrackListView: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var importing = false
    @State private var newPlaylistFor: String?
    @State private var newPlaylistName = ""

    var body: some View {
        list
            .navigationTitle(model.viewTitle(model.view))
            .navigationBarTitleDisplayMode(hSize == .compact ? .large : .inline)
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Title, composer, year or path")
            .toolbar { toolbar }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.importItems(urls) }
            }
            .alert("New playlist", isPresented: newPlaylistShown) {
                TextField("Name", text: $newPlaylistName)
                Button("Create", action: createPlaylist)
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
            }
    }

    private var list: some View {
        List {
            if !model.visible.isEmpty {
                header
            }
            ForEach(model.visible) { t in row(t) }
                .onMove(perform: moveAction)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .overlay { emptyState }
    }

    private var newPlaylistShown: Binding<Bool> {
        Binding(get: { newPlaylistFor != nil }, set: { if !$0 { newPlaylistFor = nil } })
    }

    private func createPlaylist() {
        if let path = newPlaylistFor { model.createPlaylist(newPlaylistName, firstPath: path) }
        newPlaylistName = ""
    }

    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard movable else { return nil }
        return { from, to in move(from, to) }
    }

    static let importTypes: [UTType] = [.folder, .zip, .sidTune, .data]

    private func row(_ t: TuneMeta) -> some View {
        let favorite = model.isFavorite(t.path)
        let isCurrent = t.path == model.current?.path
        return Button {
            model.playFromList(t.path)
        } label: {
            TrackRow(model: model, tune: t)
        }
        .buttonStyle(.plain)
        .listRowBackground(isCurrent ? theme.accent.opacity(0.22) : theme.bg)
        .swipeActions(edge: .leading) {
            Button {
                model.toggleFavorite(t.path)
            } label: {
                Label(favorite ? "Unfavorite" : "Favorite", systemImage: favorite ? "heart.slash" : "heart")
            }
            .tint(.pink)
        }
        .swipeActions(edge: .trailing) { removeAction(t) }
        .contextMenu { menu(for: t) }
    }

    @ViewBuilder
    private func removeAction(_ t: TuneMeta) -> some View {
        if case .playlist(let id) = model.view {
            Button(role: .destructive) { model.removeFromPlaylist(id, path: t.path) } label: { Label("Remove", systemImage: "minus.circle") }
        }
    }

    private var movable: Bool {
        if case .playlist = model.view { return model.query.isEmpty }
        return false
    }

    private func move(_ from: IndexSet, _ to: Int) {
        if case .playlist(let id) = model.view { model.movePlaylistItems(id, from: from, to: to) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("\(model.visible.count.formatted()) tune\(model.visible.count == 1 ? "" : "s")")
                .appFont(.footnote)
                .foregroundStyle(theme.muted)
            Spacer()
            Button {
                model.playPaths(model.visible.map(\.path))
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .fixedSize()
            Button {
                let paths = model.visible.map(\.path)
                model.settings.shuffle = true
                model.playPaths(paths, first: Int.random(in: 0..<paths.count))
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            // In the iPad's middle column next to Now Playing the label otherwise wraps to "Shuff / le".
            .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .listRowBackground(theme.bg)
        .listRowSeparator(.hidden)
        .moveDisabled(true)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.visible.isEmpty {
            if !model.query.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
                switch model.view {
                case .all:
                    if model.hvscStatus.state == .loading {
                        ContentUnavailableView {
                            Label("Loading the HVSC catalogue", systemImage: "arrow.down.circle")
                        } description: {
                            Text(model.hvscStatus.text)
                        } actions: {
                            ProgressView()
                        }
                    } else if model.hvscAvailable && !model.settings.onlineCatalogue {
                        ContentUnavailableView {
                            Label("Your library is empty", systemImage: "music.note.list")
                        } description: {
                            Text("""
                            Download the High Voltage SID Collection: the list of all 60,000+ tunes (about 2 MB), with each tune \
                            fetched the first time you play it. Or add your own .sid files, a .zip or an unpacked HVSC folder.
                            """)
                        } actions: {
                            Button("Download the HVSC") { model.settings.onlineCatalogue = true }.buttonStyle(.borderedProminent)
                            Button("Add my own music…") { importing = true }
                        }
                    } else {
                        ContentUnavailableView {
                            Label("Your library is empty", systemImage: "music.note.list")
                        } description: {
                            Text(model.hvscStatus.state == .error ? model.hvscStatus.text : "Add an unpacked HVSC folder (C64Music), .sid files or a .zip.")
                        } actions: {
                            if model.hvscStatus.state == .error {
                                Button("Try again") { Task { await model.connectHVSC() } }.buttonStyle(.borderedProminent)
                            }
                            Button("Add music…") { importing = true }
                        }
                    }
                case .favorites:
                    ContentUnavailableView("No favorites yet", systemImage: "heart", description: Text("Swipe right on a tune or tap the heart to add it here."))
                case .history:
                    ContentUnavailableView("Nothing played yet", systemImage: "clock", description: Text("Tunes you play show up here."))
                case .playlist:
                    ContentUnavailableView("This playlist is empty", systemImage: "music.note.list", description: Text("Long-press a tune and choose Add to Playlist."))
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.view == .all {
                Menu {
                    Picker("Sort by", selection: $model.sortKey) {
                        ForEach(AppModel.SortKey.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Descending", isOn: $model.sortDesc)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            if movable {
                EditButton()
            }
            if case .history = model.view, !model.history.isEmpty {
                Button("Clear", role: .destructive) { model.clearHistory() }
            }
            Button {
                importing = true
            } label: {
                Label("Add music", systemImage: "plus")
            }
            .disabled(model.importProgress != nil)
        }
    }

    @ViewBuilder
    private func menu(for t: TuneMeta) -> some View {
        Button { model.playFromList(t.path) } label: { Label("Play", systemImage: "play") }
        Button { model.toggleFavorite(t.path) } label: {
            Label(model.isFavorite(t.path) ? "Remove from Favorites" : "Add to Favorites", systemImage: model.isFavorite(t.path) ? "heart.slash" : "heart")
        }
        Menu {
            ForEach(model.playlists) { p in
                Button(p.name) { model.addToPlaylist(p.id, path: t.path) }
            }
            Button { newPlaylistFor = t.path } label: { Label("New Playlist…", systemImage: "plus") }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
        if case .playlist(let id) = model.view {
            Button(role: .destructive) { model.removeFromPlaylist(id, path: t.path) } label: { Label("Remove from Playlist", systemImage: "minus.circle") }
        }
        ShareLink(item: model.shareURL(for: t), message: Text("\(t.title) by \(t.author)")) { Label("Share", systemImage: "square.and.arrow.up") }
    }
}

struct TrackRow: View {
    let model: AppModel
    let tune: TuneMeta
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if tune.path == model.current?.path {
                        Image(systemName: model.playing ? "speaker.wave.2.fill" : "speaker.fill")
                            .font(.caption)
                            .foregroundStyle(theme.accentStrong)
                    }
                    Text(tune.title)
                        .appFont(.body)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                }
                Text([tune.author, tune.released].filter { !$0.isEmpty }.joined(separator: " · "))
                    .appFont(.footnote)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.isFavorite(tune.path) {
                Image(systemName: "heart.fill").font(.caption).foregroundStyle(theme.accentStrong)
            }
            if tune.songs > 1 {
                Text("\(tune.songs)")
                    .appFont(.caption2)
                    .foregroundStyle(theme.muted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().stroke(theme.muted.opacity(0.5)))
                    .accessibilityLabel("\(tune.songs) subtunes")
            }
            if let len = length {
                Text(formatTime(len))
                    .appFont(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(theme.muted)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var length: Double? {
        if let l = tune.lengths, tune.startSong - 1 < l.count { return l[tune.startSong - 1] }
        return model.songlengths?.length(path: tune.path, song: tune.startSong)
    }
}

extension UTType {
    static let sidTune = UTType(importedAs: "com.marianfujara.sidtune.sid", conformingTo: .data)
}
