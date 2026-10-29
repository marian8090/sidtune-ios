import SIDLibrary
import SwiftUI
import UniformTypeIdentifiers

/// Port of src/ui/SettingsDialog.tsx, plus the offline copy of the collection.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var picking: Pick?
    @State private var importerShown = false
    @State private var confirmClear = false
    @State private var confirmDeleteOffline = false
    @State private var exportingBackup: BackupDocument?
    @State private var restoreURL: URL?

    enum Pick: Identifiable {
        case songlengths, stil, kernal, basic, chargen, backup
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Form {
                appearance
                sound
                if model.hvscAvailable { hvsc }
                collection
                roms
                backup
                library
                Section {
                    Button("About SIDtune") {
                        dismiss()
                        model.aboutOpen = true
                    }
                    Button("Help") {
                        dismiss()
                        model.helpOpen = true
                    }
                } footer: {
                    Text("SIDtune \(Bundle.main.version)")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg2)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $importerShown, allowedContentTypes: [.data, .plainText]) { result in
                guard case .success(let url) = result, let pick = picking else { return }
                switch pick {
                case .songlengths: model.importCollectionFile(url, kind: .songlengths)
                case .stil: model.importCollectionFile(url, kind: .stil)
                case .kernal: model.setROM(url, kind: \.kernal, size: 8192)
                case .basic: model.setROM(url, kind: \.basic, size: 8192)
                case .chargen: model.setROM(url, kind: \.chargen, size: 4096)
                case .backup: restoreURL = url
                }
            }
            .fileExporter(isPresented: Binding(get: { exportingBackup != nil }, set: { if !$0 { exportingBackup = nil } }),
                          document: exportingBackup, contentType: .json, defaultFilename: BackupDocument.defaultFilename) { result in
                if case .failure(let error) = result { model.message = "Could not save the backup: \(error.localizedDescription)" }
            }
            .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restoreURL != nil }, set: { if !$0 { restoreURL = nil } }),
                                titleVisibility: .visible, presenting: restoreURL) { url in
                Button("Restore", role: .destructive) { model.restoreBackup(from: url) }
            } message: { _ in
                Text("Your current favorites, playlists, history and settings are replaced.")
            }
            .confirmationDialog("Clear the library?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear library", role: .destructive) { model.wipeLibrary() }
            } message: {
                Text("Removes all imported tunes, song lengths and STIL notes from this device. Favorites and playlists are kept.")
            }
            .confirmationDialog("Remove the offline copy?", isPresented: $confirmDeleteOffline, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { model.deleteOfflineCollection() }
            } message: {
                Text("Tunes you have played stay cached; the rest stream again when you play them.")
            }
        }
    }

    private var appearance: some View {
        Section("Appearance") {
            Picker("Theme", selection: $model.settings.theme) {
                ForEach(ThemeID.allCases) { Text($0.label).tag($0) }
            }
            Picker("Font", selection: $model.settings.font) {
                ForEach(FontID.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Welcome on startup", isOn: $model.settings.showWelcome)
        }
        .listRowBackground(theme.panel)
    }

    private var sound: some View {
        Section {
            Picker("Emulation engine", selection: $model.settings.engine) {
                Text("reSIDfp (accurate)").tag(Settings.Engine.residfp)
                Text("SIDLite (fast)").tag(Settings.Engine.sidlite)
            }
            Picker("SID chip", selection: $model.settings.sidModel) {
                Text("Auto").tag(Settings.ChipChoice.auto)
                Text("Force 6581").tag(Settings.ChipChoice.mos6581)
                Text("Force 8580").tag(Settings.ChipChoice.mos8580)
            }
            Picker("Machine clock", selection: $model.settings.c64Model) {
                Text("Auto").tag(Settings.ClockChoice.auto)
                Text("Force PAL").tag(Settings.ClockChoice.pal)
                Text("Force NTSC").tag(Settings.ClockChoice.ntsc)
            }
            Toggle("Digi boost", isOn: $model.settings.digiBoost)
            Toggle("Instant seeking", isOn: $model.settings.seekCache)
            Stepper(value: $model.settings.defaultLengthSec, in: 10...3600, step: 10) {
                LabeledContent("Default length", value: formatTime(model.settings.defaultLengthSec))
            }
            Button("Audio quality and equalizer…") {
                dismiss()
                model.soundOpen = true
            }
        } header: {
            Text("Sound")
        } footer: {
            Text("""
            reSIDfp is the accurate reference; SIDLite is much lighter. Auto uses the chip and clock the tune asks for; PAL or NTSC \
            changes tempo and pitch. Digi boost makes samples audible on the 8580. Instant seeking renders each tune into memory in the \
            background (about 11 MB per minute) so seeking is immediate. The default length is used when a tune isn't in the song-length database.
            """)
        }
        .listRowBackground(theme.panel)
    }

    private var hvsc: some View {
        Section {
            Toggle("Download the HVSC catalogue", isOn: $model.settings.onlineCatalogue)
            if model.settings.onlineCatalogue {
                LabeledContent("Status", value: model.hvscStatus.text.isEmpty ? "—" : model.hvscStatus.text)
                Button("Check for a new release") { Task { await model.connectHVSC(forceRefresh: true) } }
                    .disabled(model.hvscStatus.state == .loading)
                let packs = model.offlinePacks
                if let d = model.packDownload {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(d.text).appFont(.footnote)
                        ProgressView(value: Double(d.done), total: Double(max(1, d.total)))
                        Text("\(bytes(d.done)) of \(bytes(d.total)). Keep SIDtune open until it finishes.")
                            .appFont(.caption)
                            .foregroundStyle(theme.muted)
                    }
                    Button("Cancel download", role: .destructive) { model.cancelCollectionDownload() }
                } else if packs.total > 0 && packs.have == packs.total {
                    LabeledContent("Offline copy", value: "Complete · \(bytes(packs.bytes))")
                    Button("Remove offline copy", role: .destructive) { confirmDeleteOffline = true }
                } else if model.hvscManifest != nil {
                    Button(packs.have > 0 ? "Finish downloading the collection (\(bytes(model.offlineTotalBytes - packs.bytes)))"
                                          : "Download the whole collection (\(bytes(model.offlineTotalBytes)))") {
                        model.downloadCollection()
                    }
                }
            }
        } header: {
            Text("Online HVSC")
        } footer: {
            Text("""
            Nothing is included with the app. Turning this on downloads the list of the whole High Voltage SID Collection (about \
            2 MB); tunes download the first time you play them and are kept for next time. Download the whole collection to play \
            everything offline. Turning it off removes the list.
            """)
        }
        .listRowBackground(theme.panel)
    }

    private var collection: some View {
        Section {
            Button { pick(.songlengths) } label: {
                LabeledContent("Song lengths", value: model.songlengths.map { "\($0.count.formatted()) tunes" } ?? "Not loaded")
            }
            Button { pick(.stil) } label: {
                LabeledContent("STIL notes", value: model.stil.isEmpty ? "Not loaded" : "\(model.stil.count.formatted()) entries")
            }
        } header: {
            Text("Collection data")
        } footer: {
            Text("HVSC's DOCUMENTS/Songlengths.md5 and DOCUMENTS/STIL.txt for imported tunes. Both are picked up automatically when you add an HVSC folder; the online catalogue has its own.")
        }
        .listRowBackground(theme.panel)
    }

    private var roms: some View {
        Section {
            romRow("KERNAL (8 KiB)", have: model.roms.kernal != nil, pick: .kernal)
            romRow("BASIC (8 KiB)", have: model.roms.basic != nil, pick: .basic)
            romRow("CHARGEN (4 KiB)", have: model.roms.chargen != nil, pick: .chargen)
            if model.roms != ROMSet() {
                Button("Remove ROMs", role: .destructive) { model.clearROMs() }
            }
        } header: {
            Text("C64 ROMs (optional)")
        } footer: {
            Text("A minority of tunes (RSID, BASIC-driven) need the C64's own ROMs to run. They are copyrighted, so SIDtune cannot include them. If you own copies, add all three.")
        }
        .listRowBackground(theme.panel)
    }

    private func romRow(_ label: String, have: Bool, pick: Pick) -> some View {
        Button { self.pick(pick) } label: {
            LabeledContent(label) {
                Image(systemName: have ? "checkmark.circle.fill" : "plus.circle").foregroundStyle(have ? theme.accentStrong : theme.muted)
            }
        }
    }

    private var backup: some View {
        Section {
            Button("Save backup") { exportingBackup = model.backupDocument() }
            Button("Restore a backup") { pick(.backup) }
        } header: {
            Text("Backup")
        } footer: {
            Text("""
            Saves your \(model.favorites.count.formatted()) favorites and \(model.playlists.count) playlists, plus history and \
            settings, as a small file. It is the same file the SIDtune web app saves, so you can move between the two or to \
            another device. Restoring replaces what's here. Imported tunes are not included.
            """)
        }
        .listRowBackground(theme.panel)
    }

    private var library: some View {
        Section {
            LabeledContent("Imported tunes", value: model.localTunes.count.formatted())
            Button("Clear library", role: .destructive) { confirmClear = true }
                .disabled(model.localTunes.isEmpty && model.songlengths == nil && model.stil.isEmpty)
        } header: {
            Text("Library")
        } footer: {
            Text("Removes imported tunes, song lengths and STIL. Favorites and playlists are kept.")
        }
        .listRowBackground(theme.panel)
    }

    /// `picking` outlives the importer's isPresented binding, which is reset before the completion handler runs.
    private func pick(_ p: Pick) {
        picking = p
        importerShown = true
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

extension Bundle {
    var version: String { (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?" }
}
