import Foundation
import SIDLibrary

/// The merged library with its lookup tables and search index, built off the main thread.
struct LibraryIndex: Sendable {
    let tunes: [TuneMeta]
    let tuneMap: [String: TuneMeta]
    let indexOfPath: [String: Int]
    let search: SearchIndex

    /// Imported tunes win over the online catalogue when both have the same path. The result is in path order.
    init(local: [TuneMeta], remote: [TuneMeta]) {
        var merged: [TuneMeta]
        if local.isEmpty {
            merged = remote
        } else {
            var map = Dictionary(remote.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            for t in local { map[t.path] = t }
            merged = Array(map.values)
        }
        merged.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        tunes = merged
        tuneMap = Dictionary(merged.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        indexOfPath = Dictionary(merged.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
        search = SearchIndex(merged)
    }

    static func orderKey(_ key: AppModel.SortKey, desc: Bool) -> String { "\(key.rawValue)-\(desc)" }

    /// Indices of `tunes` sorted case- and accent-insensitively; ties (and empty values, always last) fall back to path order.
    static func order(_ tunes: [TuneMeta], by key: AppModel.SortKey, desc: Bool) -> [Int] {
        let folded: [[UInt8]] = tunes.map { t in
            let s: String = switch key {
            case .path: t.path
            case .title: t.title
            case .author: t.author
            case .released: t.released
            }
            return Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf8)
        }
        var order = Array(tunes.indices)
        order.sort { a, b in
            if folded[a] != folded[b] {
                if folded[a].isEmpty { return false }
                if folded[b].isEmpty { return true }
                return folded[a].lexicographicallyPrecedes(folded[b]) != desc
            }
            return a < b
        }
        return order
    }
}
