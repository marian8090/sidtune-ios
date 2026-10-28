import Foundation

/// Audio quality modes, ported from the web app's src/audio/fx.ts (itself using ultraSID's SIDEffects parameter values).
///
///   REAL            cheap TV speaker: mains hum, speaker EQ, tanh distortion, hiss
///   PURE            the raw chip, only inaudible subsonics removed
///   MAGIC/EPIC/MYTHIC  one chain at three intensities: an LR8 crossover keeps the bass mono and untouched while the highs get
///                   mono-compatible widening, a ping-pong delay and a reverb (all send-style), then a 3-band EQ.
public enum FxMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case real, pure, magic, epic, mythic

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .real: "Real"
        case .pure: "Pure"
        case .magic: "Magic"
        case .epic: "Epic"
        case .mythic: "Mythic"
        }
    }

    public var blurb: String {
        switch self {
        case .real: "Through a tiny monitor speaker, as most people heard it in the eighties"
        case .pure: "The raw chip, nothing added"
        case .magic: "Mild stereo widening, light delay and reverb. The recommended default"
        case .epic: "The same chain turned up: wide, deep delay and reverb, bold bass"
        case .mythic: "Everything cranked to 11"
        }
    }

    struct Params {
        var real: Bool
        var width: Double
        var delayWet: Double
        var delayFeedback: Double
        var reverbWet: Double
        var extraLowDb: Double
        var trimDb: Double
        var eqDb: [Double]
    }

    var params: Params {
        let flat = [0.0, 0, 0], fxEq = [4.0, 2, 3]
        return switch self {
        case .real: Params(real: true, width: 0, delayWet: 0, delayFeedback: 0.42, reverbWet: 0, extraLowDb: 0, trimDb: -8.5, eqDb: flat)
        case .pure: Params(real: false, width: 0, delayWet: 0, delayFeedback: 0.42, reverbWet: 0, extraLowDb: 0, trimDb: -5, eqDb: flat)
        case .magic: Params(real: false, width: 0.5, delayWet: 0.17, delayFeedback: 0.42, reverbWet: 0.32, extraLowDb: 0, trimDb: -7, eqDb: fxEq)
        case .epic: Params(real: false, width: 0.8, delayWet: 0.31, delayFeedback: 0.55, reverbWet: 0.45, extraLowDb: 1.5, trimDb: -7, eqDb: fxEq)
        case .mythic: Params(real: false, width: 1.0, delayWet: 0.46, delayFeedback: 0.71, reverbWet: 0.6, extraLowDb: 3, trimDb: -8, eqDb: fxEq)
        }
    }
}

private let splitterHz = 200.0
private let splitterParkHz = 10.0 // PURE parks the crossover below the audible band
private let splitterLowGainDb = 1.5
private let lr8Q = [0.541196100146197, 0.541196100146197, 1.30656296487637653, 1.30656296487637653]
private let eqHz = [200.0, 1000, 4000]
private let wideMonoDelaySeconds = 512.0 / 44100
private let pingPongSeconds = 32768.0 / 44100
private let fxNoiseGain = 0.05 * 0.05
private let realNoiseGain = 0.12 * 0.12
private let realHumGain = 0.07 * 0.07
private let realDistortion = 1.75
private let noiseColor = 0.5 * 0.5
private let humHarmonics = 16

private func dbToLin(_ db: Double) -> Double { pow(10, db / 20) }

/// Processes fixed-size stereo blocks. Not thread-safe: configure and process from the same thread.
public final class FXChain {
    public let sampleRate: Double
    public let blockSize: Int

    private var mode: FxMode = .magic
    private var userEq = [0.0, 0, 0]
    private var mono = true
    private let glideSeconds = 0.1
    private let sampleCoeff: Double
    private let blockCoeff: Double

    private var realGain = Glide(0), fxGain = Glide(1), lowGain = Glide(1), side = Glide(0)
    private var feedback = Glide(0), delayWet = Glide(0), reverbWet = Glide(0)
    private var fxNoise = Glide(0), realNoise = Glide(0), hum = Glide(0), trim = Glide(1)
    private var splitFreq = Glide(splitterHz)
    private var fxEqGain = [Glide(0), Glide(0), Glide(0)]
    private var realEqGain = [Glide(0), Glide(0), Glide(0)]

    private var lows: [Biquad]
    private var highs: [Biquad]
    private var fxEq: [Biquad]
    private var realEq: [Biquad]
    private var speaker: [Biquad]
    private var sideDelay: DelayLine
    private var delayA: DelayLine
    private var delayB: DelayLine
    private let reverbL: Convolver
    private let reverbR: Convolver
    private var reverbActive = true

    private let noiseL: [Double]
    private let noiseR: [Double]
    private var noisePos = 0
    private let humTable: [Double]
    private var humPhase = 0.0
    private var humHz = 50.0

    private var ppL: [Float], ppR: [Float], revL: [Float], revR: [Float]
    private var lowL: [Double], lowR: [Double], realL: [Double], realR: [Double]
    private var revGain: [Double], fxNoiseG: [Double], trimG: [Double]

    public init(sampleRate: Double, blockSize: Int = 1024) {
        self.sampleRate = sampleRate
        self.blockSize = blockSize
        sampleCoeff = 1 - exp(-1 / (glideSeconds * sampleRate))
        blockCoeff = 1 - exp(-Double(blockSize) / (glideSeconds * sampleRate))

        lows = lr8Q.map { Biquad(.lowpass(q: $0), frequency: splitterHz, sampleRate: sampleRate) }
        highs = lr8Q.map { Biquad(.highpass(q: $0), frequency: splitterHz, sampleRate: sampleRate) }
        func eq() -> [Biquad] {
            [Biquad(.lowShelf, frequency: eqHz[0], sampleRate: sampleRate),
             Biquad(.peaking(q: 0.707), frequency: eqHz[1], sampleRate: sampleRate),
             Biquad(.highShelf, frequency: eqHz[2], sampleRate: sampleRate)]
        }
        fxEq = eq()
        realEq = eq()
        speaker = [
            Biquad(.highpass(q: 1.5), frequency: 180, sampleRate: sampleRate),
            Biquad(.highpass(q: 1.5), frequency: 180, sampleRate: sampleRate),
            Biquad(.peaking(q: 1.41), frequency: 125, gainDb: -7, sampleRate: sampleRate),
            Biquad(.peaking(q: 1.41), frequency: 250, gainDb: 5, sampleRate: sampleRate),
            Biquad(.peaking(q: 1.41), frequency: 500, gainDb: -7, sampleRate: sampleRate),
            Biquad(.peaking(q: 1.41), frequency: 1000, gainDb: 10, sampleRate: sampleRate),
            Biquad(.peaking(q: 1.41), frequency: 2000, gainDb: -5, sampleRate: sampleRate),
            Biquad(.peaking(q: 1.41), frequency: 4000, gainDb: 14, sampleRate: sampleRate),
            Biquad(.peaking(q: 1.41), frequency: 8000, gainDb: -7, sampleRate: sampleRate),
            Biquad(.lowpass(q: 1.0), frequency: 16000, sampleRate: sampleRate),
        ]
        sideDelay = DelayLine(samples: Int((wideMonoDelaySeconds * sampleRate).rounded()))
        delayA = DelayLine(samples: Int((pingPongSeconds * sampleRate).rounded()))
        delayB = delayA

        let ir = Self.reverbImpulse(sampleRate: sampleRate)
        reverbL = Convolver(impulse: ir.0, blockSize: blockSize)
        reverbR = Convolver(impulse: ir.1, blockSize: blockSize)
        (noiseL, noiseR) = Self.noise(sampleRate: sampleRate, seconds: 4)
        humTable = Self.humWave()

        ppL = [Float](repeating: 0, count: blockSize)
        ppR = ppL
        revL = ppL
        revR = ppL
        lowL = [Double](repeating: 0, count: blockSize)
        lowR = lowL
        realL = lowL
        realR = lowL
        revGain = lowL
        fxNoiseG = lowL
        trimG = lowL
        apply(immediate: true)
    }

    public func setMode(_ m: FxMode, immediate: Bool = false) {
        mode = m
        apply(immediate: immediate)
    }

    /// Equalizer offsets in dB for the low (200 Hz), mid (1 kHz) and high (4 kHz) bands.
    public func setEq(_ eq: [Double], immediate: Bool = false) {
        userEq = Array((eq + [0, 0, 0]).prefix(3))
        apply(immediate: immediate)
    }

    /// A single SID chip is mono and gets widened; multi-chip tunes already have a stereo image.
    public func setMono(_ m: Bool) {
        mono = m
    }

    /// Mains hum frequency of the machine the tune was written for.
    public func setMains(_ hz: Double) {
        humHz = hz
    }

    private func apply(immediate: Bool) {
        let m = mode.params
        let fxOn = !m.real && mode != .pure
        realGain.target = m.real ? 1 : 0
        fxGain.target = m.real ? 0 : 1
        splitFreq.target = fxOn ? splitterHz : splitterParkHz
        lowGain.target = dbToLin(fxOn ? splitterLowGainDb + m.extraLowDb : 0)
        side.target = fxOn ? m.width : 0
        feedback.target = m.delayFeedback * m.delayFeedback
        delayWet.target = fxOn ? m.delayWet * m.delayWet : 0
        reverbWet.target = fxOn ? m.reverbWet * m.reverbWet : 0
        fxNoise.target = fxOn ? fxNoiseGain : 0
        realNoise.target = m.real ? realNoiseGain : 0
        hum.target = m.real ? realHumGain : 0
        for b in 0..<3 {
            fxEqGain[b].target = m.eqDb[b] + userEq[b]
            realEqGain[b].target = userEq[b]
        }
        trim.target = dbToLin(m.trimDb)
        if immediate {
            for i in 0..<3 {
                fxEqGain[i].jump()
                realEqGain[i].jump()
            }
            realGain.jump(); fxGain.jump(); splitFreq.jump(); lowGain.jump(); side.jump(); feedback.jump(); delayWet.jump()
            reverbWet.jump(); fxNoise.jump(); realNoise.jump(); hum.jump(); trim.jump()
            updateFilters(force: true)
        }
    }

    private func updateFilters(force: Bool = false) {
        let f = splitFreq.next(force ? 1 : blockCoeff)
        if force || abs(lows[0].frequency - f) > 1e-6 {
            for i in 0..<lows.count {
                lows[i].frequency = f
                lows[i].update(sampleRate: sampleRate)
                highs[i].frequency = f
                highs[i].update(sampleRate: sampleRate)
            }
        }
        for b in 0..<3 {
            let g1 = fxEqGain[b].next(force ? 1 : blockCoeff)
            if force || abs(fxEq[b].gainDb - g1) > 1e-6 {
                fxEq[b].gainDb = g1
                fxEq[b].update(sampleRate: sampleRate)
            }
            let g2 = realEqGain[b].next(force ? 1 : blockCoeff)
            if force || abs(realEq[b].gainDb - g2) > 1e-6 {
                realEq[b].gainDb = g2
                realEq[b].update(sampleRate: sampleRate)
            }
        }
    }

    /// Processes one block of exactly `blockSize` frames in place.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        updateFilters()
        let c = sampleCoeff
        let humStep = humHz / sampleRate
        let noiseCount = noiseL.count
        let humCount = Double(humTable.count)

        for i in 0..<blockSize {
            let xl = Double(left[i]), xr = Double(right[i])
            let gReal = realGain.next(c), gFx = fxGain.next(c), gLow = lowGain.next(c), gSide = side.next(c)
            let gFb = feedback.next(c), gWet = delayWet.next(c)
            let nl = noiseL[noisePos], nr = noiseR[noisePos]
            noisePos += 1
            if noisePos == noiseCount { noisePos = 0 }
            revGain[i] = reverbWet.next(c)
            fxNoiseG[i] = fxNoise.next(c)
            trimG[i] = trim.next(c)

            // REAL: speaker chain fed with the chip plus mains hum
            let h = humTable[Int(humPhase * humCount) % humTable.count] * hum.next(c)
            humPhase += humStep
            if humPhase >= 1 { humPhase -= 1 }
            var sl = xl * gReal + h, sr = xr * gReal + h
            for f in speaker.indices { speaker[f].process(&sl, &sr) }
            sl = tanh(min(1, max(-1, sl)) * realDistortion) / realDistortion
            sr = tanh(min(1, max(-1, sr)) * realDistortion) / realDistortion
            for f in realEq.indices { realEq[f].process(&sl, &sr) }
            let gRealNoise = realNoise.next(c)
            realL[i] = sl + nl * gRealNoise
            realR[i] = sr + nr * gRealNoise

            // FX: crossover; the lows go straight to the EQ, the highs through widening, delay and reverb
            var ll = xl * gFx, lr = xr * gFx
            var hl = ll, hr = lr
            for f in lows.indices { lows[f].process(&ll, &lr) }
            for f in highs.indices { highs[f].process(&hl, &hr) }
            lowL[i] = ll * gLow
            lowR[i] = lr * gLow

            var wl = hl, wr = hr
            if mono {
                let delayed = sideDelay.read()
                sideDelay.write(hl)
                wl = hl + gSide * delayed
                wr = hl - gSide * delayed
            }
            let a = delayA.read(), b = delayB.read()
            delayA.write(wl + gFb * b)
            delayB.write(wr + gFb * a)
            ppL[i] = Float(wl + gWet * b)
            ppR[i] = Float(wr + gWet * a)
        }

        let wantReverb = reverbWet.target > 0 || reverbWet.value > 1e-5
        if wantReverb {
            if !reverbActive {
                reverbL.reset()
                reverbR.reset()
                reverbActive = true
            }
            reverbL.process(ppL, &revL)
            reverbR.process(ppR, &revR)
        } else {
            reverbActive = false
        }

        for i in 0..<blockSize {
            let rev = wantReverb ? revGain[i] : 0
            var ml = Double(ppL[i]) + rev * Double(revL[i]) + lowL[i]
            var mr = Double(ppR[i]) + rev * Double(revR[i]) + lowR[i]
            for f in fxEq.indices { fxEq[f].process(&ml, &mr) }
            let n = noisePos - blockSize + i
            let k = n < 0 ? n + noiseCount : n
            ml += noiseL[k] * fxNoiseG[i]
            mr += noiseR[k] * fxNoiseG[i]
            left[i] = Float((ml + realL[i]) * trimG[i])
            right[i] = Float((mr + realR[i]) * trimG[i])
        }
    }

    // MARK: Generated signals (same recipes and seeds as fx.ts)

    private static func noise(sampleRate: Double, seconds: Double) -> ([Double], [Double]) {
        let n = Int(sampleRate * seconds)
        var seed: UInt32 = 12345
        var out: [[Double]] = []
        for _ in 0..<2 {
            var d = [Double](repeating: 0, count: n)
            var cur = 0.0
            for i in 0..<n {
                seed = 1_103_515_245 &* seed &+ 12345
                let white = Double(seed & 0x7FFF_FFFF) / 2_147_483_647 - 0.5
                cur += noiseColor * (white - cur)
                d[i] = cur
            }
            out.append(d)
        }
        return (out[0], out[1])
    }

    /// A dense, darkening, exponentially decaying stereo tail: a large plate/hall, normalised to unit energy.
    static func reverbImpulse(sampleRate: Double) -> ([Float], [Float]) {
        let len = Int(sampleRate * 2.6)
        let pre = Int(sampleRate * 0.02)
        var seed: UInt32 = 98765
        var energy = 0.0
        var chans: [[Double]] = []
        for _ in 0..<2 {
            var d = [Double](repeating: 0, count: len)
            var lp = 0.0
            for i in pre..<len {
                let t = Double(i - pre) / sampleRate
                seed = 1_664_525 &* seed &+ 1_013_904_223
                let white = Double(seed) / 4_294_967_296 - 0.5
                lp += (0.75 * exp(-t / 0.9) + 0.07) * (white - lp)
                let env = exp(-t * log(1000) / 1.9) * min(1, t / 0.012)
                d[i] = lp * env
                energy += d[i] * d[i]
            }
            chans.append(d)
        }
        let norm = 1 / sqrt(energy / 2)
        return (chans[0].map { Float($0 * norm) }, chans[1].map { Float($0 * norm) })
    }

    /// One period of the mains hum: decaying harmonics, normalised to a peak of 1 like Web Audio's PeriodicWave.
    private static func humWave() -> [Double] {
        let decay = 2 + (0.7 - 2) * 0.62
        var amps: [Double] = []
        for n in 1...humHarmonics {
            var a = pow(Double(n), -decay)
            if n == 1 { a *= 0.6 } else if n & 1 == 1 { a *= 0.5 }
            amps.append(a)
        }
        let size = 4096
        var table = (0..<size).map { i -> Double in
            let theta = 2 * Double.pi * Double(i) / Double(size)
            return amps.enumerated().reduce(0) { $0 + $1.element * cos(Double($1.offset + 1) * theta) }
        }
        let peak = table.map(abs).max() ?? 1
        table = table.map { $0 / peak }
        return table
    }
}
