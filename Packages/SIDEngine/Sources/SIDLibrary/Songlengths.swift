import Foundation

/// HVSC's DOCUMENTS/Songlengths.md5. Port of src/lib/songlengths.ts plus the parsing libsidplayfp-wasm did for it.
public struct Songlengths: Sendable {
    /// md5 -> seconds per subtune.
    public private(set) var byMD5: [String: [Double]] = [:]
    /// HVSC path -> md5, from the "; /PATH.sid" comment lines.
    public private(set) var pathToMD5: [String: String] = [:]

    public var count: Int { byMD5.count }

    public init(text: String) {
        var byMD5: [String: [Double]] = [:]
        var pathToMD5: [String: String] = [:]
        var last = ""
        text.enumerateLines { line, _ in
            if line.hasPrefix(";") {
                let p = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("/") { last = p }
                return
            }
            guard let eq = line.firstIndex(of: "="), line.distance(from: line.startIndex, to: eq) == 32 else {
                last = ""
                return
            }
            let md5 = line[..<eq].lowercased()
            let times = line[line.index(after: eq)...].split(separator: " ").compactMap(Self.seconds)
            if !times.isEmpty { byMD5[md5] = times }
            if !last.isEmpty { pathToMD5[last] = md5 }
            last = ""
        }
        self.byMD5 = byMD5
        self.pathToMD5 = pathToMD5
    }

    /// "m:ss", "m:ss.mmm", optionally followed by an old-style "(G)" flag.
    static func seconds(_ token: Substring) -> Double? {
        let t = token.split(separator: "(").first ?? token
        let parts = t.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
        return m * 60 + s
    }

    /// `song` is 1-based.
    public func length(md5: String, song: Int) -> Double? {
        guard let list = byMD5[md5.lowercased()], song >= 1, song <= list.count else { return nil }
        return list[song - 1]
    }

    public func length(path: String, song: Int) -> Double? {
        pathToMD5[path].flatMap { length(md5: $0, song: song) }
    }
}
