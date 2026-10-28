import Foundation
import SIDLibrary

/// Copies picked folders, .sid files and .zip archives into the app's library. Port of src/lib/importer.ts.
enum Importer {
    struct Result: Sendable {
        var tunes: [TuneMeta] = []
        var songlengths: String?
        var stil: String?
        var skipped = 0
    }

    /// One file to import: its path as picked (used to work out the HVSC path) and how to read it.
    private struct Item {
        var rawPath: String
        var read: () throws -> Data
    }

    static func run(_ urls: [URL], progress: @escaping @Sendable (Int, Int) -> Void) throws -> Result {
        var items: [Item] = []
        var scoped: [URL] = []
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        for url in urls {
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
            items += try collect(url)
        }
        var result = Result()
        let total = items.count
        for (i, item) in items.enumerated() {
            autoreleasepool {
                do {
                    switch ImportPaths.kind(of: item.rawPath) {
                    case .sid:
                        let data = try item.read()
                        let path = ImportPaths.normalise(item.rawPath)
                        if let meta = PSID.parse(data, path: path) {
                            try Storage.write(data, to: Storage.file(in: Storage.importedFiles, path: path), excludeFromBackup: true)
                            result.tunes.append(meta)
                        } else {
                            result.skipped += 1
                        }
                    case .songlengths:
                        result.songlengths = latin1String(try item.read())
                    case .stil:
                        result.stil = latin1String(try item.read())
                    case .zip, .other:
                        result.skipped += 1
                    }
                } catch {
                    result.skipped += 1
                }
            }
            if i % 200 == 0 || i == total - 1 { progress(i + 1, total) }
        }
        return result
    }

    /// Expands a folder (recursively) or a zip into importable items. The picked folder's own name is kept in the raw path,
    /// which `ImportPaths.normalise` relies on.
    private static func collect(_ url: URL) throws -> [Item] {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            var out: [Item] = []
            let root = url.deletingLastPathComponent().path
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            while let file = walker?.nextObject() as? URL {
                let kind = ImportPaths.kind(of: file.lastPathComponent)
                guard kind != .other else { continue }
                let rel = String(file.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if kind == .zip {
                    out += (try? zipItems(file)) ?? []
                } else {
                    out.append(Item(rawPath: rel) { try Data(contentsOf: file) })
                }
            }
            return out
        }
        if ImportPaths.kind(of: url.lastPathComponent) == .zip { return try zipItems(url) }
        return [Item(rawPath: url.lastPathComponent) { try Data(contentsOf: url) }]
    }

    private static func zipItems(_ url: URL) throws -> [Item] {
        let zip = try ZipArchive(url: url)
        return zip.entries.compactMap { entry in
            guard !entry.isDirectory else { return nil }
            switch ImportPaths.kind(of: entry.name) {
            case .sid, .songlengths, .stil:
                // A bare tune at the zip's root has no folder to strip.
                let raw = entry.name.contains("/") ? entry.name : "zip/\(entry.name)"
                return Item(rawPath: raw) { try zip.contents(of: entry) }
            default:
                return nil
            }
        }
    }
}
