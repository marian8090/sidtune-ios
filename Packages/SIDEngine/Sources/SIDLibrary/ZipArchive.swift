import Compression
import Foundation

/// Minimal read-only zip reader (stored and deflated entries, zip64), enough for HVSC archives and .sid collections.
public struct ZipArchive {
    public struct Entry: Sendable {
        public var name: String
        public var method: Int
        public var compressedSize: Int
        public var size: Int
        var localHeaderOffset: Int
        public var isDirectory: Bool { name.hasSuffix("/") }
    }

    public struct ZipError: Error, CustomStringConvertible {
        public let description: String
    }

    public let entries: [Entry]
    private let data: Data

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        self.data = data
        entries = try Self.readCentralDirectory(data)
    }

    public func contents(of entry: Entry) throws -> Data {
        let h = entry.localHeaderOffset
        guard u32(data, h) == 0x0403_4b50 else { throw ZipError(description: "bad local header for \(entry.name)") }
        let start = h + 30 + u16(data, h + 26) + u16(data, h + 28)
        guard start + entry.compressedSize <= data.count else { throw ZipError(description: "truncated entry \(entry.name)") }
        let raw = data.subdata(in: data.startIndex + start..<data.startIndex + start + entry.compressedSize)
        switch entry.method {
        case 0:
            return raw
        case 8:
            guard entry.size > 0 else { return Data() }
            var out = Data(count: entry.size)
            let n = out.withUnsafeMutableBytes { dst in
                raw.withUnsafeBytes { src in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                        src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB
                    )
                }
            }
            guard n == entry.size else { throw ZipError(description: "could not inflate \(entry.name)") }
            return out
        default:
            throw ZipError(description: "unsupported compression method \(entry.method) for \(entry.name)")
        }
    }

    private static func readCentralDirectory(_ d: Data) throws -> [Entry] {
        guard d.count >= 22 else { throw ZipError(description: "not a zip file") }
        var eocd = -1
        var i = d.count - 22
        let lowest = max(0, d.count - 22 - 65535)
        while i >= lowest {
            if u32(d, i) == 0x0605_4b50 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError(description: "not a zip file") }
        var count = u16(d, eocd + 10)
        var cdOffset = Int(u32(d, eocd + 16))
        if (count == 0xFFFF || cdOffset == 0xFFFF_FFFF), eocd >= 20, u32(d, eocd - 20) == 0x0706_4b50 {
            let z64 = Int(u64(d, eocd - 20 + 8))
            guard z64 + 56 <= d.count, u32(d, z64) == 0x0606_4b50 else { throw ZipError(description: "bad zip64 directory") }
            count = Int(u64(d, z64 + 32))
            cdOffset = Int(u64(d, z64 + 48))
        }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(d, p) == 0x0201_4b50 else { throw ZipError(description: "bad central directory") }
            let method = u16(d, p + 10)
            var csize = Int(u32(d, p + 20))
            var size = Int(u32(d, p + 24))
            let nameLen = u16(d, p + 28)
            let extraLen = u16(d, p + 30)
            let commentLen = u16(d, p + 32)
            var offset = Int(u32(d, p + 42))
            let nameBytes = d.subdata(in: d.startIndex + p + 46..<d.startIndex + p + 46 + nameLen)
            let utf8 = u16(d, p + 8) & 0x800 != 0
            let name = (utf8 ? String(data: nameBytes, encoding: .utf8) : nil) ?? latin1String(nameBytes)
            // zip64 extra field: the 0xFFFFFFFF values follow in this order.
            var e = p + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = u16(d, e)
                let len = u16(d, e + 2)
                if id == 0x0001 {
                    var q = e + 4
                    if size == 0xFFFF_FFFF { size = Int(u64(d, q)); q += 8 }
                    if csize == 0xFFFF_FFFF { csize = Int(u64(d, q)); q += 8 }
                    if offset == 0xFFFF_FFFF { offset = Int(u64(d, q)) }
                }
                e += 4 + len
            }
            entries.append(Entry(name: name, method: method, compressedSize: csize, size: size, localHeaderOffset: offset))
            p = extraEnd + commentLen
        }
        return entries
    }
}

private func u16(_ d: Data, _ o: Int) -> Int {
    Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8
}

private func u32(_ d: Data, _ o: Int) -> UInt32 {
    UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16
}

private func u64(_ d: Data, _ o: Int) -> UInt64 {
    UInt64(u32(d, o)) | UInt64(u32(d, o + 4)) << 32
}
