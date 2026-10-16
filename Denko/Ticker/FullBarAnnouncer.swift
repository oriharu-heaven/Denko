import AppKit

/// Urgent announcements take over the whole menu bar: a borderless LED board window the
/// full width and height of the bar, above it, like a station's emergency notice.
/// The board is drawn at the normal dot grid and scaled up, so it keeps the LED look.
@MainActor
final class FullBarAnnouncer: NSObject, CAAnimationDelegate {
    /// Set while a message is showing. The panel itself is created once and reused.
    private var window: NSPanel?
    private lazy var panel: NSPanel = makePanel()
    /// Bumped on every show, so a late fade-out never hides a newer message.
    private var generation = 0
    private var boardCache: (key: String, image: CGImage?)?
    private let board = CALayer()
    /// Visible stretches of the bar. On a notched display there are two, either side of the
    /// camera housing; the text runs through them as one strip, skipping the notch.
    private struct Segment { let clip: CALayer; let text: CALayer; let offset: CGFloat }
    private var segments: [Segment] = []
    private var completion: (() -> Void)?
    private var passesLeft = 0
    private var message: TickerMessage?
    private var speed: Double = 75
    private var blink = true
    private var heading = true
    private var accent: NSColor = .systemGreen
    private var timer: Timer?
    /// Watches the pointer: near the menu bar the board steps aside (fades out and lets
    /// clicks through) so the menus underneath stay usable.
    private var hoverTimer: Timer?
    private var steppedAside = false
    /// Called when the user clicks the board (it closes and the panel opens).
    var onClick: (() -> Void)?

    var isShowing: Bool { window != nil }
    /// Standard style: plain type on a menu-bar-coloured strip instead of the LED board.
    var textStyle = false

    private var textAppearance: NSAppearance { NSApp.effectiveAppearance }
    private func style(height: CGFloat) -> TextStrip.Style {
        TextStrip.Style(height: height, appearance: textAppearance, accent: accent,
                        pixelScale: window?.backingScaleFactor ?? 2)
    }

    func play(_ msg: TickerMessage, accent: NSColor, speed: Double, blink: Bool = true, heading: Bool = true,
              passes: Int, completion: @escaping () -> Void) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        else { completion(); return }
        self.message = msg
        self.accent = accent
        self.speed = speed
        self.blink = blink
        self.heading = heading
        self.passesLeft = max(1, passes)
        self.completion = completion

        let barHeight = max(22, screen.frame.maxY - screen.visibleFrame.maxY)
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - barHeight,
                           width: screen.frame.width, height: barHeight)
        generation += 1
        let t0 = Date()
        let panel = self.panel
        panel.setFrame(frame, display: false)
        window = panel
        let t1 = Date()
        layout(size: frame.size, screen: screen)
        let t2 = Date()
        Self.debugLog(String(format: "timing panel=%.2fs layout=%.2fs", t1.timeIntervalSince(t0), t2.timeIntervalSince(t1)))
        // Plain alpha changes: animating alphaValue on this above-the-menu-bar panel didn't take
        // effect (it stayed invisible).
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        steppedAside = false
        panel.ignoresMouseEvents = false
        startHoverWatch()
        showHeading(msg)
        Self.debugLog("play \(msg.title) frame=\(panel.frame) visible=\(panel.isVisible) level=\(panel.level.rawValue)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            Self.debugLog("after1s alpha=\(self.panel.alphaValue) visible=\(self.panel.isVisible) aside=\(self.steppedAside) showing=\(self.window != nil) number=\(self.panel.windowNumber)")
        }
    }

    static func debugLog(_ text: String) {
        guard ProcessInfo.processInfo.environment["DENKO_DEBUG"] != nil || FileManager.default.fileExists(atPath: "/tmp/denko-debug") else { return }
        let line = "\(Date()) \(text)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/denko-debug.log") { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
        else { try? line.write(toFile: "/tmp/denko-debug.log", atomically: true, encoding: .utf8) }
    }

    private func startHoverWatch() {
        hoverTimer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
        t.tolerance = 0.03
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    private func checkPointer() {
        guard let w = window else { return }
        // A little margin below the bar, so it's out of the way before the pointer arrives.
        let zone = w.frame.insetBy(dx: 0, dy: -12)
        let near = zone.contains(NSEvent.mouseLocation)
        guard near != steppedAside else { return }
        steppedAside = near
        w.ignoresMouseEvents = near
        w.alphaValue = near ? 0 : 1
    }

    func stop() {
        Self.debugLog("stop showing=\(window != nil)")
        hoverTimer?.invalidate()
        hoverTimer = nil
        timer?.invalidate()
        segments.forEach { $0.text.removeAllAnimations() }
        guard let w = window else { return }
        window = nil
        let gen = generation
        _ = gen
        w.orderOut(nil)
        Self.debugLog("after orderOut visible=\(w.isVisible) onActiveSpace=\(w.isOnActiveSpace) frame=\(w.frame) occl=\(w.occlusionState.rawValue)")
    }

    // MARK: - Window

    private func makePanel() -> NSPanel {
        let p = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // Just above the menu bar (and its status items).
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        let view = ClickView()
        view.onClick = { [weak self] in self?.clicked() }
        view.wantsLayer = true
        view.layer?.addSublayer(board)
        board.actions = Self.noActions
        board.contentsGravity = .resize
        p.contentView = view
        return p
    }

    private func clicked() {
        stop()
        let done = completion
        completion = nil
        done?()
        onClick?()
    }

    /// Scale from the normal dot grid up to the bar's height.
    private var scale: CGFloat = 1

    private static let noActions: [String: CAAction] =
        ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]

    private func layout(size: NSSize, screen: NSScreen) {
        scale = textStyle ? 1 : size.height / LEDRenderer.boardHeight
        board.frame = CGRect(origin: .zero, size: size)
        if textStyle {
            // A strip coloured like the menu bar, so the bar simply reads as a line of text.
            var bg = NSColor.windowBackgroundColor.cgColor
            textAppearance.performAsCurrentDrawingAppearance { bg = NSColor.windowBackgroundColor.cgColor }
            board.contents = nil
            board.backgroundColor = bg
        } else {
            board.backgroundColor = nil
        }
        let key = "\(size.width)|\(scale)|\(accent)|\(LEDRenderer.styleVersion)"
        if textStyle {
            // no dot board
        } else if boardCache?.key != key {
            boardCache = (key, LEDRenderer.board(width: size.width / scale, accent: accent)
                .cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
        if !textStyle { board.contents = boardCache?.image }
        board.cornerRadius = 0
        let s = window?.backingScaleFactor ?? 2
        board.contentsScale = s

        // Visible stretches, snapped to the dot grid so text dots line up with the board's.
        let step = textStyle ? 1 : LEDRenderer.pitch * scale
        var ranges: [(CGFloat, CGFloat)] = [(0, size.width)]
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           left.width > 0, right.width > 0, left.width + right.width < size.width {
            let l = (left.width / step).rounded(.down) * step
            let r = ((size.width - right.width) / step).rounded(.up) * step
            ranges = [(0, l), (r, size.width)]
        }
        segments.forEach { $0.clip.removeFromSuperlayer() }
        var offset: CGFloat = 0
        segments = ranges.map { minX, maxX in
            let clip = CALayer(), text = CALayer()
            clip.masksToBounds = true
            clip.frame = CGRect(x: minX, y: 0, width: maxX - minX, height: size.height)
            text.anchorPoint = .zero
            text.contentsGravity = .resize
            for l in [clip, text] { l.actions = Self.noActions; l.contentsScale = s }
            clip.addSublayer(text)
            board.addSublayer(clip)
            defer { offset += maxX - minX }
            return Segment(clip: clip, text: text, offset: offset)
        }
    }

    // MARK: - Playback

    private func showHeading(_ msg: TickerMessage) {
        guard heading || msg.urgent else { scroll(); return }
        // Each visible stretch gets the heading centred in it, so none of it hides in the notch.
        for seg in segments {
            let width = seg.clip.bounds.width
            seg.text.removeAllAnimations()
            let heading = msg.urgent ? "◆  \(msg.source.tag)  ◆  緊急のお知らせ  ◆" : "◆  \(msg.source.tag)  ◆"
            seg.text.contents = textStyle
                ? TextStrip.heading(tag: msg.source.label, urgent: msg.urgent, width: width, style: style(height: board.bounds.height))
                : LEDRenderer.staticStrip(for: heading, accent: accent, boardWidth: width / scale)
            seg.text.bounds = CGRect(x: 0, y: 0, width: width, height: board.bounds.height)
            seg.text.position = .zero
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 0.05, 1, 0.05, 1, 0.05, 1]
            blink.calculationMode = .discrete
            blink.duration = 1.8
            if msg.urgent && self.blink && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { seg.clip.add(blink, forKey: "blink") }
        }
        timer?.invalidate()
        let t = Timer(timeInterval: msg.urgent ? 2.0 : 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scroll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func scroll() {
        guard let msg = message, window != nil else { return }
        if textStyle { scrollText(msg); return }
        let strip = LEDRenderer.strip(for: "\(msg.source.tag)   \(msg.title)" + (msg.body.map { "  —  \($0)" } ?? ""),
                                      accent: accent)
        let w = strip.width * scale, h = board.bounds.height
        // Scroll along the visible stretches joined end to end (the notch is skipped): text
        // leaving the right stretch at the notch's right edge enters at its left edge at once.
        let visible = segments.reduce(0) { $0 + $1.clip.bounds.width }
        let step = LEDRenderer.pitch * scale
        let start = (visible / step).rounded(.down) * step
        let end = -w
        let steps = max(2, Int((start - end) / step))
        let duration = Double(start - end) / (speed * scale)
        let begin = CACurrentMediaTime()
        for (i, seg) in segments.enumerated() {
            seg.clip.removeAllAnimations()
            seg.text.removeAllAnimations()
            seg.text.contents = strip.image
            seg.text.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            let anim = CAKeyframeAnimation(keyPath: "position.x")
            anim.values = (0...steps).map { NSNumber(value: Double(start - CGFloat($0) * step - seg.offset)) }
            anim.calculationMode = .discrete
            anim.duration = duration
            anim.beginTime = begin
            if i == segments.count - 1 { anim.delegate = self }
            seg.text.position = CGPoint(x: end - seg.offset, y: 0)
            seg.text.add(anim, forKey: "scroll")
        }
    }

    /// Standard style: the message glides smoothly across the visible stretches.
    private func scrollText(_ msg: TickerMessage) {
        let h = board.bounds.height
        let strip = TextStrip.message(tag: msg.source.label, title: msg.title, body: msg.body,
                                      urgent: msg.urgent, style: style(height: h))
        let visible = segments.reduce(0) { $0 + $1.clip.bounds.width }
        let w = strip.width
        let duration = Double(visible + w) / speed
        let begin = CACurrentMediaTime()
        for (i, seg) in segments.enumerated() {
            seg.clip.removeAllAnimations()
            seg.text.removeAllAnimations()
            seg.text.contents = strip.image
            seg.text.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            let anim = CABasicAnimation(keyPath: "position.x")
            anim.fromValue = visible - seg.offset
            anim.toValue = -w - seg.offset
            anim.duration = duration
            anim.beginTime = begin
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            if i == segments.count - 1 { anim.delegate = self }
            seg.text.position = CGPoint(x: -w - seg.offset, y: 0)
            seg.text.add(anim, forKey: "scroll")
        }
    }

    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        MainActor.assumeIsolated {
            Self.debugLog("didStop finished=\(flag) passesLeft=\(passesLeft) duration=\(anim.duration)")
            guard flag, window != nil else { return }
            passesLeft -= 1
            if passesLeft > 0 {
                scroll()
            } else {
                stop()
                let done = completion
                completion = nil
                done?()
            }
        }
    }
}

private final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A panel allowed to sit on the menu bar: AppKit otherwise pushes windows below it.
private final class BarPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
}
