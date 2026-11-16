import Foundation
import Testing
@testable import SIDLibrary

// Fixtures were made with macOS's bsdtar from the files below:
//   bsdtar --format 7zip --options 7zip:compression=<method> -cf <method>.7z C64Music
private func pattern(_ count: Int, seed: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 7) ^ seed) })
}

private let expected: [String: Data] = [
    "C64Music/MUSICIANS/T/Test/Big.sid": pattern(70_000, seed: 1),
    "C64Music/MUSICIANS/T/Test/Small.sid": pattern(1_000, seed: 2),
    "C64Music/MUSICIANS/T/Test/Empty.sid": Data(),
    "C64Music/DOCUMENTS/STIL.txt": Data(String(repeating: "/MUSICIANS/T/Test/Small.sid\n COMMENT: Hello.\n", count: 50).utf8),
]

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "7z", subdirectory: "Fixtures"))
}

@Test(arguments: ["lzma1", "lzma2", "ppmd", "store"])
func readsSevenZipArchives(method: String) throws {
    let archive = try SevenZipArchive(url: try fixture(method))
    #expect(archive.entries.filter { !$0.isDirectory }.count == expected.count)
    #expect(archive.entries.contains { $0.isDirectory && $0.name == "C64Music/EMPTYDIR" })
    var seen: [String: Data] = [:]
    try archive.extract(where: { _ in true }) { entry, data in seen[entry.name] = data }
    #expect(seen == expected)
}

@Test func extractsOnlyWantedSevenZipEntries() throws {
    let archive = try SevenZipArchive(url: try fixture("lzma2"))
    var names: [String] = []
    try archive.extract(where: { $0.name.hasSuffix("Small.sid") }) { entry, data in
        names.append(entry.name)
        #expect(data == expected[entry.name])
    }
    #expect(names == ["C64Music/MUSICIANS/T/Test/Small.sid"])
}

@Test func rejectsDamagedSevenZipArchives() throws {
    var bytes = try Data(contentsOf: try fixture("store"))
    bytes[100] ^= 0xFF // inside the first stored file
    let url = FileManager.default.temporaryDirectory.appending(path: "damaged-\(UUID().uuidString).7z")
    try bytes.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let archive = try SevenZipArchive(url: url)
    #expect(throws: SevenZipArchive.SevenZipError.self) {
        try archive.extract(where: { _ in true }) { _, _ in }
    }
    #expect(throws: SevenZipArchive.SevenZipError.self) {
        _ = try SevenZipArchive(url: try fixture("lzma2").deletingLastPathComponent().appending(path: "missing.7z"))
    }
}

@Test func stopsWhenTheCallbackThrows() throws {
    struct Stop: Error {}
    let archive = try SevenZipArchive(url: try fixture("lzma1"))
    var calls = 0
    #expect(throws: Stop.self) {
        try archive.extract(where: { $0.size > 0 }) { _, _ in
            calls += 1
            throw Stop()
        }
    }
    #expect(calls == 1)
}

/// Decodes the real HVSC release (PPMd, LZMA with a 340 MiB dictionary, BCJ2), checking every CRC. Set HVSC_7Z to the path of
/// HVSC_xx-all-of-them.7z to run it; it's skipped otherwise.
@Test(.enabled(if: ProcessInfo.processInfo.environment["HVSC_7Z"] != nil))
func decodesTheHVSCRelease() throws {
    let url = URL(filePath: ProcessInfo.processInfo.environment["HVSC_7Z"]!)
    let start = ContinuousClock.now
    let archive = try SevenZipArchive(url: url)
    var sids = 0, bytes = 0, docs: Set<String> = []
    try archive.extract(where: { ImportPaths.kind(of: $0.name) != .other }) { entry, data in
        bytes += data.count
        switch ImportPaths.kind(of: entry.name) {
        case .sid: sids += 1
        default: docs.insert(entry.name)
        }
    }
    print("BENCH 7z: \(sids) tunes, \(bytes) bytes in \(ContinuousClock.now - start)")
    #expect(sids > 60_000)
    #expect(docs.contains("C64Music/DOCUMENTS/Songlengths.md5"))
    #expect(docs.contains("C64Music/DOCUMENTS/STIL.txt"))
}
