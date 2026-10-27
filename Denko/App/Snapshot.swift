import AppKit
import Intents
import SwiftUI

/// Development aid: `DENKO_SNAPSHOT=<folder> Denko` renders the settings panes, the panel's
/// tabs and はじめに to PNGs (light and dark) with live data, then quits. Nothing else starts
/// (no menu bar item, no local server, no account reads).
@MainActor
enum Snapshot {
    nonisolated static var isActive: Bool { ProcessInfo.processInfo.environment["DENKO_SNAPSHOT"] != nil }
    private static var folder: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["DENKO_SNAPSHOT"] ?? NSTemporaryDirectory())
    }
    /// Comma-separated subset, e.g. DENKO_SNAPSHOT_ONLY=panel-today,settings-board
    private static var only: Set<String>? {
        ProcessInfo.processInfo.environment["DENKO_SNAPSHOT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    }

    static func run(_ app: AppDelegate) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app.hub.settings = app.settings
        // Some sample notices so the history looks like real use.
        app.hub.post(.claudeCode, kind: .claudeDone, title: "応答が完了しました（Denko）", force: .normal)
        app.hub.post(.train, kind: .trainDelay, title: "中央線快速電車 遅延", body: "人身事故の影響", force: .normal)
        // Live sampling, as when the panel is open, so the app lists are real.
        app.system.setIntervals(menuBar: 1, panel: 1)
        app.system.setDetailed(true)
        app.appUsage.configure(menuBar: true, menuBarNetwork: true, detailed: true, menuBarInterval: 2, panelInterval: 1)
        Task {
            await app.info.refreshAll()
            await app.info.refreshTrains(everything: true)
            try? await Task.sleep(for: .seconds(9))
            writeStatus(app)
            renderMenuBar(app)
            render(app)
            renderCharacters(app)
            NSApp.terminate(nil)
        }
    }

    private static func render(_ app: AppDelegate) {
        let s = app.settings
        let state = PanelState()
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let settingsPanes: [(String, AnyView, CGFloat)] = [
                ("settings-setup", AnyView(SetupPane(settings: s)), 780),
                ("settings-experimental", AnyView(ExperimentalPane(settings: s)), 780),
                ("settings-general", AnyView(GeneralPane(settings: s)), 780),
                ("settings-board", AnyView(BoardLookPane(settings: s)), 780),
                ("settings-notices", AnyView(NoticesPane(settings: s)), 780),
                ("settings-dashboard", AnyView(MenuBarPane(settings: s)), 780),
                ("settings-info", AnyView(InfoHubPane(settings: s)), 780),
                ("settings-info-news", AnyView(InfoHubPane(settings: s, detail: .news)), 780),
                ("settings-info-trains", AnyView(InfoHubPane(settings: s, detail: .trains)), 780),
                ("settings-info-weather", AnyView(InfoHubPane(settings: s, detail: .weather)), 780),
                ("settings-info-ai", AnyView(InfoHubPane(settings: s, detail: .aiUsage)), 780),
                // DENKO_SNAPSHOT_SEARCH: what a user would type into the line search.
                ("settings-info-trains-search", AnyView(InfoHubPane(settings: s, detail: .trains,
                    search: ProcessInfo.processInfo.environment["DENKO_SNAPSHOT_SEARCH"] ?? "")), 780),
            ]
            for (name, view, height) in settingsPanes {
                save(AnyView(Tinted(settings: s, content: view.frame(width: 520, height: height))), name, suffix, scheme)
            }
            for tab in PanelTab.allCases {
                state.tab = tab
                let panel = MainPanel(state: state, ai: app.ai, monitor: app.system, apps: app.appUsage,
                                      awake: app.awake, settings: s, storage: app.storage)
                save(AnyView(panel), "panel-\(tab.rawValue)", suffix, scheme)
            }
            save(AnyView(OnboardingView(settings: s) { _ in }), "onboarding", suffix, scheme)
        }
    }

    /// Every character's animation frames as LED dots, one row per character.
    static func renderCharacters(_ app: AppDelegate) {
        if let only, !only.contains("characters") { return }
        LEDRenderer.configure(height: 22)
        let s = app.settings
        var rowsOut: [[CGImage]] = []
        let saved = IconRenderer.character
        for kind in CharacterKind.allCases {
            IconRenderer.character = kind
            let content = IconContent(showCharacter: true, cpu: nil, memory: nil, network: nil, showNumbers: false,
                                      colorIcons: false, numbers: s.claudeNumbers, accent: s.accent, awake: false,
                                      character: kind)
            rowsOut.append(LEDDashboard.render(content, accent: s.boardNSColor).frogFrames)
        }
        IconRenderer.character = saved
        let cell = NSSize(width: 18 * LEDRenderer.pitch * 6, height: LEDRenderer.boardHeight * 6)
        let frames = rowsOut.map(\.count).max() ?? 0
        let size = NSSize(width: cell.width * CGFloat(frames) + 20, height: (cell.height + 10) * CGFloat(rowsOut.count) + 10)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.black.setFill(); NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        for (r, row) in rowsOut.enumerated() {
            for (f, frame) in row.enumerated() {
                let rect = NSRect(x: 10 + CGFloat(f) * cell.width, y: size.height - CGFloat(r + 1) * (cell.height + 10),
                                  width: cell.width, height: cell.height)
                NSGraphicsContext.current?.cgContext.draw(frame, in: rect)
            }
        }
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent("characters.png"))
        }
    }

    /// Facts that can't be seen in a picture (permissions etc.).
    private static func writeStatus(_ app: AppDelegate) {
        if let only, !only.contains("status") { return }
        let focus: String
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: focus = "authorized"
        case .denied: focus = "denied"
        case .restricted: focus = "restricted"
        case .notDetermined: focus = "notDetermined"
        @unknown default: focus = "unknown"
        }
        let text = """
        focusAuthorization=\(focus)
        focused=\(FocusWatcher.isFocused)
        topCPU=\(app.appUsage.topCPU.prefix(4).map { "\($0.name) \(String(format: "%.1f", $0.cpu))%" })
        topMemory=\(app.appUsage.topMemory.prefix(4).map { "\($0.name) \(ByteText.size(Int64($0.memory)))" })
        cpu=\(app.system.cpu) memory=\(app.system.memoryPercent)
        trains=\(Dictionary(grouping: app.info.allTrainLines, by: \.region).map { "\($0.key):\($0.value.count)" }.sorted())
        companies=\(Set(app.info.allTrainLines.map(\.company)).sorted())
        troubles=\(app.info.allTrainLines.filter(\.isTrouble).prefix(8).map { "\($0.company) \($0.name) \($0.status)" })
        """
        try? text.write(to: folder.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
    }

    /// The menu bar item as it is drawn in each style and with each character, plus the
    /// announcement boards, on a strip that looks like the menu bar.
    private static func renderMenuBar(_ app: AppDelegate) {
        if let only, !only.contains("menubar") { return }
        let s = app.settings
        LEDRenderer.configure(height: 22)
        LEDRenderer.apply(dotSize: s.dotSize, square: s.dotShape == .square, unlit: s.unlitDots, base: s.boardBaseColor, weight: s.boardWeight)
        let saved = IconRenderer.character
        var strips: [(String, NSImage)] = []
        func content(_ kind: CharacterKind) -> IconContent {
            IconContent(showCharacter: true,
                        cpu: Gauge(percent: Int(app.system.cpu.rounded()), app: app.appUsage.topCPU.first?.id),
                        memory: Gauge(percent: Int(app.system.memoryPercent.rounded()), app: app.appUsage.topMemory.first?.id),
                        network: NetGauge(up: ByteText.compactRate(app.system.netUp), down: ByteText.compactRate(app.system.netDown),
                                          app: nil),
                        showNumbers: s.gaugeNumbers, gaugeStyle: s.gaugeStyle, colorIcons: false,
                        numbers: s.claudeNumbers, accent: s.accent, awake: false, character: kind)
        }
        for kind in CharacterKind.allCases {
            IconRenderer.character = kind
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let r = IconRenderer.render(content(kind), appearance: appearance, compatible: true,
                                            icon: { NSWorkspace.shared.icon(forFile: $0) })
                strips.append(("標準・\(kind.label)・\(dark ? "ダーク" : "ライト")", r.fullFrames.first ?? r.base))
            }
            let o = LEDDashboard.render(content(kind), accent: s.boardNSColor)
            let size = NSSize(width: o.width, height: LEDRenderer.boardHeight)
            let board = LEDRenderer.board(width: o.width, accent: s.boardNSColor)
            let img = NSImage(size: size)
            img.lockFocus()
            board.draw(in: NSRect(origin: .zero, size: size))
            if let ctx = NSGraphicsContext.current?.cgContext {
                if let c = o.content { ctx.draw(c, in: NSRect(origin: .zero, size: size)) }
                if let f = o.frogFrames.first { ctx.draw(f, in: o.frogRect) }
            }
            img.unlockFocus()
            strips.append(("電光掲示板・\(kind.label)", img))
        }
        IconRenderer.character = saved

        // An announcement on the item: heading, then the text mid-scroll.
        let width: CGFloat = 160
        for (label, text) in [("お知らせ（見出し）", "◆ 運行情報 ◆"), ("お知らせ（本文）", "中央線快速電車 遅延　人身事故の影響")] {
            let img = NSImage(size: NSSize(width: width, height: LEDRenderer.boardHeight))
            img.lockFocus()
            LEDRenderer.board(width: width, accent: s.boardNSColor).draw(in: NSRect(x: 0, y: 0, width: width, height: LEDRenderer.boardHeight))
            if let strip = LEDRenderer.staticStrip(for: text, accent: s.boardNSColor, boardWidth: width) {
                NSGraphicsContext.current?.cgContext.draw(strip, in: NSRect(x: 0, y: 0, width: width, height: LEDRenderer.boardHeight))
            }
            img.unlockFocus()
            strips.append((label, img))
        }

        // Standard style: the same notices in system type (light / dark menu bar).
        for dark in [false, true] {
            let ap = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let st = TextStrip.Style(height: 22, appearance: ap, accent: s.accent.nsColor)
            let suffix = dark ? "ダーク" : "ライト"
            for (label, urgent) in [("見出し", false), ("緊急の見出し", true)] {
                if let cg = TextStrip.heading(tag: "運行情報", urgent: urgent, width: 220, style: st) {
                    strips.append(("標準・\(label)・\(suffix)", NSImage(cgImage: cg, size: NSSize(width: 220, height: 22))))
                }
            }
            let m = TextStrip.message(tag: "運行情報", title: "中央線快速電車 遅延", body: "人身事故の影響",
                                      urgent: true, style: st)
            if let cg = m.image { strips.append(("標準・本文・\(suffix)", NSImage(cgImage: cg, size: NSSize(width: m.width, height: 22)))) }
        }

        // Compose: each strip on a menu-bar-like background, 4× for legibility.
        let scale: CGFloat = 4, rowH: CGFloat = 24 * scale, gap: CGFloat = 18
        let maxW = (strips.map(\.1.size.width).max() ?? 100) * scale + 260
        let total = NSSize(width: maxW, height: CGFloat(strips.count) * (rowH + gap) + gap)
        let out = NSImage(size: total)
        out.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill(); NSRect(origin: .zero, size: total).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        for (i, (label, img)) in strips.enumerated() {
            let y = total.height - CGFloat(i + 1) * (rowH + gap)
            let dark = label.contains("ダーク") || ((label.contains("電光") || label.contains("お知らせ")) && !label.contains("ライト"))
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(x: 240, y: y, width: maxW - 250, height: rowH).fill()
            let w = img.size.width * scale, h = img.size.height * scale
            img.draw(in: NSRect(x: 250, y: y + (rowH - h) / 2, width: w, height: h))
            (label as NSString).draw(at: NSPoint(x: 10, y: y + rowH / 2 - 10),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.white])
        }
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent("menubar.png"))
        }
    }

    private static func save(_ view: AnyView, _ name: String, _ suffix: String, _ scheme: ColorScheme) {
        if let only, !only.contains(name) { return }
        let bg = scheme == .dark ? Color(white: 0.16) : Color(white: 0.96)
        let host = NSHostingView(rootView: view.background(bg).environment(\.colorScheme, scheme))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.backgroundColor = scheme == .dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        // Paint the window background under the (transparent) view.
        let out = NSImage(size: size)
        out.lockFocus()
        window.backgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: .zero, size: size))
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}
