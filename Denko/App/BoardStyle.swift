import AppKit

/// Look of the LED board (Denko's main surface).
/// Board base colors: always dark, so the dots stay readable.
enum BoardBase: String, CaseIterable, Identifiable {
    case black, navy, green, wine, brown, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .black: return "黒"
        case .navy: return "紺"
        case .green: return "深緑"
        case .wine: return "えんじ"
        case .brown: return "焦げ茶"
        case .custom: return "好きな色"
        }
    }
    static let presets: [BoardBase] = [.black, .navy, .green, .wine, .brown]

    func color(customHex: String) -> NSColor {
        switch self {
        case .black: return .black
        case .navy: return NSColor(srgbRed: 0.03, green: 0.05, blue: 0.14, alpha: 1)
        case .green: return NSColor(srgbRed: 0.02, green: 0.10, blue: 0.06, alpha: 1)
        case .wine: return NSColor(srgbRed: 0.14, green: 0.03, blue: 0.05, alpha: 1)
        case .brown: return NSColor(srgbRed: 0.11, green: 0.06, blue: 0.03, alpha: 1)
        case .custom: return Self.darkened(NSColor(hexString: customHex) ?? .black)
        }
    }

    /// Any color, pulled down to a dark shade so lit dots stay readable on it.
    static func darkened(_ c: NSColor) -> NSColor {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(s, 0.8), brightness: min(b, 0.16), alpha: 1)
    }
}

extension NSColor {
    /// "#RRGGBB" in sRGB.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    convenience init?(hexString: String) {
        let h = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// How much the storage tab looks at. Reading Desktop / Documents / other apps' data makes
/// macOS ask for permission, so the default stays out of those places.
enum StorageMode: String, CaseIterable, Identifiable {
    case off, basic, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "使わない"
        case .basic: return "かんたん（確認なし）"
        case .full: return "詳しく"
        }
    }
}

/// The little character on the board.
enum CharacterKind: String, CaseIterable, Identifiable {
    case frog, train, chick
    var id: String { rawValue }
    var label: String {
        switch self {
        case .frog: return "カエル"
        case .train: return "電車"
        case .chick: return "ひよこ"
        }
    }
    var motion: String {
        switch self {
        case .frog: return "Mac が忙しいほど速く跳ねます。"
        case .train: return "Mac が忙しいほど速く走ります。"
        case .chick: return "Mac が忙しいほど速くはばたきます。"
        }
    }
}

enum DotShape: String, CaseIterable, Identifiable {
    case round, square
    var id: String { rawValue }
    var label: String { self == .round ? "丸" : "四角" }
}

enum BoardIdle: String, CaseIterable, Identifiable {
    case dashboard, clock, message
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dashboard: return "Mac の使用状況"
        case .clock: return "時計"
        case .message: return "ひとこと"
        }
    }
}

/// One switch for how much work Denko does in the background.
enum PerformanceMode: String, CaseIterable, Identifiable {
    case saver, standard, performance
    var id: String { rawValue }
    var label: String {
        switch self {
        case .saver: return "省電力"
        case .standard: return "標準"
        case .performance: return "パフォーマンス"
        }
    }
    var detail: String {
        switch self {
        case .saver: return "メニューバーは5秒ごと、ニュースは30分・運行情報は15分ごとに更新します。バッテリーに優しい設定です。"
        case .standard: return "メニューバーは3秒ごと、ニュースは15分・運行情報は10分ごとに更新します。"
        case .performance: return "メニューバーは1秒ごと、ニュースと運行情報は10分ごとに更新し、キャラクターもなめらかに動きます。"
        }
    }
    var menuBarInterval: Double { [5, 3, 1][index] }
    var panelInterval: Double { [2, 1, 0.5][index] }
    var animation: AnimationMode { self == .performance ? .smooth : .eco }
    var newsSeconds: TimeInterval { [1800, 900, 600][index] }
    var trainSeconds: TimeInterval { [900, 600, 600][index] }
    var disasterWarningSeconds: TimeInterval { [300, 180, 60][index] }
    private var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
