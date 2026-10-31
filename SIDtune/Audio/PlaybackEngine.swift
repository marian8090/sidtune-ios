import AVFoundation
import SIDEngine
import SIDFX
import Synchronization

/// Owns the emulator, the instant-seek cache, the FX chain, a render thread that keeps a ring buffer about `bufferAhead` seconds
/// full, and the `AVAudioSourceNode` that drains it. Port of engine.worker.ts + sid-worklet.js + controller.ts.
///
/// Control calls (load, seek, mute) run one at a time on `controlQueue` and may take a while (fast-forwarding the emulator), so
/// they report back through completions on the main queue.
final class PlaybackEngine: @unchecked Sendable {
    static let chunkFrames = 1024
    static let bufferAhead = 0.35
    static let idleStopDelay = 5.0

    let sampleRate: Int
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private let controlQueue = DispatchQueue(label: "SID control", qos: .userInitiated)

    // MARK: Emulation state, guarded by `lock`

    private enum Source { case live, cache }

    private let lock = NSLock()
    private let player: SIDPlayer
    private var config = SIDConfig()
    private var roms: ROMSet?
    private var tuneData: [UInt8] = []
    /// 1-based, as SIDPlayer wants it.
    private var song = 1
    private var chips = 1
    private var loaded = false
    private var renderError: String?
    private var mutes = [false, false, false]
    private var source = Source.live
    /// Song position (frames) of the live emulator.
    private var liveFrame = 0
    private var cache: RenderCache?
    /// The cache from before a mute change, played until `cache` (with the new mix) reaches the playhead.
    private var staleCache: RenderCache?
    private var cacheSeconds: Double?
    private var coversWholeTune = true
    /// Song position (frames) of the next chunk read from the cache.
    private var cachePos = 0
    private let fx: FXChain
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>

    // MARK: FX settings, handed from the main thread to the render thread

    private struct FXSettings: Equatable {
        var mode = FxMode.magic
        var eq = [0.0, 0, 0]
        var mono = true
        var mainsHz = 50.0
    }

    private let fxLock = NSLock()
    private var fxPending = FXSettings()
    private var fxApplied = FXSettings()

    // MARK: Ring buffer: single producer (render thread), single consumer (audio thread), interleaved stereo floats

    private let capacityFrames: Int
    private let ring: UnsafeMutablePointer<Float>
    private let writeFrame = Atomic<Int>(0)
    private let readFrame = Atomic<Int>(0)
    /// Set by the producer to drop queued audio: the consumer jumps its read position there.
    private let flushTo = Atomic<Int>(-1)
    /// Song position (frames) of the first frame after the pending flush.
    private let pendingBase = Atomic<Int>(0)
    private let positionBase = Atomic<Int>(0)
    private let playedFrames = Atomic<Int>(0)
    private let paused = Atomic<Bool>(true)
    private let running = Atomic<Bool>(true)
    /// True while the emulator fast-forwards or playback waits for the cache to reach a seek target.
    private let busyFlag = Atomic<Bool>(false)

    // MARK: Visualiser: register snapshots per rendered chunk

    private struct VizFrame {
        var frame: Int
        var regs: [[UInt8]]
    }

    private let vizLock = NSLock()
    private var viz: [VizFrame] = []

    init() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        sampleRate = Int(session.sampleRate.rounded())

        player = SIDPlayer(sampleRate: sampleRate)
        fx = FXChain(sampleRate: Double(sampleRate), blockSize: Self.chunkFrames)
        left = .allocate(capacity: Self.chunkFrames)
        right = .allocate(capacity: Self.chunkFrames)
        capacityFrames = Int(Double(sampleRate) * Self.bufferAhead) + Self.chunkFrames * 3
        ring = .allocate(capacity: capacityFrames * 2)
        ring.initialize(repeating: 0, count: capacityFrames * 2)

        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2)!
        sourceNode = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            self.pull(Int(frameCount), into: UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: format)
        try audioEngine.start()

        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
            guard let self, !self.paused.load(ordering: .relaxed) else { return }
            self.restartAudio()
        }

        let thread = Thread { [unowned self] in self.renderLoop() }
        thread.name = "SID render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit {
        running.store(false, ordering: .relaxed)
        audioEngine.stop()
        ring.deallocate()
        left.deallocate()
        right.deallocate()
    }

    /// Restarts output after a route or configuration change (or an interruption) stopped the engine.
    func restartAudio() {
        guard !audioEngine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? audioEngine.start()
    }

    // MARK: Control

    struct LoadRequest: Sendable {
        var data: [UInt8]
        /// 1-based.
        var song: Int
        var startAt: Double
        var config: SIDConfig
        var roms: ROMSet?
        var mutes: [Bool]
        /// nil turns the instant-seek cache off.
        var cacheSeconds: Double?
        var coversWholeTune: Bool
    }

    func load(_ request: LoadRequest, completion: @escaping @MainActor @Sendable (Result<SIDTuneInfo, Error>) -> Void) {
        controlQueue.async { [self] in
            busyFlag.store(true, ordering: .relaxed)
            let result: Result<SIDTuneInfo, Error> = lock.withLock {
                do {
                    loaded = false
                    renderError = nil
                    dropCaches()
                    flush(base: 0)
                    config = request.config
                    roms = request.roms
                    tuneData = request.data
                    song = request.song
                    mutes = request.mutes
                    cacheSeconds = request.cacheSeconds
                    coversWholeTune = request.coversWholeTune
                    if let r = request.roms, r.isComplete {
                        player.setROMs(kernal: r.kernal.map { [UInt8]($0) }, basic: r.basic.map { [UInt8]($0) }, chargen: r.chargen.map { [UInt8]($0) })
                    } else {
                        player.setROMs(kernal: nil, basic: nil, chargen: nil)
                    }
                    try player.load(request.data, song: request.song, config: request.config)
                    guard let info = player.tuneInfo else { throw SIDError(description: "no tune info") }
                    chips = max(1, info.sidChips)
                    applyMutes()
                    liveFrame = 0
                    source = .live
                    startCache()
                    loaded = true
                    setFX { $0.mono = info.sidChips <= 1; $0.mainsHz = info.clock == .ntsc ? 60 : 50 }
                    if request.startAt > 0 { seekLocked(request.startAt) }
                    return .success(info)
                } catch {
                    return .failure(error)
                }
            }
            busyFlag.store(false, ordering: .relaxed)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func seek(to seconds: Double, completion: @escaping @MainActor @Sendable () -> Void = {}) {
        controlQueue.async { [self] in
            busyFlag.store(true, ordering: .relaxed)
            lock.withLock { if loaded { seekLocked(seconds) } }
            busyFlag.store(false, ordering: .relaxed)
            DispatchQueue.main.async { completion() }
        }
    }

    func setMute(voice: Int, muted: Bool) {
        controlQueue.async { [self] in
            busyFlag.store(true, ordering: .relaxed)
            lock.withLock {
                mutes[voice] = muted
                guard loaded else { return }
                applyMutes()
                // The cache was rendered with the old mix, so render it again. Playing from the cache, the live emulator is
                // parked somewhere behind and catching it up would stall playback: keep playing the old mix until the new
                // cache gets there.
                if source == .cache, let old = cache {
                    if let stale = staleCache, stale.rendered >= old.rendered {
                        old.cancel()
                    } else {
                        staleCache?.cancel()
                        staleCache = old
                        old.setHeld(true)
                    }
                } else {
                    cache?.cancel()
                }
                cache = nil
                startCache()
                cache?.setPlayhead(chunk: (source == .cache ? cachePos : liveFrame) / Self.chunkFrames)
            }
            busyFlag.store(false, ordering: .relaxed)
        }
    }

    func stop() {
        controlQueue.async { [self] in
            lock.withLock {
                loaded = false
                dropCaches()
                flush(base: 0)
            }
        }
    }

    func setPaused(_ value: Bool) {
        if !value { restartAudio() }
        paused.store(value, ordering: .releasing)
        controlQueue.async { [self] in
            lock.withLock { cache?.setHeld(value) }
        }
        guard value else { return }
        // A running output keeps the audio hardware, and the app, awake. Stop it once the pause looks like it will last.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleStopDelay) { [weak self] in
            guard let self, self.paused.load(ordering: .relaxed) else { return }
            self.audioEngine.pause()
        }
    }

    func setVolume(_ v: Double) {
        audioEngine.mainMixerNode.outputVolume = Float(max(0, min(1, v)))
    }

    func setFXMode(_ mode: FxMode) { setFX { $0.mode = mode } }
    func setEQ(_ eq: [Double]) { setFX { $0.eq = eq } }

    private func setFX(_ change: (inout FXSettings) -> Void) {
        fxLock.withLock { change(&fxPending) }
    }

    /// Song position (seconds) of what is reaching the speakers.
    var position: Double {
        Double(positionBase.load(ordering: .relaxed) + playedFrames.load(ordering: .relaxed)) / Double(sampleRate)
    }

    var isBusy: Bool { busyFlag.load(ordering: .relaxed) }
    var lastError: String? { lock.try() ? { defer { lock.unlock() }; return renderError }() : nil }

    /// Register snapshots (one array of 32 per chip) for what is playing now.
    func currentRegisters() -> [[UInt8]]? {
        let frame = Int(position * Double(sampleRate))
        return vizLock.withLock {
            viz.last(where: { $0.frame <= frame })?.regs ?? viz.first?.regs
        }
    }

    /// The most recently played samples (mono), for the oscilloscope.
    func recentSamples(_ count: Int) -> [Float] {
        let read = readFrame.load(ordering: .acquiring)
        let n = min(count, capacityFrames / 2)
        return (0..<n).map { i in
            let slot = ((read - n + i + capacityFrames * 4) % capacityFrames) * 2
            return (ring[slot] + ring[slot + 1]) * 0.5
        }
    }

    // MARK: Locked helpers (call with `lock` held)

    private func applyMutes() {
        for chip in 0..<max(1, chips) {
            for v in 0..<3 { player.mute(chip: chip, voice: v, mutes[v]) }
        }
    }

    private func dropCaches() {
        cache?.cancel()
        cache = nil
        staleCache?.cancel()
        staleCache = nil
    }

    private func startCache() {
        guard let seconds = cacheSeconds else { return }
        let c = RenderCache(seconds: seconds, coversWholeTune: coversWholeTune, sampleRate: sampleRate, chunkFrames: Self.chunkFrames)
        c.setHeld(paused.load(ordering: .relaxed))
        c.start(data: tuneData, song: song, config: config, roms: roms, mutes: mutes, sampleRate: sampleRate)
        cache = c
    }

    private func seekLocked(_ seconds: Double) {
        let target = max(0, Int(seconds * Double(sampleRate)))
        if let c = cache, target < c.capacityFrames - Self.chunkFrames {
            cachePos = target / Self.chunkFrames * Self.chunkFrames
            c.setPlayhead(chunk: cachePos / Self.chunkFrames)
            source = .cache
            flush(base: cachePos)
        } else {
            flush(base: target)
            fastForwardLive(to: target)
            source = .live
        }
    }

    /// Runs the live emulator to `target`, restarting the song first if it is already past it.
    private func fastForwardLive(to target: Int) {
        if target < liveFrame {
            try? player.selectSong(song)
            applyMutes()
            liveFrame = 0
        }
        let scratch = UnsafeMutableBufferPointer<Int16>.allocate(capacity: Self.chunkFrames * 2)
        defer { scratch.deallocate() }
        while liveFrame < target {
            let n = min(Self.chunkFrames, target - liveFrame)
            do {
                try player.render(into: UnsafeMutableBufferPointer(rebasing: scratch[0..<(n * 2)]))
            } catch {
                renderError = "\(error)"
                return
            }
            liveFrame += n
        }
    }

    /// Drops queued audio; playback continues with whatever the producer writes next, at song position `base`.
    private func flush(base: Int) {
        pendingBase.store(base, ordering: .relaxed)
        flushTo.store(writeFrame.load(ordering: .acquiring), ordering: .releasing)
        vizLock.withLock { viz.removeAll() }
    }

    // MARK: Render thread

    private enum Step { case rendered, wait }

    private func renderLoop() {
        let scratch = UnsafeMutableBufferPointer<Int16>.allocate(capacity: Self.chunkFrames * 2)
        defer { scratch.deallocate() }
        let target = Int(Double(sampleRate) * Self.bufferAhead)
        while running.load(ordering: .relaxed) {
            let write = writeFrame.load(ordering: .relaxed)
            let pending = flushTo.load(ordering: .acquiring)
            let queued = write - (pending >= 0 ? pending : readFrame.load(ordering: .acquiring))
            // Keeps filling while paused too, so pressing play starts without an underrun.
            if queued + Self.chunkFrames > target {
                // Sleep until about a chunk has drained; nothing drains while paused.
                let drain = Double(queued + Self.chunkFrames - target) / Double(sampleRate)
                Thread.sleep(forTimeInterval: paused.load(ordering: .relaxed) ? 0.05 : min(0.05, max(0.005, drain)))
                continue
            }
            if renderChunk(scratch) == .wait { Thread.sleep(forTimeInterval: 0.005) }
        }
    }

    private func renderChunk(_ scratch: UnsafeMutableBufferPointer<Int16>) -> Step {
        lock.withLock {
            guard loaded, renderError == nil else { return .wait }
            if source == .live, let c = cache, c.coversWholeTune, liveFrame % Self.chunkFrames == 0,
               liveFrame / Self.chunkFrames < c.rendered {
                // The cache has caught up with playback: play from it and let the live emulator rest.
                cachePos = liveFrame
                source = .cache
            }
            let songFrame: Int
            var regs: [[UInt8]] = []
            switch source {
            case .live:
                cache?.setPlayhead(chunk: liveFrame / Self.chunkFrames)
                do {
                    try player.render(into: scratch)
                } catch {
                    renderError = "\(error)"
                    return .wait
                }
                songFrame = liveFrame
                liveFrame += Self.chunkFrames
                for chip in 0..<min(chips, RenderCache.chipSlots) {
                    if let r = player.registers(chip: chip) { regs.append(r) }
                }
            case .cache:
                guard let c = cache else {
                    source = .live
                    return .wait
                }
                let index = cachePos / Self.chunkFrames
                c.setPlayhead(chunk: index)
                if index < c.rendered {
                    regs = c.read(chunk: index, into: scratch.baseAddress!)
                    if let stale = staleCache {
                        stale.cancel()
                        staleCache = nil
                    }
                } else if let stale = staleCache, index < stale.rendered {
                    stale.setPlayhead(chunk: index)
                    regs = stale.read(chunk: index, into: scratch.baseAddress!)
                } else if c.finished && !c.coversWholeTune {
                    // Past the end of the memory budget: carry on with the live emulator.
                    busyFlag.store(true, ordering: .relaxed)
                    fastForwardLive(to: cachePos)
                    busyFlag.store(false, ordering: .relaxed)
                    source = .live
                    return .wait
                } else if c.finished {
                    scratch.update(repeating: 0)
                } else {
                    busyFlag.store(true, ordering: .relaxed)
                    return .wait
                }
                busyFlag.store(false, ordering: .relaxed)
                songFrame = cachePos
                cachePos += Self.chunkFrames
            }

            let settings = fxLock.withLock { fxPending }
            if settings != fxApplied {
                if settings.mode != fxApplied.mode { fx.setMode(settings.mode) }
                if settings.eq != fxApplied.eq { fx.setEq(settings.eq) }
                fx.setMono(settings.mono)
                fx.setMains(settings.mainsHz)
                fxApplied = settings
            }
            for i in 0..<Self.chunkFrames {
                left[i] = Float(scratch[i * 2]) / 32768
                right[i] = Float(scratch[i * 2 + 1]) / 32768
            }
            fx.process(left: left, right: right)

            let w = writeFrame.load(ordering: .relaxed)
            for i in 0..<Self.chunkFrames {
                let slot = ((w + i) % capacityFrames) * 2
                ring[slot] = left[i]
                ring[slot + 1] = right[i]
            }
            writeFrame.store(w + Self.chunkFrames, ordering: .releasing)

            vizLock.withLock {
                viz.append(VizFrame(frame: songFrame, regs: regs))
                if viz.count > 64 { viz.removeFirst(viz.count - 64) }
            }
            return .rendered
        }
    }

    // MARK: Audio thread

    private func pull(_ frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        let l = buffers[0].mData!.assumingMemoryBound(to: Float.self)
        let r = buffers[1].mData!.assumingMemoryBound(to: Float.self)

        var read = readFrame.load(ordering: .relaxed)
        let flush = flushTo.exchange(-1, ordering: .acquiringAndReleasing)
        if flush >= 0 {
            read = flush
            positionBase.store(pendingBase.load(ordering: .relaxed), ordering: .relaxed)
            playedFrames.store(0, ordering: .relaxed)
        }
        let available = paused.load(ordering: .relaxed) ? 0 : writeFrame.load(ordering: .acquiring) - read
        let n = min(frames, max(0, available))
        for i in 0..<n {
            let slot = ((read + i) % capacityFrames) * 2
            l[i] = ring[slot]
            r[i] = ring[slot + 1]
        }
        for i in n..<frames {
            l[i] = 0
            r[i] = 0
        }
        readFrame.store(read + n, ordering: .releasing)
        playedFrames.add(n, ordering: .relaxed)
    }
}
