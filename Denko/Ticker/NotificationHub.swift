import Foundation

enum TickerSource: String, CaseIterable, Identifiable, Codable {
    case claudeCode, github, rss, webhook, system, news, weather, today, train, fx, codex, gemini, agent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .agent: return "コーディングエージェント"
        case .github: return "GitHub"
        case .rss: return "RSS"
        case .webhook: return "Webhook"
        case .system: return "このアプリ"
        case .news: return "ニュース"
        case .weather: return "天気"
        case .today: return "今日の情報"
        case .train: return "運行情報"
        case .fx: return "為替"
        }
    }
    var symbol: String {
        switch self {
        case .claudeCode, .codex, .gemini, .agent: return "terminal"
        case .github: return "arrow.triangle.branch"
        case .rss: return "dot.radiowaves.up.forward"
        case .webhook: return "link"
        case .system: return "bell"
        case .news: return "newspaper"
        case .weather: return "cloud.sun"
        case .today: return "sun.max"
        case .train: return "tram"
        case .fx: return "yensign.circle"
        }
    }
    /// Short tag shown on the LED board before the message.
    var tag: String {
        switch self {
        case .claudeCode: return "CLAUDE"
        case .codex: return "CODEX"
        case .gemini: return "GEMINI"
        case .agent: return "AGENT"
        case .github: return "GITHUB"
        case .rss: return "NEWS"
        case .webhook: return "INFO"
        case .system: return "INFO"
        case .news: return "NEWS"
        case .weather: return "天気"
        case .today: return "TODAY"
        case .train: return "運行情報"
        case .fx: return "為替"
        }
    }
}

struct TickerMessage: Identifiable, Equatable {
    let id = UUID()
    let source: TickerSource
    let title: String
    let body: String?
    let url: URL?
    /// Urgent messages (e.g. Claude Code waiting for permission) jump the queue and blink.
    var urgent = false
    let date = Date()

    /// The single line scrolled across the board.
    var boardText: String {
        var s = "\(source.tag)  \(title)"
        if let body, !body.isEmpty { s += " — \(body)" }
        return s
    }
}

/// Collects messages from every source. The ticker plays `queue`; `history` backs the panel.
@MainActor
final class NotificationHub: ObservableObject {
    static let historyLimit = 50

    @Published private(set) var history: [TickerMessage] = []
    @Published private(set) var unreadCount = 0
    private(set) var queue: [TickerMessage] = []

    /// Called whenever a new message is queued (with its urgency).
    var onEnqueue: ((Bool) -> Void)?
    /// Levels per kind and the quiet rules; set by the app delegate.
    weak var settings: AppSettings?

    /// `kind` picks the level (緊急 / ふつう / 流さない) from the settings; `urgent` is only a
    /// hint for kinds that leave it to the sender (Webhook's priority=high).
    /// `record: false` plays on the board without adding to the history (periodic info roll).
    func post(_ source: TickerSource, kind: NoticeKind = .other, title: String, body: String? = nil,
              url: URL? = nil, urgent hint: Bool = false, record: Bool = true, force: NoticeLevel? = nil) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var level = force ?? settings?.level(for: kind) ?? kind.defaultLevel
        if kind == .webhook && hint && level == .normal { level = .urgent }
        // A Focus with Denko's filter decides; a full-screen app in front counts as 緊急だけ.
        if force == nil, let s = settings {
            var quiet = FocusChoice.current
            if quiet == .same && (s.isPaused || (s.quietInFullScreen && FocusWatcher.isFullScreenAppInFront)) { quiet = .urgentOnly }
            if quiet == .silent || (quiet == .urgentOnly && level != .urgent) { level = .off }
        }
        let urgent = level == .urgent
        let msg = TickerMessage(source: source, title: String(title.prefix(200)),
                                body: body.map { String($0.prefix(300)) }, url: url, urgent: urgent)
        // Drop exact repeats that arrive back-to-back (e.g. duplicate hooks).
        if let last = history.first, last.source == source, last.title == msg.title, last.body == msg.body,
           msg.date.timeIntervalSince(last.date) < 5 {
            return
        }
        if record {
            history.insert(msg, at: 0)
            if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
            unreadCount += 1
        }
        guard level != .off else { return }
        if urgent { queue.insert(msg, at: 0) } else { queue.append(msg) }
        if queue.count > 20 { queue.removeFirst(queue.count - 20) }
        onEnqueue?(urgent)
    }

    func dequeue() -> TickerMessage? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    func markRead() { unreadCount = 0 }

    func clear() {
        history.removeAll()
        queue.removeAll()
        unreadCount = 0
    }
}
