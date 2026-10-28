import Foundation

public enum ImportPaths {
    /// Maps a picked path to the HVSC-style path ("/MUSICIANS/...") used for Songlengths/STIL lookups. Port of `normalisePath`.
    public static func normalise(_ raw: String) -> String {
        let p = raw.replacingOccurrences(of: "\\", with: "/")
        if let r = p.range(of: "(?:^|/)c64music/", options: [.regularExpression, .caseInsensitive]) {
            return "/" + p[r.upperBound...]
        }
        var parts = p.split(separator: "/").map(String.init)
        if parts.count > 1 { parts.removeFirst() } // picked folder's own name
        return "/" + parts.joined(separator: "/")
    }

    public enum Kind: Sendable {
        case sid, songlengths, stil, zip, other
    }

    public static func kind(of name: String) -> Kind {
        let n = (name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? name).lowercased()
        if n.hasSuffix(".sid") { return .sid }
        if n == "songlengths.md5" { return .songlengths }
        if n == "stil.txt" { return .stil }
        if n.hasSuffix(".zip") { return .zip }
        return .other
    }
}
