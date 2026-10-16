import AppKit
import ApplicationServices

/// A menu bar item (status item / menu extra) of some app.
///
/// macOS 27 draws the whole menu bar in MenuBarAgent, so items are no longer
/// per-app windows; they are discovered through each app's `AXExtrasMenuBar`
/// (requires Accessibility). Older systems fall back to the window list.
struct MenuBarItemInfo: Identifiable, Equatable {
    let pid: pid_t
    let ownerName: String
    /// AXTitle / AXDescription / window title, whatever the system exposes.
    let title: String?
    /// AXIdentifier, e.g. "com.apple.menuextra.wifi" — the most stable handle when present.
    let identifier: String?
    let bundleID: String?
    /// Global coordinates, top-left origin.
    let frame: CGRect
    /// Stable identifier used for rules.
    var key: String = ""
    var section: ItemSection = .visible

    var id: String { "\(pid)|\(key)" }

    var displayName: String {
        if let title, !title.isEmpty, title != ownerName { return "\(ownerName) – \(title)" }
        return ownerName
    }

    var icon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }
}

enum MenuBarItems {
    /// Menu bar items of other apps (or only `pids`), sorted left → right.
    static func scan(pids: Set<pid_t>? = nil) -> [MenuBarItemInfo] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var items = axScan(pids: pids).filter { $0.pid != ownPID }
        if items.isEmpty && !isTrusted {
            items = windowScan().filter { $0.pid != ownPID && (pids?.contains($0.pid) ?? true) }
        }
        items.sort { $0.frame.minX < $1.frame.minX }

        // Keys: identifier if any, else title, else ordinal within the app.
        var seen: [String: Int] = [:]
        for i in items.indices {
            let base = items[i].bundleID ?? items[i].ownerName
            if let ident = items[i].identifier, !ident.isEmpty {
                items[i].key = "\(base)|id:\(ident)"
            } else if let t = items[i].title, !t.isEmpty {
                items[i].key = "\(base)|\(t)"
            } else {
                let n = seen[base, default: 0]
                seen[base] = n + 1
                items[i].key = n == 0 ? base : "\(base)#\(n + 1)"
            }
        }
        return items
    }

    /// Frames of this app's own status items, keyed by accessibility identifier.
    static func ownItemFrames() -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        let pid = ProcessInfo.processInfo.processIdentifier
        for item in axItems(of: pid, ownerName: "", bundleID: nil) {
            if let ident = item.identifier { out[ident] = item.frame }
        }
        return out
    }

    /// Right edge of the menus of the app that currently owns the menu bar (global x).
    /// The hider never stretches past this, so app menus are never covered.
    static func appMenusMaxX() -> CGFloat? {
        guard isTrusted, let app = NSWorkspace.shared.menuBarOwningApplication else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.15)
        guard let bar: AXUIElement = attribute(el, kAXMenuBarAttribute),
              let menus: [AXUIElement] = attribute(bar, kAXChildrenAttribute)
        else { return nil }
        var maxX: CGFloat = 0
        for m in menus {
            guard let pv: AXValue = attribute(m, kAXPositionAttribute),
                  let sv: AXValue = attribute(m, kAXSizeAttribute) else { continue }
            var p = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(pv, .cgPoint, &p)
            AXValueGetValue(sv, .cgSize, &sz)
            maxX = max(maxX, p.x + sz.width)
        }
        return maxX > 0 ? maxX : nil
    }

    // MARK: Accessibility enumeration

    private static func axScan(pids: Set<pid_t>?) -> [MenuBarItemInfo] {
        guard isTrusted else { return [] }
        var out: [MenuBarItemInfo] = []
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            if let pids, !pids.contains(pid) { continue }
            out += axItems(of: pid, ownerName: app.localizedName ?? "?", bundleID: app.bundleIdentifier)
        }
        return out
    }

    private static func axItems(of pid: pid_t, ownerName: String, bundleID: String?) -> [MenuBarItemInfo] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)   // don't hang on unresponsive apps
        guard let bar: AXUIElement = attribute(app, "AXExtrasMenuBar"),
              let children: [AXUIElement] = attribute(bar, kAXChildrenAttribute)
        else { return [] }
        return children.compactMap { el in
            guard let posValue: AXValue = attribute(el, kAXPositionAttribute),
                  let sizeValue: AXValue = attribute(el, kAXSizeAttribute)
            else { return nil }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(posValue, .cgPoint, &p)
            AXValueGetValue(sizeValue, .cgSize, &s)
            guard s.width > 1 else { return nil }
            let title: String? = attribute(el, kAXTitleAttribute) ?? attribute(el, kAXDescriptionAttribute)
            return MenuBarItemInfo(pid: pid, ownerName: ownerName, title: title,
                                   identifier: attribute(el, kAXIdentifierAttribute),
                                   bundleID: bundleID, frame: CGRect(origin: p, size: s))
        }
    }

    private static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    // MARK: Window-list fallback (macOS 14–26)

    private static func windowScan() -> [MenuBarItemInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == statusLayer,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width > 1, frame.height <= 50, frame.minY < 60
            else { return nil }
            return MenuBarItemInfo(pid: pid, ownerName: w[kCGWindowOwnerName as String] as? String ?? "?",
                                   title: w[kCGWindowName as String] as? String, identifier: nil,
                                   bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                                   frame: frame)
        }
    }

    // MARK: - Accessibility (needed to move other apps' items)

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Simulates the ⌘-drag the user would do by hand, then puts the cursor back.
    static func commandDrag(from start: CGPoint, to end: CGPoint) async {
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location

        func post(_ type: CGEventType, _ p: CGPoint) {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

        post(.mouseMoved, start)
        await pause(40)
        post(.leftMouseDown, start)
        await pause(120)
        let steps = 14
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y))
            await pause(15)
        }
        await pause(80)
        post(.leftMouseUp, end)
        await pause(80)
        if let original {
            CGWarpMouseCursorPosition(original)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }
}
