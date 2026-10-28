import SIDLibrary
import SwiftUI

/// Port of src/ui/NowPlaying.tsx. On iPhone it also carries the full transport, since the mini player only has play and next.
struct NowPlayingView: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.dismiss) private var dismiss
    @State private var newPlaylist = false
    @State private var playlistName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                if let t = model.current {
                    content(t)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                } else {
                    ContentUnavailableView("Nothing playing", systemImage: "music.note", description: Text("Pick a tune from the library."))
                        .padding(.top, 60)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg2)
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if hSize == .compact {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "chevron.down") }
                            .accessibilityLabel("Close")
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.nowPlayingOpen = false } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                }
            }
        }
        .alert("New playlist", isPresented: $newPlaylist) {
            TextField("Name", text: $playlistName)
            Button("Create") {
                if let t = model.current { model.createPlaylist(playlistName, firstPath: t.path) }
                playlistName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Laid out to fit an iPhone screen down to the start of the STIL notes: no cover, voices and actions share a row,
    /// and subtunes scroll sideways.
    @ViewBuilder
    private func content(_ t: TuneMeta) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(t.title).appFont(.title3).fontWeight(.bold).multilineTextAlignment(.center).lineLimit(2).foregroundStyle(theme.text)
                Text([t.author, t.released].filter { !$0.isEmpty }.joined(separator: " · "))
                    .appFont(.subheadline)
                    .foregroundStyle(theme.accentStrong)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(t.summary + (model.lengthKnown ? "" : " · length unknown, using default"))
                    .appFont(.caption)
                    .foregroundStyle(theme.muted)
            }
            .padding(.top, 4)

            if hSize == .compact {
                VStack(spacing: 10) {
                    SeekBar(model: model)
                    Transport(model: model)
                    HStack(spacing: 16) {
                        VolumeSlider(model: model)
                        SoundButton(model: model)
                    }
                }
            }

            VizView(model: model, compact: hSize == .compact)

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { v in
                    Chip(label: "V\(v + 1)", on: !model.voiceMuted[v]) { model.toggleVoice(v) }
                        .accessibilityLabel("Voice \(v + 1) \(model.voiceMuted[v] ? "muted" : "on")")
                }
                Spacer(minLength: 4)
                actions(t)
            }

            let songs = model.details?.songs ?? t.songs
            if songs > 1 {
                HStack(spacing: 8) {
                    Text("Subtune").appFont(.caption).foregroundStyle(theme.muted)
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(0..<songs, id: \.self) { i in
                                    Chip(label: "\(i + 1)", on: model.songIndex == i) { model.selectSong(i) }.id(i)
                                }
                            }
                        }
                        .onAppear { proxy.scrollTo(model.songIndex, anchor: .center) }
                        .onChange(of: model.songIndex) { proxy.scrollTo(model.songIndex, anchor: .center) }
                    }
                }
            }

            if let note = model.stilFor(t.path) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("STIL").appFont(.headline).foregroundStyle(theme.text)
                    ForEach(Array(Self.stilEntries(note).enumerated()), id: \.offset) { _, entry in
                        if let field = entry.field {
                            (Text(field + "  ").fontWeight(.semibold).foregroundStyle(theme.text) + Text(entry.text).foregroundStyle(theme.muted))
                                .appFont(.footnote)
                        } else {
                            Text(entry.text).appFont(.footnote).fontWeight(.semibold).foregroundStyle(theme.accentStrong).padding(.top, 4)
                        }
                    }
                    .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.panel))
            }

            Text(t.path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.muted)
                .textSelection(.enabled)
        }
    }

    /// STIL wraps long fields onto lines indented under the text; join them back up. "(#3)" lines head a subtune's notes.
    static func stilEntries(_ note: String) -> [(field: String?, text: String)] {
        var out: [(field: String?, text: String)] = []
        for raw in note.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("(#") {
                out.append((nil, "Subtune " + line.trimmingCharacters(in: CharacterSet(charactersIn: "(#)"))))
            } else if let colon = line.firstIndex(of: ":"), line[..<colon].allSatisfy({ $0.isUppercase }), !line[..<colon].isEmpty {
                out.append((String(line[..<colon]).capitalized, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            } else if let last = out.last, last.field != nil {
                out[out.count - 1].text += " " + line
            } else {
                out.append(("", line))
            }
        }
        return out
    }

    private func actions(_ t: TuneMeta) -> some View {
        HStack(spacing: 6) {
            Button { model.toggleFavorite(t.path) } label: {
                Label("Favorite", systemImage: model.isFavorite(t.path) ? "heart.fill" : "heart")
            }
            Menu {
                ForEach(model.playlists) { p in Button(p.name) { model.addToPlaylist(p.id, path: t.path) } }
                Button { newPlaylist = true } label: { Label("New Playlist…", systemImage: "plus") }
            } label: {
                Label("Playlist", systemImage: "text.badge.plus")
            }
            ShareLink(item: model.shareURL(for: t), message: Text("\(t.title) by \(t.author)")) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

struct Chip: View {
    let label: String
    let on: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(label)
                .appFont(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
                .frame(minWidth: 32)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(on ? theme.accentInk : theme.muted)
                .background(Capsule().fill(on ? theme.accentStrong : theme.panel2))
        }
        .buttonStyle(.plain)
    }
}
