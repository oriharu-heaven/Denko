import AppKit
import Combine
import SwiftUI

/// The single merged status item: hopping frog, optional metrics, and the Claude double ring.
///
/// Kept cheap on purpose:
/// - the static part is one bitmap, rebuilt only when what it shows changes
/// - the frog animates in its own layer, so a frame is just a layer-contents swap
/// - the animation stops whenever the icon can't be seen (fullscreen, display asleep,
///   screen locked), in Low Power Mode, and optionally on battery
/// - the SwiftUI panel exists only while it's open
@MainActor
final class MainStatusController: NSObject, NSPopoverDelegate, NSViewToolTipOwner, CAAnimationDelegate {
    private let item: NSStatusItem
    private let ai: AIUsageStore
    let panelState = PanelState()
    /// Clickable parts of the icon (image x ranges), from the last render.
    private var regions: [(IconRegion, ClosedRange<CGFloat>)] = []
    private let monitor: SystemMonitor
    private let settings: AppSettings
    private let awake: SleepPreventer
    private let apps: AppUsageMonitor

    private var popover: NSPopover?
    private let characterLayer = CALayer()
    /// Holds the rendered icon; swapping layer contents is far cheaper than replacing
    /// the button image (which re-lays out the menu bar).
    private let contentLayer = CALayer()
    private var placeholderSize = NSSize.zero
    /// LED board background (black + unlit dots): shown in LED mode and during announcements.
    private let boardLayer = CALayer()
    /// Announcements scroll here, clipped to the board.
    private let announceClip = CALayer()
    private let announceText = CALayer()
    private let hub: NotificationHub
    private var announcing: TickerMessage?
    private var passesLeft = 0
    private var announceTimer: Timer?
    private let fullBar = FullBarAnnouncer()
    private var boardCache: (width: CGFloat, style: String, image: CGImage?)?
    private var renderedStyle = ""
    private var clockTimer: Timer?
    private static let minAnnounceWidth: CGFloat = 130

    private var isLED: Bool { settings.displayStyle == .led }
    /// x (in button coordinates) of the last mouse-down on the item, recorded by a local
    /// event monitor: on macOS 27 the event current when the action fires doesn't always
    /// carry the click position, which made every click open the previous tab.
    private var lastPressX: CGFloat?
    private var pressMonitor: Any?
    private var characterFrames: [CGImage] = []
    private var fullFrames: [NSImage] = []
    private var characterRect = NSRect.zero
    private var frameIndex = 0
    private var content: IconContent?
    private var renderedCompat = false
    private var animTimer: Timer?
    private var screensAsleep = false
    private var onBattery = false
    private var bag = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?

    private var frameCount: Int { max(characterFrames.count, fullFrames.count) }

    init(ai: AIUsageStore, monitor: SystemMonitor, apps: AppUsageMonitor,
         settings: AppSettings, awake: SleepPreventer, hub: NotificationHub) {
        self.hub = hub
        self.ai = ai
        self.apps = apps
        self.monitor = monitor
        self.settings = settings
        self.awake = awake
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "main"
        super.init()

        // Size the LED board to the menu bar item (22pt → 19 dot rows).
        LEDRenderer.configure(height: NSStatusBar.system.thickness)

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.wantsLayer = true
            characterLayer.magnificationFilter = .nearest
            characterLayer.contentsGravity = .resize
            characterLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            contentLayer.contentsGravity = .resize
            contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            for l in [boardLayer, announceClip, announceText] {
                l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(),
                             "opacity": NSNull()]
            }
            boardLayer.contentsGravity = .resize
            boardLayer.isHidden = true
            announceClip.masksToBounds = true
            announceClip.isHidden = true
            announceText.anchorPoint = .zero
            announceText.contentsGravity = .resize
            announceClip.addSublayer(announceText)
            button.layer?.addSublayer(boardLayer)
            button.layer?.addSublayer(contentLayer)
            button.layer?.addSublayer(characterLayer)
            button.layer?.addSublayer(announceClip)
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.positionCharacter()
                }
            }
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.rebuild(force: true) }
            }
        }
        observe()
        hub.onEnqueue = { [weak self] urgent in self?.messageArrived(urgent: urgent) }
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, let button = self.item.button, e.window === button.window else { return }
                self.lastPressX = button.convert(e.locationInWindow, from: nil).x
            }
            return e
        }
        rebuild(force: true)
    }

    deinit {
        if let m = pressMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Observation

    private var lastMenuBarConfigKey = ""

    private func observe() {
        lastMenuBarConfigKey = settings.menuBarConfigKey
        // objectWillChange fires before the value changes, so hop to the next runloop turn.
        ai.objectWillChange
            .merge(with: awake.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.updateSampling()
                self.rebuild(force: false)
                self.updateAnimation()
            }
            .store(in: &bag)
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                let key = self.settings.menuBarConfigKey
                guard key != self.lastMenuBarConfigKey else { return }
                self.lastMenuBarConfigKey = key
                self.updateSampling()
                self.rebuild(force: false)
                self.updateAnimation()
            }
            .store(in: &bag)
        updateSampling()
        apps.$leader.removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild(force: false, dataDriven: true) }
            .store(in: &bag)

        monitor.$cpu
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.settings.pauseOnBattery {
                    self.onBattery = SystemMonitor.isOnBattery
                }
                self.rebuild(force: false, dataDriven: true)
                self.updateAnimation()
            }
            .store(in: &bag)

        let ws = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true),
                               (NSWorkspace.sessionDidResignActiveNotification, true),
                               (NSWorkspace.screensDidWakeNotification, false),
                               (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            ws.publisher(for: name)
                .sink { [weak self] _ in
                    self?.screensAsleep = asleep
                    self?.updateSampling()
                    self?.updateAnimation()
                }
                .store(in: &bag)
        }

        let nc = NotificationCenter.default
        nc.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateAnimation() }
            .store(in: &bag)
        nc.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .sink { [weak self] note in
                guard let self, (note.object as? NSWindow) === self.item.button?.window else { return }
                self.updateAnimation()
            }
            .store(in: &bag)
    }

    /// Only sample what is actually on screen.
    private func updateSampling() {
        monitor.setPaused(screensAsleep)
        monitor.sampleMemoryAlways = settings.showMemoryGauge
        monitor.sampleNetworkAlways = settings.showNetworkGauge
        let gauges = settings.showCPUGauge || settings.showMemoryGauge || settings.showNetworkGauge
        monitor.setIntervals(menuBar: settings.menuBarInterval, panel: settings.panelInterval)
        // Scan apps for CPU/Memory when gauges are shown; only run background nettop when the
        // top-app icon is actually displayed on the menu bar (otherwise sample on tooltip hover).
        apps.configure(menuBar: !screensAsleep && gauges,
                       menuBarNetwork: !screensAsleep && settings.showNetworkGauge && settings.showTopApp,
                       detailed: !screensAsleep && popover != nil,
                       menuBarInterval: max(6, settings.menuBarInterval * 2),
                       panelInterval: settings.panelInterval)
    }

    // MARK: - Rendering

    private func currentContent() -> IconContent {
        IconContent(showCharacter: settings.showCharacter,
                    cpu: settings.showCPUGauge
                        ? Gauge(percent: quantized(monitor.cpu), app: topApp(.cpu)) : nil,
                    memory: settings.showMemoryGauge
                        ? Gauge(percent: quantized(monitor.memoryPercent), app: topApp(.memory)) : nil,
                    network: settings.showNetworkGauge
                        ? NetGauge(up: ByteText.compactRate(monitor.netUp), down: ByteText.compactRate(monitor.netDown),
                                   app: topApp(.network)) : nil,
                    showNumbers: settings.gaugeNumbers,
                    gaugeStyle: settings.gaugeStyle,
                    colorIcons: settings.colorAppIcons,
                    reserveAppSlot: settings.showTopApp,
                    ai: aiGauges(),
                    numbers: settings.claudeNumbers,
                    accent: settings.accent,
                    awake: awake.isActive,
                    character: settings.character)
    }

    private func aiGauges() -> [AIGauge] {
        let shown = AIProvider.allCases.filter { settings.menuBarAI.contains($0) && settings.aiProviders.contains($0) }
        return shown.map { p in
            AIGauge(provider: p, tag: shown.count > 1 ? p.tag : nil,
                    outer: ai.usage[p]?.primary.map { Double(Int($0.percent.rounded())) },
                    inner: ai.usage[p]?.secondary.map { Double(Int($0.percent.rounded())) },
                    error: ai.errors[p] != nil)
        }
    }

    private func topApp(_ m: AppUsageMonitor.Metric) -> String? {
        settings.showTopApp ? apps.leader[m] : nil
    }

    /// Ring-only gauges move in 5% steps (what the eye can tell apart); with numbers, 1%.
    private func quantized(_ v: Double) -> Int {
        settings.gaugeNumbers ? Int(v.rounded()) : Int((v / 5).rounded()) * 5
    }

    private var lastDataRebuild = Date.distantPast
    private var pendingDataRebuild: Timer?
    /// Each new menu bar image costs a re-layout in the menu bar, so value-only
    /// updates are limited to one every few seconds.
    private static let minDataInterval: TimeInterval = 5

    private func rebuild(force: Bool, dataDriven: Bool = false) {
        let c = currentContent()
        let compat = settings.compatibleCatRendering
        let style = settings.boardStyleKey
        LEDRenderer.apply(dotSize: settings.dotSize, square: settings.dotShape == .square,
                          unlit: settings.unlitDots, base: settings.boardBaseColor)
        guard force || compat != renderedCompat || c != content || style != renderedStyle,
              let button = item.button else { return }
        renderedStyle = style
        updateClockTimer()
        if dataDriven && !force {
            let wait = Self.minDataInterval - Date().timeIntervalSince(lastDataRebuild)
            if wait > 0 {
                if pendingDataRebuild == nil {
                    let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.pendingDataRebuild = nil
                            self?.rebuild(force: false, dataDriven: true)
                        }
                    }
                    t.tolerance = 0.5
                    RunLoop.main.add(t, forMode: .common)
                    pendingDataRebuild = t
                }
                return
            }
            lastDataRebuild = Date()
        }
        content = c
        renderedCompat = compat

        if isLED {
            renderLED(c, button: button)
            return
        }
        boardLayer.isHidden = announcing == nil
        let r = IconRenderer.render(c, appearance: button.effectiveAppearance, compatible: compat,
                                    icon: { [apps, settings] in apps.icon(for: $0, grayscale: !settings.colorAppIcons) })
        characterFrames = r.characterFrames
        fullFrames = r.fullFrames
        regions = r.regions
        characterRect = r.characterRect
        frameIndex = frameCount == 0 ? 0 : frameIndex % frameCount
        if fullFrames.isEmpty {
            // Only touch the button image when the width changes.
            setPlaceholder(r.base.size, on: button)
            contentLayer.isHidden = announcing != nil
            contentLayer.contents = r.base.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else {
            placeholderSize = .zero
            contentLayer.isHidden = true
            button.image = fullFrames[frameIndex]
        }
        characterLayer.isHidden = characterFrames.isEmpty || announcing != nil
        characterLayer.contents = characterFrames.isEmpty ? nil : characterFrames[frameIndex]
        positionCharacter()
        updateAccessibilityLabel(button)
    }

    /// Clock on the idle board: redraw on each minute.
    private func updateClockTimer() {
        let wanted = isLED && settings.boardIdle == .clock
        if !wanted { clockTimer?.invalidate(); clockTimer = nil; return }
        guard clockTimer == nil else { return }
        let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0),
                                             matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
        let t = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild(force: true) }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()

    /// Idle board showing a clock or a fixed message instead of the dashboard.
    private func renderIdleText(button: NSStatusBarButton) {
        let text = settings.boardIdle == .clock ? Self.clockFormatter.string(from: Date())
            : (settings.idleMessage.isEmpty ? "DENKO" : String(settings.idleMessage.prefix(40)))
        let m = LEDRenderer.mask(for: text)
        let width = CGFloat(max(m.columns + 8, 26)) * LEDRenderer.pitch
        characterFrames = []
        fullFrames = []
        regions = []
        characterRect = .zero
        setPlaceholder(NSSize(width: width, height: LEDRenderer.boardHeight), on: button)
        boardLayer.contents = boardImage(width: placeholderSize.width)
        boardLayer.isHidden = false
        contentLayer.contents = LEDRenderer.staticStrip(for: text, accent: settings.boardNSColor,
                                                        boardWidth: placeholderSize.width)
        contentLayer.isHidden = announcing != nil
        characterLayer.isHidden = true
        updateAccessibilityLabel(button)
    }

    /// LED mode: the dashboard drawn natively on the dot board.
    private func renderLED(_ c: IconContent, button: NSStatusBarButton) {
        if settings.boardIdle != .dashboard {
            renderIdleText(button: button)
            return
        }
        let o = LEDDashboard.render(c, accent: settings.boardNSColor)
        characterFrames = o.frogFrames
        fullFrames = []
        regions = o.regions
        characterRect = o.frogRect
        frameIndex = frameCount == 0 ? 0 : frameIndex % frameCount
        setPlaceholder(NSSize(width: o.width, height: LEDRenderer.boardHeight), on: button)
        boardLayer.contents = boardImage(width: max(o.width, placeholderSize.width))
        boardLayer.isHidden = false
        contentLayer.contents = o.content
        contentLayer.isHidden = announcing != nil
        characterLayer.isHidden = characterFrames.isEmpty || announcing != nil
        characterLayer.contents = characterFrames.isEmpty ? nil : characterFrames[frameIndex]
        positionCharacter()
        updateAccessibilityLabel(button)
    }

    /// The board background, cached per width and accent.
    private func boardImage(width: CGFloat) -> CGImage? {
        if let c = boardCache, c.width == width, c.style == settings.boardStyleKey { return c.image }
        let img = LEDRenderer.board(width: width, accent: settings.boardNSColor)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        boardCache = (width, settings.boardStyleKey, img)
        return img
    }

    /// Sizes the (transparent) button image, which sets the item's width. During an
    /// announcement the item is kept at least wide enough to read the board.
    private var dashboardSize = NSSize.zero
    private func setPlaceholder(_ size: NSSize, on button: NSStatusBarButton) {
        dashboardSize = size
        var s = size
        if announcing != nil { s.width = max(s.width, Self.minAnnounceWidth) }
        if placeholderSize != s || button.image == nil {
            placeholderSize = s
            button.image = NSImage(size: s)
        }
    }

    private var lastAXUpdate = Date.distantPast

    /// Changing the label pings every Accessibility client, so refresh it at most every 30s.
    private func updateAccessibilityLabel(_ button: NSStatusBarButton) {
        guard Date().timeIntervalSince(lastAXUpdate) > 30 else { return }
        lastAXUpdate = Date()
        // Short and static: macOS 27 shows the item's label when hovering the menu bar,
        // so a long, changing description appeared as a hover balloon.
        button.setAccessibilityLabel("Denko")
        // The readings go in the value (read by VoiceOver, not shown as a hover balloon).
        button.setAccessibilityValue(tooltip().replacingOccurrences(of: "\n", with: "、"))
        button.toolTip = nil
    }

    /// Tooltip text is built only when the pointer actually hovers; each part of the icon
    /// has its own tooltip area, so hovering the CPU pie shows CPU details, and so on.
    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                          point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        return MainActor.assumeIsolated {
            guard index >= 0, index < regions.count else { return tooltip() }
            return tooltip(for: regions[index].0)
        }
    }


    private var lastTipWidth: CGFloat = 0

    private func tooltip(for region: IconRegion) -> String {
        func top(_ list: [AppUsageMonitor.AppUsage], _ value: (AppUsageMonitor.AppUsage) -> String) -> String {
            list.prefix(3).map { "・\($0.name)  \(value($0))" }.joined(separator: "\n")
        }
        let hint = "クリックで詳細"
        switch region {
        case .character, .cpu:
            var s = String(format: "CPU %.0f%%", monitor.cpu)
            let t = top(apps.topCPU) { String(format: "%.1f%%", $0.cpu) }
            if !t.isEmpty { s += "\n" + t }
            if region == .character && Features.sleepPrevention {
                s += "\nスリープ防止: \(awake.remainingText())\n⌥クリックでスリープ防止を切り替え"
            }
            return s + "\n" + hint
        case .memory:
            var s = "メモリ \(ByteText.size(Int64(monitor.memoryUsed))) / \(ByteText.size(Int64(monitor.memoryTotal)))"
                + String(format: "（%.0f%%）", monitor.memoryPercent)
            let t = top(apps.topMemory) { ByteText.size(Int64($0.memory)) }
            if !t.isEmpty { s += "\n" + t }
            return s + "\n" + hint
        case .network:
            apps.sampleNetworkIfNeeded()
            var s = "受信 \(ByteText.rate(monitor.netDown))　送信 \(ByteText.rate(monitor.netUp))"
            let t = top(apps.topNetwork) { ByteText.rate($0.net) }
            if !t.isEmpty { s += "\n" + t }
            return s + "\n" + hint
        case .ai(let p):
            guard let u = ai.usage[p] else { return "\(p.name): \(ai.errors[p] ?? "取得中…")" }
            var lines = [p.name]
            for w in [u.primary, u.secondary].compactMap({ $0 }) {
                var line = "\(w.label) \(Int(w.percent.rounded()))%"
                if let r = w.resetsAt { line += "（リセット\(TimeText.untilReset(r).replacingOccurrences(of: "あと ", with: "まで"))）" }
                lines.append(line)
            }
            lines.append("\(TimeText.absolute(u.updatedAt)) 更新・\(hint)")
            return lines.joined(separator: "\n")
        }
    }

    /// Places the content layer where the image would be drawn, and the frog over its gap.
    private func positionCharacter() {
        guard let button = item.button, let image = button.image else { return }
        let bounds = button.bounds
        let originX = ((bounds.width - image.size.width) / 2).rounded()
        let originY = ((bounds.height - image.size.height) / 2).rounded()
        let scale = button.window?.backingScaleFactor ?? 2
        let full = NSRect(x: originX, y: originY, width: image.size.width, height: image.size.height)
        // Content keeps its natural width (it may be narrower than the board during announcements).
        contentLayer.frame = NSRect(x: originX, y: originY,
                                    width: dashboardSize.width > 0 ? dashboardSize.width : image.size.width,
                                    height: image.size.height)
        contentLayer.contentsScale = scale
        boardLayer.frame = full
        boardLayer.contentsScale = scale
        announceClip.frame = full
        announceClip.cornerRadius = 3.5
        announceText.contentsScale = scale
        guard !characterFrames.isEmpty else { return }
        characterLayer.frame = NSRect(x: (originX + characterRect.minX).rounded(),
                                      y: (originY + characterRect.minY).rounded(),
                                      width: characterRect.width, height: characterRect.height)
        characterLayer.contentsScale = button.window?.backingScaleFactor ?? 2
    }

    private func tooltip() -> String {
        var lines: [String] = []
        for p in ai.enabled {
            guard let u = ai.usage[p] else { continue }
            var parts: [String] = []
            if let w = u.primary { parts.append("\(w.label) \(Int(w.percent.rounded()))%") }
            if let w = u.secondary { parts.append("\(w.label) \(Int(w.percent.rounded()))%") }
            lines.append("\(p.name): " + parts.joined(separator: " / "))
        }
        func appName(_ m: AppUsageMonitor.Metric) -> String {
            guard let id = apps.leader[m] else { return "" }
            let list = m == .cpu ? apps.topCPU : m == .memory ? apps.topMemory : apps.topNetwork
            return list.first { $0.id == id }.map { "（最多: \($0.name)）" } ?? ""
        }
        lines.append(String(format: "CPU %.0f%%", monitor.cpu) + appName(.cpu))
        lines.append(String(format: "メモリ %.0f%%", monitor.memoryPercent) + appName(.memory))
        lines.append("通信 ↓\(ByteText.rate(monitor.netDown)) ↑\(ByteText.rate(monitor.netUp))" + appName(.network))
        if Features.sleepPrevention {
            lines.append("スリープ防止: \(awake.remainingText())")
            lines.append("⌥クリックでスリープ防止を切り替え")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Animation

    private var shouldAnimate: Bool {
        guard settings.showCharacter, settings.animationMode != .still, frameCount > 1 else { return false }
        if screensAsleep || ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        if settings.pauseOnBattery && onBattery { return false }
        if let window = item.button?.window, !window.occlusionState.contains(.visible) { return false }
        return true
    }

    private func updateAnimation() {
        if shouldAnimate {
            if animTimer == nil { scheduleNextFrame() }
        } else {
            animTimer?.invalidate()
            animTimer = nil
        }
    }

    private func scheduleNextFrame() {
        let interval = IconRenderer.frameInterval(cpu: monitor.cpu, mode: settings.animationMode)
        guard interval.isFinite else { return }
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.animTimer = nil
                guard self.shouldAnimate else { return }
                self.frameIndex = (self.frameIndex + 1) % self.frameCount
                if self.fullFrames.isEmpty {
                    self.characterLayer.contents = self.characterFrames[self.frameIndex]
                } else {
                    self.item.button?.image = self.fullFrames[self.frameIndex]
                }
                self.scheduleNextFrame()
            }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    // MARK: - Announcements (station-style board takeover)

    /// A notification takes over the item: a heading (blinking if urgent), then the message
    /// scrolls past one dot column at a time, then the dashboard comes back.
    private func messageArrived(urgent: Bool) {
        FullBarAnnouncer.debugLog("arrived urgent=\(urgent) announcing=\(announcing?.title ?? "nil") ticker=\(settings.tickerEnabled)")
        guard settings.tickerEnabled else {
            _ = hub.dequeue()
            return
        }
        if announcing == nil || (urgent && announcing?.urgent != true) {
            playNextAnnouncement()
        }
    }

    private func playNextAnnouncement() {
        guard let msg = hub.dequeue() else {
            endAnnouncement()
            return
        }
        passesLeft = settings.tickerRepeat
        beginAnnouncement(msg)
    }

    /// While a notice is on the board: open its link / coding agent host, or close it.
    private func announcementMenuItems() -> [NSMenuItem] {
        guard let msg = announcing else { return [] }
        var items: [NSMenuItem] = []
        let header = NSMenuItem(title: "流れているお知らせ：\(msg.title.prefix(24))", action: nil, keyEquivalent: "")
        items.append(header)
        if msg.canOpen {
            let open = NSMenuItem(title: msg.openLabel, action: #selector(openAnnouncement), keyEquivalent: "")
            open.target = self
            items.append(open)
        }
        let close = NSMenuItem(title: "このお知らせを閉じる", action: #selector(closeAnnouncement), keyEquivalent: "")
        close.target = self
        items.append(close)
        return items
    }

    @objc private func openAnnouncement() {
        announcing?.open()
        closeAnnouncement()
    }

    @objc private func closeAnnouncement() {
        fullBar.stop()
        playNextAnnouncement()
    }

    private func beginAnnouncement(_ msg: TickerMessage) {
        guard let button = item.button else { return }
        // VoiceOver reads notices out (urgent ones interrupt).
        NSAccessibility.post(element: button, notification: .announcementRequested, userInfo: [
            .announcement: "\(msg.source.label)、\(msg.title)",
            .priority: (msg.urgent ? NSAccessibilityPriorityLevel.high : .medium).rawValue,
        ])
        // Urgent (or, by setting, everything): take over the whole menu bar, scrolling faster.
        FullBarAnnouncer.debugLog("begin \(msg.title)")
        if settings.fullBarUrgent && (msg.urgent || settings.fullBarAll) {
            // The item itself goes back to the dashboard while the full-bar board plays.
            announceTimer?.invalidate()
            announceText.removeAllAnimations()
            announceClip.isHidden = true
            boardLayer.isHidden = !isLED
            contentLayer.isHidden = !fullFrames.isEmpty
            characterLayer.isHidden = characterFrames.isEmpty
            announcing = msg
            // Click: open the article or jump to the coding agent's terminal/editor if available.
            fullBar.onClick = {
                msg.open()
            }
            fullBar.textStyle = !isLED
            fullBar.play(msg, accent: settings.boardNSColor, speed: settings.tickerSpeed * settings.urgentSpeed,
                         blink: settings.urgentBlink, heading: settings.showHeading,
                         passes: msg.urgent ? settings.tickerRepeat : 1) { [weak self] in
                self?.playNextAnnouncement()
            }
            return
        }
        announcing = msg
        announceTimer?.invalidate()
        setPlaceholder(dashboardSize, on: button)          // widen if needed
        // LED style: the dot board. Standard style: plain type on the menu bar, like the dashboard.
        boardLayer.contents = isLED ? boardImage(width: placeholderSize.width) : nil
        boardLayer.isHidden = !isLED
        contentLayer.isHidden = true
        characterLayer.isHidden = true
        announceClip.isHidden = false
        positionCharacter()

        // Heading, like a station board: "◆ GITHUB ◆" (blinks for urgent messages).
        let accent = settings.boardNSColor
        guard settings.showHeading || msg.urgent else { scroll(msg); return }
        let heading = msg.urgent ? "◆ \(msg.source.tag) ◆" : msg.source.tag
        announceText.removeAllAnimations()
        announceText.contents = isLED
            ? LEDRenderer.staticStrip(for: heading, accent: accent, boardWidth: placeholderSize.width)
            : TextStrip.heading(tag: msg.source.label, urgent: msg.urgent, width: placeholderSize.width,
                                style: textStyle(button))
        announceText.bounds = CGRect(x: 0, y: 0, width: placeholderSize.width, height: announceClip.bounds.height)
        announceText.position = .zero
        announceClip.removeAnimation(forKey: "blink")
        var headingDuration: TimeInterval = 1.0
        if msg.urgent && settings.urgentBlink && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 0.1, 1, 0.1, 1, 0.1, 1]
            blink.calculationMode = .discrete
            blink.duration = 1.6
            announceClip.add(blink, forKey: "blink")
            headingDuration = 1.8
        }
        let t = Timer(timeInterval: headingDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scroll(msg) }
        }
        RunLoop.main.add(t, forMode: .common)
        announceTimer = t
    }

    /// Type style for the standard look, matched to the menu bar's light / dark appearance.
    private func textStyle(_ button: NSStatusBarButton) -> TextStrip.Style {
        TextStrip.Style(height: max(16, announceClip.bounds.height), appearance: button.effectiveAppearance,
                        accent: settings.accent.nsColor, pixelScale: button.window?.backingScaleFactor ?? 2)
    }

    private func scroll(_ msg: TickerMessage) {
        guard announcing?.id == msg.id else { return }
        let width = placeholderSize.width
        if !isLED, let button = item.button {
            // Standard style: the same message in system type, gliding smoothly.
            let strip = TextStrip.message(tag: msg.source.label, title: msg.title, body: msg.body,
                                          urgent: msg.urgent, style: textStyle(button))
            announceText.removeAllAnimations()
            announceText.contents = strip.image
            announceText.bounds = CGRect(x: 0, y: 0, width: strip.width, height: announceClip.bounds.height)
            let anim = CABasicAnimation(keyPath: "position.x")
            anim.fromValue = width
            anim.toValue = -strip.width
            anim.duration = Double(width + strip.width) / settings.tickerSpeed
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            anim.delegate = self
            announceText.position = CGPoint(x: -strip.width, y: 0)
            announceText.add(anim, forKey: "scroll")
            return
        }
        let strip = LEDRenderer.strip(for: msg.title + (msg.body.map { " — \($0)" } ?? ""),
                                      accent: settings.boardNSColor)
        announceText.removeAllAnimations()
        announceText.contents = strip.image
        announceText.bounds = CGRect(x: 0, y: 0, width: strip.width, height: LEDRenderer.boardHeight)
        let pitch = LEDRenderer.pitch
        let start = (width / pitch).rounded(.down) * pitch
        let end = -strip.width
        let steps = max(2, Int((start - end) / pitch))
        let anim = CAKeyframeAnimation(keyPath: "position.x")
        anim.values = (0...steps).map { NSNumber(value: Double(start - CGFloat($0) * pitch)) }
        anim.calculationMode = .discrete
        anim.duration = Double(start - end) / settings.tickerSpeed
        anim.delegate = self
        announceText.position = CGPoint(x: end, y: 0)
        announceText.add(anim, forKey: "scroll")
    }

    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        MainActor.assumeIsolated {
            guard flag, let msg = announcing else { return }
            passesLeft -= 1
            if passesLeft > 0 {
                scroll(msg)
            } else {
                playNextAnnouncement()
            }
        }
    }

    private func endAnnouncement() {
        announcing = nil
        fullBar.stop()
        announceTimer?.invalidate()
        announceText.removeAllAnimations()
        announceClip.removeAllAnimations()
        announceClip.isHidden = true
        guard let button = item.button else { return }
        setPlaceholder(dashboardSize, on: button)
        boardLayer.isHidden = !isLED
        if isLED { boardLayer.contents = boardImage(width: placeholderSize.width) }
        contentLayer.isHidden = !fullFrames.isEmpty
        characterLayer.isHidden = characterFrames.isEmpty
        positionCharacter()
    }

    // MARK: - Click handling / panel

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            StatusMenu.show(on: item, extra: announcementMenuItems() + (Features.sleepPrevention ? awakeMenuItems() : []))
            return
        }
        if Features.sleepPrevention, event?.modifierFlags.contains(.option) == true {
            awake.toggle()
            return
        }
        let tab = (settings.openTabAtClick || announcing != nil) ? tabForClick(event) : nil
        if let popover, popover.isShown {
            // Clicking another part switches tabs; the same part closes the panel.
            if let tab, tab != panelState.tab {
                panelState.tab = tab
            } else {
                popover.performClose(nil)
            }
            return
        }
        if let tab { panelState.tab = tab }
        panelState.selectedApp = nil
        showPanel()
    }

    /// Maps the click position to the part of the icon under it.
    private func tabForClick(_ event: NSEvent?) -> PanelTab? {
        if announcing != nil { return .today }
        guard let button = item.button, let image = button.image else { return nil }
        let originX = ((button.bounds.width - image.size.width) / 2).rounded()
        let width = button.bounds.width

        // Candidates for where the click landed, most reliable first.
        // On macOS 27 the click events forwarded by MenuBarAgent always carry the item's
        // centre (seen in clicks.log: every click at x = width/2), so the pointer's real
        // screen position comes first and event positions at the exact centre are ignored.
        var candidates: [(String, CGFloat)] = []
        if let w = button.window {
            let screenFrame = w.convertToScreen(button.convert(button.bounds, to: nil))
            candidates.append(("screen", NSEvent.mouseLocation.x - screenFrame.minX))
        }
        let centre = width / 2
        if let x = lastPressX, abs(x - centre) > 1 { candidates.append(("mouseDown", x)) }
        if let event, event.window === button.window {
            let x = button.convert(event.locationInWindow, from: nil).x
            if abs(x - centre) > 1 { candidates.append(("event", x)) }
        }
        lastPressX = nil

        let chosen = candidates.first { $0.1 >= 0 && $0.1 <= width }
        // Exact hit, or else the nearest part (clicks in the gaps between parts count too).
        let region: IconRegion? = chosen.flatMap { c in
            let x = c.1 - originX
            if let hit = regions.first(where: { $0.1.contains(x) }) { return hit.0 }
            return regions.min(by: { distance($0.1, x) < distance($1.1, x) })?.0
        }
        logClick(candidates: candidates, chosen: chosen?.0, originX: originX, width: width, region: region)
        guard let region else { return nil }
        switch region {
        case .character, .cpu: return .cpu
        case .memory: return .memory
        case .network: return .network
        case .ai: return .ai
        }
    }

    private func distance(_ r: ClosedRange<CGFloat>, _ x: CGFloat) -> CGFloat {
        x < r.lowerBound ? r.lowerBound - x : max(0, x - r.upperBound)
    }

    /// Last clicks, for diagnosing position problems: ~/Library/Logs/Denko/clicks.log
    private func logClick(candidates: [(String, CGFloat)], chosen: String?, originX: CGFloat,
                          width: CGFloat, region: IconRegion?) {
        #if !DEBUG
        return
        #endif
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Denko")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("clicks.log")
        let regionsText = regions.map { "\($0.0)=\(Int($0.1.lowerBound))-\(Int($0.1.upperBound))" }.joined(separator: " ")
        let line = "\(Date()) cand=\(candidates.map { "\($0.0):\(Int($0.1))" }) chosen=\(chosen ?? "none") "
            + "origin=\(Int(originX)) width=\(Int(width)) region=\(region.map { "\($0)" } ?? "none") [\(regionsText)]\n"
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").suffix(30).map(String.init)
        lines.append(line.trimmingCharacters(in: .newlines))
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func awakeMenuItems() -> [NSMenuItem] {
        var items = [NSMenuItem.sectionHeader(title: "スリープ防止")]
        if awake.isActive {
            let status = NSMenuItem(title: awake.remainingText(), action: nil, keyEquivalent: "")
            status.isEnabled = false
            items.append(status)
        }
        let off = NSMenuItem(title: "オフ", action: #selector(awakeOff), keyEquivalent: "")
        off.target = self
        off.state = awake.isActive ? .off : .on
        items.append(off)
        for minutes in SleepPreventer.durations {
            let mi = NSMenuItem(title: SleepPreventer.label(minutes: minutes),
                                action: #selector(awakeFor(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = minutes
            items.append(mi)
        }
        return items
    }

    @objc private func awakeOff() { awake.stop() }
    @objc private func awakeFor(_ sender: NSMenuItem) { awake.start(minutes: sender.tag) }

    func showPanel() {
        guard let button = item.button else { return }
        if let popover, popover.isShown { return }
        let host = NSHostingController(rootView: MainPanel(state: panelState, ai: ai, monitor: monitor, apps: apps,
                                                           awake: awake, settings: settings,
                                                           storage: AppDelegate.shared.storage))
        host.sizingOptions = .preferredContentSize
        let p = NSPopover()
        p.contentViewController = host
        // Test mode keeps it open while another app drives it.
        p.behavior = TestMode.isActive ? .applicationDefined : .transient
        p.animates = true
        p.delegate = self
        popover = p
        monitor.setDetailed(true)
        updateSampling()
        // Lay the content out and size the popover before it appears, instead of letting it
        // start at 0×0 and resize once SwiftUI reports its size.
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        host.view.setFrameSize(size)
        p.contentSize = size
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        host.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        // Drop the SwiftUI view graph so it stops observing while hidden.
        popover?.contentViewController = nil
        popover = nil
        monitor.setDetailed(false)
        updateSampling()
    }
}
