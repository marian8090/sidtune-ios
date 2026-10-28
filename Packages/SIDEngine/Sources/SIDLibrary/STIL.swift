import Foundation

public enum STIL {
    /// Parses HVSC's STIL.txt into path -> notes. Directory entries (trailing "/") are skipped. Port of src/lib/stil.ts.
    public static func parse(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        var path = ""
        var lines: [String] = []
        func flush() {
            if !path.isEmpty && !path.hasSuffix("/") && !lines.isEmpty {
                map[path] = lines.joined(separator: "\n").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
            path = ""
            lines = []
        }
        text.enumerateLines { raw, _ in
            if raw.hasPrefix("#") { return }
            if raw.hasPrefix("/") {
                flush()
                path = raw.trimmingCharacters(in: .whitespaces)
            } else if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if !path.isEmpty {
                lines.append(raw)
            }
        }
        flush()
        return map
    }
}

/// Text files from HVSC are Latin-1.
public func latin1String(_ data: Data) -> String {
    String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
}
