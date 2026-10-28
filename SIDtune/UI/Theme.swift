import SwiftUI

/// The six themes of the web app (src/styles.css). Views read colours from the theme, never hardcode them.
enum ThemeID: String, Codable, CaseIterable, Identifiable {
    case sidtune, c64, green, amber, monoDark = "mono-dark", monoLight = "mono-light"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sidtune: "SIDtune Purple"
        case .c64: "C64 Blue"
        case .green: "Green Phosphor"
        case .amber: "Amber Phosphor"
        case .monoDark: "Monochrome Dark"
        case .monoLight: "Monochrome Light"
        }
    }

    var theme: Theme {
        switch self {
        case .sidtune:
            Theme(bg: 0x120E27, bg2: 0x1A1538, panel: 0x231C4D, panel2: 0x2C2460, text: 0xEEEAFF, muted: 0xA39DD6,
                  accent: 0x8B7FE8, accentStrong: 0xA89DFF, accentInk: 0x120E27,
                  vizBg: 0x0E0A22, vizTri: 0x5FD7FF, vizSaw: 0xFFD75F, vizPulse: 0xFF7AB6, vizNoise: 0xB8B8C8, vizMix: 0xB48CFF, vizScope: 0xA0A0FF)
        case .c64:
            Theme(bg: 0x352879, bg2: 0x2A1F66, panel: 0x43379A, panel2: 0x4E42AB, text: 0xD2CCFF, muted: 0xA49AEA,
                  accent: 0x6C5EB5, accentStrong: 0xB4ABFF, accentInk: 0xFFFFFF,
                  vizBg: 0x241A5A, vizTri: 0x5FD7FF, vizSaw: 0xFFD75F, vizPulse: 0xFF7AB6, vizNoise: 0xB8B8C8, vizMix: 0xB48CFF, vizScope: 0xB4ABFF)
        case .green:
            Theme.phosphor(p: 0x33FF66, bg: 0x020A03, bg2: 0x031206, panel: 0x07200C, panel2: 0x0A2B10,
                           saw: 0x26CC50, pulse: 0x1C993C, noise: 0x136628, mix: 0x8CFFAA)
        case .amber:
            Theme.phosphor(p: 0xFFB000, bg: 0x0C0700, bg2: 0x140C00, panel: 0x241600, panel2: 0x2F1D00,
                           saw: 0xCC8D00, pulse: 0x996A00, noise: 0x664700, mix: 0xFFD480)
        case .monoDark:
            Theme(bg: 0x0B0B0B, bg2: 0x141414, panel: 0x1F1F1F, panel2: 0x292929, text: 0xEDEDED, muted: 0x9B9B9B,
                  accent: 0xD0D0D0, accentStrong: 0xFFFFFF, accentInk: 0x000000,
                  vizBg: 0x000000, vizTri: 0xFFFFFF, vizSaw: 0xC8C8C8, vizPulse: 0x969696, vizNoise: 0x6E6E6E, vizMix: 0xE0E0E0, vizScope: 0xFFFFFF)
        case .monoLight:
            Theme(bg: 0xF3F3F3, bg2: 0xFFFFFF, panel: 0xE6E6E6, panel2: 0xDCDCDC, text: 0x141414, muted: 0x5C5C5C,
                  accent: 0x2B2B2B, accentStrong: 0x000000, accentInk: 0xFFFFFF,
                  vizBg: 0xFFFFFF, vizTri: 0x000000, vizSaw: 0x444444, vizPulse: 0x777777, vizNoise: 0xAAAAAA, vizMix: 0x222222, vizScope: 0x000000,
                  isLight: true)
        }
    }
}

enum FontID: String, Codable, CaseIterable, Identifiable {
    case system, apple2, c64, mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System (default)"
        case .apple2: "Apple II (Print Char 21)"
        case .c64: "C64 (Pet Me 64)"
        case .mono: "Monospaced"
        }
    }

    /// The Kreative Korp fonts are bundled byte-identical to the originals (their licence forbids modifying them).
    func font(_ style: Font.TextStyle) -> Font {
        switch self {
        case .system: .system(style)
        case .mono: .system(style, design: .monospaced)
        case .apple2: .custom("PrintChar21", size: Self.retroSize(style), relativeTo: style)
        case .c64: .custom("PetMe64", size: Self.retroSize(style), relativeTo: style)
        }
    }

    /// The pixel fonts are wide, so they run a few points smaller than the system font.
    private static func retroSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 18
        case .title3: 16
        case .headline, .body: 13
        case .callout, .subheadline: 12
        default: 10
        }
    }
}

struct Theme {
    var bg, bg2, panel, panel2, text, muted, accent, accentStrong, accentInk: Color
    var vizBg, vizTri, vizSaw, vizPulse, vizNoise, vizMix, vizScope: Color
    var isLight = false

    init(bg: UInt32, bg2: UInt32, panel: UInt32, panel2: UInt32, text: UInt32, muted: UInt32, accent: UInt32, accentStrong: UInt32,
         accentInk: UInt32, vizBg: UInt32, vizTri: UInt32, vizSaw: UInt32, vizPulse: UInt32, vizNoise: UInt32, vizMix: UInt32,
         vizScope: UInt32, isLight: Bool = false) {
        self.bg = Color(hex: bg)
        self.bg2 = Color(hex: bg2)
        self.panel = Color(hex: panel)
        self.panel2 = Color(hex: panel2)
        self.text = Color(hex: text)
        self.muted = Color(hex: muted)
        self.accent = Color(hex: accent)
        self.accentStrong = Color(hex: accentStrong)
        self.accentInk = Color(hex: accentInk)
        self.vizBg = Color(hex: vizBg)
        self.vizTri = Color(hex: vizTri)
        self.vizSaw = Color(hex: vizSaw)
        self.vizPulse = Color(hex: vizPulse)
        self.vizNoise = Color(hex: vizNoise)
        self.vizMix = Color(hex: vizMix)
        self.vizScope = Color(hex: vizScope)
        self.isLight = isLight
    }

    /// Green and amber phosphor: everything is shades of one colour, as in styles.css's color-mix() rules.
    static func phosphor(p: UInt32, bg: UInt32, bg2: UInt32, panel: UInt32, panel2: UInt32, saw: UInt32, pulse: UInt32, noise: UInt32, mix: UInt32) -> Theme {
        Theme(bg: bg, bg2: bg2, panel: panel, panel2: panel2, text: p, muted: blend(p, bg, 0.62), accent: blend(p, bg, 0.75),
              accentStrong: p, accentInk: bg, vizBg: 0x000000, vizTri: p, vizSaw: saw, vizPulse: pulse, vizNoise: noise, vizMix: mix, vizScope: p)
    }

    private static func blend(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ c: UInt32, _ s: UInt32) -> Double { Double((c >> s) & 0xFF) }
        func mix(_ s: UInt32) -> UInt32 { UInt32((ch(a, s) * t + ch(b, s) * (1 - t)).rounded()) << s }
        return mix(16) | mix(8) | mix(0)
    }

    var colorScheme: ColorScheme { isLight ? .light : .dark }

    /// Waveform colours for the visualiser, keyed by the SID control register's waveform bits.
    func waveColor(_ bits: Int) -> Color {
        switch bits {
        case 1: vizTri
        case 2: vizSaw
        case 4: vizPulse
        case 8: vizNoise
        case 0: vizNoise
        default: vizMix
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ThemeID.sidtune.theme
}

private struct FontIDKey: EnvironmentKey {
    static let defaultValue = FontID.system
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }

    var fontID: FontID {
        get { self[FontIDKey.self] }
        set { self[FontIDKey.self] = newValue }
    }
}

/// Text in the chosen font.
struct AppFont: ViewModifier {
    @Environment(\.fontID) private var fontID
    let style: Font.TextStyle

    func body(content: Content) -> some View {
        content.font(fontID.font(style))
    }
}

extension View {
    func appFont(_ style: Font.TextStyle) -> some View { modifier(AppFont(style: style)) }
}
