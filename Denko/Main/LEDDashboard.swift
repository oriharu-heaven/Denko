import AppKit

/// The dashboard drawn natively on the 16-row LED board (frog, pies, network, AI ring),
/// laid out on the dot grid instead of down-sampling the normal icon, so it stays legible.
@MainActor
enum LEDDashboard {
    struct Output {
        let content: CGImage?          // everything except the frog (lit dots only)
        let frogFrames: [CGImage]      // one image per hop frame
        let frogRect: NSRect           // in board coordinates
        let width: CGFloat             // board width in points
        let regions: [(IconRegion, ClosedRange<CGFloat>)]
    }

    private static var rows: Int { LEDRenderer.rows }
    /// Diameter of pies and the AI ring: as tall as the board allows (odd, so it has a centre dot).
    private static var gauge: Int { (rows - 2) | 1 }
    /// Top row of an 8-row line of small text, vertically centred.
    private static var midRow: Int { (rows - 8) / 2 }
    private static var frogCache: (color: NSColor, rows: Int, style: Int, kind: CharacterKind, frames: [CGImage])?
    private static let pad = 2         // empty columns at both ends

    /// Dot canvas: brightness per dot (0 = off, 0.3 = dim, 1 = lit), row 0 at the top.
    @MainActor
    private struct Canvas {
        var columns: Int
        var levels: [CGFloat]
        init(columns: Int) { self.columns = columns; levels = Array(repeating: 0, count: columns * LEDRenderer.rows) }
        mutating func set(_ c: Int, _ r: Int, _ v: CGFloat) {
            guard c >= 0, c < columns, r >= 0, r < LEDRenderer.rows else { return }
            levels[r * columns + c] = max(levels[r * columns + c], v)
        }
    }

    static func render(_ c: IconContent, accent: NSColor) -> Output {
        // 1. Measure each piece in columns.
        enum Piece { case frog, pie(String, Int, IconRegion), net(String, String), ai(AIGauge, String?) }
        var pieces: [(Piece, Int)] = []
        if c.showCharacter || c.isEmpty { pieces.append((.frog, 18)) }
        // Pie + its % in a mid-size font, with a fixed number width so the board never jumps.
        let numW = numberWidth
        if let g = c.cpu { pieces.append((.pie("C", g.percent, .cpu), 6 + gauge + 2 + numW)) }
        if let g = c.memory { pieces.append((.pie("M", g.percent, .memory), 6 + gauge + 2 + numW)) }
        if let n = c.network {
            // Fixed width (room for "999K") so the board doesn't change size as speeds change.
            let w = 6 + max(smallWidth("999K"), smallWidth(n.up), smallWidth(n.down))
            pieces.append((.net(n.up, n.down), w))
        }
        for g in c.ai {
            let pct: String? = c.numbers == .none ? nil : g.outer.map { "\(Int($0))" } ?? "--"
            pieces.append((.ai(g, pct), gauge + (pct == nil ? 0 : 2 + numW)))
        }
        let gap = 4
        let columns = pad * 2 + pieces.reduce(0) { $0 + $1.1 } + gap * max(0, pieces.count - 1)

        // 2. Draw.
        var canvas = Canvas(columns: columns)
        var regions: [(IconRegion, ClosedRange<CGFloat>)] = []
        var frogCol: Int?
        var x = pad
        for (i, (piece, w)) in pieces.enumerated() {
            let start = CGFloat(x) * LEDRenderer.pitch
            switch piece {
            case .frog:
                frogCol = x
                regions.append((.character, start...(start + CGFloat(w) * LEDRenderer.pitch)))
            case .pie(let letter, let pct, let region):
                drawSmall(letter, col: x, row: midRow, into: &canvas)
                drawPie(pct, col: x + 6, into: &canvas)
                drawNumber("\(pct)", col: x + 6 + gauge + 2, width: numberWidth, into: &canvas)
                regions.append((region, start...(start + CGFloat(w) * LEDRenderer.pitch)))
            case .net(let up, let down):
                // Two lines of 8 rows, with a 1-row gap when the board is tall enough.
                let top = max(0, (rows - 17) / 2), second = top + (rows >= 17 ? 9 : 8)
                drawArrow(up: true, col: x, row: top, into: &canvas)
                drawArrow(up: false, col: x, row: second, into: &canvas)
                drawSmall(up, col: x + 6 + (w - 6 - smallWidth(up)), row: top, into: &canvas)
                drawSmall(down, col: x + 6 + (w - 6 - smallWidth(down)), row: second, into: &canvas)
                regions.append((.network, start...(start + CGFloat(w) * LEDRenderer.pitch)))
            case .ai(let g, let pct):
                drawDoubleRing(outer: g.outer, inner: g.inner, col: x, into: &canvas)
                if let pct { drawNumber(pct, col: x + gauge + 2, width: numberWidth, into: &canvas) }
                regions.append((.ai(g.provider), start...(start + CGFloat(w) * LEDRenderer.pitch)))
            }
            x += w + (i < pieces.count - 1 ? gap : 0)
        }

        let content = LEDRenderer.dots(levels: canvas.levels, columns: columns, accent: accent)

        // 3. Frog frames, 1 dot per pixel (cached: they only depend on the color).
        var frogs: [CGImage] = []
        var frogRect = NSRect.zero
        if let fc = frogCol {
            frogRect = NSRect(x: CGFloat(fc) * LEDRenderer.pitch, y: 0,
                              width: 18 * LEDRenderer.pitch, height: LEDRenderer.boardHeight)
            if let cached = frogCache, cached.color == accent, cached.rows == rows,
               cached.style == LEDRenderer.styleVersion, cached.kind == IconRenderer.character { frogs = cached.frames }
        }
        if frogCol != nil && frogs.isEmpty {
            for f in 0..<IconRenderer.frameCount {
                var fcanvas = Canvas(columns: 18)
                let frame = IconRenderer.frogFrame(f)
                let offset = (rows - 16) / 2        // centre the 16-row frog on a taller board
                for (r, row) in frame.rows.enumerated() {
                    for (col, ch) in row.enumerated() where ch == "#" {
                        fcanvas.set(col, offset + frame.top + r, 1)
                    }
                }
                if let img = LEDRenderer.dots(levels: fcanvas.levels, columns: 18, accent: accent) { frogs.append(img) }
            }
            frogCache = (accent, rows, LEDRenderer.styleVersion, IconRenderer.character, frogs)
        }
        return Output(content: content, frogFrames: frogs, frogRect: frogRect,
                      width: CGFloat(columns) * LEDRenderer.pitch, regions: regions)
    }

    // MARK: - Primitives

    /// Pie (gauge × gauge dots): dim disc, lit wedge from 12 o'clock clockwise.
    private static func drawPie(_ pct: Int, col: Int, into c: inout Canvas) {
        let d = gauge, r = Double(d) / 2, cx = Double(col) + r, top = (rows - d) / 2
        for y in 0..<d {
            for x in 0..<d {
                let dx = Double(col + x) + 0.5 - cx, dy = Double(y) + 0.5 - r
                guard dx * dx + dy * dy <= r * r + 0.5 else { continue }
                var a = atan2(dx, -dy) / (2 * .pi)
                if a < 0 { a += 1 }
                c.set(col + x, top + y, a < Double(pct) / 100 ? 1 : 0.28)
            }
        }
    }

    /// Outer ring (short window) and inner ring (long window), each 2 dots thick.
    private static func drawDoubleRing(outer: Double?, inner: Double?, col: Int, into c: inout Canvas) {
        let d = gauge, r = Double(d) / 2, cx = Double(col) + r, top = (rows - d) / 2
        for y in 0..<d {
            for x in 0..<d {
                let dx = Double(col + x) + 0.5 - cx, dy = Double(y) + 0.5 - r
                let dist = sqrt(dx * dx + dy * dy)
                var a = atan2(dx, -dy) / (2 * .pi)
                if a < 0 { a += 1 }
                if dist > r - 2.1 && dist <= r + 0.1 {
                    c.set(col + x, top + y, a < (outer ?? 0) / 100 ? 1 : 0.28)
                } else if dist > r - 5.3 && dist <= r - 3.2 {
                    c.set(col + x, top + y, a < (inner ?? 0) / 100 ? 1 : 0.28)
                }
            }
        }
    }

    /// 5×8 dot font text (from LEDRenderer), 6 columns per character.
    private static func drawSmall(_ text: String, col: Int, row: Int, into c: inout Canvas) {
        var x = col
        for ch in text {
            guard let v = ch.asciiValue, v >= 0x20, v <= 0x7E else { x += 6; continue }
            let i = Int(v - 0x20) * 5
            for cc in 0..<5 {
                let byte = LEDRenderer.font5x8Table[i + cc]
                for bit in 0..<8 where (byte >> UInt8(bit)) & 1 == 1 {
                    c.set(x + cc, row + bit, 1)
                }
            }
            x += 6
        }
    }

    private static func smallWidth(_ text: String) -> Int { max(0, text.count * 6 - 1) }

    /// Numbers next to pies / the AI ring: ~60% of the board height, bold.
    private static var numberSize: CGFloat { CGFloat(rows) * 0.56 }
    /// Room for two digits so widths stay constant ("100" is rare and may touch the gap).
    private static var numberWidth: Int { LEDRenderer.numberMask("88", size: numberSize).count }

    /// Right-aligned number in the mid-size dot font.
    private static func drawNumber(_ text: String, col: Int, width: Int, into c: inout Canvas) {
        let mask = LEDRenderer.numberMask(text, size: numberSize)
        let start = col          // left-aligned, right next to its pie / ring
        for (x, column) in mask.enumerated() {
            for (y, on) in column.enumerated() where on { c.set(start + x, y, 1) }
        }
    }

    /// 5×7 arrow glyph (↑ / ↓), dim so the numbers stand out.
    private static func drawArrow(up: Bool, col: Int, row: Int, into c: inout Canvas) {
        let shape = ["..#..", ".###.", "#.#.#", "..#..", "..#..", "..#..", "..#.."]
        for (r, line) in (up ? shape : shape.reversed()).enumerated() {
            for (x, ch) in line.enumerated() where ch == "#" { c.set(col + x, row + r, 0.6) }
        }
    }
}
