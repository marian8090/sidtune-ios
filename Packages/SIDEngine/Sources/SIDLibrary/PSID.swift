import Foundation

public enum PSID {
    /// Reads the PSID/RSID header. Returns nil for anything that is not a SID file. Port of src/lib/psid.ts.
    public static func parse(_ data: Data, path: String) -> TuneMeta? {
        let b = [UInt8](data)
        guard b.count >= 0x76 else { return nil }
        let magic = string(b, 0, 4)
        guard magic == "PSID" || magic == "RSID" else { return nil }
        let u16 = { (off: Int) in Int(b[off]) << 8 | Int(b[off + 1]) }
        let version = u16(4)
        let songs = max(1, u16(14))
        let startSong = min(max(1, u16(16)), songs)
        let title = string(b, 0x16, 32)
        let author = string(b, 0x36, 32)
        let released = string(b, 0x56, 32)

        var sids = 1
        var sidModel = "?"
        var clock = "?"
        if version >= 2 && b.count >= 0x7c {
            let flags = u16(0x76)
            clock = ["?", "PAL", "NTSC", "PAL/NTSC"][(flags >> 2) & 3]
            sidModel = ["?", "6581", "8580", "6581/8580"][(flags >> 4) & 3]
            if version >= 3 {
                if b[0x7a] != 0 { sids += 1 }
                if version >= 4 && b[0x7b] != 0 { sids += 1 }
            }
        }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return TuneMeta(
            path: path,
            title: title.isEmpty ? name.replacingOccurrences(of: ".sid", with: "", options: [.caseInsensitive, .anchored, .backwards]) : title,
            author: author,
            released: released,
            isRSID: magic == "RSID",
            version: version,
            songs: songs,
            startSong: startSong,
            sids: sids,
            sidModel: sidModel,
            clock: clock,
            size: b.count
        )
    }

    /// Header strings are Latin-1, NUL-padded.
    private static func string(_ b: [UInt8], _ off: Int, _ len: Int) -> String {
        var end = off
        while end < off + len && b[end] != 0 { end += 1 }
        return String(decoding: b[off..<end].map { UInt16($0) }, as: UTF16.self).trimmingCharacters(in: .whitespaces)
    }
}
