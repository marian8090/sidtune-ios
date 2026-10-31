import AVFoundation
import Foundation
import Observation
import SIDEngine
import SIDFX
import SIDLibrary
import UIKit

/// All app state plus the playback, queue, library and playlist logic. Port of src/state.ts.
@MainActor @Observable
final class AppModel {
    enum View: Hashable {
        case all, favorites, history, playlist(String)
    }

    enum SortKey: String, CaseIterable {
        case path, title, author, released

        var label: String {
            switch self {
            case .path: "Path"
            case .title: "Title"
            case .author: "Composer"
            case .released: "Released"
            }
        }
    }

    struct HVSCStatus: Equatable {
        enum State { case off, loading, ready, error }
        var state = State.off
        var text = ""
    }

    struct PackDownload: Equatable {
        var done: Int64
        var total: Int64
        var text: String
    }

    // MARK: Library

    private(set) var localTunes: [TuneMeta] = []
    private(set) var remoteTunes: [TuneMeta] = []
    /// Imported tunes win over the online catalogue when both have the same path.
    private(set) var tunes: [TuneMeta] = []
    private(set) var tuneMap: [String: TuneMeta] = [:]
    @ObservationIgnored private var indexOfPath: [String: Int] = [:]
    @ObservationIgnored private var searchIndex = SearchIndex([])
    @ObservationIgnored private var sortOrders: [String: [Int]] = [:]
    @ObservationIgnored private var remoteParts: [String] = []
    private(set) var hvscStatus = HVSCStatus()
    private(set) var hvscManifest: HVSCCatalogue.Manifest?
    private(set) var packDownload: PackDownload?
    @ObservationIgnored private var packTask: Task<Void, Never>?
    private(set) var songlengths: Songlengths?
    private(set) var stil: [String: String] = [:]
    private(set) var remoteStil: [String: String] = [:]
    private(set) var roms = ROMSet()
    private(set) var importProgress: (done: Int, total: Int)?
    let hvscAvailable = HVSCClient.baseURL != nil

    var settings = Settings.load() {
        didSet { settingsChanged(from: oldValue) }
    }

    private(set) var collections = Storage.readJSON(UserCollections.self, from: Storage.collections) ?? UserCollections() {
        didSet {
            Storage.writeJSON(collections, to: Storage.collections)
            if visibleDependsOnCollections { refreshVisible() }
        }
    }

    var favorites: [String] { collections.favorites }
    var playlists: [Playlist] { collections.playlists }
    var history: [String] { collections.history }
    func isFavorite(_ path: String) -> Bool { collections.favorites.contains(path) }

    // MARK: List

    var view = View.all { didSet { refreshVisible() } }
    var query = "" { didSet { refreshVisible() } }
    var sortKey = SortKey.path { didSet { refreshVisible() } }
    var sortDesc = false { didSet { refreshVisible() } }
    private(set) var visible: [TuneMeta] = []
    private var visibleDependsOnCollections: Bool { view != .all }

    // MARK: Playback

    private(set) var current: TuneMeta?
    /// 0-based, like the web app's `song` signal.
    private(set) var songIndex = 0
    private(set) var details: SIDTuneInfo?
    private(set) var playing = false
    private(set) var loading = false
    private(set) var seeking = false
    private(set) var busy = false
    private(set) var position = 0.0
    private(set) var duration = 180.0
    private(set) var lengthKnown = false
    private(set) var voiceMuted = [false, false, false]
    /// Progress of the background render for instant seeking; nil when the current tune isn't being pre-rendered.
    private(set) var prerender: PlaybackEngine.Prerender?
    var message: String?
    var nowPlayingOpen = false
    var settingsOpen = false
    var soundOpen = false
    var aboutOpen = false
    var helpOpen = false

    @ObservationIgnored private var engine: PlaybackEngine?
    @ObservationIgnored private var currentData: [UInt8]?
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var queueIndex = -1
    /// The list the queue was started from. While it is on screen, the queue follows it, so a new search or sort changes what plays next.
    @ObservationIgnored private var queueView: View?
    @ObservationIgnored private var played: [String] = []
    @ObservationIgnored private var playToken = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let nowPlaying = NowPlayingCenter()
    @ObservationIgnored private var lastNowPlayingUpdate = Date.distantPast

    init() {
        aboutOpen = settings.showWelcome
    }

    // MARK: Boot

    func boot() async {
        do {
            engine = try PlaybackEngine()
        } catch {
            message = "Audio could not start: \(error.localizedDescription)"
        }
        engine?.setVolume(settings.volume)
        engine?.setFXMode(settings.fxMode)
        engine?.setEQ(settings.eq)
        roms = Storage.readJSON(ROMSet.self, from: Storage.roms) ?? ROMSet()

        let loaded = await Task.detached(priority: .userInitiated) {
            let local = Storage.readJSON([TuneMeta].self, from: Storage.importedIndex) ?? []
            let sl = (try? Data(contentsOf: Storage.songlengths)).map { Songlengths(text: latin1String($0)) }
            let st = (try? Data(contentsOf: Storage.stil)).map { STIL.parse(latin1String($0)) } ?? [:]
            return (local, sl, st)
        }.value
        localTunes = loaded.0
        songlengths = loaded.1
        stil = loaded.2
        rebuildTunes()

        nowPlaying.attach(self)
        observeAudioSession()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker?.tolerance = 0.03
        await connectHVSC()
    }

    // MARK: Library list

    /// Merging, indexing and sorting 60,000 tunes takes a moment, so it happens off the main thread.
    private func rebuildTunes() {
        let local = localTunes, remote = remoteTunes
        rebuildToken += 1
        let token = rebuildToken
        Task {
            let built = await Task.detached(priority: .userInitiated) { LibraryIndex(local: local, remote: remote) }.value
            guard token == rebuildToken else { return }
            tunes = built.tunes
            tuneMap = built.tuneMap
            indexOfPath = built.indexOfPath
            searchIndex = built.search
            sortOrders = [LibraryIndex.orderKey(.path, desc: false): Array(built.tunes.indices)]
            refreshVisible()
        }
    }

    @ObservationIgnored private var rebuildToken = 0
    @ObservationIgnored private var sorting: Set<String> = []

    /// The cached order for the current sort, or nil while it is computed in the background (the list then shows path order).
    private func sortOrder() -> [Int]? {
        let key = LibraryIndex.orderKey(sortKey, desc: sortDesc)
        if let cached = sortOrders[key] { return cached }
        guard !sorting.contains(key) else { return nil }
        sorting.insert(key)
        let tunes = tunes, sortKey = sortKey, desc = sortDesc, token = rebuildToken
        Task {
            let order = await Task.detached(priority: .userInitiated) { LibraryIndex.order(tunes, by: sortKey, desc: desc) }.value
            sorting.remove(key)
            guard token == rebuildToken else { return }
            sortOrders[key] = order
            refreshVisible()
        }
        return nil
    }

    private func refreshVisible() {
        let q = query.trimmingCharacters(in: .whitespaces)
        switch view {
        case .all:
            let order = sortOrder() ?? Array(tunes.indices)
            if let hits = searchIndex.matches(q) {
                var mask = [Bool](repeating: false, count: tunes.count)
                for i in hits { mask[i] = true }
                visible = order.lazy.filter { mask[$0] }.map { self.tunes[$0] }
            } else {
                visible = order.map { tunes[$0] }
            }
        default:
            let paths: [String] = switch view {
            case .favorites: collections.favorites
            case .history: collections.history
            case .playlist(let id): collections.playlists.first { $0.id == id }?.paths ?? []
            case .all: []
            }
            visible = paths.compactMap { p in
                guard let i = indexOfPath[p] else { return nil }
                return q.isEmpty || searchIndex.matches(q, at: i) ? tunes[i] : nil
            }
        }
        followVisible()
    }

    private func followVisible() {
        // a search with no matches (often half-typed) keeps the previous queue rather than leaving nothing to play
        guard view == queueView, !visible.isEmpty else { return }
        queue = visible.map(\.path)
        // -1 when the playing tune is filtered out: next then starts from the top of the new list
        queueIndex = current.flatMap { queue.firstIndex(of: $0.path) } ?? -1
    }

    func viewTitle(_ v: View) -> String {
        switch v {
        case .all: "Library"
        case .favorites: "Favorites"
        case .history: "History"
        case .playlist(let id): collections.playlists.first { $0.id == id }?.name ?? "Playlist"
        }
    }

    // MARK: Import

    func importItems(_ urls: [URL]) {
        guard !urls.isEmpty, importProgress == nil else { return }
        importProgress = (0, 0)
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Importer.run(urls) { done, total in
                        Task { @MainActor in self.importProgress = (done, total) }
                    }
                }.value
                var map = Dictionary(localTunes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                for t in result.tunes { map[t.path] = t }
                localTunes = map.values.sorted { $0.path < $1.path }
                let local = localTunes
                await Task.detached { Storage.writeJSON(local, to: Storage.importedIndex) }.value
                if let text = result.songlengths { saveSonglengths(text) }
                if let text = result.stil { saveSTIL(text) }
                rebuildTunes()
                let extras = [result.songlengths != nil ? "song lengths" : nil, result.stil != nil ? "STIL notes" : nil].compactMap { $0 }.joined(separator: " and ")
                if result.tunes.isEmpty && extras.isEmpty {
                    message = "No SID files found in that selection."
                } else {
                    let n = result.tunes.count
                    message = "Added \(n.formatted()) tune\(n == 1 ? "" : "s")\(extras.isEmpty ? "" : " plus \(extras)")."
                }
            } catch {
                message = "Import failed: \(error.localizedDescription)"
            }
            importProgress = nil
        }
    }

    func importCollectionFile(_ url: URL, kind: ImportPaths.Kind) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            message = "Could not read \(url.lastPathComponent)."
            return
        }
        if kind == .songlengths {
            saveSonglengths(latin1String(data))
            message = "Song lengths loaded."
        } else {
            saveSTIL(latin1String(data))
            message = "STIL notes loaded."
        }
    }

    private func saveSonglengths(_ text: String) {
        try? Storage.write(Data(text.utf8), to: Storage.songlengths)
        songlengths = Songlengths(text: text)
    }

    private func saveSTIL(_ text: String) {
        try? Storage.write(Data(text.utf8), to: Storage.stil)
        stil = STIL.parse(text)
    }

    func saveROMs(_ r: ROMSet) {
        roms = r
        Storage.writeJSON(r, to: Storage.roms)
        message = r.isComplete ? "ROMs saved. They apply from the next tune you play." : "ROM saved. Add all three for them to be used."
    }

    func setROM(_ url: URL, kind: WritableKeyPath<ROMSet, Data?>, size: Int) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count == size else {
            message = "ROM sizes must be KERNAL 8192, BASIC 8192, CHARGEN 4096 bytes."
            return
        }
        var r = roms
        r[keyPath: kind] = data
        saveROMs(r)
    }

    func clearROMs() {
        saveROMs(ROMSet())
        message = "ROMs removed."
    }

    func wipeLibrary() {
        stop()
        try? FileManager.default.removeItem(at: Storage.importedFiles)
        try? FileManager.default.removeItem(at: Storage.importedIndex)
        try? FileManager.default.removeItem(at: Storage.songlengths)
        try? FileManager.default.removeItem(at: Storage.stil)
        localTunes = []
        songlengths = nil
        stil = [:]
        collections.history = []
        rebuildTunes()
        message = "Library cleared."
    }

    // MARK: Online HVSC catalogue

    /// Loads the catalogue from disk straight away, then checks the server for a newer release.
    func connectHVSC(forceRefresh: Bool = false) async {
        guard let base = HVSCClient.baseURL, settings.onlineCatalogue else {
            // Off means nothing of HVSC's is kept, apart from an offline copy the user downloaded deliberately.
            for name in ["manifest.json", "index.json", "stil.txt"] {
                try? FileManager.default.removeItem(at: Storage.hvsc.appending(path: name))
            }
            hvscManifest = nil
            remoteTunes = []
            remoteParts = []
            remoteStil = [:]
            hvscStatus = HVSCStatus()
            rebuildTunes()
            return
        }
        let client = HVSCClient(base: base)
        hvscStatus = HVSCStatus(state: .loading, text: "Loading the HVSC catalogue…")
        let manifestURL = Storage.hvsc.appending(path: "manifest.json")
        let indexURL = Storage.hvsc.appending(path: "index.json")
        let stilURL = Storage.hvsc.appending(path: "stil.txt")
        let cachedManifest = Storage.readJSON(HVSCCatalogue.Manifest.self, from: manifestURL)
        do {
            var haveIndex = false
            if !forceRefresh, let data = try? Data(contentsOf: indexURL) {
                try await applyIndex(data)
                haveIndex = true
                if let s = try? Data(contentsOf: stilURL) { remoteStil = await Task.detached { STIL.parse(latin1String(s)) }.value }
                hvscManifest = cachedManifest
            }
            let manifest: HVSCCatalogue.Manifest
            do {
                manifest = try await client.manifest()
            } catch {
                if haveIndex { return } // offline: keep what we have
                throw error
            }
            if manifest.index != cachedManifest?.index || !haveIndex {
                hvscStatus = HVSCStatus(state: .loading, text: "Downloading HVSC \(manifest.hvsc) catalogue…")
                let data = try await client.file(manifest.index)
                try await applyIndex(data)
                try Storage.write(data, to: indexURL, excludeFromBackup: true)
                if let old = cachedManifest, old.hvsc != manifest.hvsc { message = "HVSC updated to \(manifest.hvsc)." }
            }
            if manifest.stil != cachedManifest?.stil || remoteStil.isEmpty {
                let data = try await client.file(manifest.stil)
                remoteStil = await Task.detached { STIL.parse(latin1String(data)) }.value
                try Storage.write(data, to: stilURL, excludeFromBackup: true)
            }
            Storage.writeJSON(manifest, to: manifestURL)
            hvscManifest = manifest
        } catch {
            hvscStatus = HVSCStatus(state: .error, text: "Could not load the HVSC catalogue: \(error.localizedDescription)")
        }
    }

    private func applyIndex(_ data: Data) async throws {
        let index = try await Task.detached(priority: .userInitiated) { try HVSCCatalogue.parseIndex(data) }.value
        remoteTunes = index.tunes
        remoteParts = index.parts
        rebuildTunes()
        hvscStatus = HVSCStatus(state: .ready, text: "HVSC \(index.hvsc) · \(index.tunes.count.formatted()) tunes")
    }

    /// Bytes of the collection stored on this device for offline play.
    var offlinePacks: (have: Int, total: Int, bytes: Int64) {
        guard let m = hvscManifest else { return (0, 0, 0) }
        let have = m.parts.filter { LocalPacks.has($0.name, size: $0.size) }
        return (have.count, m.parts.count, have.reduce(0) { $0 + Int64($1.size) })
    }

    var offlineTotalBytes: Int64 { hvscManifest?.parts.reduce(0) { $0 + Int64($1.size) } ?? 0 }

    /// Downloads every pack of the collection so all tunes play offline.
    func downloadCollection() {
        guard packTask == nil, let base = HVSCClient.baseURL, let manifest = hvscManifest else { return }
        let client = HVSCClient(base: base)
        let total = manifest.parts.reduce(Int64(0)) { $0 + Int64($1.size) }
        packTask = Task {
            var done = manifest.parts.filter { LocalPacks.has($0.name, size: $0.size) }.reduce(Int64(0)) { $0 + Int64($1.size) }
            packDownload = PackDownload(done: done, total: total, text: "Starting…")
            for part in manifest.parts where !LocalPacks.has(part.name, size: part.size) {
                if Task.isCancelled { break }
                let before = done
                do {
                    try await client.downloadPack(part.name, to: LocalPacks.url(for: part.name)) { written in
                        Task { @MainActor in
                            self.packDownload = PackDownload(done: before + written, total: total, text: "Downloading \(part.name)…")
                        }
                    }
                    done = before + Int64(part.size)
                } catch {
                    if !Task.isCancelled { message = "Download failed: \(error.localizedDescription)" }
                    break
                }
            }
            packDownload = nil
            packTask = nil
            if offlinePacks.have == manifest.parts.count { message = "The whole collection is now available offline." }
        }
    }

    func cancelCollectionDownload() {
        packTask?.cancel()
        packTask = nil
        packDownload = nil
    }

    func deleteOfflineCollection() {
        cancelCollectionDownload()
        try? FileManager.default.removeItem(at: Storage.hvscPacks)
        message = "Offline copy of the collection removed."
    }

    /// Imported copy first, then the tune cache, a downloaded pack, and finally the server (cached for next time).
    private func tuneData(_ meta: TuneMeta) async throws -> [UInt8] {
        let imported = Storage.file(in: Storage.importedFiles, path: meta.path)
        if meta.remote == nil || localTunes.contains(where: { $0.path == meta.path }), let data = try? Data(contentsOf: imported) {
            return [UInt8](data)
        }
        let cached = Storage.file(in: Storage.tuneCache, path: meta.path)
        if let data = try? Data(contentsOf: cached) { return [UInt8](data) }
        let parts = remoteParts
        if let data = await Task.detached(operation: { LocalPacks.read(meta, parts: parts) }).value { return [UInt8](data) }
        guard meta.remote != nil, let base = HVSCClient.baseURL else { throw HVSCClient.HTTPError(message: "file missing from library") }
        let data = try await HVSCClient(base: base).tune(meta, parts: parts)
        try? Storage.write(data, to: cached)
        return [UInt8](data)
    }

    private func prefetchNext() {
        guard queueIndex + 1 < queue.count, let meta = tuneMap[queue[queueIndex + 1]], meta.remote != nil else { return }
        Task { _ = try? await tuneData(meta) }
    }

    func stilFor(_ path: String) -> String? { stil[path] ?? remoteStil[path] }

    // MARK: Playback

    private func lengthFor(_ meta: TuneMeta, song: Int, md5: String? = nil) -> Double? {
        if let l = meta.lengths, song < l.count { return l[song] }
        if let md5, let l = songlengths?.length(md5: md5, song: song + 1) { return l }
        return songlengths?.length(path: meta.path, song: song + 1)
    }

    private func loadRequest(_ data: [UInt8], meta: TuneMeta, song: Int, startAt: Double) -> PlaybackEngine.LoadRequest {
        let length = lengthFor(meta, song: song) ?? settings.defaultLengthSec
        let whole = length + 2 <= Settings.seekCacheMaxSeconds || settings.prerenderLong
        return PlaybackEngine.LoadRequest(
            data: data, song: song + 1, startAt: startAt, config: settings.sidConfig, roms: roms.isComplete ? roms : nil,
            mutes: voiceMuted, cacheSeconds: settings.seekCache ? (whole ? length + 2 : Settings.seekCacheMaxSeconds) : nil,
            coversWholeTune: whole
        )
    }

    private func start(_ path: String, song: Int?) {
        guard let meta = tuneMap[path] else { return }
        playToken += 1
        let token = playToken
        loading = true
        Task {
            do {
                let data = try await tuneData(meta)
                guard token == playToken else { return }
                currentData = data
                current = meta
                songIndex = song ?? meta.startSong - 1
                position = 0
                details = nil
                load(startAt: 0)
                engine?.setPaused(false)
                playing = true
                collections.history = Array(([path] + collections.history.filter { $0 != path }).prefix(500))
                nowPlaying.update(force: true)
                prefetchNext()
            } catch {
                guard token == playToken else { return }
                loading = false
                message = "Could not play: \(error.localizedDescription)"
            }
        }
    }

    private func load(startAt: Double) {
        guard let meta = current, let data = currentData, let engine else { return }
        loading = true
        let token = playToken
        engine.load(loadRequest(data, meta: meta, song: songIndex, startAt: startAt)) { [weak self] result in
            guard let self, token == self.playToken else { return }
            loading = false
            switch result {
            case .success(let info):
                details = info
                let len = lengthFor(meta, song: songIndex, md5: info.md5)
                lengthKnown = len != nil
                duration = len ?? settings.defaultLengthSec
                nowPlaying.update(force: true)
            case .failure(let error):
                playing = false
                engine.setPaused(true)
                message = "Could not play this tune: \(error)"
            }
        }
    }

    /// Starts a tune from the visible list so next/previous follow what the user sees.
    func playFromList(_ path: String, song: Int? = nil) {
        queueView = view
        queue = visible.map(\.path)
        queueIndex = queue.firstIndex(of: path) ?? -1
        if queueIndex < 0 {
            queue = [path]
            queueIndex = 0
        }
        played = []
        start(path, song: song)
    }

    func playPaths(_ paths: [String], first: Int = 0) {
        guard !paths.isEmpty else { return }
        queueView = nil
        queue = paths
        queueIndex = first
        played = []
        start(paths[first], song: nil)
    }

    func selectSong(_ i: Int) {
        guard current != nil, currentData != nil else { return }
        playToken += 1
        songIndex = i
        position = 0
        load(startAt: 0)
        engine?.setPaused(false)
        playing = true
    }

    func togglePlay() {
        guard current != nil else {
            if let first = visible.first { playFromList(first.path) }
            return
        }
        playing.toggle()
        engine?.setPaused(!playing)
        nowPlaying.update(force: true)
    }

    func stop() {
        playToken += 1
        playing = false
        current = nil
        details = nil
        engine?.setPaused(true)
        engine?.stop()
        nowPlaying.update(force: true)
    }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        if auto && settings.repeatMode == .one, let c = current {
            start(c.path, song: songIndex)
            return
        }
        if let c = current { played.append(c.path) }
        if !auto && queueRanOut && adoptVisibleQueue() {
            start(queue[queueIndex], song: nil)
            return
        }
        if settings.shuffle && queue.count > 1 {
            var i = queueIndex
            while i == queueIndex { i = Int.random(in: 0..<queue.count) }
            queueIndex = i
        } else if queueIndex + 1 < queue.count {
            queueIndex += 1
        } else if settings.repeatMode == .all || !auto {
            queueIndex = 0
        } else {
            playing = false
            engine?.setPaused(true)
            nowPlaying.update(force: true)
            return
        }
        start(queue[queueIndex], song: nil)
    }

    private var queueRanOut: Bool {
        queue.count <= 1 || (settings.repeatMode != .all && queueIndex + 1 >= queue.count)
    }

    /// Switches the queue to the list on screen, positioned just after the playing tune (or at its top).
    private func adoptVisibleQueue() -> Bool {
        guard view != queueView, !visible.isEmpty else { return false }
        queueView = view
        queue = visible.map(\.path)
        let at = current.flatMap { queue.firstIndex(of: $0.path) } ?? -1
        queueIndex = at + 1 < queue.count ? at + 1 : 0
        return true
    }

    func previous() {
        if position > 3 && current != nil { return seek(0) }
        if let prev = played.popLast() {
            queueIndex = max(0, queue.firstIndex(of: prev) ?? 0)
            start(prev, song: nil)
        } else if queueIndex > 0 {
            queueIndex -= 1
            start(queue[queueIndex], song: nil)
        } else {
            seek(0)
        }
    }

    func seek(_ seconds: Double) {
        guard current != nil, let engine else { return }
        let s = max(0, min(seconds, duration))
        position = s
        seeking = true
        engine.seek(to: s) { [weak self] in
            self?.seeking = false
            self?.nowPlaying.update(force: true)
        }
    }

    func skip(_ delta: Double) { seek(position + delta) }

    func setVolume(_ v: Double) {
        settings.volume = max(0, min(1, v))
    }

    func toggleVoice(_ v: Int) {
        voiceMuted[v].toggle()
        engine?.setMute(voice: v, muted: voiceMuted[v])
    }

    func toggleShuffle() { settings.shuffle.toggle() }

    func cycleRepeat() {
        settings.repeatMode = switch settings.repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    func cycleTheme(_ step: Int = 1) {
        let all = ThemeID.allCases
        let i = all.firstIndex(of: settings.theme) ?? 0
        settings.theme = all[(i + step + all.count) % all.count]
    }

    private func settingsChanged(from before: Settings) {
        settings.save()
        if settings.volume != before.volume { engine?.setVolume(settings.volume) }
        if settings.fxMode != before.fxMode { engine?.setFXMode(settings.fxMode) }
        if settings.eq != before.eq { engine?.setEQ(settings.eq) }
        let engineChanged = settings.engine != before.engine || settings.sidModel != before.sidModel || settings.c64Model != before.c64Model
            || settings.digiBoost != before.digiBoost || settings.seekCache != before.seekCache
            || settings.prerenderLong != before.prerenderLong
        if engineChanged && current != nil {
            load(startAt: position)
        }
        if settings.onlineCatalogue != before.onlineCatalogue {
            Task { await connectHVSC() }
        }
    }

    private func tick() {
        guard let engine else { return }
        busy = engine.isBusy
        let p = current == nil ? nil : engine.prerender
        if p != prerender { prerender = p }
        guard playing, !loading, !seeking, current != nil else { return }
        position = engine.position
        if position >= duration { return next(auto: true) }
        if let e = engine.lastError {
            message = "Could not play this tune: \(e)"
            playing = false
            engine.setPaused(true)
        }
        if Date().timeIntervalSince(lastNowPlayingUpdate) > 5 {
            lastNowPlayingUpdate = Date()
            nowPlaying.update()
        }
    }

    // MARK: Visualiser

    func currentRegisters() -> [[UInt8]]? { engine?.currentRegisters() }
    func recentSamples(_ n: Int) -> [Float] { engine?.recentSamples(n) ?? [] }

    // MARK: Favorites & playlists

    func toggleFavorite(_ path: String) {
        if collections.favorites.contains(path) {
            collections.favorites.removeAll { $0 == path }
        } else {
            collections.favorites.insert(path, at: 0)
        }
        nowPlaying.update(force: true)
    }

    @discardableResult
    func createPlaylist(_ name: String, firstPath: String? = nil) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let pl = Playlist(name: trimmed.isEmpty ? "Untitled" : trimmed, paths: firstPath.map { [$0] } ?? [])
        collections.playlists.append(pl)
        return pl
    }

    func addToPlaylist(_ id: String, path: String) {
        guard let i = collections.playlists.firstIndex(where: { $0.id == id }), !collections.playlists[i].paths.contains(path) else { return }
        collections.playlists[i].paths.append(path)
        message = "Added to \(collections.playlists[i].name)."
    }

    func removeFromPlaylist(_ id: String, path: String) {
        guard let i = collections.playlists.firstIndex(where: { $0.id == id }) else { return }
        collections.playlists[i].paths.removeAll { $0 == path }
    }

    func movePlaylistItems(_ id: String, from: IndexSet, to: Int) {
        guard let i = collections.playlists.firstIndex(where: { $0.id == id }) else { return }
        collections.playlists[i].paths.move(fromOffsets: from, toOffset: to)
    }

    func deletePlaylist(_ id: String) {
        collections.playlists.removeAll { $0.id == id }
        if view == .playlist(id) { view = .all }
    }

    func renamePlaylist(_ id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = collections.playlists.firstIndex(where: { $0.id == id }) else { return }
        collections.playlists[i].name = trimmed
    }

    func replaceCollections(_ c: UserCollections) {
        collections = c
        if case .playlist(let id) = view, !c.playlists.contains(where: { $0.id == id }) { view = .all }
    }

    func clearHistory() {
        collections.history = []
    }

    // MARK: Share

    /// sidtune://tune?path=/MUSICIANS/...&song=2 (1-based), the app's version of the web app's ?tune= links.
    func shareURL(for t: TuneMeta) -> URL {
        var c = URLComponents()
        c.scheme = "sidtune"
        c.host = "tune"
        c.queryItems = [URLQueryItem(name: "path", value: t.path)]
        if t.path == current?.path, songIndex != t.startSong - 1 { c.queryItems?.append(URLQueryItem(name: "song", value: "\(songIndex + 1)")) }
        return c.url!
    }

    func open(_ url: URL) {
        if url.isFileURL {
            importItems([url])
            return
        }
        guard url.scheme == "sidtune", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value else { return }
        let song = items.first(where: { $0.name == "song" })?.value.flatMap(Int.init)
        Task {
            for _ in 0..<100 where tuneMap[path] == nil && hvscStatus.state == .loading {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let meta = tuneMap[path] else {
                message = "The shared tune is not in your library or the online catalogue."
                return
            }
            playPaths([path])
            if let song, song >= 1, song <= meta.songs, song != meta.startSong {
                try? await Task.sleep(for: .milliseconds(300))
                selectSong(song - 1)
            }
            nowPlayingOpen = true
        }
    }

    // MARK: Audio session

    private func observeAudioSession() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let resume = ((note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0) & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began, self.playing {
                    self.togglePlay()
                } else if type == .ended, resume, !self.playing, self.current != nil {
                    self.togglePlay()
                }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                // Headphones unplugged: pause rather than blast the speaker.
                if reason == .oldDeviceUnavailable, let self, self.playing { self.togglePlay() }
            }
        }
    }
}

func formatTime(_ s: Double) -> String {
    let t = max(0, Int(s.isFinite ? s : 0))
    return "\(t / 60):" + String(format: "%02d", t % 60)
}
