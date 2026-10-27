import AppKit
import Intents

/// How a kind of notice is played.
enum NoticeLevel: String, CaseIterable, Identifiable, Codable {
    case urgent, normal, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .urgent: return String(localized: "緊急")
        case .normal: return String(localized: "ふつう")
        case .off: return String(localized: "流さない")
        }
    }
}

/// Every kind of notice Denko can play, each with its own level (設定 → 掲示板).
enum NoticeKind: String, CaseIterable, Identifiable, Codable {
    case claudeWaiting, claudeDone, githubReview, githubOther, trainDelay, trainRecovered,
         newsBreaking, newsNew, weatherRain, weatherMorning, fxMove, aiUsage, awakeEnded,
         rss, webhook, todayRoll, other,
         quakeStrong, quakeOther, tsunami, weatherWarning

    var id: String { rawValue }

    var group: String {
        switch self {
        case .claudeWaiting, .claudeDone, .githubReview, .githubOther, .aiUsage, .webhook: return String(localized: "開発・AI")
        case .trainDelay, .trainRecovered: return String(localized: "電車")
        case .newsBreaking, .newsNew, .rss: return String(localized: "ニュース")
        case .weatherRain, .weatherMorning, .fxMove, .todayRoll: return String(localized: "今日の情報")
        case .quakeStrong, .quakeOther, .tsunami, .weatherWarning: return String(localized: "防災")
        case .awakeEnded, .other: return String(localized: "このアプリ")
        }
    }

    var label: String {
        switch self {
        case .claudeWaiting: return String(localized: "コーディングエージェントの許可待ち・入力待ち")
        case .claudeDone: return String(localized: "コーディングエージェントの作業完了")
        case .githubReview: return String(localized: "GitHub のレビュー依頼・メンション")
        case .githubOther: return String(localized: "GitHub のその他の通知")
        case .aiUsage: return String(localized: "AI の使用量（80%・100%・リセット）")
        case .webhook: return String(localized: "Webhook・スクリプトから")
        case .trainDelay: return String(localized: "見ている路線の遅延・運転見合わせ")
        case .trainRecovered: return String(localized: "平常運転に戻ったとき")
        case .newsBreaking: return String(localized: "ニュース速報")
        case .newsNew: return String(localized: "新しいニュース")
        case .rss: return String(localized: "RSS の新着")
        case .weatherRain: return String(localized: "まもなく雨")
        case .weatherMorning: return String(localized: "朝の天気予報")
        case .fxMove: return String(localized: "為替の大きな動き")
        case .todayRoll: return String(localized: "今日の情報（定期的に流すもの）")
        case .awakeEnded: return String(localized: "スリープ防止の終了")
        case .other: return String(localized: "その他")
        case .quakeStrong: return String(localized: "強い地震（震度5弱以上・地元で震度4以上）")
        case .quakeOther: return String(localized: "震度4の地震・地元で震度3の地震")
        case .tsunami: return String(localized: "津波警報・注意報、噴火速報")
        case .weatherWarning: return String(localized: "地元の気象警報・土砂災害警戒情報など")
        }
    }

    var defaultLevel: NoticeLevel {
        switch self {
        // 緊急 is only for danger to the user: it fills the menu bar and still plays while paused
        // or in a Focus. Everything else plays normally, and chatty kinds stay in the history.
        case .quakeStrong, .tsunami:
            return .urgent
        case .newsNew, .trainRecovered, .githubOther, .rss:
            return .off
        default:
            return .normal
        }
    }

    static var groups: [String] { ["防災", String(localized: "開発・AI"), String(localized: "電車"), String(localized: "ニュース"), String(localized: "今日の情報")] }
}

/// While a Focus is on (or a full-screen app is in front), what still plays.
enum FocusBehavior: String, CaseIterable, Identifiable {
    case same, urgentOnly, silent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .same: return String(localized: "いつもどおり")
        case .urgentOnly: return String(localized: "緊急だけ")
        case .silent: return String(localized: "流さない")
        }
    }
}

/// Reads whether a Focus (集中モード) is on. macOS asks the user once for permission.
@MainActor
enum FocusWatcher {
    static var isAuthorized: Bool { INFocusStatusCenter.default.authorizationStatus == .authorized }

    static func requestAuthorization(_ done: @escaping @MainActor (Bool) -> Void) {
        INFocusStatusCenter.default.requestAuthorization { status in
            Task { @MainActor in done(status == .authorized) }
        }
    }

    /// A window of the frontmost app covering a whole screen (presentation, video, game).
    static var isFullScreenAppInFront: Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return false }
        let screens = NSScreen.screens.map(\.frame.size)
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return screens.contains { $0.width == b["Width"] && $0.height == b["Height"] }
        }
    }

    static var isFocused: Bool {
        guard isAuthorized else { return false }
        return INFocusStatusCenter.default.focusStatus.isFocused ?? false
    }
}
