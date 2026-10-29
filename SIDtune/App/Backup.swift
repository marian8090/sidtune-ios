import SIDFX
import SwiftUI
import UniformTypeIdentifiers

/// The web app's backup file (`Backup` in src/state.ts), so favorites and playlists move between the web app and iOS.
struct Backup: Codable {
    var app = "sidtune"
    var version = 1
    var favorites: [String]
    var playlists: [Playlist]
    var history: [String]
    var settings: BackupSettings?
}

/// Settings under the web app's key names and values. The online catalogue is left out: it is opt-in on iOS but on by
/// default on the web, so a backup from either side shouldn't switch it.
struct BackupSettings: Codable {
    var engine: String?
    var sidModel: String?
    var c64Model: String?
    var digiBoost: Bool?
    var fxMode: String?
    var eq: [Double]?
    var seekCache: Bool?
    var defaultLengthSec: Double?
    var volume: Double?
    var shuffle: Bool?
    var `repeat`: String?
    // iOS only; the web app keeps these as separate preferences and ignores them here
    var theme: String?
    var font: String?

    init(_ s: Settings) {
        engine = s.engine.rawValue
        sidModel = switch s.sidModel {
        case .auto: "auto"
        case .mos6581: "MOS6581"
        case .mos8580: "MOS8580"
        }
        c64Model = switch s.c64Model {
        case .auto: "auto"
        case .pal: "PAL"
        case .ntsc: "NTSC"
        }
        digiBoost = s.digiBoost
        fxMode = s.fxMode.rawValue
        eq = s.eq
        seekCache = s.seekCache
        defaultLengthSec = s.defaultLengthSec
        volume = s.volume
        shuffle = s.shuffle
        `repeat` = s.repeatMode.rawValue
        theme = s.theme.rawValue
        font = s.font.rawValue
    }

    /// Keys that are missing or hold unknown values keep what `base` has.
    func applied(to base: Settings) -> Settings {
        var s = base
        if let v = engine.flatMap(Settings.Engine.init(rawValue:)) { s.engine = v }
        switch sidModel {
        case "auto": s.sidModel = .auto
        case "MOS6581": s.sidModel = .mos6581
        case "MOS8580": s.sidModel = .mos8580
        default: break
        }
        switch c64Model {
        case "auto": s.c64Model = .auto
        case "PAL": s.c64Model = .pal
        case "NTSC": s.c64Model = .ntsc
        default: break
        }
        if let digiBoost { s.digiBoost = digiBoost }
        if let v = fxMode.flatMap(FxMode.init(rawValue:)) { s.fxMode = v }
        if let eq, eq.count == 3 { s.eq = eq }
        if let seekCache { s.seekCache = seekCache }
        if let defaultLengthSec, defaultLengthSec > 0 { s.defaultLengthSec = defaultLengthSec }
        if let volume { s.volume = min(max(volume, 0), 1) }
        if let shuffle { s.shuffle = shuffle }
        if let v = `repeat`.flatMap(Settings.RepeatMode.init(rawValue:)) { s.repeatMode = v }
        if let v = theme.flatMap(ThemeID.init(rawValue:)) { s.theme = v }
        if let v = font.flatMap(FontID.init(rawValue:)) { s.font = v }
        return s
    }
}

struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    static var defaultFilename: String {
        "sidtune-backup-\(Date().formatted(.iso8601.year().month().day()))"
    }
}

extension AppModel {
    func backupDocument() -> BackupDocument {
        let b = Backup(favorites: favorites, playlists: playlists, history: history, settings: BackupSettings(settings))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return BackupDocument(data: (try? enc.encode(b)) ?? Data())
    }

    func restoreBackup(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(Backup.self, from: data), b.app == "sidtune" else {
            message = "That file is not a SIDtune backup."
            return
        }
        replaceCollections(UserCollections(favorites: b.favorites, playlists: b.playlists, history: b.history))
        if let s = b.settings { settings = s.applied(to: settings) }
        let n = b.playlists.count
        message = "Restored \(b.favorites.count.formatted()) favorite\(b.favorites.count == 1 ? "" : "s") and \(n) playlist\(n == 1 ? "" : "s")."
    }
}
