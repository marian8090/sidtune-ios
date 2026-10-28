import Foundation
import SIDEngine
import SIDFX
import UIKit

/// Port of `Settings` in src/lib/types.ts plus the look-and-feel preferences from src/lib/prefs.ts.
struct Settings: Codable, Equatable {
    enum Engine: String, Codable, CaseIterable { case residfp, sidlite }
    enum ChipChoice: String, Codable, CaseIterable { case auto, mos6581, mos8580 }
    enum ClockChoice: String, Codable, CaseIterable { case auto, pal, ntsc }
    enum RepeatMode: String, Codable { case off, all, one }

    var engine = Engine.residfp
    var sidModel = ChipChoice.auto
    var c64Model = ClockChoice.auto
    var digiBoost = true
    var fxMode = FxMode.magic
    /// Equalizer offsets in dB for the low (200 Hz), mid (1 kHz) and high (4 kHz) bands.
    var eq = [0.0, 0, 0]
    /// Browse the online HVSC catalogue. Off until the user chooses to download it.
    var onlineCatalogue = false
    /// Pre-render tunes in the background so seeking is instant.
    var seekCache = true
    var defaultLengthSec = 180.0
    var volume = 0.8
    var shuffle = false
    var repeatMode = RepeatMode.off
    var theme = ThemeID.sidtune
    var font = FontID.system
    var showWelcome = true

    init() {}

    /// Missing keys keep their defaults, so settings saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        engine = (try? c.decodeIfPresent(Engine.self, forKey: .engine)) ?? d.engine
        sidModel = (try? c.decodeIfPresent(ChipChoice.self, forKey: .sidModel)) ?? d.sidModel
        c64Model = (try? c.decodeIfPresent(ClockChoice.self, forKey: .c64Model)) ?? d.c64Model
        digiBoost = (try? c.decodeIfPresent(Bool.self, forKey: .digiBoost)) ?? d.digiBoost
        fxMode = (try? c.decodeIfPresent(FxMode.self, forKey: .fxMode)) ?? d.fxMode
        eq = (try? c.decodeIfPresent([Double].self, forKey: .eq)) ?? d.eq
        onlineCatalogue = (try? c.decodeIfPresent(Bool.self, forKey: .onlineCatalogue)) ?? d.onlineCatalogue
        seekCache = (try? c.decodeIfPresent(Bool.self, forKey: .seekCache)) ?? d.seekCache
        defaultLengthSec = (try? c.decodeIfPresent(Double.self, forKey: .defaultLengthSec)) ?? d.defaultLengthSec
        volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? d.volume
        shuffle = (try? c.decodeIfPresent(Bool.self, forKey: .shuffle)) ?? d.shuffle
        repeatMode = (try? c.decodeIfPresent(RepeatMode.self, forKey: .repeatMode)) ?? d.repeatMode
        theme = (try? c.decodeIfPresent(ThemeID.self, forKey: .theme)) ?? d.theme
        font = (try? c.decodeIfPresent(FontID.self, forKey: .font)) ?? d.font
        showWelcome = (try? c.decodeIfPresent(Bool.self, forKey: .showWelcome)) ?? d.showWelcome
    }

    var sidConfig: SIDConfig {
        var c = SIDConfig()
        c.emulation = engine == .sidlite ? .sidlite : .residfp
        c.chipModel = switch sidModel {
        case .auto: nil
        case .mos6581: .mos6581
        case .mos8580: .mos8580
        }
        c.c64Model = switch c64Model {
        case .auto: nil
        case .pal: .pal
        case .ntsc: .ntsc
        }
        c.digiBoost = digiBoost
        return c
    }

    /// Longest tune (seconds) kept fully in memory for instant seeking; phones get a smaller budget.
    static var seekCacheMaxSeconds: Double { UIDevice.current.userInterfaceIdiom == .phone ? 300 : 600 }

    private static let key = "settings"

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

struct Playlist: Codable, Identifiable, Equatable, Hashable {
    var id = UUID().uuidString
    var name: String
    var paths: [String]
}

/// Favorites, playlists and history: what the web app kept in its IndexedDB `kv` store.
struct UserCollections: Codable, Equatable {
    var favorites: [String] = []
    var playlists: [Playlist] = []
    var history: [String] = []
}

/// Where everything lives on disk.
enum Storage {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "SIDtune", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let caches: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "SIDtune", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var importedIndex: URL { support.appending(path: "imported.json") }
    static var importedFiles: URL { support.appending(path: "Imported", directoryHint: .isDirectory) }
    static var collections: URL { support.appending(path: "collections.json") }
    static var songlengths: URL { support.appending(path: "Songlengths.md5") }
    static var stil: URL { support.appending(path: "STIL.txt") }
    static var roms: URL { support.appending(path: "roms.json") }
    static var hvsc: URL { support.appending(path: "HVSC", directoryHint: .isDirectory) }
    static var hvscPacks: URL { hvsc.appending(path: "packs", directoryHint: .isDirectory) }
    static var tuneCache: URL { caches.appending(path: "Tunes", directoryHint: .isDirectory) }

    /// `path` is an HVSC-style path starting with "/".
    static func file(in base: URL, path: String) -> URL {
        base.appending(path: String(path.drop(while: { $0 == "/" })))
    }

    static func write(_ data: Data, to url: URL, excludeFromBackup: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if excludeFromBackup {
            var u = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? u.setResourceValues(values)
        }
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        if let data = try? JSONEncoder().encode(value) { try? write(data, to: url) }
    }
}
