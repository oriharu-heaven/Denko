import AppKit
import Foundation

enum AnimationMode: String, CaseIterable, Identifiable {
    case eco, smooth, still
    var id: String { rawValue }
    var label: String {
        switch self {
        case .eco: return "省電力（おすすめ）"
        case .smooth: return "なめらか"
        case .still: return "止める"
        }
    }
}

enum DisplayStyle: String, CaseIterable, Identifiable {
    case standard, led
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "アイコン"
        case .led: return "電光掲示板"
        }
    }
}

enum GaugeStyle: String, CaseIterable, Identifiable {
    case pie, bar, ring
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pie: return "円グラフ"
        case .bar: return "縦バー"
        case .ring: return "リング"
        }
    }
}

enum ClaudeNumbers: String, CaseIterable, Identifiable {
    case none, fiveHour, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "表示しない"
        case .fiveHour: return "5時間枠のみ"
        case .both: return "5時間枠と週間"
        }
    }
}

enum ItemSection: String, CaseIterable, Identifiable {
    case visible, hidden, alwaysHidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .visible: return "表示"
        case .hidden: return "隠す"
        case .alwaysHidden: return "常に隠す"
        }
    }
}

/// App-wide settings, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    // Merged icon
    @Published var showCharacter: Bool { didSet { d.set(showCharacter, forKey: "showCharacter") } }
    @Published var character: CharacterKind {
        didSet { d.set(character.rawValue, forKey: "character"); IconRenderer.character = character }
    }
    // Mac-wide usage gauges
    @Published var showCPUGauge: Bool { didSet { d.set(showCPUGauge, forKey: "showCPUGauge") } }
    @Published var showMemoryGauge: Bool { didSet { d.set(showMemoryGauge, forKey: "showMemoryGauge") } }
    @Published var showNetworkGauge: Bool { didSet { d.set(showNetworkGauge, forKey: "showNetworkGauge") } }
    @Published var gaugeNumbers: Bool { didSet { d.set(gaugeNumbers, forKey: "gaugeNumbers") } }
    @Published var gaugeStyle: GaugeStyle { didSet { d.set(gaugeStyle.rawValue, forKey: "gaugeStyle") } }
    /// Standard icons, or the whole dashboard drawn on the LED board.
    @Published var displayStyle: DisplayStyle { didSet { d.set(displayStyle.rawValue, forKey: "displayStyle") } }
    /// Sampling interval (seconds) while only the menu bar is shown / while the panel is open.
    @Published var menuBarInterval: Double { didSet { d.set(menuBarInterval, forKey: "menuBarInterval") } }
    @Published var panelInterval: Double { didSet { d.set(panelInterval, forKey: "panelInterval") } }
    @Published var showTopApp: Bool { didSet { d.set(showTopApp, forKey: "showTopApp") } }
    /// Clicking a part of the icon (CPU, memory …) opens that tab; off = the panel opens on the last tab.
    @Published var openTabAtClick: Bool { didSet { d.set(openTabAtClick, forKey: "openTabAtClick") } }
    @Published var colorAppIcons: Bool { didSet { d.set(colorAppIcons, forKey: "colorAppIcons") } }
    /// AI services whose usage is tracked (none by default).
    @Published var aiProviders: [AIProvider] { didSet { d.set(aiProviders.map(\.rawValue), forKey: "aiProviders") } }
    /// Which of them get a ring in the menu bar.
    @Published var menuBarAI: [AIProvider] { didSet { d.set(menuBarAI.map(\.rawValue), forKey: "menuBarAI") } }
    @Published var claudeNumbers: ClaudeNumbers { didSet { d.set(claudeNumbers.rawValue, forKey: "claudeNumbers") } }
    @Published var animationMode: AnimationMode { didSet { d.set(animationMode.rawValue, forKey: "animationMode") } }
    @Published var pauseOnBattery: Bool { didSet { d.set(pauseOnBattery, forKey: "pauseOnBattery") } }
    @Published var compatibleCatRendering: Bool { didSet { d.set(compatibleCatRendering, forKey: "compatibleCatRendering") } }


    // LED board
    @Published var tickerEnabled: Bool { didSet { d.set(tickerEnabled, forKey: "tickerEnabled") } }
    /// Scroll speed in points per second.
    @Published var tickerSpeed: Double { didSet { d.set(tickerSpeed, forKey: "tickerSpeed") } }
    @Published var tickerRepeat: Int { didSet { d.set(tickerRepeat, forKey: "tickerRepeat") } }


    // 今日 (weather / news / trends)
    @Published var infoWeather: Bool { didSet { d.set(infoWeather, forKey: "infoWeather") } }
    @Published var infoNews: Bool { didSet { d.set(infoNews, forKey: "infoNews") } }
    @Published var infoTrends: Bool { didSet { d.set(infoTrends, forKey: "infoTrends") } }
    @Published var weatherPlace: String { didSet { d.set(weatherPlace, forKey: "weatherPlace") } }
    @Published var weatherLatitude: Double { didSet { d.set(weatherLatitude, forKey: "weatherLatitude") } }
    @Published var weatherLongitude: Double { didSet { d.set(weatherLongitude, forKey: "weatherLongitude") } }
    @Published var newsFeed: NewsChoice { didSet { d.set(newsFeed.raw, forKey: "newsChoice") } }
    @Published var announceNews: Bool { didSet { d.set(announceNews, forKey: "announceNews") } }
    @Published var announceRain: Bool { didSet { d.set(announceRain, forKey: "announceRain") } }
    @Published var announceMorning: Bool { didSet { d.set(announceMorning, forKey: "announceMorning") } }
    @Published var infoTrains: Bool { didSet { d.set(infoTrains, forKey: "infoTrains") } }
    /// Lines to watch, by name (e.g. "山手線"). Empty = every line.
    @Published var trainLines: [String] { didSet { d.set(trainLines, forKey: "trainLines") } }
    /// Region watched when no lines are picked ("" = from the weather place's prefecture).
    @Published var trainRegion: String { didSet { d.set(trainRegion, forKey: "trainRegion") } }
    var effectiveTrainRegion: String {
        trainRegion.isEmpty ? TrainFeed.region(forPrefecture: weatherPrefecture) : trainRegion
    }
    @Published var announceTrains: Bool { didSet { d.set(announceTrains, forKey: "announceTrains") } }
    @Published var infoFX: Bool { didSet { d.set(infoFX, forKey: "infoFX") } }
    /// e.g. ["USDJPY", "EURJPY"]
    @Published var fxPairs: [String] { didSet { d.set(fxPairs, forKey: "fxPairs") } }
    /// Announce when a pair moves this much (%) from the previous close. 0 = never.
    @Published var fxAlertPercent: Double { didSet { d.set(fxAlertPercent, forKey: "fxAlertPercent") } }
    /// Minutes between periodic weather / news / trends rolls on the board (0 = off).
    @Published var infoRollMinutes: Int { didSet { d.set(infoRollMinutes, forKey: "infoRollMinutes") } }
    /// Urgent messages take over the whole menu bar.
    @Published var fullBarUrgent: Bool { didSet { d.set(fullBarUrgent, forKey: "fullBarUrgent") } }
    /// Every notification (not just urgent ones) plays across the whole menu bar.
    @Published var fullBarAll: Bool { didSet { d.set(fullBarAll, forKey: "fullBarAll") } }

    @Published var storageMode: StorageMode { didSet { d.set(storageMode.rawValue, forKey: "storageMode") } }

    /// Per-kind levels the user changed (others use the kind's default).
    @Published var noticeLevels: [String: String] { didSet { d.set(noticeLevels, forKey: "noticeLevels") } }
    @Published var focusBehavior: FocusBehavior { didSet { d.set(focusBehavior.rawValue, forKey: "focusBehavior") } }
    /// Treat a full-screen app in front (presentations, video) like a Focus.
    @Published var quietInFullScreen: Bool { didSet { d.set(quietInFullScreen, forKey: "quietInFullScreen") } }
    /// Show the detailed settings (refresh rates, Webhook, tokens …).
    @Published var showAdvanced: Bool { didSet { d.set(showAdvanced, forKey: "showAdvanced") } }

    func level(for kind: NoticeKind) -> NoticeLevel {
        noticeLevels[kind.rawValue].flatMap(NoticeLevel.init(rawValue:)) ?? kind.defaultLevel
    }

    /// 気象庁の地震・津波・警報.
    @Published var infoDisaster: Bool { didSet { d.set(infoDisaster, forKey: "infoDisaster") } }
    /// Prefecture of the weather place (for local warnings / intensities), e.g. "東京都".
    @Published var weatherPrefecture: String { didSet { d.set(weatherPrefecture, forKey: "weatherPrefecture") } }

    /// 省電力 / 標準 / パフォーマンス. Choosing one also sets the detailed intervals below.
    @Published var performance: PerformanceMode {
        didSet {
            d.set(performance.rawValue, forKey: "performance")
            guard performance != oldValue else { return }
            menuBarInterval = performance.menuBarInterval
            panelInterval = performance.panelInterval
            animationMode = performance.animation
        }
    }

    /// Until this time only urgent notices play (quick pause for meetings etc.).
    @Published var pausedUntil: Date? {
        didSet { if let p = pausedUntil { d.set(p, forKey: "pausedUntil") } else { d.removeObject(forKey: "pausedUntil") } }
    }
    var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }

    func pause(minutes: Int?) {
        if let minutes {
            pausedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            // Until 7:00 tomorrow.
            let cal = Calendar.current
            let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            pausedUntil = cal.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow)
        }
    }

    // Board look and motion
    @Published var dotShape: DotShape { didSet { d.set(dotShape.rawValue, forKey: "dotShape") } }
    /// Dot diameter as a share of the dot pitch.
    @Published var dotSize: Double { didSet { d.set(dotSize, forKey: "dotSize") } }
    /// Brightness of unlit dots (0 = invisible).
    @Published var unlitDots: Double { didSet { d.set(unlitDots, forKey: "unlitDots") } }
    /// "#RRGGBB" of the custom theme color (AccentPreset.custom).
    @Published var boardCustomColor: String {
        didSet { d.set(boardCustomColor, forKey: "boardCustomColor"); AccentPreset.customHex = boardCustomColor }
    }
    /// "#RRGGBB" of the custom board base (darkened when drawn).
    @Published var boardBaseCustom: String { didSet { d.set(boardBaseCustom, forKey: "boardBaseCustom") } }
    /// The board's (always dark) base color.
    @Published var boardBase: BoardBase { didSet { d.set(boardBase.rawValue, forKey: "boardBase") } }
    /// Urgent messages scroll this many times faster.
    @Published var urgentSpeed: Double { didSet { d.set(urgentSpeed, forKey: "urgentSpeed") } }
    @Published var urgentBlink: Bool { didSet { d.set(urgentBlink, forKey: "urgentBlink") } }
    /// Show the "◆ 天気 ◆" heading before each message.
    @Published var showHeading: Bool { didSet { d.set(showHeading, forKey: "showHeading") } }
    /// What the board shows between messages.
    @Published var boardIdle: BoardIdle { didSet { d.set(boardIdle.rawValue, forKey: "boardIdle") } }
    @Published var idleMessage: String { didSet { d.set(idleMessage, forKey: "idleMessage") } }

    /// Lit-dot color for the board.
    var boardNSColor: NSColor { accent.ledColor }
    var boardBaseColor: NSColor { boardBase.color(customHex: boardBaseCustom) }

    /// Changes whenever anything that affects how the board is drawn changes.
    var boardStyleKey: String {
        "\(accent.rawValue)|\(dotShape.rawValue)|\(dotSize)|\(unlitDots)|\(boardBase.rawValue)|\(boardCustomColor)|\(boardBaseCustom)|\(boardIdle.rawValue)|\(idleMessage)"
    }

    // Board sources
    @Published var notifyServerEnabled: Bool { didSet { d.set(notifyServerEnabled, forKey: "notifyServerEnabled") } }
    @Published var notifyPort: Int { didSet { d.set(notifyPort, forKey: "notifyPort") } }
    @Published var githubEnabled: Bool { didSet { d.set(githubEnabled, forKey: "githubEnabled") } }
    @Published var rssEnabled: Bool { didSet { d.set(rssEnabled, forKey: "rssEnabled") } }
    @Published var rssFeeds: [String] { didSet { d.set(rssFeeds, forKey: "rssFeeds") } }
    @Published var rssMinutes: Int { didSet { d.set(rssMinutes, forKey: "rssMinutes") } }
    @Published var alertClaudeUsage: Bool { didSet { d.set(alertClaudeUsage, forKey: "alertClaudeUsage") } }
    @Published var alertAwake: Bool { didSet { d.set(alertAwake, forKey: "alertAwake") } }

    // Appearance
    @Published var accent: AccentPreset { didSet { d.set(accent.rawValue, forKey: "accent") } }

    // Sleep prevention
    @Published var keepAwakeDefaultMinutes: Int { didSet { d.set(keepAwakeDefaultMinutes, forKey: "keepAwakeDefaultMinutes") } }
    @Published var allowDisplaySleep: Bool { didSet { d.set(allowDisplaySleep, forKey: "allowDisplaySleep") } }
    /// Stop when on battery at or below this percent (0 = never).
    @Published var keepAwakeBatteryLimit: Int { didSet { d.set(keepAwakeBatteryLimit, forKey: "keepAwakeBatteryLimit") } }
    @Published var keepAwakeOnLaunch: Bool { didSet { d.set(keepAwakeOnLaunch, forKey: "keepAwakeOnLaunch") } }

    // Menu bar hider
    @Published var hiderEnabled: Bool { didSet { d.set(hiderEnabled, forKey: "hiderEnabled") } }
    @Published var alwaysHiddenEnabled: Bool { didSet { d.set(alwaysHiddenEnabled, forKey: "alwaysHiddenEnabled") } }
    @Published var showOnHover: Bool { didSet { d.set(showOnHover, forKey: "showOnHover") } }
    @Published var autoRehide: Bool { didSet { d.set(autoRehide, forKey: "autoRehide") } }
    @Published var autoRehideSeconds: Double { didSet { d.set(autoRehideSeconds, forKey: "autoRehideSeconds") } }
    @Published var rehideOnAppSwitch: Bool { didSet { d.set(rehideOnAppSwitch, forKey: "rehideOnAppSwitch") } }
    @Published var autoArrange: Bool { didSet { d.set(autoArrange, forKey: "autoArrange") } }
    @Published var newItemSection: ItemSection { didSet { d.set(newItemSection.rawValue, forKey: "newItemSection") } }
    /// Item key → section the user chose for it.
    @Published var itemRules: [String: ItemSection] {
        didSet { d.set(itemRules.mapValues(\.rawValue), forKey: "itemRules") }
    }

    /// Carries settings over from before the rename to Denko (once).
    private static func migrateLegacyDefaults(_ d: UserDefaults) {
        guard !d.bool(forKey: "migratedFromClaudeUsageOnBar") else { return }
        d.set(true, forKey: "migratedFromClaudeUsageOnBar")
        let old = "com.haru.ClaudeUsageOnBar" as CFString
        guard let keys = CFPreferencesCopyKeyList(old, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              let values = CFPreferencesCopyMultiple(keys as CFArray, old, kCFPreferencesCurrentUser,
                                                     kCFPreferencesAnyHost) as? [String: Any] else { return }
        for (k, v) in values where d.object(forKey: k) == nil && !k.hasPrefix("NS") && !k.hasPrefix("SU") {
            d.set(v, forKey: k)
        }
    }

    init() {
        let d = UserDefaults.standard
        Self.migrateLegacyDefaults(d)
        func bool(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }
        showCharacter = bool("showCharacter", true)
        let kind = CharacterKind(rawValue: d.string(forKey: "character") ?? "") ?? .frog
        character = kind
        IconRenderer.character = kind
        showCPUGauge = bool("showCPUGauge", true)
        showMemoryGauge = bool("showMemoryGauge", true)
        showNetworkGauge = bool("showNetworkGauge", true)
        gaugeNumbers = bool("gaugeNumbers", false)
        gaugeStyle = GaugeStyle(rawValue: d.string(forKey: "gaugeStyle") ?? "") ?? .pie
        displayStyle = DisplayStyle(rawValue: d.string(forKey: "displayStyle") ?? "") ?? .led
        menuBarInterval = d.object(forKey: "menuBarInterval") as? Double ?? 3
        panelInterval = d.object(forKey: "panelInterval") as? Double ?? 2
        // Details (app icons, numbers) live in the hover tooltip by default.
        showTopApp = bool("showTopApp", false)
        openTabAtClick = bool("openTabAtClick", true)
        colorAppIcons = bool("colorAppIcons", false)
        aiProviders = (d.stringArray(forKey: "aiProviders") ?? []).compactMap(AIProvider.init(rawValue:))
        menuBarAI = (d.stringArray(forKey: "menuBarAI") ?? []).compactMap(AIProvider.init(rawValue:))
        claudeNumbers = ClaudeNumbers(rawValue: d.string(forKey: "claudeNumbers") ?? "") ?? .fiveHour
        animationMode = AnimationMode(rawValue: d.string(forKey: "animationMode") ?? "") ?? .eco
        pauseOnBattery = bool("pauseOnBattery", false)
        compatibleCatRendering = bool("compatibleCatRendering", false)


        tickerEnabled = bool("tickerEnabled", true)
        tickerSpeed = d.object(forKey: "tickerSpeed") as? Double ?? 30
        tickerRepeat = d.object(forKey: "tickerRepeat") as? Int ?? 2


        infoWeather = bool("infoWeather", true)
        infoNews = bool("infoNews", true)
        infoTrends = bool("infoTrends", true)
        weatherPlace = d.string(forKey: "weatherPlace") ?? "東京"
        weatherLatitude = d.object(forKey: "weatherLatitude") as? Double ?? 35.6812
        weatherLongitude = d.object(forKey: "weatherLongitude") as? Double ?? 139.7671
        newsFeed = NewsChoice(d.string(forKey: "newsChoice"))
        announceNews = bool("announceNews", true)
        announceRain = bool("announceRain", true)
        announceMorning = bool("announceMorning", true)
        infoTrains = bool("infoTrains", true)
        trainLines = d.stringArray(forKey: "trainLines") ?? TrainFeed.defaultLines
        announceTrains = bool("announceTrains", true)
        trainRegion = d.string(forKey: "trainRegion") ?? ""
        infoFX = bool("infoFX", true)
        fxPairs = d.stringArray(forKey: "fxPairs") ?? ["USDJPY", "EURJPY"]
        fxAlertPercent = d.object(forKey: "fxAlertPercent") as? Double ?? 1.0
        infoRollMinutes = d.object(forKey: "infoRollMinutes") as? Int ?? 15
        fullBarUrgent = bool("fullBarUrgent", true)
        fullBarAll = bool("fullBarAll", true)

        infoDisaster = bool("infoDisaster", true)
        weatherPrefecture = d.string(forKey: "weatherPrefecture") ?? "東京都"
        pausedUntil = d.object(forKey: "pausedUntil") as? Date
        noticeLevels = d.dictionary(forKey: "noticeLevels") as? [String: String] ?? [:]
        focusBehavior = FocusBehavior(rawValue: d.string(forKey: "focusBehavior") ?? "") ?? .urgentOnly
        quietInFullScreen = bool("quietInFullScreen", true)
        showAdvanced = bool("showAdvanced", false)
        storageMode = StorageMode(rawValue: d.string(forKey: "storageMode") ?? "") ?? .basic
        dotShape = DotShape(rawValue: d.string(forKey: "dotShape") ?? "") ?? .round
        dotSize = d.object(forKey: "dotSize") as? Double ?? 0.87
        unlitDots = d.object(forKey: "unlitDots") as? Double ?? 0.07
        let customHex = d.string(forKey: "boardCustomColor") ?? "#FF9E29"
        boardCustomColor = customHex
        AccentPreset.customHex = customHex
        boardBaseCustom = d.string(forKey: "boardBaseCustom") ?? "#102040"
        boardBase = BoardBase(rawValue: d.string(forKey: "boardBase") ?? "") ?? .black
        urgentSpeed = d.object(forKey: "urgentSpeed") as? Double ?? 2.5
        urgentBlink = bool("urgentBlink", true)
        showHeading = bool("showHeading", true)
        boardIdle = BoardIdle(rawValue: d.string(forKey: "boardIdle") ?? "") ?? .dashboard
        idleMessage = d.string(forKey: "idleMessage") ?? "DENKO"

        notifyServerEnabled = bool("notifyServerEnabled", true)
        notifyPort = d.object(forKey: "notifyPort") as? Int ?? 47326
        githubEnabled = bool("githubEnabled", false)
        rssEnabled = bool("rssEnabled", false)
        rssFeeds = d.stringArray(forKey: "rssFeeds") ?? []
        rssMinutes = d.object(forKey: "rssMinutes") as? Int ?? 30
        alertClaudeUsage = bool("alertClaudeUsage", true)
        alertAwake = bool("alertAwake", true)

        // The station-board amber is Denko's default color (applied once to earlier installs too).
        if d.bool(forKey: "stationColorDefault") {
            accent = AccentPreset(rawValue: d.string(forKey: "accent") ?? "") ?? .station
        } else {
            d.set(true, forKey: "stationColorDefault")
            accent = .station
            d.set(AccentPreset.station.rawValue, forKey: "accent")
        }

        keepAwakeDefaultMinutes = d.object(forKey: "keepAwakeDefaultMinutes") as? Int ?? 60
        allowDisplaySleep = bool("allowDisplaySleep", false)
        keepAwakeBatteryLimit = d.object(forKey: "keepAwakeBatteryLimit") as? Int ?? 20
        keepAwakeOnLaunch = bool("keepAwakeOnLaunch", false)

        // Off by default: on macOS 26+ it needs Accessibility to work safely.
        hiderEnabled = bool("hiderEnabled", false)
        alwaysHiddenEnabled = bool("alwaysHiddenEnabled", false)
        showOnHover = bool("showOnHover", false)
        autoRehide = bool("autoRehide", true)
        autoRehideSeconds = d.object(forKey: "autoRehideSeconds") as? Double ?? 10
        rehideOnAppSwitch = bool("rehideOnAppSwitch", false)
        autoArrange = bool("autoArrange", true)
        newItemSection = ItemSection(rawValue: d.string(forKey: "newItemSection") ?? "") ?? .visible
        let raw = d.dictionary(forKey: "itemRules") as? [String: String] ?? [:]
        itemRules = raw.compactMapValues(ItemSection.init(rawValue:))
        // First run of this version: start light (省電力).
        if let p = d.string(forKey: "performance").flatMap(PerformanceMode.init(rawValue:)) {
            performance = p
        } else {
            performance = .saver
            menuBarInterval = PerformanceMode.saver.menuBarInterval
            panelInterval = PerformanceMode.saver.panelInterval
            animationMode = PerformanceMode.saver.animation
            d.set(PerformanceMode.saver.rawValue, forKey: "performance")
        }
    }
}
