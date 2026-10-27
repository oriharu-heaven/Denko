import AppKit

/// Shared right-click menu (settings / quit).
@MainActor
enum StatusMenu {
    @MainActor private final class Target: NSObject {
        @objc func openSettings() { AppDelegate.shared.openSettings() }
        @objc func checkForUpdates() { AppDelegate.shared.updater.checkForUpdates() }
        @objc func quit() { NSApp.terminate(nil) }
        @objc func pause(_ sender: NSMenuItem) {
            AppDelegate.shared.settings.pause(minutes: sender.tag > 0 ? sender.tag : nil)
        }
        @objc func about() {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        @objc func resume() { AppDelegate.shared.settings.pausedUntil = nil }
    }
    private static let target = Target()

    static func show(on item: NSStatusItem, extra: [NSMenuItem] = []) {
        let menu = NSMenu()
        for e in extra { menu.addItem(e) }
        if !extra.isEmpty { menu.addItem(.separator()) }
        let s = AppDelegate.shared.settings
        if s.isPaused, let until = s.pausedUntil {
            let f = DateFormatter()
            f.dateFormat = Calendar.current.isDateInToday(until) ? "H:mm" : "M/d H:mm"
            menu.addItem(withTitle: String(localized: "\(f.string(from: until)) まで緊急のお知らせだけ流しています"), action: nil, keyEquivalent: "")
            let resume = menu.addItem(withTitle: String(localized: "お知らせを再開"), action: #selector(Target.resume), keyEquivalent: "")
            resume.target = target
        } else {
            let pauseItem = menu.addItem(withTitle: String(localized: "お知らせを止める（緊急だけ流す）"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, minutes) in [(String(localized: "30分"), 30), (String(localized: "1時間"), 60), (String(localized: "明日の朝まで"), 0)] {
                let mi = sub.addItem(withTitle: title, action: #selector(Target.pause(_:)), keyEquivalent: "")
                mi.tag = minutes
                mi.target = target
            }
            pauseItem.submenu = sub
        }
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: String(localized: "設定…"), action: #selector(Target.openSettings), keyEquivalent: ",")
        settings.target = target
        let update = menu.addItem(withTitle: String(localized: "アップデートを確認…"), action: #selector(Target.checkForUpdates), keyEquivalent: "")
        update.target = target
        let about = menu.addItem(withTitle: String(localized: "Denko について"), action: #selector(Target.about), keyEquivalent: "")
        about.target = target
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: String(localized: "終了"), action: #selector(Target.quit), keyEquivalent: "q")
        quit.target = target
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}
