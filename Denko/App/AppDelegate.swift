import AppKit
import Intents
import ServiceManagement
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static private(set) var shared: AppDelegate!

    let settings = AppSettings()
    let usageStore = UsageStore()
    private(set) lazy var ai = AIUsageStore(claude: usageStore, settings: settings)
    let system = SystemMonitor()
    let appUsage = AppUsageMonitor()
    let hub = NotificationHub()
    let updater = Updater()
    /// Kept for the app's lifetime so a finished scan is still there next time the panel opens.
    let storage = StorageAnalyzer()
    private(set) lazy var info = InfoStore(settings: settings, hub: hub)
    private(set) lazy var awake = SleepPreventer(settings: settings)
    private(set) lazy var notifyServer = LocalNotifyServer(hub: hub)
    private(set) lazy var github = GitHubSource(hub: hub)
    private lazy var rss = RSSSource(hub: hub)
    private lazy var alerts = BuiltInAlerts(hub: hub, settings: settings)

    private var mainItem: MainStatusController?
    var mainItemForTesting: MainStatusController? { mainItem }
    private(set) var hider: MenuBarHider?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshot.isActive { Snapshot.run(self); return }
        MainMenu.install()
        hub.settings = settings
        // はじめに until the user finishes it (closing it just brings it back next launch).
        // Starting at login is one of its choices, so it's never turned on without asking.
        if needsOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showOnboarding() }
        }
        Keychain.migrateLegacy(accounts: [GitHubSource.keychainAccount, TrainFeed.keychainAccount])
        // New status items are inserted to the left of existing ones, so creation order
        // gives the initial layout: [always-hidden ┆ hidden ┊ ‹] [LED board] [frog + Claude]
        // Notifications play on the main item itself (board takeover), so there's no
        // separate ticker item any more.
        mainItem = MainStatusController(ai: ai, monitor: system, apps: appUsage,
                                        settings: settings, awake: awake, hub: hub)
        if !MenuBarHider.hasBuiltInHiding {
            hider = MenuBarHider(settings: settings)
        }
        wireSources()
        _ = info
        TestMode.start(self)
        settings.$infoWeather.combineLatest(settings.$infoNews)
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.info.schedule() } }
            .store(in: &bag)
        settings.$performance.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.info.schedule() } }
            .store(in: &bag)
        settings.$infoDisaster.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.info.schedule() } }
            .store(in: &bag)
        settings.$infoTrains.combineLatest(settings.$infoFX)
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.info.schedule() } }
            .store(in: &bag)
        settings.$experimentalTrainPages.combineLatest(settings.$experimentalNHKFlash).dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.info.schedule() } }
            .store(in: &bag)
        settings.$trainLines.dropFirst().debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.info.refreshTrains() } }
            .store(in: &bag)
        settings.$fxPairs.dropFirst().debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.info.refreshFX() } }
            .store(in: &bag)
        settings.$infoRollMinutes.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.info.scheduleRoll() } }
            .store(in: &bag)
        settings.$newsFeed.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { Task { await self?.info.refreshNews() } } }
            .store(in: &bag)
    }

    private func wireSources() {
        // The endpoint always runs so coding agents keep reaching the board; the Webhook
        // switch only decides whether plain script / Shortcuts posts are accepted.
        notifyServer.onClaudeStatusLine = { [weak self] in self?.usageStore.receive(statusLine: $0) }
        // Turning Gemini off under 実験的 also takes it off the menu bar and panel.
        settings.$experimentalGemini.dropFirst().filter { !$0 }
            .sink { [weak self] _ in
                self?.settings.aiProviders.removeAll { $0 == .gemini }
                self?.settings.menuBarAI.removeAll { $0 == .gemini }
            }
            .store(in: &bag)
        settings.$experimentalClaudeSessionKey
            .sink { [weak self] in self?.usageStore.useSessionKey = $0 }
            .store(in: &bag)
        settings.$experimentalRealtimeClaude.combineLatest(settings.$aiProviders)
            .sink { [weak self] on, providers in self?.usageStore.realtime = on && providers.contains(.claude) }
            .store(in: &bag)
        settings.$notifyPort.removeDuplicates()
            .sink { [weak self] port in
                guard let self else { return }
                if let p = UInt16(exactly: port) { self.notifyServer.start(port: p) } else { self.notifyServer.stop() }
                // Point an installed status line script at the (new) port.
                if ClaudeStatusLine.isOurs, !ClaudeStatusLine.isInstalled(endpoint: self.notifyServer.endpoint) {
                    try? ClaudeStatusLine.install(endpoint: self.notifyServer.endpoint)
                }
            }
            .store(in: &bag)
        settings.$notifyServerEnabled.removeDuplicates()
            .sink { [weak self] in self?.notifyServer.acceptsWebhook = $0 }
            .store(in: &bag)

        settings.$githubEnabled.removeDuplicates()
            .sink { [weak self] in self?.github.setEnabled($0) }
            .store(in: &bag)

        settings.$rssEnabled.combineLatest(settings.$rssFeeds, settings.$rssMinutes)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] on, feeds, minutes in self?.rss.configure(enabled: on, feeds: feeds, minutes: minutes) }
            .store(in: &bag)

        usageStore.$snapshot
            .sink { [weak self] in self?.alerts.usageChanged($0) }
            .store(in: &bag)
        awake.$isActive.removeDuplicates()
            .sink { [weak self] in self?.alerts.awakeChanged(isActive: $0) }
            .store(in: &bag)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let host = NSHostingController(rootView: OnboardingView(settings: settings) { [weak self] choices in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.applyOnboarding(choices)
                // What はじめに couldn't do itself (lines, permissions …) is next in セットアップ.
                self?.openSettings(tab: "セットアップ")
            })
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable]
            w.title = "はじめに"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            onboardingWindow = w
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        MainMenu.updateActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func menuOpenSettings() { openSettings() }

    /// `tab`: the toolbar tab to show (its title, e.g. "情報連携"); `feed`: a 情報連携 page to open.
    /// With no tab, a finished セットアップ steps aside for 一般.
    func openSettings(tab: String? = nil, feed: InfoHubPane.Feed? = nil) {
        let isNew = settingsWindow == nil
        if settingsWindow == nil {
            let window = SettingsWindow.make(settings: settings, ai: ai, awake: awake, hider: hider)
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        let wanted = tab ?? (isNew && SetupStep.remaining(settings).isEmpty ? "一般" : nil)
        if let wanted, let tabs = settingsWindow?.contentViewController as? NSTabViewController,
           let index = tabs.tabViewItems.firstIndex(where: { $0.label == wanted }) {
            tabs.selectedTabViewItemIndex = index
        }
        SettingsRouter.shared.infoDetail = feed
        settingsWindow?.makeKeyAndOrderFront(nil)
        MainMenu.updateActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        awake.stop()
        notifyServer.stop()
    }

    func windowWillClose(_ notification: Notification) {
        // Release the SwiftUI hierarchy instead of keeping it alive in the background.
        if (notification.object as? NSWindow) === settingsWindow {
            settingsWindow?.contentViewController = nil
            settingsWindow = nil
        }
        if (notification.object as? NSWindow) === onboardingWindow {
            onboardingWindow = nil
        }
        // Back to a menu-bar-only app once its windows are gone.
        DispatchQueue.main.async { MainMenu.updateActivationPolicy() }
    }
}
