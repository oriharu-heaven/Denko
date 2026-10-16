import AppKit

/// Development aid for hands-on testing: `DENKO_TEST=1 Denko` runs Denko as a regular app
/// (Dock icon, app menu) so its windows can be driven like any other app, and
/// `DENKO_TEST_OPEN=settings|onboarding|panel` opens that window at launch.
@MainActor
enum TestMode {
    static var isActive: Bool { ProcessInfo.processInfo.environment["DENKO_TEST"] != nil }

    static func start(_ app: AppDelegate) {
        guard isActive else {
            // Opening a window at launch also works in the normal (menu-bar) mode.
            if ProcessInfo.processInfo.environment["DENKO_TEST_OPEN"] == "settings" { app.openSettings() }
            return
        }
        NSApp.setActivationPolicy(.regular)
        if let appMenu = NSApp.mainMenu?.items.first?.submenu {
            appMenu.insertItem(.separator(), at: 0)
            appMenu.insertItem(withTitle: "（テスト）パネル", action: #selector(AppDelegate.testOpenPanel), keyEquivalent: "p", at: 0)
            appMenu.insertItem(withTitle: "（テスト）はじめに", action: #selector(AppDelegate.testOpenOnboarding), keyEquivalent: "", at: 0)
        }
        switch ProcessInfo.processInfo.environment["DENKO_TEST_OPEN"] {
        case "settings": app.openSettings()
        case "onboarding": app.showOnboarding()
        case "panel": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { app.testOpenPanel() }
        default: break
        }
    }
}

extension AppDelegate {
    @objc func testOpenSettings() { openSettings() }
    @objc func testOpenOnboarding() { showOnboarding() }
    @objc func testOpenPanel() { mainItemForTesting?.showPanel() }
}
