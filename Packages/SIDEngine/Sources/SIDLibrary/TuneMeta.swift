import Foundation

/// One tune in the library. Port of `TuneMeta` in src/lib/types.ts.
public struct TuneMeta: Codable, Hashable, Sendable, Identifiable {
    public struct Remote: Codable, Hashable, Sendable {
        public var part: Int
        public var offset: Int
        public init(part: Int, offset: Int) {
            self.part = part
            self.offset = offset
        }
    }

    /// Normalised HVSC-style path, e.g. /MUSICIANS/H/Hubbard_Rob/Commando.sid
    public var path: String
    public var title: String
    public var author: String
    public var released: String
    public var isRSID: Bool
    public var version: Int
    /// 1-based, like the PSID header.
    public var songs: Int
    public var startSong: Int
    public var sids: Int
    /// "6581", "8580", "6581/8580" or "?".
    public var sidModel: String
    /// "PAL", "NTSC", "PAL/NTSC" or "?".
    public var clock: String
    public var size: Int
    /// Where the file lives inside the online catalogue's packs.
    public var remote: Remote?
    /// Song lengths in seconds, one per subtune, when known.
    public var lengths: [Double]?

    public var id: String { path }
    public var format: String { isRSID ? "RSID" : "PSID" }
    public var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }

    public init(
        path: String, title: String, author: String, released: String, isRSID: Bool, version: Int, songs: Int, startSong: Int,
        sids: Int, sidModel: String, clock: String, size: Int, remote: Remote? = nil, lengths: [Double]? = nil
    ) {
        self.path = path
        self.title = title
        self.author = author
        self.released = released
        self.isRSID = isRSID
        self.version = version
        self.songs = songs
        self.startSong = startSong
        self.sids = sids
        self.sidModel = sidModel
        self.clock = clock
        self.size = size
        self.remote = remote
        self.lengths = lengths
    }

    /// "PSID · 2×SID · 6581 · PAL", as in the web app's `describe`.
    public var summary: String {
        var bits = [format]
        if sids > 1 { bits.append("\(sids)×SID") }
        if sidModel != "?" { bits.append(sidModel) }
        if clock != "?" { bits.append(clock) }
        return bits.joined(separator: " · ")
    }
}
