import Foundation
import Testing
@testable import SIDLibrary

private func psidHeader(title: String, author: String, released: String, songs: Int, start: Int, flags: UInt16 = 0x14) -> Data {
    var b = [UInt8](repeating: 0, count: 0x7c + 4)
    b.replaceSubrange(0..<4, with: Array("PSID".utf8))
    b[5] = 2
    b[7] = 0x7c
    b[15] = UInt8(songs)
    b[17] = UInt8(start)
    for (off, s) in [(0x16, title), (0x36, author), (0x56, released)] {
        let bytes = Array(s.utf8)
        b.replaceSubrange(off..<off + bytes.count, with: bytes)
    }
    b[0x76] = UInt8(flags >> 8)
    b[0x77] = UInt8(flags & 0xFF)
    return Data(b)
}

@Test func parsesPSIDHeader() throws {
    let meta = try #require(PSID.parse(psidHeader(title: "Commando", author: "Rob Hubbard", released: "1985 Elite", songs: 19, start: 1), path: "/MUSICIANS/H/Hubbard_Rob/Commando.sid"))
    #expect(meta.title == "Commando")
    #expect(meta.author == "Rob Hubbard")
    #expect(meta.released == "1985 Elite")
    #expect(meta.songs == 19)
    #expect(meta.startSong == 1)
    #expect(meta.clock == "PAL")
    #expect(meta.sidModel == "6581")
    #expect(meta.summary == "PSID · 6581 · PAL")
}

@Test func rejectsNonSIDData() {
    #expect(PSID.parse(Data(repeating: 0, count: 200), path: "/x.sid") == nil)
}

@Test func untitledTuneFallsBackToFileName() throws {
    let meta = try #require(PSID.parse(psidHeader(title: "", author: "", released: "", songs: 1, start: 1), path: "/A/Some_Tune.sid"))
    #expect(meta.title == "Some_Tune")
}

@Test func parsesSonglengths() {
    let text = """
    [Database]
    ; /MUSICIANS/H/Hubbard_Rob/Commando.sid
    0123456789abcdef0123456789abcdef=3:55.600 1:01.3 0:06
    ; /DEMOS/old.sid
    fedcba9876543210fedcba9876543210=1:02(G) 0:30
    """
    let sl = Songlengths(text: text)
    #expect(sl.count == 2)
    #expect(sl.length(md5: "0123456789ABCDEF0123456789ABCDEF", song: 1) == 235.6)
    #expect(sl.length(path: "/MUSICIANS/H/Hubbard_Rob/Commando.sid", song: 3) == 6)
    #expect(sl.length(path: "/DEMOS/old.sid", song: 1) == 62)
    #expect(sl.length(path: "/DEMOS/old.sid", song: 3) == nil)
}

@Test func parsesSTIL() {
    let text = """
    ### header
    /MUSICIANS/H/Hubbard_Rob/
      COMMENT: a folder note

    /MUSICIANS/H/Hubbard_Rob/Commando.sid
      COMMENT: The classic.
       ARTIST: Rob Hubbard

    /OTHER/x.sid
    (#1)
      TITLE: First
    """
    let stil = STIL.parse(text)
    #expect(stil.count == 2)
    #expect(stil["/MUSICIANS/H/Hubbard_Rob/Commando.sid"] == "  COMMENT: The classic.\n   ARTIST: Rob Hubbard")
    #expect(stil["/OTHER/x.sid"]?.contains("TITLE: First") == true)
}

@Test func parsesCatalogueIndex() throws {
    let json = """
    {"format":1,"hvsc":"85","parts":["pack-85-000.bin"],
     "cols":["path","title","author","released","rsid","version","songs","startSong","sids","sidModel","clock","size","part","offset","lengths"],
     "rows":[["/A/b.sid","B","C","1990",0,2,3,2,1,"8580","PAL",4000,0,1234,[60,1.5,2]],
             ["/A/c.sid","D","E","1991",1,2,1,1,2,"6581","NTSC",500,0,5234,null]]}
    """
    let index = try HVSCCatalogue.parseIndex(Data(json.utf8))
    #expect(index.hvsc == "85")
    #expect(index.parts == ["pack-85-000.bin"])
    #expect(index.tunes.count == 2)
    #expect(index.tunes[0].remote == .init(part: 0, offset: 1234))
    #expect(index.tunes[0].lengths == [60, 1.5, 2])
    #expect(index.tunes[0].startSong == 2)
    #expect(index.tunes[1].isRSID)
    #expect(index.tunes[1].lengths == nil)
}

@Test func normalisesImportPaths() {
    #expect(ImportPaths.normalise("C64Music/MUSICIANS/H/x.sid") == "/MUSICIANS/H/x.sid")
    #expect(ImportPaths.normalise("Downloads/HVSC/C64Music/DEMOS/y.sid") == "/DEMOS/y.sid")
    #expect(ImportPaths.normalise("MyTunes/sub/z.sid") == "/sub/z.sid")
    #expect(ImportPaths.normalise("z.sid") == "/z.sid")
    #expect(ImportPaths.kind(of: "C64Music/DOCUMENTS/Songlengths.md5") == .songlengths)
    #expect(ImportPaths.kind(of: "a/STIL.txt") == .stil)
    #expect(ImportPaths.kind(of: "a/B.SID") == .sid)
}

@Test func searchMatchesAllTokens() {
    let tunes = [
        TuneMeta(path: "/MUSICIANS/H/Hubbard_Rob/Commando.sid", title: "Commando", author: "Rob Hubbard", released: "1985 Elite",
                 isRSID: false, version: 2, songs: 19, startSong: 1, sids: 1, sidModel: "6581", clock: "PAL", size: 1),
        TuneMeta(path: "/MUSICIANS/G/Galway_Martin/Arkanoid.sid", title: "Arkanoid", author: "Martin Galway", released: "1987 Imagine",
                 isRSID: false, version: 2, songs: 20, startSong: 1, sids: 1, sidModel: "6581", clock: "PAL", size: 1),
    ]
    let index = SearchIndex(tunes)
    #expect(index.matches("") == nil)
    #expect(index.matches("hubbard") == [0])
    #expect(index.matches("1987 GALWAY") == [1])
    #expect(index.matches("musicians") == [0, 1])
    #expect(index.matches("hubbard arkanoid") == [])
}

@Test func readsZipArchives() throws {
    // "hello.txt" stored and "deflated.txt" deflated, made with Python's zipfile.
    let base64 = "UEsDBBQAAAAAAAAAISiGphA2BQAAAAUAAAAJAAAAaGVsbG8udHh0aGVsbG9QSwMEFAAAAAgAAAAhKMHTwWsFAAAAHgAAAAwAAABkZWZsYXRlZC50eHRLTMQHAFBLAQIUAxQAAAAAAAAAISiGphA2BQAAAAUAAAAJAAAAAAAAAAAAAACAAQAAAABoZWxsby50eHRQSwECFAMUAAAACAAAACEowdPBawUAAAAeAAAADAAAAAAAAAAAAAAAgAEsAAAAZGVmbGF0ZWQudHh0UEsFBgAAAAACAAIAcQAAAFsAAAAAAA=="
    let zip = try ZipArchive(data: try #require(Data(base64Encoded: base64)))
    #expect(zip.entries.map(\.name) == ["hello.txt", "deflated.txt"])
    #expect(String(decoding: try zip.contents(of: zip.entries[0]), as: UTF8.self) == "hello")
    #expect(String(decoding: try zip.contents(of: zip.entries[1]), as: UTF8.self) == String(repeating: "a", count: 30))
}
