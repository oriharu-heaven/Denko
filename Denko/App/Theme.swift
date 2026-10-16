import AppKit
import SwiftUI

/// Denko's one color: the LED board's light, also used for emphasis in the panel and
/// settings. Default is the amber of station boards; four muted presets, or any color.
enum AccentPreset: String, CaseIterable, Identifiable {
    case station, sage, slate, clay, moss, custom

    /// "#RRGGBB" of the custom color (kept in sync by AppSettings).
    nonisolated(unsafe) static var customHex = "#FF9E29"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sage: return "セージ"
        case .slate: return "スレート"
        case .clay: return "クレイ"
        case .moss: return "モス"
        case .station: return "駅の案内"
        case .custom: return "好きな色"
        }
    }

    /// Light / dark variants, both low-saturation so they sit quietly next to black text.
    private var hex: (light: UInt32, dark: UInt32) {
        switch self {
        case .sage: return (0x5E8C6A, 0x8DB89A)
        case .slate: return (0x5B7A99, 0x8FA9C4)
        case .clay: return (0xA86F55, 0xCF977C)
        case .moss: return (0x707A45, 0xA3AD74)
        case .station: return (0xB86E10, 0xF0A040)
        case .custom:
            let v = UInt32(Self.customHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFF9E29
            return (Self.readableOnLight(v), v)
        }
    }

    /// A custom color dimmed until it reads on a light background (light yellow → ochre).
    private static func readableOnLight(_ v: UInt32) -> UInt32 {
        var r = Double((v >> 16) & 0xFF), g = Double((v >> 8) & 0xFF), b = Double(v & 0xFF)
        func luminance() -> Double { (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 }
        while luminance() > 0.45 { r *= 0.88; g *= 0.88; b *= 0.88 }
        return (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    }

    var nsColor: NSColor {
        let (light, dark) = hex
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
                .map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
            return NSColor(hex: isDark ? dark : light)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Lit LED color: the dark-mode variant, lifted a little so it glows on the black board.
    var ledColor: NSColor {
        switch self {
        case .station: return NSColor(hex: 0xFF9E29)
        case .custom: return NSColor(hex: hex.dark)
        default: return NSColor(hex: hex.dark).blended(withFraction: 0.45, of: .white) ?? NSColor(hex: hex.dark)
        }
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

enum Theme {
    /// Usage at or above this is emphasized with the accent color.
    static let highUsage: Double = 80
}
