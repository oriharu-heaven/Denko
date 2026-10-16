import Combine
import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case claude, codex, gemini
    var id: String { rawValue }

    /// Whether this service seems to be used on this Mac (no secrets are read).
    var isDetected: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return Keychain.claudeCodeItemModified() != nil
            || FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
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
        case .claude, .codex: return ("5時間枠", "週間")
        case .gemini: return ("1日", "1日（ほかのモデル）")
        }
    }

    var sourceNote: String {
        switch self {
        case .claude: return "Claude Code のログイン情報、または claude.ai のセッションキーから取得"
        case .codex: return "Codex CLI のローカル記録（~/.codex/sessions）から取得。Codex を使うと更新されます"
        case .gemini: return "Gemini CLI のログイン情報で Google の利用枠を取得（実験的）"
        }
    }
}

/// One rate-limit window, normalized across providers.
struct AIWindow: Equatable {
    var label: String
    var percent: Double          // used, 0–100
    var resetsAt: Date?
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

/// Usage for every enabled AI service. Claude reuses the existing UsageStore.
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

    /// Codex / Gemini refresh on the same interval as Claude (1 minute by default).
    private func scheduleOthers() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, claude.refreshMinutes) * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refreshOthers() }
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
        if settings.aiProviders.contains(.claude) { await claude.refresh() }
        await refreshOthers()
    }

    private func syncClaude() {
        claude.isEnabled = settings.aiProviders.contains(.claude)
        guard settings.aiProviders.contains(.claude) else {
            usage[.claude] = nil
            errors[.claude] = nil
            return
        }
        if let s = claude.snapshot {
            var extras: [AIWindow] = []
            if let o = s.sevenDayOpus { extras.append(AIWindow(label: "週間 Opus", percent: o.utilization, resetsAt: o.resetsAt)) }
            if let n = s.sevenDaySonnet { extras.append(AIWindow(label: "週間 Sonnet", percent: n.utilization, resetsAt: n.resetsAt)) }
            let u = AIUsage(primary: s.fiveHour.map { AIWindow(label: "5時間枠", percent: $0.utilization, resetsAt: $0.resetsAt) },
                            secondary: s.sevenDay.map { AIWindow(label: "週間", percent: $0.utilization, resetsAt: $0.resetsAt) },
                            extras: extras, updatedAt: claude.lastUpdated ?? Date(),
                            source: claude.source?.rawValue ?? "Claude")
            if usage[.claude] != u { usage[.claude] = u }
        }
        if errors[.claude] != claude.lastError { errors[.claude] = claude.lastError }
    }

    private func refreshOthers() async {
        guard !Snapshot.isActive else { return }
        for p in [AIProvider.codex, .gemini] {
            guard settings.aiProviders.contains(p) else {
                usage[p] = nil
                errors[p] = nil
                continue
            }
            do {
                let u = try await (p == .codex ? CodexUsage.fetch() : GeminiUsage.fetch())
                usage[p] = u
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
        else { throw AIUsageError(message: "Codex CLI の記録が見つかりません（~/.codex/sessions）。Codex を一度使うと表示されます。") }

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
                               updatedAt: stamp, source: "Codex CLI の記録")
            }
        }
        throw AIUsageError(message: "Codex の使用量の記録がまだありません。Codex を一度使うと表示されます。")
    }

    private static func window(_ any: Any?, stamp: Date) -> AIWindow? {
        guard let w = any as? [String: Any], let used = w["used_percent"] as? Double else { return nil }
        let minutes = w["window_minutes"] as? Double ?? 0
        let label = minutes >= 1440 ? (minutes >= 10_080 ? "週間" : "\(Int(minutes / 1440))日") : "\(Int(max(minutes, 60) / 60))時間枠"
        var reset: Date?
        if let at = w["resets_at"] as? Double { reset = Date(timeIntervalSince1970: at) }
        else if let inS = w["resets_in_seconds"] as? Double { reset = stamp.addingTimeInterval(inS) }
        // A window that already reset since the log was written is back to 0%.
        if let r = reset, r < Date() { return AIWindow(label: label, percent: 0, resetsAt: nil) }
        return AIWindow(label: label, percent: used, resetsAt: reset)
    }
}

// MARK: - Gemini (Code Assist quota, experimental)

/// Uses the Gemini CLI's own login (~/.gemini/oauth_creds.json, read-only) to ask Google
/// for the remaining request quota per model. The access token is refreshed in memory
/// only; the CLI's files are never modified.
enum GeminiUsage {
    private static let endpoint = "https://cloudcode-pa.googleapis.com/v1internal"

    @MainActor private static var cachedToken: (token: String, expires: Date)?
    @MainActor private static var cachedProject: String?

    @MainActor
    static func fetch() async throws -> AIUsage {
        let token = try await accessToken()
        let project = try await projectID(token: token)
        let json = try await post("\(endpoint):retrieveUserQuota", token: token, body: ["project": project])
        guard let buckets = json["buckets"] as? [[String: Any]], !buckets.isEmpty else {
            throw AIUsageError(message: "Gemini の利用枠情報を取得できませんでした。")
        }
        var windows: [AIWindow] = []
        for b in buckets {
            guard let remaining = (b["remainingFraction"] as? Double) ?? Double(b["remainingFraction"] as? String ?? "")
            else { continue }
            let model = (b["modelId"] as? String ?? "Gemini")
                .replacingOccurrences(of: "gemini-", with: "")
            let reset = (b["resetTime"] as? String).flatMap(UsageWindow.parseDate)
            windows.append(AIWindow(label: model, percent: (1 - remaining) * 100, resetsAt: reset))
        }
        windows.sort { $0.percent > $1.percent }
        guard let top = windows.first else { throw AIUsageError(message: "Gemini の利用枠情報が空です。") }
        // Outer ring: the most-used model's daily quota; inner: the next one.
        return AIUsage(primary: AIWindow(label: "1日（\(top.label)）", percent: top.percent, resetsAt: top.resetsAt),
                       secondary: windows.dropFirst().first.map {
                           AIWindow(label: "1日（\($0.label)）", percent: $0.percent, resetsAt: $0.resetsAt) },
                       extras: Array(windows.dropFirst(2).prefix(4)),
                       updatedAt: Date(), source: "Gemini CLI のログイン")
    }

    @MainActor
    private static func accessToken() async throws -> String {
        if let c = cachedToken, c.expires > Date().addingTimeInterval(60) { return c.token }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: url),
              let creds = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AIUsageError(message: "Gemini CLI にログインしていません（~/.gemini/oauth_creds.json がありません）。") }

        if let token = creds["access_token"] as? String, let ms = creds["expiry_date"] as? Double,
           Date(timeIntervalSince1970: ms / 1000) > Date().addingTimeInterval(60) {
            cachedToken = (token, Date(timeIntervalSince1970: ms / 1000))
            return token
        }
        guard let refresh = creds["refresh_token"] as? String else {
            throw AIUsageError(message: "Gemini のログインが期限切れです。Gemini CLI を一度起動してください。")
        }
        guard let client = await GeminiCLIClient.find() else {
            throw AIUsageError(message: "Gemini のログインを更新するには、Gemini CLI がインストールされている必要があります。Gemini CLI を一度起動すると、しばらくは表示されます。")
        }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = ["client_id": client.id, "client_secret": client.secret,
                    "refresh_token": refresh, "grant_type": "refresh_token"]
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let token = j["access_token"] as? String
        else { throw AIUsageError(message: "Gemini のログインを更新できませんでした。Gemini CLI を一度起動してください。") }
        let expires = Date().addingTimeInterval(j["expires_in"] as? Double ?? 3000)
        cachedToken = (token, expires)
        return token
    }

    @MainActor
    private static func projectID(token: String) async throws -> String {
        if let p = cachedProject { return p }
        let json = try await post("\(endpoint):loadCodeAssist", token: token, body: [
            "metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"],
        ])
        let project = json["cloudaicompanionProject"] as? String
            ?? (json["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
        guard let project else { throw AIUsageError(message: "Gemini の利用枠を確かめられませんでした。Gemini CLI で一度 Code Assist を使うと表示されるようになります。") }
        cachedProject = project
        return project
    }

    private static func post(_ url: String, token: String, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIUsageError(message: UsageError.friendly(code: code, service: "Gemini"))
        }
        return json
    }
}

/// The OAuth client the Gemini CLI signs in with. Its token can only be refreshed with the
/// same client, so it's read from the installed Gemini CLI rather than kept in this source.
enum GeminiCLIClient {
    struct Client: Sendable { let id: String; let secret: String }

    @MainActor private static var cached: Client?

    @MainActor
    static func find() async -> Client? {
        if let cached { return cached }
        let found = await Task.detached(priority: .utility) { search() }.value
        cached = found
        return found
    }

    /// Package folders of the Gemini CLI in the usual install locations (Homebrew, npm, nvm, Volta).
    private static func packageFolders() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var prefixes = ["/opt/homebrew", "/usr/local", "\(home)/.npm-global", "\(home)/.volta/tools/image/packages/@google/gemini-cli"]
        for cellar in ["/opt/homebrew/Cellar/gemini-cli", "/usr/local/Cellar/gemini-cli"] {
            let versions = (try? fm.contentsOfDirectory(atPath: cellar)) ?? []
            prefixes += versions.sorted(by: >).map { "\(cellar)/\($0)/libexec" }
        }
        let nvm = "\(home)/.nvm/versions/node"
        prefixes += ((try? fm.contentsOfDirectory(atPath: nvm)) ?? []).sorted(by: >).map { "\(nvm)/\($0)" }
        return prefixes
            .map { URL(fileURLWithPath: $0).appendingPathComponent("lib/node_modules/@google/gemini-cli") }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    private static func search() -> Client? {
        let fm = FileManager.default
        for package in packageFolders() {
            // Older releases keep the constants in gemini-cli-core; newer ones bundle everything.
            var files = [package.appendingPathComponent("node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js")]
            let bundle = package.appendingPathComponent("bundle")
            files += ((try? fm.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "js" }
            for file in files {
                if let client = read(file) { return client }
            }
        }
        return nil
    }

    private static let marker = Data("OAUTH_CLIENT_SECRET".utf8)

    /// Reads `OAUTH_CLIENT_ID = "…"` and `OAUTH_CLIENT_SECRET = "…"` from a script file.
    private static func read(_ file: URL) -> Client? {
        // Memory-mapped and checked for the marker first: the bundled files are ~16 MB each.
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped),
              let hit = data.range(of: marker) else { return nil }
        let start = max(data.startIndex, hit.lowerBound - 4096)
        let end = min(data.endIndex, hit.upperBound + 4096)
        let text = String(decoding: data[start..<end], as: UTF8.self)
        func value(_ name: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: name + #"\s*=\s*["']([^"']+)["']"#),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        guard let id = value("OAUTH_CLIENT_ID"), id.hasSuffix(".apps.googleusercontent.com"),
              let secret = value("OAUTH_CLIENT_SECRET") else { return nil }
        return Client(id: id, secret: secret)
    }
}
