import AppKit

/// Renders text as a dot-matrix LED strip: black board, lit dots in the accent color.
///
/// Text is rasterized once at 1 px per dot with antialiasing off (so Japanese works
/// with the system font), then every lit pixel becomes a round LED.
@MainActor
enum LEDRenderer {
    /// Dot rows; set from the menu bar item's height so the board fills it (19 on a 22pt item).
    static var rows = 16
    static let pitch: CGFloat = 1.125       // pt between dot centres
    /// Board look (set from the settings via `apply`).
    static var dot: CGFloat = 0.98
    static var square = false
    static var unlitAlpha: CGFloat = 0.07
    static var baseColor: NSColor = .black
    /// Bumped whenever the look changes, so cached dot images get redrawn.
    static private(set) var styleVersion = 0

    /// Text weight: 0 細い, 1 ふつう, 2 太い.
    static private(set) var weight = 1

    static func apply(dotSize: Double, square: Bool, unlit: Double, base: NSColor, weight: Int) {
        let d = pitch * CGFloat(dotSize)
        guard d != dot || square != self.square || CGFloat(unlit) != unlitAlpha || base != baseColor
                || weight != self.weight
        else { return }
        if weight != self.weight {
            self.weight = weight
            glyphCache = [:]
        }
        dot = d
        self.square = square
        unlitAlpha = CGFloat(unlit)
        baseColor = base
        styleVersion += 1
    }

    /// Adds one dot (round or square) to a path.
    static func addDot(_ path: CGMutablePath, column: Int, row: Int) {
        let r = dotRect(column: column, row: row)
        if square { path.addRect(r) } else { path.addEllipse(in: r) }
    }

    private static func fillDots(_ color: NSColor, _ build: (CGMutablePath) -> Void) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = CGMutablePath()
        build(path)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }
    static var boardHeight: CGFloat { CGFloat(rows) * pitch }

    /// Fit the board to `height` points (the status item's height).
    static func configure(height: CGFloat) {
        let r = max(16, min(28, Int(height / pitch)))
        guard r != rows else { return }
        rows = r
        glyphCache = [:]
    }

    private static var font: NSFont {
        let name = ["HiraginoSans-W3", "HiraginoSans-W5", "HiraginoSans-W7"][min(max(weight, 0), 2)]
        return NSFont(name: name, size: CGFloat(rows) - 1) ?? .systemFont(ofSize: CGFloat(rows) - 1, weight: .medium)
    }
    /// Latin text uses the system font (crisper than doubling the 5×8 font).
    private static var latinFont: NSFont {
        .systemFont(ofSize: CGFloat(rows) - 2, weight: [NSFont.Weight.regular, .semibold, .heavy][min(max(weight, 0), 2)])
    }

    /// Lit-dot mask for `text`: columns × rows, row 0 at the top.
    /// ASCII uses a classic 5×8 LED font (crisp at this size); everything else
    /// (Japanese etc.) is rasterized from the system font, one glyph at a time.
    static func mask(for text: String) -> (columns: Int, bits: [Bool]) {
        var columns: [[Bool]] = []   // each column = `rows` bools, top → bottom
        for ch in text {
            if rows < 16, let glyph = asciiGlyph(ch) {
                columns += glyph
                columns.append(blankColumn)
            } else {
                columns += fontGlyph(ch)
                columns.append(blankColumn)
            }
        }
        var bits = [Bool](repeating: false, count: columns.count * rows)
        for (x, col) in columns.enumerated() {
            for y in 0..<rows where col[y] { bits[y * columns.count + x] = true }
        }
        return (columns.count, bits)
    }

    static var blankColumn: [Bool] { [Bool](repeating: false, count: rows) }
    /// Top row of ASCII glyphs; leaves room above, descenders end at row 10.
    private static let asciiTop = 3

    private static func asciiGlyph(_ ch: Character) -> [[Bool]]? {
        guard let v = ch.asciiValue, v >= 0x20, v <= 0x7E else { return nil }
        if v == 0x20 { return [blankColumn, blankColumn] }
        let i = Int(v - 0x20) * 5
        return (0..<5).map { c in
            let byte = font5x8[i + c]
            return (0..<rows).map { y in
                let bit = y - asciiTop
                return bit >= 0 && bit < 8 && (byte >> UInt8(bit)) & 1 == 1
            }
        }
    }

    private static var glyphCache: [Character: [[Bool]]] = [:]

    private static func fontGlyph(_ ch: Character) -> [[Bool]] {
        if let cached = glyphCache[ch] { return cached }
        let str = String(ch) as NSString
        let f = ch.isASCII ? latinFont : font
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.white]
        let size = str.size(withAttributes: attrs)
        let width = max(1, Int(ceil(size.width)))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: rows,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return [blankColumn] }
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        ctx?.shouldAntialias = false
        ctx?.cgContext.setShouldSmoothFonts(false)
        // Shared baseline 3 dots above the bottom so Latin and Japanese line up.
        str.draw(at: NSPoint(x: 0, y: 3 + f.descender), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        let cols = (0..<width).map { x in
            (0..<rows).map { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }
        }
        // Trim empty columns at the edges (proportional spacing).
        let first = cols.firstIndex { $0.contains(true) } ?? 0
        let last = cols.lastIndex { $0.contains(true) } ?? (cols.count - 1)
        let trimmed = first <= last ? Array(cols[first...last])
            : Array(repeating: blankColumn, count: ch == " " ? 4 : 3)
        glyphCache[ch] = trimmed
        return trimmed
    }

    /// Classic 5×8 dot-matrix font for 0x20–0x7E. 5 bytes per glyph (columns), bit 0 = top row.
    static let font5x8Table: [UInt8] = font5x8
    private static let font5x8: [UInt8] = [
        0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x5F,0x00,0x00, 0x00,0x07,0x00,0x07,0x00, 0x14,0x7F,0x14,0x7F,0x14,
        0x24,0x2A,0x7F,0x2A,0x12, 0x23,0x13,0x08,0x64,0x62, 0x36,0x49,0x56,0x20,0x50, 0x00,0x00,0x07,0x00,0x00,
        0x00,0x1C,0x22,0x41,0x00, 0x00,0x41,0x22,0x1C,0x00, 0x2A,0x1C,0x7F,0x1C,0x2A, 0x08,0x08,0x3E,0x08,0x08,
        0x00,0x50,0x30,0x00,0x00, 0x08,0x08,0x08,0x08,0x08, 0x00,0x60,0x60,0x00,0x00, 0x20,0x10,0x08,0x04,0x02,
        0x3E,0x51,0x49,0x45,0x3E, 0x00,0x42,0x7F,0x40,0x00, 0x72,0x49,0x49,0x49,0x46, 0x21,0x41,0x49,0x4D,0x33,
        0x18,0x14,0x12,0x7F,0x10, 0x27,0x45,0x45,0x45,0x39, 0x3C,0x4A,0x49,0x49,0x31, 0x41,0x21,0x11,0x09,0x07,
        0x36,0x49,0x49,0x49,0x36, 0x46,0x49,0x49,0x29,0x1E, 0x00,0x00,0x14,0x00,0x00, 0x00,0x40,0x34,0x00,0x00,
        0x00,0x08,0x14,0x22,0x41, 0x14,0x14,0x14,0x14,0x14, 0x00,0x41,0x22,0x14,0x08, 0x02,0x01,0x59,0x09,0x06,
        0x3E,0x41,0x5D,0x59,0x4E, 0x7C,0x12,0x11,0x12,0x7C, 0x7F,0x49,0x49,0x49,0x36, 0x3E,0x41,0x41,0x41,0x22,
        0x7F,0x41,0x41,0x41,0x3E, 0x7F,0x49,0x49,0x49,0x41, 0x7F,0x09,0x09,0x09,0x01, 0x3E,0x41,0x41,0x51,0x73,
        0x7F,0x08,0x08,0x08,0x7F, 0x00,0x41,0x7F,0x41,0x00, 0x20,0x40,0x41,0x3F,0x01, 0x7F,0x08,0x14,0x22,0x41,
        0x7F,0x40,0x40,0x40,0x40, 0x7F,0x02,0x1C,0x02,0x7F, 0x7F,0x04,0x08,0x10,0x7F, 0x3E,0x41,0x41,0x41,0x3E,
        0x7F,0x09,0x09,0x09,0x06, 0x3E,0x41,0x51,0x21,0x5E, 0x7F,0x09,0x19,0x29,0x46, 0x26,0x49,0x49,0x49,0x32,
        0x03,0x01,0x7F,0x01,0x03, 0x3F,0x40,0x40,0x40,0x3F, 0x1F,0x20,0x40,0x20,0x1F, 0x3F,0x40,0x38,0x40,0x3F,
        0x63,0x14,0x08,0x14,0x63, 0x03,0x04,0x78,0x04,0x03, 0x61,0x59,0x49,0x4D,0x43, 0x00,0x7F,0x41,0x41,0x41,
        0x02,0x04,0x08,0x10,0x20, 0x00,0x41,0x41,0x41,0x7F, 0x04,0x02,0x01,0x02,0x04, 0x40,0x40,0x40,0x40,0x40,
        0x00,0x03,0x07,0x08,0x00, 0x20,0x54,0x54,0x78,0x40, 0x7F,0x28,0x44,0x44,0x38, 0x38,0x44,0x44,0x44,0x28,
        0x38,0x44,0x44,0x28,0x7F, 0x38,0x54,0x54,0x54,0x18, 0x00,0x08,0x7E,0x09,0x02, 0x18,0xA4,0xA4,0x9C,0x78,
        0x7F,0x08,0x04,0x04,0x78, 0x00,0x44,0x7D,0x40,0x00, 0x20,0x40,0x40,0x3D,0x00, 0x7F,0x10,0x28,0x44,0x00,
        0x00,0x41,0x7F,0x40,0x00, 0x7C,0x04,0x78,0x04,0x78, 0x7C,0x08,0x04,0x04,0x78, 0x38,0x44,0x44,0x44,0x38,
        0xFC,0x18,0x24,0x24,0x18, 0x18,0x24,0x24,0x18,0xFC, 0x7C,0x08,0x04,0x04,0x08, 0x48,0x54,0x54,0x54,0x24,
        0x04,0x04,0x3F,0x44,0x24, 0x3C,0x40,0x40,0x20,0x7C, 0x1C,0x20,0x40,0x20,0x1C, 0x3C,0x40,0x30,0x40,0x3C,
        0x44,0x28,0x10,0x28,0x44, 0x4C,0x90,0x90,0x90,0x7C, 0x44,0x64,0x54,0x4C,0x44, 0x00,0x08,0x36,0x41,0x00,
        0x00,0x00,0x77,0x00,0x00, 0x00,0x41,0x36,0x08,0x00, 0x02,0x01,0x02,0x04,0x02,
    ]

    /// Strip of lit dots only (transparent elsewhere), to slide over the static board.
    static func strip(for text: String, accent: NSColor, scale: CGFloat = 2) -> (image: CGImage?, width: CGFloat) {
        let m = mask(for: text)
        let size = NSSize(width: CGFloat(m.columns) * pitch, height: boardHeight)
        let image = bitmap(size: size, scale: scale) {
            fillDots(accent) { path in
                for y in 0..<rows {
                    for x in 0..<m.columns where m.bits[y * m.columns + x] { addDot(path, column: x, row: y) }
                }
            }
        }
        return (image, size.width)
    }

    /// The board: black pill with a faint grid of unlit dots.
    static func board(width: CGFloat, accent: NSColor, scale: CGFloat = 2) -> NSImage {
        let size = NSSize(width: width, height: boardHeight)
        let img = NSImage(size: size)
        if let cg = bitmap(size: size, scale: scale, {
            baseColor.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3.5, yRadius: 3.5).fill()
            guard unlitAlpha > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
            // One dot drawn once, then tiled: filling thousands of separate dots was slow
            // (seconds for a full-width board).
            let columns = Int(width / pitch)
            if let cell = unlitCell(accent.withAlphaComponent(unlitAlpha), scale: scale) {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 0, y: 0, width: CGFloat(columns) * pitch, height: CGFloat(rows) * pitch))
                ctx.draw(cell, in: CGRect(x: 0, y: 0, width: pitch, height: pitch), byTiling: true)
                ctx.restoreGState()
            }
        }) {
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = size
            img.addRepresentation(rep)
        }
        return img
    }

    /// A single unlit dot in a pitch × pitch cell, for tiling.
    private static func unlitCell(_ color: NSColor, scale: CGFloat) -> CGImage? {
        bitmap(size: NSSize(width: pitch, height: pitch), scale: scale * 4) {
            let inset = (pitch - dot) / 2
            let r = NSRect(x: inset, y: inset, width: dot, height: dot)
            color.setFill()
            (square ? NSBezierPath(rect: r) : NSBezierPath(ovalIn: r)).fill()
        }
    }

    /// Static text centred on the board (used for the idle clock).
    static func staticStrip(for text: String, accent: NSColor, boardWidth: CGFloat) -> CGImage? {
        let m = mask(for: text)
        let columns = Int(boardWidth / pitch)
        let offset = max(0, (columns - m.columns) / 2)
        return bitmap(size: NSSize(width: boardWidth, height: boardHeight), scale: 2) {
            fillDots(accent) { path in
                for y in 0..<rows {
                    for x in 0..<m.columns where m.bits[y * m.columns + x] && x + offset < columns {
                        addDot(path, column: x + offset, row: y)
                    }
                }
            }
        }
    }

    /// Dot mask of `text` in a mid-size font (for numbers on the dashboard): columns of
    /// `rows` dots, vertically centred on the cap height.
    private static var numberCache: [String: [[Bool]]] = [:]

    static func numberMask(_ text: String, size: CGFloat) -> [[Bool]] {
        let key = "\(text)|\(size)|\(rows)"
        if let cached = numberCache[key] { return cached }
        let result = renderNumberMask(text, size: size)
        if numberCache.count > 400 { numberCache.removeAll() }
        numberCache[key] = result
        return result
    }

    private static func renderNumberMask(_ text: String, size: CGFloat) -> [[Bool]] {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let width = max(1, Int(ceil((text as NSString).size(withAttributes: attrs).width)) + 1)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: rows,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return [] }
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        ctx?.shouldAntialias = false
        let baseline = (CGFloat(rows) - font.capHeight) / 2
        (text as NSString).draw(at: NSPoint(x: 0, y: baseline + font.descender), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        let cols = (0..<width).map { x in (0..<rows).map { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 } }
        let first = cols.firstIndex { $0.contains(true) } ?? 0
        let last = cols.lastIndex { $0.contains(true) } ?? 0
        return first <= last ? Array(cols[first...last]) : []
    }

    // MARK: - Projecting images onto the board

    /// Turns any rendered image (e.g. the dashboard, drawn white-on-clear) into lit dots:
    /// each dot's brightness is the average coverage of its cell. Returns dots on a
    /// transparent background, to lay over `board(...)`.
    static func ledify(_ image: NSImage, accent: NSColor) -> (image: CGImage?, columns: Int) {
        let columns = Int(floor(image.size.width / pitch))
        guard columns > 0 else { return (nil, 0) }
        let s: CGFloat = 4
        let w = Int(ceil(image.size.width * s)), h = Int(ceil(image.size.height * s))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return (nil, 0) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        NSGraphicsContext.restoreGraphicsState()

        var levels = [CGFloat](repeating: 0, count: columns * rows)
        let cell = pitch * s
        let yOffset = (image.size.height - boardHeight) / 2 * s
        for r in 0..<rows {
            for c in 0..<columns {
                let x0 = Int(CGFloat(c) * cell), y0 = Int(yOffset + CGFloat(r) * cell)
                var sum: CGFloat = 0, n: CGFloat = 0
                for y in y0..<min(h, y0 + Int(cell)) where y >= 0 {
                    for x in x0..<min(w, x0 + Int(cell)) {
                        sum += rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                        n += 1
                    }
                }
                levels[r * columns + c] = n > 0 ? sum / n : 0
            }
        }
        return (dots(levels: levels, columns: columns, accent: accent), columns)
    }

    /// Lit dots from brightness levels (0…1), row 0 at the top.
    static func dots(levels: [CGFloat], columns: Int, accent: NSColor) -> CGImage? {
        // Bucket dots by brightness and fill each bucket as one path (thousands of
        // separate fills per frame were the main cost of the LED board).
        var buckets: [Int: CGMutablePath] = [:]
        for r in 0..<rows {
            for c in 0..<columns {
                let v = levels[r * columns + c]
                guard v > 0.12 else { continue }
                let alpha = v >= 0.95 ? 1 : max(0.22, min(0.9, v * 1.1))
                let key = Int((alpha * 20).rounded())          // 5% steps
                let path = buckets[key] ?? CGMutablePath()
                addDot(path, column: c, row: r)
                buckets[key] = path
            }
        }
        return bitmap(size: NSSize(width: CGFloat(columns) * pitch, height: boardHeight), scale: 2) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            for (key, path) in buckets {
                ctx.setFillColor(accent.withAlphaComponent(CGFloat(key) / 20).cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
    }

    static func dotRect(column: Int, row: Int) -> NSRect {
        // Bitmap y grows downward in the mask; drawing y grows upward.
        let inset = (pitch - dot) / 2
        return NSRect(x: CGFloat(column) * pitch + inset,
                      y: CGFloat(rows - 1 - row) * pitch + inset,
                      width: dot, height: dot)
    }

    static func bitmap(size: NSSize, scale: CGFloat, _ body: () -> Void) -> CGImage? {
        guard size.width >= 1, size.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        ctx?.cgContext.scaleBy(x: scale, y: scale)
        body()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
