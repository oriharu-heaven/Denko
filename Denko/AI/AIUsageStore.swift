import Combine
import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case claude, codex, gemini
    var id: String { rawValue }

    /// Whether this service seems to be used on this Mac (no secrets are read).
    var isDetected: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
        case .codex: return FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path)
        case .gemini: return FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini").path)
        }
    }

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    /// Short tag drawn before the ring when several AIs are shown in the menu bar.
    var tag: String {
        switch self {
        case .claude: return "Cl"
        case .codex: return "Cx"
        case .gemini: return "Gm"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "circle.hexagongrid"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "diamond"
        }
    }

    /// Window names shown before the first data arrives.
    var defaultLabels: (outer: String, inner: String) {
        switch self {
        case .claude, .codex: return (String(localized: "5時間枠"), String(localized: "週間"))
        case .gemini: return (String(localized: "1日"), String(localized: "1日（ほかのモデル）"))
        }
    }

    /// The services the user can turn on: Gemini only with 実験的 → Gemini on.
    @MainActor
    static func offered(_ settings: AppSettings) -> [AIProvider] {
        let gemini = settings.experimentalGemini
        return allCases.filter { $0 != .gemini || gemini }
    }

    var sourceNote: String {
        switch self {
        case .claude: return String(localized: "Claude Code がステータスラインに知らせる使用量から取得。Claude Code を使うと更新されます")
        case .codex: return String(localized: "Codex CLI のローカル記録（~/.codex/sessions）から取得。Codex を使うと更新されます")
        case .gemini: return String(localized: "Gemini CLI のログインで Google の利用枠を取得（実験的）")
        }
    }
}

/// One rate-limit window, normalized across providers.
struct AIWindow: Equatable {
    var label: String
    var percent: Double          // used, 0–100
    var resetsAt: Date?
    var windowMinutes: Double? = nil

    /// Compares used % against elapsed window % so developers can tell if they're burning
    /// through their quota faster than the reset clock.
    func paceStatus(now: Date = Date()) -> (text: String, isHigh: Bool)? {
        guard let resetsAt, percent > 0 else { return nil }
        let totalMinutes: Double
        if let windowMinutes, windowMinutes > 0 {
            totalMinutes = windowMinutes
        } else if label.contains("週間") {
            totalMinutes = 7 * 24 * 60
        } else if label.contains("5時間") {
            totalMinutes = 5 * 60
        } else if label.contains("1日") {
            totalMinutes = 24 * 60
        } else {
            return nil
        }
        let remaining = resetsAt.timeIntervalSince(now)
        let total = totalMinutes * 60
        guard remaining > 0, remaining < total else { return nil }
        let elapsedPercent = ((total - remaining) / total) * 100
        let diff = percent - elapsedPercent
        if diff >= 15 {
            return (String(localized: "ペース速め・経過\(Int(elapsedPercent.rounded()))%"), true)
        } else if elapsedPercent >= 10 && diff <= -15 {
            return (String(localized: "余裕あり・経過\(Int(elapsedPercent.rounded()))%"), false)
        }
        return (String(localized: "経過\(Int(elapsedPercent.rounded()))%"), false)
    }
}

struct AIUsage: Equatable {
    /// Shown as the outer ring (the short window, e.g. 5 hours).
    var primary: AIWindow?
    /// Shown as the inner ring (the long window, e.g. weekly).
    var secondary: AIWindow?
    /// Extra per-model windows shown only in the panel.
    var extras: [AIWindow] = []
    var updatedAt: Date
    var source: String
}

/// Usage for every enabled AI service. Claude comes from UsageStore (Claude Code's status line).
@MainActor
final class AIUsageStore: ObservableObject {
    @Published private(set) var usage: [AIProvider: AIUsage] = [:]
    @Published private(set) var errors: [AIProvider: String] = [:]
    @Published private(set) var isLoading = false

    let claude: UsageStore
    private let settings: AppSettings
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    init(claude: UsageStore, settings: AppSettings) {
        self.claude = claude
        self.settings = settings

        claude.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.syncClaude() }
            .store(in: &bag)
        settings.$aiProviders
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncClaude()
                Task { await self?.refreshOthers() }
            }
            .store(in: &bag)

        scheduleOthers()
        claude.$refreshMinutes
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.scheduleOthers() } }
            .store(in: &bag)
    }

    /// Codex's local logs are re-read on this interval (1 minute by default).
    private func scheduleOthers() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, claude.refreshMinutes) * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Claude's windows reset on the clock even when no new report arrives.
                self?.syncClaude()
                await self?.refreshOthers()
            }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var enabled: [AIProvider] { AIProvider.allCases.filter { settings.aiProviders.contains($0) } }

    func refresh() async {
        guard !Snapshot.isActive else { return }
        isLoading = true
        defer { isLoading = false }
        await claude.fetchNow()
        syncClaude()
        await refreshOthers()
    }

    private func syncClaude() {
        guard settings.aiProviders.contains(.claude) else {
            usage[.claude] = nil
            errors[.claude] = nil
            return
        }
        if let s = claude.snapshot {
            // A window whose reset time has passed since the last report is back to 0%.
            func window(_ w: UsageWindow, _ label: String, _ minutes: Double) -> AIWindow {
                if let r = w.resetsAt, r < Date() { return AIWindow(label: label, percent: 0, resetsAt: nil, windowMinutes: minutes) }
                return AIWindow(label: label, percent: w.utilization, resetsAt: w.resetsAt, windowMinutes: minutes)
            }
            let u = AIUsage(primary: s.fiveHour.map { window($0, String(localized: "5時間枠"), 300) },
                            secondary: s.sevenDay.map { window($0, String(localized: "週間"), 10_080) },
                            updatedAt: claude.lastUpdated ?? Date(),
                            source: "Claude Code")
            if usage[.claude] != u { usage[.claude] = u }
        }
        if errors[.claude] != claude.lastError { errors[.claude] = claude.lastError }
    }

    private func refreshOthers() async {
        guard !Snapshot.isActive else { return }
        for p in [AIProvider.codex, .gemini] {
            guard settings.aiProviders.contains(p), p != .gemini || settings.experimentalGemini else {
                usage[p] = nil
                errors[p] = nil
                continue
            }
            do {
                usage[p] = try await (p == .codex ? CodexUsage.fetch() : GeminiUsage.fetch())
                errors[p] = nil
            } catch {
                errors[p] = error.localizedDescription
            }
        }
    }
}

struct AIUsageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Codex (local session logs)

/// Codex CLI records the ChatGPT plan's rate limits in its session logs
/// (`event_msg` / `token_count` → `rate_limits.primary/secondary`). Reading the newest
/// one needs no credentials and no network.
enum CodexUsage {
    static func fetch() async throws -> AIUsage {
        try await Task.detached(priority: .utility) { try read() }.value
    }

    private static func read() throws -> AIUsage {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { throw AIUsageError(message: String(localized: "Codex CLI の記録が見つかりません（~/.codex/sessions）。Codex を一度使うと表示されます。")) }

        var files: [(URL, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            files.append((url, d))
        }
        for (url, modified) in files.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
                guard line.contains("rate_limits"),
                      let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                else { continue }
                let payload = obj["payload"] as? [String: Any] ?? obj
                guard let limits = payload["rate_limits"] as? [String: Any] else { continue }
                let stamp = (obj["timestamp"] as? String).flatMap(UsageWindow.parseDate) ?? modified
                return AIUsage(primary: window(limits["primary"], stamp: stamp),
                               secondary: window(limits["secondary"], stamp: stamp),
                               updatedAt: stamp, source: String(localized: "Codex CLI の記録"))
            }
        }
        throw AIUsageError(message: String(localized: "Codex の使用量の記録がまだありません。Codex を一度使うと表示されます。"))
    }

    private static func window(_ any: Any?, stamp: Date) -> AIWindow? {
        guard let w = any as? [String: Any], let used = w["used_percent"] as? Double else { return nil }
        let minutes = w["window_minutes"] as? Double ?? 0
        let label = minutes >= 1440 ? (minutes >= 10_080 ? String(localized: "週間") : String(localized: "\(Int(minutes / 1440))日")) : String(localized: "\(Int(max(minutes, 60) / 60))時間枠")
        var reset: Date?
        if let at = w["resets_at"] as? Double { reset = Date(timeIntervalSince1970: at) }
        else if let inS = w["resets_in_seconds"] as? Double { reset = stamp.addingTimeInterval(inS) }
        // A window that already reset since the log was written is back to 0%.
        if let r = reset, r < Date() { return AIWindow(label: label, percent: 0, resetsAt: nil, windowMinutes: minutes > 0 ? minutes : nil) }
        return AIWindow(label: label, percent: used, resetsAt: reset, windowMinutes: minutes > 0 ? minutes : nil)
    }
}
