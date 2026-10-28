import Foundation
import Testing
@testable import SIDEngine

private func fixture(_ name: String) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try [UInt8](Data(contentsOf: url))
}

private func render(_ player: SIDPlayer, seconds: Double) throws -> [Int16] {
    var out = [Int16](repeating: 0, count: Int(seconds * Double(player.sampleRate)) * 2)
    try out.withUnsafeMutableBufferPointer { buf in
        let chunk = 1024 * 2
        var i = 0
        while i < buf.count {
            let n = min(chunk, buf.count - i)
            try player.render(into: UnsafeMutableBufferPointer(rebasing: buf[i..<(i + n)]))
            i += n
        }
    }
    return out
}

@Test func loadsTuneInfo() throws {
    let player = SIDPlayer(sampleRate: 48000)
    try player.load(fixture("Commando.sid"), config: SIDConfig())
    let info = try #require(player.tuneInfo)
    #expect(info.songs == 19)
    #expect(info.startSong == 1)
    #expect(info.currentSong == 1)
    #expect(info.sidChips == 1)
    #expect(info.infoStrings == ["Commando", "Rob Hubbard", "1985 Elite"])
    #expect(info.md5?.count == 32)
}

@Test func selectsSubtune() throws {
    let player = SIDPlayer(sampleRate: 48000)
    try player.load(fixture("Commando.sid"), song: 3, config: SIDConfig())
    #expect(player.tuneInfo?.currentSong == 3)
    try player.selectSong(5)
    #expect(player.tuneInfo?.currentSong == 5)
}

@Test func rejectsGarbage() {
    let player = SIDPlayer(sampleRate: 48000)
    #expect(throws: SIDError.self) { try player.load([1, 2, 3, 4], config: SIDConfig()) }
}

@Test(arguments: [SIDConfig.Emulation.residfp, .sidlite])
func rendersAudibleDeterministicAudio(emulation: SIDConfig.Emulation) throws {
    var config = SIDConfig()
    config.emulation = emulation
    let data = try fixture("Commando.sid")

    let a = SIDPlayer(sampleRate: 48000)
    try a.load(data, config: config)
    let first = try render(a, seconds: 3)
    #expect(first.contains { abs(Int($0)) > 1000 }, "expected audible output")
    #expect(a.registers(chip: 0) != nil)
    #expect(a.registers(chip: 1) == nil)
    #expect(abs(a.time - 3) < 0.1)

    // reSIDfp dithers its filter tables from a counter shared by every instance (FilterModelConfig::Randomnoise), so
    // runs differ by a few LSB. Anything bigger means the emulation itself diverged.
    let b = SIDPlayer(sampleRate: 48000)
    try b.load(data, config: config)
    let second = try render(b, seconds: 3)
    let maxDiff = zip(first, second).map { abs(Int($0) - Int($1)) }.max() ?? 0
    #expect(maxDiff <= 4, "same tune, same settings, same samples (max difference \(maxDiff))")
}

@Test func muteSilencesVoices() throws {
    let player = SIDPlayer(sampleRate: 48000)
    try player.load(fixture("Commando.sid"), config: SIDConfig())
    for v in 0..<3 { player.mute(chip: 0, voice: v, true) }
    let pcm = try render(player, seconds: 2)
    #expect(pcm.allSatisfy { abs(Int($0)) < 200 })
}

/// Prints how many times faster than real time each engine renders. Run with `swift test -c release` for meaningful numbers.
@Test(arguments: [SIDConfig.Emulation.residfp, .sidlite])
func benchmark(emulation: SIDConfig.Emulation) throws {
    var config = SIDConfig()
    config.emulation = emulation
    let player = SIDPlayer(sampleRate: 48000)
    try player.load(fixture("Commando.sid"), config: config)
    let seconds = 30.0
    let start = ContinuousClock.now
    _ = try render(player, seconds: seconds)
    let elapsed = ContinuousClock.now - start
    let factor = seconds / (Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds))
    print("BENCH \(emulation): \(Int(seconds)) s of audio in \(elapsed), \(String(format: "%.1f", factor))x realtime")
    #expect(factor > 1)
}
