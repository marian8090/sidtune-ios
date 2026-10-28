import CSIDPlayFP
import Foundation

public struct SIDConfig: Equatable, Sendable {
    public enum Emulation: Sendable { case residfp, sidlite }
    public enum ChipModel: Sendable { case mos6581, mos8580 }
    public enum C64Model: Sendable { case pal, ntsc }

    public var emulation: Emulation = .residfp
    /// nil = use what the tune asks for (6581 when it doesn't say).
    public var chipModel: ChipModel?
    /// nil = use what the tune asks for (PAL when it doesn't say).
    public var c64Model: C64Model?
    public var digiBoost = true

    public init() {}

    var raw: sid_config {
        sid_config(
            emulation: emulation == .sidlite ? SID_EMU_SIDLITE : SID_EMU_RESIDFP,
            sid_model: chipModel == .mos8580 ? SID_CHIP_8580 : SID_CHIP_6581,
            force_sid_model: chipModel != nil,
            c64_model: c64Model == .ntsc ? SID_C64_NTSC : SID_C64_PAL,
            force_c64_model: c64Model != nil,
            digi_boost: digiBoost
        )
    }
}

public struct SIDTuneInfo: Equatable, Sendable {
    public enum Clock: Sendable { case unknown, pal, ntsc, any }

    /// Subtune numbers are 1-based.
    public var songs: Int
    public var startSong: Int
    public var currentSong: Int
    public var sidChips: Int
    public var clock: Clock
    public var format: String
    public var md5: String?
    public var infoStrings: [String]
}

public struct SIDError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public var errorDescription: String? { description }

    public init(description: String) {
        self.description = description
    }
}

/// One emulated C64. Not thread-safe: use each instance from one thread (the render thread) at a time.
public final class SIDPlayer {
    public let sampleRate: Int
    private let engine: OpaquePointer

    public init(sampleRate: Int) {
        self.sampleRate = sampleRate
        engine = sid_engine_create(UInt32(sampleRate))
    }

    deinit { sid_engine_destroy(engine) }

    private var error: SIDError { SIDError(description: String(cString: sid_engine_error(engine))) }

    public func setROMs(kernal: [UInt8]?, basic: [UInt8]?, chargen: [UInt8]?) {
        withOptionalPointer(kernal) { k in
            withOptionalPointer(basic) { b in
                withOptionalPointer(chargen) { c in sid_engine_set_roms(engine, k, b, c) }
            }
        }
    }

    /// Loads a .sid file and starts `song` (1-based, nil = the tune's default).
    public func load(_ data: [UInt8], song: Int? = nil, config: SIDConfig) throws {
        var raw = config.raw
        let ok = data.withUnsafeBufferPointer { buf in
            sid_engine_load(engine, buf.baseAddress, UInt32(buf.count), UInt32(song ?? 0), &raw)
        }
        if !ok { throw error }
    }

    public func selectSong(_ song: Int) throws {
        if !sid_engine_select_song(engine, UInt32(song)) { throw error }
    }

    /// New emulation settings. Restarts the current song.
    public func configure(_ config: SIDConfig) throws {
        var raw = config.raw
        if !sid_engine_configure(engine, &raw) { throw error }
    }

    /// Fills `buffer` with interleaved stereo frames (`buffer.count / 2` of them).
    public func render(into buffer: UnsafeMutableBufferPointer<Int16>) throws {
        if sid_engine_render(engine, buffer.baseAddress, Int32(buffer.count / 2)) < 0 { throw error }
    }

    public func mute(chip: Int, voice: Int, _ muted: Bool) {
        sid_engine_mute(engine, UInt32(chip), UInt32(voice), muted)
    }

    /// The last values written to a chip's 32 registers, nil if the chip doesn't exist.
    public func registers(chip: Int) -> [UInt8]? {
        var regs = [UInt8](repeating: 0, count: 32)
        let ok = regs.withUnsafeMutableBufferPointer { sid_engine_registers(engine, UInt32(chip), $0.baseAddress) }
        return ok ? regs : nil
    }

    public var tuneInfo: SIDTuneInfo? {
        var raw = sid_tune_info()
        guard sid_engine_tune_info(engine, &raw) else { return nil }
        let format = withUnsafeBytes(of: raw.format) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let md5 = withUnsafeBytes(of: raw.md5) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let clock: SIDTuneInfo.Clock = switch raw.clock {
        case 1: .pal
        case 2: .ntsc
        case 3: .any
        default: .unknown
        }
        return SIDTuneInfo(
            songs: Int(raw.songs),
            startSong: Int(raw.start_song),
            currentSong: Int(raw.current_song),
            sidChips: Int(raw.sid_chips),
            clock: clock,
            format: format,
            md5: md5.isEmpty ? nil : md5,
            infoStrings: (0..<raw.info_count).map { String(cString: sid_engine_info_string(engine, $0)) }
        )
    }

    /// Emulated time since the song started.
    public var time: Double { Double(sid_engine_time_ms(engine)) / 1000 }
}

private func withOptionalPointer<R>(_ array: [UInt8]?, _ body: (UnsafePointer<UInt8>?) -> R) -> R {
    guard let array else { return body(nil) }
    return array.withUnsafeBufferPointer { body($0.baseAddress) }
}
