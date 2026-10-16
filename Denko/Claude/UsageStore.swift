import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var source: UsageSource?
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = false

    @Published var refreshMinutes: Int {
        didSet {
            UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes")
            scheduleTimer()
        }
    }

    private var timer: Timer?
    /// Fetch only while Claude is enabled under AI usage.
    var isEnabled: Bool = (UserDefaults.standard.stringArray(forKey: "aiProviders") ?? []).contains("claude") {
        didSet { if isEnabled && !oldValue { Task { await refresh() } } }
    }

    init() {
        let d = UserDefaults.standard
        refreshMinutes = d.object(forKey: "refreshMinutes") as? Int ?? 1
        scheduleTimer()
        Task { await refresh() }
    }

    func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, refreshMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        timer?.tolerance = 10
    }

    func refresh() async {
        guard isEnabled, !isLoading, !Snapshot.isActive else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (snap, src) = try await UsageService.fetch()
            snapshot = snap
            source = src
            lastError = nil
            lastUpdated = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setSessionKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        UsageService.setSessionKey(trimmed.isEmpty ? nil : trimmed)
        Task { await refresh() }
    }

    var hasSessionKey: Bool { UsageService.cachedSessionKey != nil }
}

enum TimeText {
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
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d(E) HH:mm"
        return f.string(from: date)
    }
}
