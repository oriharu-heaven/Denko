import Foundation
import SwiftUI

/// Claude's usage limits as Claude Code last reported them to its status line
/// (see ClaudeStatusLine). Nothing is fetched over the network; the latest report is kept
/// across launches.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastUpdated: Date?

    /// How often Codex's local logs are re-read (Claude updates whenever Claude Code reports).
    @Published var refreshMinutes: Int {
        didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes") }
    }

    var lastError: String? {
        snapshot == nil ? "Claude Code を使うと表示されます（Pro・Max プランのとき、Claude Code が使用量を知らせます）。" : nil
    }

    private static let storeKey = "claudeStatusLineUsage"
    private static let dateKey = "claudeStatusLineUpdated"

    init() {
        let d = UserDefaults.standard
        refreshMinutes = d.object(forKey: "refreshMinutes") as? Int ?? 1
        if let data = d.data(forKey: Self.storeKey) {
            snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        }
        lastUpdated = d.object(forKey: Self.dateKey) as? Date
    }

    /// A status line report from Claude Code (the JSON it passes to its status line).
    func receive(statusLine json: [String: Any]) {
        guard let snap = UsageSnapshot(statusLine: json) else { return }
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
        if s <= 0 { return "まもなくリセット" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "あと \(d)日\(h)時間" }
        if h > 0 { return "あと \(h)時間\(m)分" }
        return "あと \(m)分"
    }

    static func absolute(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = Calendar.current.isDateInToday(date) ? todayFormatter : dateTimeFormatter
        return f.string(from: date)
    }
}
