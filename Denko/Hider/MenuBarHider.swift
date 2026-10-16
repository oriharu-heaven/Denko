import AppKit
import Combine

/// Ice / Hidden Bar style menu bar organizer.
///
/// Layout (left → right):  [always-hidden items] ┆ [hidden items] ┊ ‹ [visible items]
/// Collapsing a section stretches its divider to a huge width so everything to its left
/// is pushed off-screen. Items are placed either by the user's ⌘-drag or automatically
/// from the per-item rules in Settings (simulated ⌘-drag, needs Accessibility).
@MainActor
final class MenuBarHider: NSResponder, ObservableObject {
    private static let legacyCollapsedLength: CGFloat = 10_000
    /// From macOS 26 the menu bar is drawn by MenuBarAgent and overflows into its own «»» menu:
    /// a huge divider just becomes empty space that eats the app menus, and window frames
    /// no longer tell where items are. There we only collapse with Accessibility (exact
    /// positions) and stretch exactly up to the app menus, never past them.
    static let isModernMenuBar = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    /// macOS 27 (Golden Gate) folds menu bar items behind its own « control and draws the
    /// whole bar in MenuBarAgent, so a stretched divider can't hide anything any more.
    /// There the built-in feature is used instead and this hider isn't created at all.
    static let hasBuiltInHiding = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))

    @Published private(set) var items: [MenuBarItemInfo] = []
    @Published private(set) var isArranging = false
    @Published private(set) var isTrusted = MenuBarItems.isTrusted

    private let settings: AppSettings
    private let toggle: NSStatusItem
    private let divider: NSStatusItem
    private let alwaysDivider: NSStatusItem

    private(set) var isHiddenSectionShown = false
    private(set) var isAlwaysHiddenSectionShown = false
    private var rehideTimer: Timer?
    private var hoverTimer: Timer?
    private var bag = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        let bar = NSStatusBar.system
        toggle = bar.statusItem(withLength: NSStatusItem.variableLength)
        divider = bar.statusItem(withLength: NSStatusItem.variableLength)
        alwaysDivider = bar.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = "hider-toggle"
        divider.autosaveName = "hider-divider"
        alwaysDivider.autosaveName = "hider-always-divider"
        super.init()

        for s in [toggle, divider, alwaysDivider] {
            s.button?.target = self
            s.button?.action = #selector(toggleClicked)
            s.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        toggle.button?.setAccessibilityIdentifier("cuob-toggle")
        divider.button?.setAccessibilityIdentifier("cuob-divider")
        alwaysDivider.button?.setAccessibilityIdentifier("cuob-always")
        toggle.button?.toolTip = "クリックで隠した項目を表示（⌥クリックで「常に隠す」も）"
        if let b = toggle.button {
            b.addTrackingArea(NSTrackingArea(rect: .zero,
                                             options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                             owner: self, userInfo: nil))
        }

        settings.$hiderEnabled
            .combineLatest(settings.$alwaysHiddenEnabled)
            .sink { [weak self] enabled, always in
                DispatchQueue.main.async { self?.applyEnabled(enabled, always: always) }
            }
            .store(in: &bag)

        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                guard let self, self.settings.hiderEnabled, !self.isArranging else { return }
                if self.settings.rehideOnAppSwitch, self.isHiddenSectionShown {
                    self.collapse()
                } else if !self.isHiddenSectionShown, Self.isModernMenuBar {
                    // Each app has a different menu width: re-fit so menus are never covered.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.render() }
                }
            }
            .store(in: &bag)
        ws.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .sink { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let pid = app?.processIdentifier else { return }
                // Give the app time to create its status item.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    Task { await self?.enforceRules(forPID: pid) }
                }
            }
            .store(in: &bag)

        // Wait for the status bar to lay the items out before checking their order.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.settings.hiderEnabled else { return }
            self.collapse()
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Enable / disable

    private func applyEnabled(_ enabled: Bool, always: Bool) {
        toggle.isVisible = enabled
        divider.isVisible = enabled
        alwaysDivider.isVisible = enabled && always && !Self.isModernMenuBar
        if !always { isAlwaysHiddenSectionShown = false }
        if enabled { render() }
    }

    // MARK: - Interaction

    @objc private func toggleClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            let item = NSMenuItem(title: isHiddenSectionShown ? "隠す" : "隠した項目を表示",
                                  action: #selector(toggleFromMenu), keyEquivalent: "")
            item.target = self
            StatusMenu.show(on: toggle, extra: [item])
            return
        }
        if event?.modifierFlags.contains(.option) == true, settings.alwaysHiddenEnabled {
            isAlwaysHiddenSectionShown ? collapse() : expand(includingAlwaysHidden: true)
        } else {
            isHiddenSectionShown ? collapse() : expand(includingAlwaysHidden: false)
        }
    }

    @objc private func toggleFromMenu() {
        isHiddenSectionShown ? collapse() : expand(includingAlwaysHidden: false)
    }

    override func mouseEntered(with event: NSEvent) {
        guard settings.showOnHover, !isHiddenSectionShown else { return }
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expand(includingAlwaysHidden: false) }
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
    }

    // MARK: - Expand / collapse

    func expand(includingAlwaysHidden: Bool) {
        isHiddenSectionShown = true
        isAlwaysHiddenSectionShown = includingAlwaysHidden && settings.alwaysHiddenEnabled
        render()
        scheduleRehide()
    }

    func collapse() {
        rehideTimer?.invalidate()
        if Self.isModernMenuBar && !MenuBarItems.isTrusted {
            // Without exact positions, collapsing is unsafe: stay expanded.
            isTrusted = false
            isHiddenSectionShown = true
            isAlwaysHiddenSectionShown = true
            render()
            return
        }
        // Safety: never collapse if a divider ended up to the right of the toggle,
        // otherwise the toggle itself (and everything else) would be pushed off-screen.
        guard isOrderValid() else {
            isHiddenSectionShown = true
            isAlwaysHiddenSectionShown = settings.alwaysHiddenEnabled
            render()
            return
        }
        isHiddenSectionShown = false
        isAlwaysHiddenSectionShown = false
        render()
    }

    private func scheduleRehide() {
        rehideTimer?.invalidate()
        guard settings.autoRehide, !isArranging else { return }
        rehideTimer = Timer.scheduledTimer(withTimeInterval: settings.autoRehideSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Wait while the user is ⌘-dragging, a mouse button is down, or the pointer is in the menu bar.
                if NSEvent.pressedMouseButtons != 0 || NSEvent.modifierFlags.contains(.command) || self.pointerInMenuBar() {
                    self.scheduleRehide()
                } else {
                    self.collapse()
                }
            }
        }
        rehideTimer?.tolerance = 0.5
    }

    private func pointerInMenuBar() -> Bool {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) else { return false }
        let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return p.y >= screen.frame.maxY - max(barHeight, 24)
    }

    /// Frames of our control items in global top-left coordinates.
    /// Prefers Accessibility (correct on macOS 27, where the menu bar is drawn by MenuBarAgent);
    /// falls back to the button windows. Only x is compared, which both sources agree on.
    private func controlFrames() -> (toggle: CGRect?, divider: CGRect?, always: CGRect?) {
        let ax = MenuBarItems.isTrusted ? MenuBarItems.ownItemFrames() : [:]
        func frame(_ item: NSStatusItem, _ ident: String) -> CGRect? {
            guard item.isVisible else { return nil }
            if Self.isModernMenuBar { return ax[ident] }
            return ax[ident] ?? item.button?.window?.frame
        }
        return (frame(toggle, "cuob-toggle"), frame(divider, "cuob-divider"), frame(alwaysDivider, "cuob-always"))
    }

    private func isOrderValid() -> Bool {
        let f = controlFrames()
        guard let t = f.toggle, let d = f.divider else { return false }
        guard d.maxX <= t.minX + 1 else { return false }
        if let a = f.always { return a.maxX <= d.minX + 1 }
        return true
    }

    // MARK: - Item list & rules

    /// Re-scans other apps' menu bar items and classifies them by section.
    func refreshItems(pids: Set<pid_t>? = nil) {
        isTrusted = MenuBarItems.isTrusted
        let f = controlFrames()
        let dividerX = f.divider?.minX
        let alwaysX = f.always?.minX
        items = MenuBarItems.scan(pids: pids).map { item in
            var item = item
            let mid = item.frame.midX
            if let alwaysX, mid < alwaysX {
                item.section = .alwaysHidden
            } else if let dividerX, mid < dividerX {
                item.section = .hidden
            } else {
                item.section = .visible
            }
            return item
        }
    }

    func requestAccessibility() {
        MenuBarItems.requestTrust()
    }

    /// User picked a section for one item in Settings: remember it and move the item now.
    func setSection(_ section: ItemSection, for item: MenuBarItemInfo) {
        settings.itemRules[item.key] = section
        Task { await arrange([(item.key, section)]) }
    }

    /// Moves every item whose rule differs from where it currently is.
    func applyAllRules() async {
        refreshItems()
        let moves = items.compactMap { item -> (String, ItemSection)? in
            guard let want = settings.itemRules[item.key], want != item.section else { return nil }
            return (item.key, want)
        }
        await arrange(moves)
    }

    /// Called shortly after an app launches: put its items where the rules (or the
    /// "new item" default) say they belong.
    private func enforceRules(forPID pid: pid_t) async {
        guard settings.hiderEnabled, settings.autoArrange, MenuBarItems.isTrusted, !isArranging else { return }
        refreshItems(pids: [pid])
        var moves: [(String, ItemSection)] = []
        for item in items where item.pid == pid {
            let want = settings.itemRules[item.key] ?? settings.newItemSection
            if settings.itemRules[item.key] == nil { settings.itemRules[item.key] = want }
            if want != item.section { moves.append((item.key, want)) }
        }
        await arrange(moves)
    }

    private func arrange(_ moves: [(String, ItemSection)]) async {
        guard settings.hiderEnabled, !moves.isEmpty, !isArranging else { return }
        guard MenuBarItems.isTrusted else {
            isTrusted = false
            requestAccessibility()
            return
        }
        isArranging = true
        let restoreHidden = isHiddenSectionShown, restoreAlways = isAlwaysHiddenSectionShown
        rehideTimer?.invalidate()

        // Bring everything on screen so the items can be dragged.
        isHiddenSectionShown = true
        isAlwaysHiddenSectionShown = settings.alwaysHiddenEnabled
        render()
        try? await Task.sleep(nanoseconds: 400_000_000)

        for (key, target) in moves {
            refreshItems()
            guard let item = items.first(where: { $0.key == key }),
                  item.section != target,
                  let targetX = dropX(for: target, from: item.section)
            else { continue }
            let y = item.frame.midY
            await MenuBarItems.commandDrag(from: CGPoint(x: item.frame.midX, y: y),
                                           to: CGPoint(x: targetX, y: y))
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        refreshItems()
        isArranging = false
        if restoreHidden {
            isAlwaysHiddenSectionShown = restoreAlways
            render()
            scheduleRehide()
        } else {
            collapse()
        }
    }

    /// Where to drop an item so the menu bar inserts it into `section`.
    /// The bar reorders once the dragged item passes a neighbour's midpoint, so we
    /// aim just past the relevant control item.
    private func dropX(for section: ItemSection, from current: ItemSection) -> CGFloat? {
        let f = controlFrames()
        guard let t = f.toggle, let d = f.divider else { return nil }
        let a = f.always
        switch section {
        case .visible:
            return t.maxX - 2
        case .hidden:
            if current == .alwaysHidden, let a { return a.maxX - 2 }
            return d.minX + 2
        case .alwaysHidden:
            guard let a else { return nil }
            return a.minX + 2
        }
    }

    // MARK: - Drawing

    private func render() {
        toggle.button?.image = symbol(isHiddenSectionShown ? "chevron.compact.right" : "chevron.compact.left")
        configure(divider, collapsed: !isHiddenSectionShown)
        configure(alwaysDivider, collapsed: !isAlwaysHiddenSectionShown)
    }

    /// How far to stretch a collapsed divider.
    private func collapsedLength(for item: NSStatusItem, ident: String) -> CGFloat {
        guard Self.isModernMenuBar else { return Self.legacyCollapsedLength }
        guard let frame = MenuBarItems.ownItemFrames()[ident],
              let menusEnd = MenuBarItems.appMenusMaxX()
        else { return item.length > 0 ? item.length : 1 }
        // The divider is anchored at its right edge; reach left to just past the app menus.
        return max(1, frame.maxX - menusEnd - 8)
    }

    private func configure(_ item: NSStatusItem, collapsed: Bool) {
        if collapsed {
            item.button?.image = nil
            item.length = collapsedLength(for: item, ident: item === divider ? "cuob-divider" : "cuob-always")
        } else {
            item.length = NSStatusItem.variableLength
            item.button?.image = dividerImage(dashed: item === alwaysDivider)
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "隠した項目")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        img?.isTemplate = true
        return img
    }

    private func dividerImage(dashed: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 6, height: 16), flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.45).setStroke()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: rect.midX, y: 1))
            p.line(to: NSPoint(x: rect.midX, y: rect.height - 1))
            p.lineWidth = 1.5
            if dashed { p.setLineDash([2, 2], count: 2, phase: 0) }
            p.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}
