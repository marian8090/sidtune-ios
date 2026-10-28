import Foundation

/// The online catalogue built by the web app's tools/build-hvsc.mjs. Port of the parsing half of src/lib/hvsc.ts.
public enum HVSCCatalogue {
    public struct Manifest: Codable, Equatable, Sendable {
        public struct Part: Codable, Equatable, Sendable {
            public var name: String
            public var size: Int
        }
        public var format: Int
        public var hvsc: String
        public var built: String
        public var count: Int
        public var index: String
        public var stil: String
        public var parts: [Part]
    }

    public struct Index: Sendable {
        public var hvsc: String
        /// Pack file names, indexed by `TuneMeta.Remote.part`.
        public var parts: [String]
        public var tunes: [TuneMeta]
    }

    public struct FormatError: Error, CustomStringConvertible {
        public let description: String
    }

    static let columns = "path,title,author,released,rsid,version,songs,startSong,sids,sidModel,clock,size,part,offset,lengths"

    public static func parseIndex(_ data: Data) throws -> Index {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? Int == 1,
              (root["cols"] as? [String])?.joined(separator: ",") == columns,
              let rows = root["rows"] as? [[Any]],
              let parts = root["parts"] as? [String]
        else { throw FormatError(description: "unsupported catalogue format") }
        let hvsc = (root["hvsc"] as? String) ?? (root["hvsc"].map { "\($0)" } ?? "?")
        var tunes: [TuneMeta] = []
        tunes.reserveCapacity(rows.count)
        for r in rows where r.count >= 15 {
            let int = { (i: Int) in (r[i] as? NSNumber)?.intValue ?? 0 }
            let str = { (i: Int) in r[i] as? String ?? "" }
            let lengths = (r[14] as? [NSNumber])?.map(\.doubleValue)
            tunes.append(TuneMeta(
                path: str(0), title: str(1), author: str(2), released: str(3),
                isRSID: int(4) != 0, version: int(5), songs: max(1, int(6)), startSong: max(1, int(7)), sids: max(1, int(8)),
                sidModel: str(9), clock: str(10), size: int(11),
                remote: .init(part: int(12), offset: int(13)),
                lengths: lengths
            ))
        }
        return Index(hvsc: hvsc, parts: parts, tunes: tunes)
    }
}
