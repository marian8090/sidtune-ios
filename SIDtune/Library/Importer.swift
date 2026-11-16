import Foundation
import SIDLibrary

/// Copies picked folders, .sid files, .zip and .7z archives into the app's library. Port of src/lib/importer.ts.
enum Importer {
    struct Result: Sendable {
        var tunes: [TuneMeta] = []
        var songlengths: String?
        var stil: String?
        var skipped = 0
        /// Archives that stopped partway, with the reason. Tunes read before the problem are kept.
        var failures: [String] = []
    }

    /// One file to import: its path as picked (used to work out the HVSC path) and how to read it.
    private struct Item {
        var rawPath: String
        var read: () throws -> Data
    }

    /// 7z archives are solid, so they can't hand out entries one at a time like a zip; they're decoded in one pass after the
    /// other items.
    private struct SevenZip {
        var name: String
        var archive: SevenZipArchive
    }

    static func run(_ urls: [URL], progress: @escaping @Sendable (Int, Int) -> Void) throws -> Result {
        var items: [Item] = []
        var archives: [SevenZip] = []
        var scoped: [URL] = []
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        for url in urls {
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
            try collect(url, items: &items, archives: &archives)
        }
        var result = Result()
        let total = items.count + archives.reduce(0) { $0 + $1.archive.entries.filter(isWanted).count }
        var done = 0
        func step() {
            done += 1
            if done % 200 == 0 || done == total { progress(done, total) }
        }
        for item in items {
            autoreleasepool { ingest(item.rawPath, read: item.read, into: &result) }
            step()
        }
        for sevenZip in archives {
            do {
                try sevenZip.archive.extract(where: isWanted) { entry, data in
                    autoreleasepool { ingest(archivePath(entry.name, archive: "7z"), read: { data }, into: &result) }
                    step()
                }
            } catch {
                result.failures.append("\(sevenZip.name): \(error.localizedDescription)")
            }
        }
        return result
    }

    private static func ingest(_ rawPath: String, read: () throws -> Data, into result: inout Result) {
        do {
            switch ImportPaths.kind(of: rawPath) {
            case .sid:
                let data = try read()
                let path = ImportPaths.normalise(rawPath)
                if let meta = PSID.parse(data, path: path) {
                    try Storage.write(data, to: Storage.file(in: Storage.importedFiles, path: path), excludeFromBackup: true)
                    result.tunes.append(meta)
                } else {
                    result.skipped += 1
                }
            case .songlengths:
                result.songlengths = latin1String(try read())
            case .stil:
                result.stil = latin1String(try read())
            case .zip, .sevenZip, .other:
                result.skipped += 1
            }
        } catch {
            result.skipped += 1
        }
    }

    private static func isWanted(_ entry: SevenZipArchive.Entry) -> Bool {
        switch ImportPaths.kind(of: entry.name) {
        case .sid, .songlengths, .stil: true
        case .zip, .sevenZip, .other: false
        }
    }

    /// A bare tune at an archive's root has no folder to strip.
    private static func archivePath(_ name: String, archive: String) -> String {
        name.contains("/") || name.contains("\\") ? name : "\(archive)/\(name)"
    }

    /// Expands a folder (recursively) or an archive into importable items. The picked folder's own name is kept in the raw
    /// path, which `ImportPaths.normalise` relies on.
    private static func collect(_ url: URL, items: inout [Item], archives: inout [SevenZip]) throws {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            let root = url.deletingLastPathComponent().path
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            while let file = walker?.nextObject() as? URL {
                switch ImportPaths.kind(of: file.lastPathComponent) {
                case .other:
                    continue
                case .zip:
                    items += (try? zipItems(file)) ?? []
                case .sevenZip:
                    if let archive = try? SevenZipArchive(url: file) { archives.append(SevenZip(name: file.lastPathComponent, archive: archive)) }
                case .sid, .songlengths, .stil:
                    let rel = String(file.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    items.append(Item(rawPath: rel) { try Data(contentsOf: file) })
                }
            }
            return
        }
        switch ImportPaths.kind(of: url.lastPathComponent) {
        case .zip:
            items += try zipItems(url)
        case .sevenZip:
            archives.append(SevenZip(name: url.lastPathComponent, archive: try SevenZipArchive(url: url)))
        default:
            items.append(Item(rawPath: url.lastPathComponent) { try Data(contentsOf: url) })
        }
    }

    private static func zipItems(_ url: URL) throws -> [Item] {
        let zip = try ZipArchive(url: url)
        return zip.entries.compactMap { entry in
            guard !entry.isDirectory else { return nil }
            switch ImportPaths.kind(of: entry.name) {
            case .sid, .songlengths, .stil:
                return Item(rawPath: archivePath(entry.name, archive: "zip")) { try zip.contents(of: entry) }
            default:
                return nil
            }
        }
    }
}
