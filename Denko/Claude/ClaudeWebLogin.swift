import AppKit
import WebKit

/// 実験 → claude.ai: the user signs in to claude.ai in a small window, and Denko keeps the
/// `sessionKey` cookie claude.ai sets (in the keychain) — no developer tools or copying.
/// The window uses a throwaway web store, so nothing else from the sign-in stays behind,
/// and nothing is read from the user's own browsers.
@MainActor
final class ClaudeWebLogin: NSObject, WKHTTPCookieStoreObserver, NSWindowDelegate {
    static let shared = ClaudeWebLogin()

    private var window: NSWindow?
    private var store: WKHTTPCookieStore?
    private var onSignedIn: (() -> Void)?

    func start(onSignedIn: @escaping () -> Void) {
        self.onSignedIn = onSignedIn
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 680), configuration: config)
        // claude.ai's sign-in expects a regular browser.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        let store = config.websiteDataStore.httpCookieStore
        store.add(self)
        self.store = store
        web.load(URLRequest(url: URL(string: "https://claude.ai/login")!))

        let w = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = String(localized: "claude.ai にログイン")
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        MainMenu.updateActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            let cookies = await cookieStore.allCookies()
            guard let key = cookies.first(where: { $0.name == "sessionKey" && $0.domain.hasSuffix("claude.ai") })?.value,
                  !key.isEmpty else { return }
            self.finish(key)
        }
    }

    private func finish(_ key: String) {
        guard window != nil else { return }   // already handled
        Keychain.save(key, account: ClaudeUsageAPI.sessionKeyAccount)
        let done = onSignedIn
        onSignedIn = nil
        window?.close()
        done?()
    }

    func windowWillClose(_ notification: Notification) {
        store?.remove(self)
        store = nil
        window = nil
        DispatchQueue.main.async { MainMenu.updateActivationPolicy() }
    }
}
