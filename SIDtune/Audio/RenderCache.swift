import Foundation
import SIDEngine
import Synchronization

/// Renders a whole tune into memory on its own thread so seeks inside it are instant. Port of cache.worker.ts.
/// Stores the raw chip output (16-bit stereo, about 11 MB per minute) plus a register snapshot per chunk for the visualiser.
final class RenderCache: @unchecked Sendable {
    static let chipSlots = 3

    let chunkFrames: Int
    let chunks: Int
    /// False when the tune is longer than the memory budget, so the cache stops short of its end.
    let coversWholeTune: Bool
    private let pcm: UnsafeMutablePointer<Int16>
    private let regs: UnsafeMutablePointer<UInt8>
    private let renderedChunks = Atomic<Int>(0)
    private let done = Atomic<Bool>(false)
    private let cancelled = Atomic<Bool>(false)
    private let chipCount = Atomic<Int>(1)

    var capacityFrames: Int { chunks * chunkFrames }
    var rendered: Int { renderedChunks.load(ordering: .acquiring) }
    var finished: Bool { done.load(ordering: .acquiring) }
    var chips: Int { chipCount.load(ordering: .relaxed) }

    init(seconds: Double, coversWholeTune: Bool, sampleRate: Int, chunkFrames: Int) {
        self.chunkFrames = chunkFrames
        chunks = max(1, Int((seconds * Double(sampleRate)).rounded(.up)) / chunkFrames + 1)
        self.coversWholeTune = coversWholeTune
        pcm = .allocate(capacity: chunks * chunkFrames * 2)
        regs = .allocate(capacity: chunks * Self.chipSlots * 32)
    }

    deinit {
        pcm.deallocate()
        regs.deallocate()
    }

    func start(data: [UInt8], song: Int, config: SIDConfig, roms: ROMSet?, mutes: [Bool], sampleRate: Int) {
        let thread = Thread { [self] in
            let player = SIDPlayer(sampleRate: sampleRate)
            if let roms { player.setROMs(kernal: roms.kernal.map { [UInt8]($0) }, basic: roms.basic.map { [UInt8]($0) }, chargen: roms.chargen.map { [UInt8]($0) }) }
            do {
                try player.load(data, song: song, config: config)
            } catch {
                done.store(true, ordering: .releasing)
                return
            }
            let chips = max(1, player.tuneInfo?.sidChips ?? 1)
            chipCount.store(chips, ordering: .relaxed)
            for chip in 0..<chips {
                for (v, m) in mutes.enumerated() where m { player.mute(chip: chip, voice: v, true) }
            }
            for i in 0..<chunks {
                if cancelled.load(ordering: .relaxed) { break }
                do {
                    try player.render(into: UnsafeMutableBufferPointer(start: pcm + i * chunkFrames * 2, count: chunkFrames * 2))
                } catch {
                    break
                }
                for chip in 0..<min(chips, Self.chipSlots) {
                    if let r = player.registers(chip: chip) {
                        (regs + (i * Self.chipSlots + chip) * 32).update(from: r, count: 32)
                    }
                }
                renderedChunks.store(i + 1, ordering: .releasing)
            }
            done.store(true, ordering: .releasing)
        }
        thread.name = "SID cache"
        thread.qualityOfService = .utility
        thread.start()
    }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
    }

    /// Copies chunk `index` (which must be rendered) into `out` and returns its register snapshots.
    func read(chunk index: Int, into out: UnsafeMutablePointer<Int16>) -> [[UInt8]] {
        out.update(from: pcm + index * chunkFrames * 2, count: chunkFrames * 2)
        return (0..<min(chips, Self.chipSlots)).map { chip in
            Array(UnsafeBufferPointer(start: regs + (index * Self.chipSlots + chip) * 32, count: 32))
        }
    }
}

struct ROMSet: Codable, Equatable, Sendable {
    var kernal: Data?
    var basic: Data?
    var chargen: Data?

    var isComplete: Bool { kernal != nil && basic != nil && chargen != nil }
}
