import CLZMA
import Foundation

/// Read-only 7z archive, decoded front to back: solid blocks can't be read at random without unpacking everything before
/// the entry, so instead of `contents(of:)` there is one `extract` pass that hands over the wanted entries in archive order.
public final class SevenZipArchive {
    public struct Entry: Sendable {
        public var index: Int
        public var name: String
        public var size: Int
        public var isDirectory: Bool
    }

    public struct SevenZipError: Error, CustomStringConvertible, LocalizedError {
        public let description: String
        public var errorDescription: String? { description }
    }

    public let entries: [Entry]
    private let handle: OpaquePointer

    /// `temporaryDirectory` holds memory-mapped scratch files for the decoder's large dictionaries (up to a few hundred MB).
    public init(url: URL, temporaryDirectory: URL? = FileManager.default.temporaryDirectory) throws {
        var error = [CChar](repeating: 0, count: 256)
        let opened = error.withUnsafeMutableBufferPointer { message in
            url.withUnsafeFileSystemRepresentation { path in
                if let temporaryDirectory {
                    temporaryDirectory.withUnsafeFileSystemRepresentation { sz_open(path, $0, message.baseAddress, message.count) }
                } else {
                    sz_open(path, nil, message.baseAddress, message.count)
                }
            }
        }
        guard let opened else { throw SevenZipError(description: Self.string(error)) }
        handle = opened
        var name = [CChar](repeating: 0, count: 1024)
        entries = (0..<sz_count(opened)).map { i in
            let needed = sz_name(opened, i, &name, name.count)
            if needed >= name.count {
                name = [CChar](repeating: 0, count: needed + 1)
                _ = sz_name(opened, i, &name, name.count)
            }
            return Entry(index: Int(i), name: Self.string(name), size: Int(sz_size(opened, i)), isDirectory: sz_is_dir(opened, i))
        }
    }

    deinit { sz_close(handle) }

    private static func string(_ chars: [CChar]) -> String {
        String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Calls `body` with each wanted entry's contents, in archive order. Empty entries are passed without decoding anything.
    /// Throws on damaged or unsupported archives; entries handed over before that are intact (their CRCs were checked).
    public func extract(where wanted: (Entry) -> Bool, _ body: (Entry, Data) throws -> Void) throws {
        let mask = entries.map { !$0.isDirectory && wanted($0) }
        for entry in entries where mask[entry.index] && entry.size == 0 { try body(entry, Data()) }
        var error = [CChar](repeating: 0, count: 256)
        try withoutActuallyEscaping(body) { body in
            var context = Context(entries: entries, body: body)
            let result = withUnsafeMutablePointer(to: &context) { ctx in
                error.withUnsafeMutableBufferPointer { message in
                    sz_extract(handle, mask, { raw, index, data, size in
                        let ctx = raw!.assumingMemoryBound(to: Context.self)
                        do {
                            try ctx.pointee.body(ctx.pointee.entries[Int(index)], Data(bytes: data!, count: size))
                            return 0
                        } catch {
                            ctx.pointee.thrown = error
                            return 1
                        }
                    }, ctx, message.baseAddress, message.count)
                }
            }
            if let thrown = context.thrown { throw thrown }
            if result < 0 { throw SevenZipError(description: Self.string(error)) }
        }
    }

    private struct Context {
        var entries: [Entry]
        var body: (Entry, Data) throws -> Void
        var thrown: Error?
    }
}
