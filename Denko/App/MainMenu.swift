import AppKit

/// The standard menus. Denko lives in the menu bar, but its windows still need the usual
/// keys: ⌘V to paste a token, ⌘W to close settings, ⌘Q to quit.
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let app = NSMenu(title: "Denko")
        app.addItem(withTitle: "Denko について", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "設定…", action: #selector(AppDelegate.menuOpenSettings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Denko を隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Denko を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        let edit = NSMenu(title: "編集")
        edit.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        let window = NSMenu(title: "ウインドウ")
        window.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        add(window, to: main)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }

    /// Settings and はじめに are ordinary windows: while one is open, Denko shows in the Dock
    /// and ⌘Tab so it can be brought back from behind other apps.
    static func updateActivationPolicy() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && ($0.styleMask.contains(.titled)) }
        let wanted: NSApplication.ActivationPolicy = (hasWindow || TestMode.isActive) ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }
}
