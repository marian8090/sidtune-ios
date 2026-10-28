import Foundation
import SIDLibrary

/// The online HVSC catalogue: manifest, index, STIL, single tunes by HTTP Range, and whole packs for offline use. Port of the
/// network half of src/lib/hvsc.ts.
struct HVSCClient: Sendable {
    /// Set by the `HVSCURL` Info.plist key (project.yml). Empty means the feature is off.
    static let baseURL: URL? = {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "HVSCURL") as? String, !s.isEmpty else { return nil }
        return URL(string: s.hasSuffix("/") ? String(s.dropLast()) : s)
    }()

    struct HTTPError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let base: URL

    func manifest() async throws -> HVSCCatalogue.Manifest {
        var req = URLRequest(url: base.appending(path: "manifest.json"))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let data = try await fetch(req)
        return try JSONDecoder().decode(HVSCCatalogue.Manifest.self, from: data)
    }

    func file(_ name: String) async throws -> Data {
        try await fetch(URLRequest(url: base.appending(path: name)))
    }

    /// Downloads one tune from its pack with an HTTP Range request.
    func tune(_ meta: TuneMeta, parts: [String]) async throws -> Data {
        guard let remote = meta.remote, remote.part < parts.count else { throw HTTPError(message: "not an online tune") }
        var req = URLRequest(url: base.appending(path: parts[remote.part]))
        req.setValue("bytes=\(remote.offset)-\(remote.offset + meta.size - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 206 { return data }
        if status == 200 { throw HTTPError(message: "the HVSC server does not support range requests") }
        throw HTTPError(message: "the HVSC server answered HTTP \(status)")
    }

    /// Downloads a whole pack to `destination`, reporting bytes written.
    func downloadPack(_ name: String, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = ProgressDelegate(progress)
        let (tmp, response) = try await URLSession.shared.download(for: URLRequest(url: base.appending(path: name)), delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPError(message: "\(name): HTTP \(status)") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
        var url = destination
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func fetch(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPError(message: "\(req.url?.lastPathComponent ?? "request"): HTTP \(status)") }
        return data
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64) -> Void

    init(_ progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// Reads a tune straight out of a downloaded pack.
enum LocalPacks {
    static func url(for part: String) -> URL { Storage.hvscPacks.appending(path: part) }

    static func has(_ part: String, size: Int) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url(for: part).path)
        return (attrs?[.size] as? Int) == size
    }

    static func read(_ meta: TuneMeta, parts: [String]) -> Data? {
        guard let remote = meta.remote, remote.part < parts.count,
              let handle = try? FileHandle(forReadingFrom: url(for: parts[remote.part])) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(remote.offset))
        guard let data = try? handle.read(upToCount: meta.size), data.count == meta.size else { return nil }
        return data
    }
}
