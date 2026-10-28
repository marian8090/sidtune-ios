import Foundation

/// Lower-cased "title author released path" haystacks, matched with memmem so filtering 60,000 tunes per keystroke stays cheap.
public struct SearchIndex: Sendable {
    private var keys: [[UInt8]]

    public init(_ tunes: [TuneMeta]) {
        keys = tunes.map { Array("\($0.title) \($0.author) \($0.released) \($0.path)".lowercased().utf8) }
    }

    /// Indices of tunes whose haystack contains every whitespace-separated token of `query`.
    public func matches(_ query: String) -> [Int]? {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
        guard !tokens.isEmpty else { return nil }
        var out: [Int] = []
        for (i, key) in keys.enumerated() where tokens.allSatisfy({ Self.contains(key, $0) }) {
            out.append(i)
        }
        return out
    }

    public func matches(_ query: String, at index: Int) -> Bool {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
        return tokens.allSatisfy { Self.contains(keys[index], $0) }
    }

    private static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        hay.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil }
        }
    }
}
