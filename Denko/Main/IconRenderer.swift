import AppKit

/// Everything that affects how the merged status icon looks.
/// Bitmaps are re-rendered only when this changes; animation just swaps cached frames.
struct IconContent: Equatable {
    var showCharacter: Bool
    /// Mac-wide gauges; nil = not shown. `app` is the top consumer's id (for its icon).
    var cpu: Gauge?
    var memory: Gauge?
    var network: NetGauge?
    var showNumbers: Bool
    var gaugeStyle: GaugeStyle = .pie
    var colorIcons: Bool
    /// Keep room for the top-app icon even when there's no leader, so the width never jumps.
    var reserveAppSlot: Bool = false
    /// AI usage double rings (outer = short window, inner = long window).
    var ai: [AIGauge] = []
    var numbers: ClaudeNumbers
    var accent: AccentPreset
    /// Sleep prevention on → the frog is drawn in the accent color.
    var awake: Bool
    var character: CharacterKind = .frog

    var isEmpty: Bool { !showCharacter && cpu == nil && memory == nil && network == nil && ai.isEmpty }
}

struct AIGauge: Equatable {
    var provider: AIProvider
    /// Short tag (Cl / Cx / Gm) drawn when several AIs are shown.
    var tag: String?
    var outer: Double?
    var inner: Double?
    var error: Bool
}

/// Which part of the icon was clicked → which panel tab opens.
enum IconRegion: Equatable {
    case character, cpu, memory, network, ai(AIProvider)
}

struct Gauge: Equatable {
    var percent: Int
    var app: String?
}

struct NetGauge: Equatable {
    var up: String
    var down: String
    var app: String?
}

@MainActor
enum IconRenderer {
    static let height: CGFloat = 18

    // MARK: - Chibi frog (18×16 canvas, 1pt per px)

    private static let head = [
        "...###......###...",
        "..#...#....#...#..",
        "..#.#.#....#.#.#..",
        ".##...######...##.",
        ".################.",
        "###.##########.###",
        "####..........####",
        "##################",
    ]
    private static let belly = ".################."
    private static let hips = "..##############.."
    private static let sitLegs = [".###.########.###.",
                                  "####..........####"]
    private static let crouchLegs = ["####.########.####",
                                     "#####........#####"]
    private static let jumpLegs = ["...##........##...",
                                   "...##........##...",
                                   "..##..........##.."]

    /// One hop: sit → crouch → rise → apex → fall → crouch.
    private static let frogFrames: [(rows: [String], top: Int)] = [
        (head + [belly, hips] + sitLegs, 4),
        (head + [belly] + crouchLegs, 5),
        (head + [belly, hips] + jumpLegs, 2),
        (head + [belly, hips] + jumpLegs, 0),
        (head + [belly, hips] + jumpLegs, 1),
        (head + [belly] + crouchLegs, 5),
    ]

    // MARK: - Train (a little commuter car; wheels turn, the body rocks on the rails)

    private static let trainBody = [
        "..##############..",
        ".#..............#.",
        "#.##..##..##..##.#",
        "#.##..##..##..##.#",
        "#................#",
        "##################",
        ".################.",
        "..##.##....##.##..",
    ]
    /// Sleepers sliding under the wheels give the sense of motion.
    private static let railA = "#.#.#.#.#.#.#.#.#."
    private static let railB = ".#.#.#.#.#.#.#.#.#"
    private static let trainFrames: [(rows: [String], top: Int)] = [
        (trainBody + [railA], 6), (trainBody + [railB], 6), (trainBody + [railA], 5),
        (trainBody + [railB], 6), (trainBody + [railA], 6), (trainBody + [railB], 5),
    ]

    // MARK: - Chick (bobs and flaps)

    private static let chickHead = [
        ".......#####......",
        "......#######.....",
        ".....###.#####....",
        "...############...",
        ".....#########....",
    ]
    private static let chickBody = [
        ".....#########....",
        "....############..",
        "....############..",
        ".....##########...",
    ]
    private static let chickFlap = [
        ".....#########....",
        "...##############.",
        "....############..",
        ".....##########...",
    ]
    private static let chickFeet = ["........#..#......", ".......##.##......"]
    private static let chickFrames: [(rows: [String], top: Int)] = [
        (chickHead + chickBody + chickFeet, 5),
        (chickHead + chickFlap + chickFeet, 4),
        (chickHead + chickBody + chickFeet, 3),
        (chickHead + chickFlap + chickFeet, 4),
        (chickHead + chickBody + chickFeet, 5),
        (chickHead + chickBody + chickFeet, 5),
    ]

    /// Which character is drawn (set from the settings before rendering).
    static var character: CharacterKind = .frog

    private static var frames: [(rows: [String], top: Int)] {
        switch character {
        case .frog: return frogFrames
        case .train: return trainFrames
        case .chick: return chickFrames
        }
    }

    static var frameCount: Int { frames.count }

    /// Frog pixel rows for one frame (for drawing it as LED dots), top offset in a 16-row canvas.
    static func frogFrame(_ i: Int) -> (rows: [String], top: Int) { frames[i % frames.count] }
    static let characterSize = NSSize(width: 18, height: 16)
    private static let ringSize: CGFloat = 18

    // MARK: - Fonts

    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    fileprivate static let metricFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let tagFont = NSFont.systemFont(ofSize: 9, weight: .semibold)

    // MARK: - Render

    struct Rendered {
        /// Static part (metrics, Claude ring). Leaves room on the left for the frog.
        let base: NSImage
        /// Frog frames, drawn by a separate layer so a frame change doesn't
        /// re-layout or resend the whole status item.
        let characterFrames: [CGImage]
        let characterRect: NSRect
        /// Compatibility mode: whole-icon frames with the frog baked in (heavier).
        let fullFrames: [NSImage]
        /// Horizontal extent of each clickable part, in image coordinates.
        var regions: [(IconRegion, ClosedRange<CGFloat>)] = []
    }

    /// Frog frames only depend on color + appearance, so they're cached across renders.
    private static var frogCache: (key: String, frames: [CGImage])?

    static func render(_ c: IconContent, appearance: NSAppearance, compatible: Bool = false,
                       icon: (String) -> NSImage? = { _ in nil }) -> Rendered {
        var result: Rendered!
        appearance.performAsCurrentDrawingAppearance {
            MainActor.assumeIsolated {
                let palette = Palette(label: .labelColor, accent: c.accent.nsColor)
                let pieces = makePieces(c, palette: palette, hasIcon: { icon($0) != nil })
                let width = max(1, ceil(pieces.reduce(0) { $0 + $1.leading + $1.width }))
                // Click regions: consecutive pieces of the same region are merged (gaps split evenly).
                var regions: [(IconRegion, ClosedRange<CGFloat>)] = []
                var cursor: CGFloat = 0
                for p in pieces {
                    let start = cursor + p.leading
                    cursor = start + p.width
                    guard let r = p.region else { continue }
                    if let last = regions.last, last.0 == r {
                        regions[regions.count - 1].1 = last.1.lowerBound...cursor
                    } else {
                        regions.append((r, (start - p.leading / 2)...cursor))
                    }
                }
                let charRect = NSRect(x: 0, y: (height - characterSize.height) / 2,
                                      width: characterSize.width, height: characterSize.height)
                let charColor = c.awake ? palette.accent : palette.label
                let animated = c.showCharacter

                @MainActor func drawBase(frogFrame: Int?) {
                    var x: CGFloat = 0
                    for p in pieces {
                        x += p.leading
                        switch p.kind {
                        case .character:
                            if let f = frogFrame { drawFrog(frame: f, origin: NSPoint(x: x, y: charRect.minY), color: charColor) }
                        case .ring(let g):
                            drawRing(outer: g.outer, inner: g.inner, x: x, palette: palette)
                        case .gauge(let letter, let percent):
                            drawGauge(letter: letter, percent: percent, x: x, palette: palette)
                        case .bar(let letter, let percent):
                            drawBar(letter: letter, percent: percent, x: x, palette: palette)
                        case .pie(let letter, let percent):
                            drawPie(letter: letter, percent: percent, x: x, palette: palette)
                        case .net(let up, let down):
                            drawNet(up: up, down: down, x: x, width: p.width, palette: palette)
                        case .appIcon(let id):
                            if !id.isEmpty, let img = icon(id) { drawAppIcon(img, x: x, color: c.colorIcons, label: palette.label) }
                        case .text(let segments):
                            var tx = x
                            for s in segments { drawText(s, x: tx); tx += s.width }
                        }
                        x += p.width
                    }
                }

                if compatible && animated {
                    let full = (0..<frameCount).map { f in
                        bitmap(size: NSSize(width: width, height: height)) { drawBase(frogFrame: f) }
                    }
                    result = Rendered(base: full[0], characterFrames: [], characterRect: charRect, fullFrames: full,
                                      regions: regions)
                    return
                }
                // Animated frog goes in its own layer; a still fallback frog is baked into the base.
                let base = bitmap(size: NSSize(width: width, height: height)) { drawBase(frogFrame: animated ? nil : 0) }
                var chars: [CGImage] = []
                if animated {
                    let key = "\(appearance.name.rawValue)|\(c.accent.rawValue)|\(c.awake)|\(c.character.rawValue)"
                    if let cached = frogCache, cached.key == key {
                        chars = cached.frames
                    } else {
                        for f in 0..<frameCount {
                            let img = bitmap(size: characterSize) { drawFrog(frame: f, origin: .zero, color: charColor) }
                            if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { chars.append(cg) }
                        }
                        frogCache = (key, chars)
                    }
                }
                result = Rendered(base: base, characterFrames: chars, characterRect: charRect, fullFrames: [],
                                  regions: regions)
            }
        }
        return result
    }

    // MARK: - Layout pieces

    private struct Palette {
        let label: NSColor
        let accent: NSColor
        var secondary: NSColor { label.withAlphaComponent(0.55) }
        var track: NSColor { label.withAlphaComponent(0.2) }
        func value(_ v: Double?) -> NSColor {
            guard let v else { return secondary }
            return v >= Theme.highUsage ? accent : label
        }
    }

    private struct Segment {
        let text: String
        let font: NSFont
        let color: NSColor
        var width: CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
    }

    private enum Kind {
        case character, text([Segment])
        case ring(AIGauge)
        case gauge(letter: String, percent: Int)
        case bar(letter: String, percent: Int)
        case pie(letter: String, percent: Int)
        case net(up: String, down: String)
        case appIcon(String)
    }

    private struct Piece {
        let kind: Kind
        let width: CGFloat
        var leading: CGFloat = 0
        var region: IconRegion?
    }

    private static let iconSize: CGFloat = 12
    private static let netWidth: CGFloat = 29
    /// Letter (5pt) + gap + 5pt bar.
    private static let barGaugeWidth: CGFloat = 11
    /// Letter (5pt) + gap + 13pt pie.
    private static let pieGaugeWidth: CGFloat = 19

    private static func makePieces(_ c: IconContent, palette: Palette, hasIcon: (String) -> Bool) -> [Piece] {
        func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "--" }
        func textPiece(_ segs: [Segment]) -> Piece { Piece(kind: .text(segs), width: segs.reduce(0) { $0 + $1.width }) }

        var pieces: [Piece] = []
        if c.showCharacter || c.isEmpty {
            pieces.append(Piece(kind: .character, width: characterSize.width, region: .character))
        }
        // Mac-wide gauges: ring (or ↑↓ text) + optional % + the top app's icon, tightly grouped.
        func addGauge(_ g: Gauge?, letter: String, region: IconRegion) {
            guard let g else { return }
            if c.gaugeStyle == .pie {
                pieces.append(Piece(kind: .pie(letter: letter, percent: g.percent), width: pieGaugeWidth, region: region))
            } else if c.gaugeStyle == .bar {
                pieces.append(Piece(kind: .bar(letter: letter, percent: g.percent), width: barGaugeWidth, region: region))
            } else {
                pieces.append(Piece(kind: .gauge(letter: letter, percent: g.percent), width: ringSize, region: region))
            }
            if c.showNumbers {
                let t = textPiece([Segment(text: "\(g.percent)%", font: metricFont,
                                           color: Double(g.percent) >= Theme.highUsage ? palette.accent : palette.label)])
                pieces.append(Piece(kind: t.kind, width: max(t.width, percentWidth), leading: 2, region: region))
            }
            addAppSlot(g.app, region: region)
        }
        func addAppSlot(_ app: String?, region: IconRegion) {
            if let app, hasIcon(app) {
                pieces.append(Piece(kind: .appIcon(app), width: iconSize, leading: 2, region: region))
            } else if c.reserveAppSlot {
                pieces.append(Piece(kind: .appIcon(""), width: iconSize, leading: 2, region: region))
            }
        }
        addGauge(c.cpu, letter: "C", region: .cpu)
        addGauge(c.memory, letter: "M", region: .memory)
        if let n = c.network {
            pieces.append(Piece(kind: .net(up: n.up, down: n.down), width: netWidth, region: .network))
            addAppSlot(n.app, region: .network)
        }

        // AI usage: [tag] ring [numbers]
        for g in c.ai {
            let region = IconRegion.ai(g.provider)
            if let tag = g.tag {
                pieces.append(Piece(kind: .text([Segment(text: tag, font: tagFont, color: palette.secondary)]),
                                    width: textPiece([Segment(text: tag, font: tagFont, color: palette.secondary)]).width,
                                    region: region))
                pieces.append(Piece(kind: .ring(g), width: ringSize, leading: 2, region: region))
            } else {
                pieces.append(Piece(kind: .ring(g), width: ringSize, region: region))
            }
            var segs: [Segment] = []
            switch c.numbers {
            case .none: break
            case .fiveHour:
                segs = [Segment(text: pct(g.outer), font: valueFont, color: palette.value(g.outer))]
            case .both:
                segs = [Segment(text: pct(g.outer), font: valueFont, color: palette.value(g.outer)),
                        Segment(text: " / ", font: tagFont, color: palette.secondary),
                        Segment(text: pct(g.inner), font: valueFont, color: palette.value(g.inner))]
            }
            if g.error { segs.append(Segment(text: "!", font: valueFont, color: palette.accent)) }
            if !segs.isEmpty {
                var piece = textPiece(segs)
                piece.leading = 3   // numbers hug their ring
                piece.region = region
                pieces.append(piece)
            }
        }
        // Wider gap between groups.
        for i in pieces.indices.dropFirst() where pieces[i].leading == 0 {
            pieces[i].leading = 5
        }
        return pieces
    }

    // MARK: - Drawing

    /// Concentric rings: outer = 5-hour window, inner = weekly. Starts at 12 o'clock, clockwise.
    private static func drawRing(outer: Double?, inner: Double?, x: CGFloat, palette: Palette) {
        let center = NSPoint(x: x + ringSize / 2, y: height / 2)
        let lineWidth: CGFloat = 2.2
        let outerRadius = ringSize / 2 - lineWidth / 2
        let rings: [(radius: CGFloat, value: Double?)] = [
            (outerRadius, outer),
            (outerRadius - lineWidth - 1.0, inner),
        ]
        for ring in rings {
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: ring.radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            palette.track.setStroke()
            track.stroke()

            guard let v = ring.value, v > 0 else { continue }
            let fraction = CGFloat(min(v, 100) / 100)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: ring.radius,
                          startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = fraction < 1 ? .round : .butt
            palette.accent.setStroke()
            arc.stroke()
        }
    }

    /// Fixed width for "100%" so the menu bar doesn't jitter as numbers change.
    private static let percentWidth: CGFloat = ceil(("100%" as NSString).size(withAttributes: [.font: metricFont]).width)

    /// Pie: small letter on the left, filled wedge from 12 o'clock clockwise over a faint disc.
    private static func drawPie(letter: String, percent: Int, x: CGFloat, palette: Palette) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7.5, weight: .bold),
                                                    .foregroundColor: palette.secondary]
        let size = (letter as NSString).size(withAttributes: attrs)
        (letter as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: attrs)
        let d: CGFloat = 13
        let rect = NSRect(x: x + 6, y: (height - d) / 2, width: d, height: d)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        palette.track.setFill()
        NSBezierPath(ovalIn: rect).fill()
        guard percent > 0 else { return }
        palette.accent.setFill()
        if percent >= 100 {
            NSBezierPath(ovalIn: rect).fill()
            return
        }
        let wedge = NSBezierPath()
        wedge.move(to: center)
        wedge.appendArc(withCenter: center, radius: d / 2, startAngle: 90,
                        endAngle: 90 - 360 * CGFloat(percent) / 100, clockwise: true)
        wedge.close()
        wedge.fill()
    }

    /// Compact vertical bar: small letter on the left, bar filling from the bottom.
    private static func drawBar(letter: String, percent: Int, x: CGFloat, palette: Palette) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7.5, weight: .bold),
                                                    .foregroundColor: palette.secondary]
        let size = (letter as NSString).size(withAttributes: attrs)
        (letter as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: attrs)
        let track = NSRect(x: x + 6, y: 2, width: 5, height: height - 4)
        palette.track.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        guard percent > 0 else { return }
        let h = max(1.5, track.height * CGFloat(min(percent, 100)) / 100)
        palette.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width, height: h),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// Single ring with a letter inside (C = CPU, M = memory).
    private static func drawGauge(letter: String, percent: Int, x: CGFloat, palette: Palette) {
        let center = NSPoint(x: x + ringSize / 2, y: height / 2)
        let lineWidth: CGFloat = 2.2
        let radius = ringSize / 2 - lineWidth / 2
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        palette.track.setStroke()
        track.stroke()
        if percent > 0 {
            let f = CGFloat(min(percent, 100)) / 100
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * f, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = f < 1 ? .round : .butt
            palette.accent.setStroke()
            arc.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .bold),
                                                    .foregroundColor: palette.label]
        let size = (letter as NSString).size(withAttributes: attrs)
        (letter as NSString).draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                                  withAttributes: attrs)
    }

    /// Two right-aligned lines: ↑ upload over ↓ download.
    private static func drawNet(up: String, down: String, x: CGFloat, width: CGFloat, palette: Palette) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        for (i, line) in [("↑", up), ("↓", down)].enumerated() {
            let arrow = NSAttributedString(string: line.0, attributes: [.font: font, .foregroundColor: palette.secondary])
            let value = NSAttributedString(string: line.1, attributes: [.font: font, .foregroundColor: palette.label])
            let y: CGFloat = i == 0 ? height / 2 : height / 2 - 9
            arrow.draw(at: NSPoint(x: x, y: y - 0.5))
            value.draw(at: NSPoint(x: x + width - value.size().width, y: y - 0.5))
        }
    }

    /// App icon; grayscale unless color icons are enabled (keeps the black + one accent palette).
    private static func drawAppIcon(_ img: NSImage, x: CGFloat, color: Bool, label: NSColor) {
        let rect = NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        if img.isTemplate {
            // SF Symbols (non-app processes): tint with the label color.
            let inset = rect.insetBy(dx: 1, dy: 1)
            if let ctx = NSGraphicsContext.current?.cgContext,
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.saveGState()
                ctx.clip(to: inset, mask: cg)
                ctx.setFillColor(label.cgColor)
                ctx.fill(inset)
                ctx.restoreGState()
            }
            return
        }
        // Grayscale conversion happens once, upstream (AppUsageMonitor.icon(for:grayscale:)).
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: color ? 1 : 0.9)
    }

    private static func drawFrog(frame: Int, origin: NSPoint, color: NSColor) {
        let f = frames[frame % frames.count]
        color.setFill()
        let canvasTop = origin.y + characterSize.height
        for (y, row) in f.rows.enumerated() {
            for (i, ch) in row.enumerated() where ch == "#" {
                NSRect(x: origin.x + CGFloat(i), y: canvasTop - CGFloat(f.top + y + 1), width: 1, height: 1).fill()
            }
        }
    }

    private static func drawText(_ s: Segment, x: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: s.font, .foregroundColor: s.color]
        let size = (s.text as NSString).size(withAttributes: attrs)
        (s.text as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: attrs)
    }

    /// Draws into a 2× bitmap once; the status bar then only blits it.
    private static func bitmap(size: NSSize, _ body: () -> Void) -> NSImage {
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        ctx?.cgContext.scaleBy(x: scale, y: scale)
        body()
        NSGraphicsContext.restoreGraphicsState()
        rep.size = size
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    /// Frame delay for the hopping frog; higher CPU → faster.
    static func frameInterval(cpu: Double, mode: AnimationMode) -> TimeInterval {
        switch mode {
        case .smooth: return max(0.05, 0.16 / max(1.0, cpu / 5.0))
        case .eco: return max(0.1, 0.3 / max(1.0, cpu / 10.0))
        case .still: return .infinity
        }
    }
}
