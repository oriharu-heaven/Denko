import Foundation
import SwiftUI

/// Claude's usage limits as Claude Code last reported them to its status line
/// (see ClaudeStatusLine), or — with 実験的 → リアルタイム on — as Anthropic reports them every
/// few minutes (ClaudeUsageAPI). The newest report wins and is kept across launches.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastUpdated: Date?

    /// How often Codex's logs are re-read and, with リアルタイム on, Claude's usage is fetched.
    @Published var refreshMinutes: Int {
        didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes"); scheduleRealtime() }
    }

    /// 実験的: poll the usage API too (set from AppSettings).
    var realtime = false {
        didSet {
            guard realtime != oldValue else { return }
            apiError = nil
            scheduleRealtime()
        }
    }
    /// 実験: use the saved claude.ai session key instead of Claude Code's login.
    var useSessionKey = false {
        didSet { if useSessionKey != oldValue && realtime { Task { await fetchNow() } } }
    }
    @Published private(set) var apiError: String?
    private var timer: Timer?

    var lastError: String? {
        if realtime, let apiError { return apiError }
        return snapshot == nil ? String(localized: "まだ届いていません") : nil
    }

    private static let storeKey = "claudeStatusLineUsage"
    private static let dateKey = "claudeStatusLineUpdated"

    init() {
        let d = UserDefaults.standard
        // The choices are 1 / 5 / 15 minutes; older builds offered more.
        let saved = d.object(forKey: "refreshMinutes") as? Int ?? 1
        refreshMinutes = [1, 5, 15].min { abs($0 - saved) < abs($1 - saved) } ?? 1
        if let data = d.data(forKey: Self.storeKey) {
            snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        }
        lastUpdated = d.object(forKey: Self.dateKey) as? Date
    }

    /// A status line report from Claude Code (the JSON it passes to its status line).
    func receive(statusLine json: [String: Any]) {
        guard let snap = UsageSnapshot(statusLine: json) else { return }
        store(snap)
    }

    private func scheduleRealtime() {
        timer?.invalidate()
        timer = nil
        guard realtime else { return }
        let t = Timer(timeInterval: TimeInterval(max(1, refreshMinutes) * 60), repeats: true) { [weak self] _ in
            Task { await self?.fetchNow() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { await fetchNow() }
    }

    /// 実験的 → リアルタイム: one request to the usage API.
    func fetchNow() async {
        guard realtime, !Snapshot.isActive else { return }
        do {
            store(try await ClaudeUsageAPI.fetch(useSessionKey: useSessionKey))
            apiError = nil
        } catch {
            apiError = error.localizedDescription
        }
    }

    private func store(_ snap: UsageSnapshot) {
        lastUpdated = Date()
        if snap != snapshot { snapshot = snap }
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(snap), forKey: Self.storeKey)
        d.set(lastUpdated, forKey: Self.dateKey)
    }
}

enum TimeText {
    private static let todayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E) HH:mm"
        return f
    }()

    static func untilReset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return String(localized: "まもなくリセット") }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return String(localized: "あと \(d)日\(h)時間") }
        if h > 0 { return String(localized: "あと \(h)時間\(m)分") }
        return String(localized: "あと \(m)分")
    }

    static func absolute(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = Calendar.current.isDateInToday(date) ? todayFormatter : dateTimeFormatter
        return f.string(from: date)
    }
}
