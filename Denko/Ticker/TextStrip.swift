import AppKit

/// Announcements in the standard style: system type like the dashboard, not LED dots.
/// A small square tag names the source (filled with the board color when urgent),
/// followed by the message in the menu bar's label color.
@MainActor
enum TextStrip {
    struct Style {
        var height: CGFloat
        var appearance: NSAppearance
        var accent: NSColor
        var pixelScale: CGFloat = 2
    }

    /// Tag + message, for scrolling. Returns the image and its width in points.
    static func message(tag: String, title: String, body: String?, urgent: Bool, style: Style) -> (image: CGImage?, width: CGFloat) {
        var parts: [(String, NSColor, NSFont)] = [(title, .labelColor, mainFont(style))]
        if let body, !body.isEmpty {
            parts.append(("　—　", .tertiaryLabelColor, mainFont(style)))
            parts.append((body, .secondaryLabelColor, mainFont(style)))
        }
        return draw(tag: tag, urgent: urgent, parts: parts, style: style, width: nil)
    }

    /// Tag (and "緊急のお知らせ" when urgent) centred in `width`, for the heading.
    static func heading(tag: String, urgent: Bool, width: CGFloat, style: Style) -> CGImage? {
        let parts: [(String, NSColor, NSFont)] = urgent ? [(String(localized: "緊急のお知らせ"), .labelColor, mainFont(style))] : []
        return draw(tag: tag, urgent: urgent, parts: parts, style: style, width: width).image
    }

    private static func mainFont(_ s: Style) -> NSFont { .systemFont(ofSize: (s.height * 0.56).rounded(), weight: .medium) }
    private static func tagFont(_ s: Style) -> NSFont { .systemFont(ofSize: (s.height * 0.42).rounded(), weight: .semibold) }

    private static func draw(tag: String, urgent: Bool, parts: [(String, NSColor, NSFont)],
                             style s: Style, width fixedWidth: CGFloat?) -> (image: CGImage?, width: CGFloat) {
        var result: (CGImage?, CGFloat) = (nil, 0)
        s.appearance.performAsCurrentDrawingAppearance {
            let tagAttrs: [NSAttributedString.Key: Any] = [
                .font: tagFont(s),
                .foregroundColor: urgent ? NSColor.white : NSColor.secondaryLabelColor,
            ]
            let tagSize = (tag as NSString).size(withAttributes: tagAttrs)
            let pillH = (s.height * 0.68).rounded()
            let pillW = (tagSize.width + pillH * 0.6).rounded()
            let gap: CGFloat = 8
            let texts = parts.map { NSAttributedString(string: $0.0, attributes: [.font: $0.2, .foregroundColor: $0.1]) }
            let textW = texts.reduce(0) { $0 + ceil($1.size().width) }
            let content = pillW + (texts.isEmpty ? 0 : gap + textW)
            let width = fixedWidth ?? content + 4
            let x0 = fixedWidth.map { max(0, ($0 - content) / 2) } ?? 2
            let size = NSSize(width: max(1, width), height: s.height)
            result.1 = size.width
            result.0 = LEDRenderer.bitmap(size: size, scale: s.pixelScale) {
                // Tag pill.
                let pill = NSRect(x: x0, y: ((s.height - pillH) / 2).rounded(), width: pillW, height: pillH)
                (urgent ? s.accent : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 2, yRadius: 2).fill()
                (tag as NSString).draw(at: NSPoint(x: pill.midX - tagSize.width / 2, y: pill.midY - tagSize.height / 2),
                                       withAttributes: tagAttrs)
                // Message.
                var x = pill.maxX + gap
                for t in texts {
                    let sz = t.size()
                    t.draw(at: NSPoint(x: x, y: (s.height - sz.height) / 2))
                    x += ceil(sz.width)
                }
            }
        }
        return result
    }
}
