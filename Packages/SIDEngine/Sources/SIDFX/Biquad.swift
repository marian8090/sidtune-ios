import Foundation

/// RBJ cookbook biquads with Web Audio's conventions (shelves use S = 1), so fx.ts parameter values carry over unchanged.
/// Q is always linear here; fx.ts converts its lowpass/highpass Q to dB only because Web Audio wants it that way.
struct Biquad {
    enum Kind {
        case lowpass(q: Double)
        case highpass(q: Double)
        case peaking(q: Double)
        case lowShelf
        case highShelf
    }

    var kind: Kind
    var frequency: Double
    var gainDb: Double
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var zl1 = 0.0, zl2 = 0.0, zr1 = 0.0, zr2 = 0.0

    init(_ kind: Kind, frequency: Double, gainDb: Double = 0, sampleRate: Double) {
        self.kind = kind
        self.frequency = frequency
        self.gainDb = gainDb
        update(sampleRate: sampleRate)
    }

    mutating func update(sampleRate: Double) {
        let f = min(frequency, sampleRate * 0.49)
        let w0 = 2 * Double.pi * f / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let A = pow(10, gainDb / 40)
        var n0, n1, n2, d0, d1, d2: Double
        switch kind {
        case .lowpass(let q):
            let alpha = sw / (2 * q)
            (n0, n1, n2) = ((1 - cw) / 2, 1 - cw, (1 - cw) / 2)
            (d0, d1, d2) = (1 + alpha, -2 * cw, 1 - alpha)
        case .highpass(let q):
            let alpha = sw / (2 * q)
            (n0, n1, n2) = ((1 + cw) / 2, -(1 + cw), (1 + cw) / 2)
            (d0, d1, d2) = (1 + alpha, -2 * cw, 1 - alpha)
        case .peaking(let q):
            let alpha = sw / (2 * q)
            (n0, n1, n2) = (1 + alpha * A, -2 * cw, 1 - alpha * A)
            (d0, d1, d2) = (1 + alpha / A, -2 * cw, 1 - alpha / A)
        case .lowShelf:
            let k = 2 * sqrt(A) * sw / 2 * sqrt(2)
            (n0, n1, n2) = (A * ((A + 1) - (A - 1) * cw + k), 2 * A * ((A - 1) - (A + 1) * cw), A * ((A + 1) - (A - 1) * cw - k))
            (d0, d1, d2) = ((A + 1) + (A - 1) * cw + k, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - k)
        case .highShelf:
            let k = 2 * sqrt(A) * sw / 2 * sqrt(2)
            (n0, n1, n2) = (A * ((A + 1) + (A - 1) * cw + k), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - k))
            (d0, d1, d2) = ((A + 1) - (A - 1) * cw + k, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - k)
        }
        b0 = n0 / d0
        b1 = n1 / d0
        b2 = n2 / d0
        a1 = d1 / d0
        a2 = d2 / d0
    }

    @inline(__always)
    mutating func process(_ l: inout Double, _ r: inout Double) {
        let yl = b0 * l + zl1
        zl1 = b1 * l - a1 * yl + zl2
        zl2 = b2 * l - a2 * yl
        l = yl
        let yr = b0 * r + zr1
        zr1 = b1 * r - a1 * yr + zr2
        zr2 = b2 * r - a2 * yr
        r = yr
    }

    /// Magnitude response at `hz`, for tests.
    func magnitude(at hz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return sqrt((nr * nr + ni * ni) / (dr * dr + di * di))
    }
}

/// A one-pole glide towards a target, like Web Audio's `setTargetAtTime`.
struct Glide {
    var value: Double
    var target: Double

    init(_ v: Double) {
        value = v
        target = v
    }

    @inline(__always)
    mutating func next(_ coeff: Double) -> Double {
        value += coeff * (target - value)
        return value
    }

    mutating func jump() { value = target }
}

/// Stereo delay line with a fixed integer delay.
struct DelayLine {
    private var buffer: [Double]
    private var pos = 0

    init(samples: Int) {
        buffer = [Double](repeating: 0, count: max(1, samples))
    }

    @inline(__always)
    func read() -> Double { buffer[pos] }

    @inline(__always)
    mutating func write(_ v: Double) {
        buffer[pos] = v
        pos += 1
        if pos == buffer.count { pos = 0 }
    }

    mutating func clear() {
        for i in buffer.indices { buffer[i] = 0 }
    }
}
