import AppKit
import SwiftUI

/// Neutral marks for the AI services: a monogram knocked out of a rounded square.
/// Deliberately not the services' own logos (those are their owners' trademarks).
enum ProviderMark {
    private static func monogram(_ provider: AIProvider) -> String {
        switch provider {
        case .claude: return "C"
        case .gemini: return "G"
        case .codex: return ">_"
        }
    }

    /// Path of the mark inside `rect` (y up, AppKit coordinates). Fill with even-odd.
    static func path(_ provider: AIProvider, in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let path = CGMutablePath()
        path.addRoundedRect(in: box, cornerWidth: side * 0.26, cornerHeight: side * 0.26)

        // Letters as outlines, centred in the box.
        let text = monogram(provider)
        let font = CTFontCreateWithName("SFProRounded-Heavy" as CFString, side * (text.count > 1 ? 0.5 : 0.68), nil)
        let fallback = NSFont.systemFont(ofSize: side * (text.count > 1 ? 0.5 : 0.68), weight: .heavy)
        let useFont: CTFont = CTFontCopyPostScriptName(font) as String == "SFProRounded-Heavy" ? font : fallback
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: useFont]))
        let glyphs = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for (g, p) in zip(ids, positions) {
                guard let gp = CTFontCreatePathForGlyph(runFont, g, nil) else { continue }
                glyphs.addPath(gp, transform: CGAffineTransform(translationX: p.x, y: p.y))
            }
        }
        let b = glyphs.boundingBoxOfPath
        path.addPath(glyphs, transform: CGAffineTransform(translationX: box.midX - b.midX, y: box.midY - b.midY))
        return path
    }

    /// Template image (tints like an SF Symbol), e.g. for tab icons.
    static func image(_ provider: AIProvider, size: CGFloat = 16) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(path(provider, in: rect.insetBy(dx: size * 0.06, dy: size * 0.06)))
            ctx.fillPath(using: .evenOdd)
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// SwiftUI view of a provider mark.
struct ProviderMarkView: View {
    let provider: AIProvider
    var color: Color = .secondary

    var body: some View {
        Image(nsImage: ProviderMark.image(provider, size: 32))
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(color)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel(provider.name)
    }
}
