import Accelerate

/// Uniformly partitioned overlap-save FFT convolution of fixed-size blocks with a long impulse response (the reverb tail).
final class Convolver {
    let blockSize: Int
    private let fftSize: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let partitions: Int
    /// IR spectra, partition-major: partition k occupies [k * half, (k + 1) * half).
    private var irRe: [Float]
    private var irIm: [Float]
    /// Frequency-domain delay line of past input spectra.
    private var fdlRe: [Float]
    private var fdlIm: [Float]
    private var fdlPos = 0
    private var window: [Float]
    private var accRe: [Float]
    private var accIm: [Float]
    private var timeBuf: [Float]
    /// vDSP's real FFTs scale forward by 2 and inverse by N: the product of two forward spectra comes back 4N too big.
    private let scale: Float

    init(impulse: [Float], blockSize: Int) {
        self.blockSize = blockSize
        fftSize = blockSize * 2
        half = blockSize
        log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        partitions = max(1, (impulse.count + blockSize - 1) / blockSize)
        irRe = [Float](repeating: 0, count: partitions * half)
        irIm = irRe
        fdlRe = irRe
        fdlIm = irRe
        window = [Float](repeating: 0, count: fftSize)
        accRe = [Float](repeating: 0, count: half)
        accIm = accRe
        timeBuf = window
        scale = 1 / Float(4 * fftSize)

        for k in 0..<partitions {
            var segment = [Float](repeating: 0, count: fftSize)
            let start = k * blockSize
            let end = min(impulse.count, start + blockSize)
            if start < end { segment.replaceSubrange(0..<(end - start), with: impulse[start..<end]) }
            forward(segment, intoRe: &irRe, intoIm: &irIm, at: k * half)
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func reset() {
        vDSP.clear(&fdlRe)
        vDSP.clear(&fdlIm)
        vDSP.clear(&window)
    }

    private func forward(_ signal: [Float], intoRe re: inout [Float], intoIm im: inout [Float], at offset: Int) {
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress! + offset, imagp: ip.baseAddress! + offset)
                signal.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
    }

    /// Convolves one block of `blockSize` samples.
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) {
        window.withUnsafeMutableBufferPointer { w in
            w.baseAddress!.update(from: w.baseAddress! + blockSize, count: blockSize)
            (w.baseAddress! + blockSize).update(from: input, count: blockSize)
        }
        forward(window, intoRe: &fdlRe, intoIm: &fdlIm, at: fdlPos * half)

        vDSP.clear(&accRe)
        vDSP.clear(&accIm)
        let n = vDSP_Length(half - 1)
        fdlRe.withUnsafeBufferPointer { xr in
            fdlIm.withUnsafeBufferPointer { xi in
                irRe.withUnsafeBufferPointer { hr in
                    irIm.withUnsafeBufferPointer { hi in
                        accRe.withUnsafeMutableBufferPointer { ar in
                            accIm.withUnsafeMutableBufferPointer { ai in
                                var dc: Float = 0, nyquist: Float = 0
                                for k in 0..<partitions {
                                    let xo = ((fdlPos - k + partitions) % partitions) * half
                                    let ho = k * half
                                    // Element 0 packs the purely real DC and Nyquist bins.
                                    dc += xr[xo] * hr[ho]
                                    nyquist += xi[xo] * hi[ho]
                                    var x = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: xr.baseAddress! + xo + 1),
                                                            imagp: UnsafeMutablePointer(mutating: xi.baseAddress! + xo + 1))
                                    var h = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: hr.baseAddress! + ho + 1),
                                                            imagp: UnsafeMutablePointer(mutating: hi.baseAddress! + ho + 1))
                                    var acc = DSPSplitComplex(realp: ar.baseAddress! + 1, imagp: ai.baseAddress! + 1)
                                    vDSP_zvma(&x, 1, &h, 1, &acc, 1, &acc, 1, n)
                                }
                                ar[0] = dc
                                ai[0] = nyquist
                                var split = DSPSplitComplex(realp: ar.baseAddress!, imagp: ai.baseAddress!)
                                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                                timeBuf.withUnsafeMutableBytes { raw in
                                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                                }
                            }
                        }
                    }
                }
            }
        }
        timeBuf.withUnsafeBufferPointer { t in
            var s = scale
            vDSP_vsmul(t.baseAddress! + blockSize, 1, &s, output, 1, vDSP_Length(blockSize))
        }
        fdlPos = (fdlPos + 1) % partitions
    }
}
