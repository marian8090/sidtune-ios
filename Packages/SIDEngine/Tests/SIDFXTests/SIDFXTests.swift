import Foundation
import Testing
@testable import SIDFX

@Test func convolverMatchesDirectConvolution() {
    let block = 64
    var rng = SystemRandomNumberGenerator()
    let ir = (0..<300).map { _ in Float.random(in: -1...1, using: &rng) }
    let input = (0..<block * 8).map { _ in Float.random(in: -1...1, using: &rng) }
    let conv = Convolver(impulse: ir, blockSize: block)
    var fast = [Float](repeating: 0, count: input.count)
    for b in 0..<8 {
        input.withUnsafeBufferPointer { i in
            fast.withUnsafeMutableBufferPointer { o in conv.process(i.baseAddress! + b * block, o.baseAddress! + b * block) }
        }
    }
    var maxErr: Float = 0
    for n in input.indices {
        var direct: Float = 0
        for k in 0..<min(ir.count, n + 1) { direct += ir[k] * input[n - k] }
        maxErr = max(maxErr, abs(direct - fast[n]))
    }
    #expect(maxErr < 1e-3, "max error \(maxErr)")
}

@Test func biquadsMatchWebAudioShapes() {
    let fs = 48000.0
    let lp = Biquad(.lowpass(q: 0.7071), frequency: 1000, sampleRate: fs)
    #expect(abs(lp.magnitude(at: 1000, sampleRate: fs) - 0.7071) < 0.01)
    #expect(lp.magnitude(at: 100, sampleRate: fs) > 0.99)
    let peak = Biquad(.peaking(q: 1.41), frequency: 4000, gainDb: 14, sampleRate: fs)
    #expect(abs(20 * log10(peak.magnitude(at: 4000, sampleRate: fs)) - 14) < 0.01)
    let shelf = Biquad(.lowShelf, frequency: 200, gainDb: 6, sampleRate: fs)
    #expect(abs(20 * log10(shelf.magnitude(at: 20, sampleRate: fs)) - 6) < 0.1)
    #expect(abs(20 * log10(shelf.magnitude(at: 200, sampleRate: fs)) - 3) < 0.1)
    let high = Biquad(.highShelf, frequency: 4000, gainDb: -6, sampleRate: fs)
    #expect(abs(20 * log10(high.magnitude(at: 20000, sampleRate: fs)) + 6) < 0.2)
}

@Test(arguments: FxMode.allCases)
func everyModeProducesFiniteBoundedAudio(mode: FxMode) {
    let fx = FXChain(sampleRate: 48000)
    fx.setMode(mode, immediate: true)
    var l = [Float](repeating: 0, count: 1024), r = l
    var peak: Float = 0
    for block in 0..<100 {
        for i in 0..<1024 {
            let t = Float(block * 1024 + i) / 48000
            l[i] = 0.5 * sin(2 * .pi * 440 * t)
            r[i] = l[i]
        }
        fx.process(left: &l, right: &r)
        for v in l + r {
            #expect(v.isFinite)
            peak = max(peak, abs(v))
        }
    }
    #expect(peak > 0.01 && peak < 2, "\(mode): peak \(peak)")
}

@Test func pureIsCloseToTheDrySignal() {
    let fx = FXChain(sampleRate: 48000)
    fx.setMode(.pure, immediate: true)
    var l = [Float](repeating: 0, count: 1024), r = l
    var dry: [Float] = []
    for block in 0..<20 {
        for i in 0..<1024 {
            l[i] = 0.5 * sin(2 * .pi * 1000 * Float(block * 1024 + i) / 48000)
            r[i] = l[i]
        }
        dry = l
        fx.process(left: &l, right: &r)
    }
    // Pure is the raw chip at -5 dB. The crossover parked at 10 Hz still sums to an allpass, so compare level, not samples.
    let rms = { (x: [Float]) in sqrt(x.map { $0 * $0 }.reduce(0, +) / Float(x.count)) }
    let gainDb = 20 * log10(rms(l) / rms(dry))
    #expect(abs(gainDb + 5) < 0.1, "gain \(gainDb) dB")
}
