import Foundation

/// GitHub notifications (personal access token with the `notifications` scope).
/// Honors Last-Modified / X-Poll-Interval, so polling is a cheap 304 most of the time.
@MainActor
final class GitHubSource {
    static let keychainAccount = "github-token"

    private let hub: NotificationHub
    private var timer: Timer?
    private var lastModified: String?
    private var seen = Set<String>()
    private var primed = false
    private var interval: TimeInterval = 60

    init(hub: NotificationHub) { self.hub = hub }

    /// Existence check without reading the secret (never prompts).
    var hasToken: Bool { cachedToken != nil || Keychain.exists(account: Self.keychainAccount) }
    /// Read once per launch; the keychain is only touched again if the token changes.
    private var cachedToken: String?

    private func token() -> String? {
        if cachedToken == nil { cachedToken = Keychain.load(account: Self.keychainAccount) }
        return cachedToken
    }

    func setToken(_ token: String?) {
        let value = token?.isEmpty == true ? nil : token
        Keychain.save(value, account: Self.keychainAccount)
        cachedToken = value
        reset()
    }

    func setEnabled(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on, hasToken else { return }
        Task { await poll() }
    }

    private func reset() {
        lastModified = nil
        seen = []
        primed = false
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { await self?.poll() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func poll() async {
        defer { schedule() }
        guard let token = token() else { return }
        var req = URLRequest(url: URL(string: "https://api.github.com/notifications")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let lastModified { req.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return }
        if let p = http.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(Double.init) { interval = max(60, p) }
        if http.statusCode == 401 {
            hub.post(.github, title: String(localized: "トークンが無効です"), body: String(localized: "設定 → 掲示板 で GitHub トークンを確認してください"))
            timer?.invalidate()
            return
        }
        guard http.statusCode == 200,
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        lastModified = http.value(forHTTPHeaderField: "Last-Modified")

        var fresh: [[String: Any]] = []
        for item in items {
            guard let id = item["id"] as? String else { continue }
            let key = "\(id)|\(item["updated_at"] as? String ?? "")"
            if seen.insert(key).inserted { fresh.append(item) }
        }
        // First run: don't replay the existing backlog, just summarize it.
        if !primed {
            primed = true
            if !items.isEmpty { hub.post(.github, kind: .githubOther, title: String(localized: "未読の通知が \(items.count) 件あります")) }
            return
        }
        for item in fresh.reversed() {
            let subject = item["subject"] as? [String: Any]
            let repo = (item["repository"] as? [String: Any])?["full_name"] as? String ?? ""
            let title = subject?["title"] as? String ?? String(localized: "通知")
            let kind = Self.kindLabel(subject?["type"] as? String, reason: item["reason"] as? String)
            // Things that need the user (review requests, mentions, assignments) are urgent.
            let reason = item["reason"] as? String ?? ""
            let urgent = ["review_requested", "mention", "team_mention", "assign"].contains(reason)
            hub.post(.github, kind: urgent ? .githubReview : .githubOther, title: "\(repo) \(kind)", body: title, url: Self.htmlURL(item))
        }
    }

    private static func kindLabel(_ type: String?, reason: String?) -> String {
        switch reason {
        case "review_requested": return String(localized: "レビュー依頼")
        case "mention", "team_mention": return String(localized: "メンション")
        case "ci_activity": return "CI"
        case "assign": return String(localized: "アサイン")
        default: break
        }
        switch type {
        case "PullRequest": return "PR"
        case "Issue": return "Issue"
        case "Release": return String(localized: "リリース")
        case "CheckSuite": return "CI"
        default: return type ?? ""
        }
    }

    /// api.github.com/repos/o/r/pulls/1 → github.com/o/r/pull/1
    private static func htmlURL(_ item: [String: Any]) -> URL? {
        if let api = (item["subject"] as? [String: Any])?["url"] as? String {
            let web = api.replacingOccurrences(of: "https://api.github.com/repos/", with: "https://github.com/")
                .replacingOccurrences(of: "/pulls/", with: "/pull/")
            if let u = URL(string: web) { return u }
        }
        return ((item["repository"] as? [String: Any])?["html_url"] as? String).flatMap(URL.init(string:))
    }
}

/// RSS / Atom feeds. New entries after the first fetch are posted.
@MainActor
final class RSSSource {
    private let hub: NotificationHub
    private var timer: Timer?
    private var seen: [String: Set<String>] = [:]
    private var feeds: [String] = []

    init(hub: NotificationHub) { self.hub = hub }

    func configure(enabled: Bool, feeds: [String], minutes: Int) {
        timer?.invalidate()
        timer = nil
        self.feeds = feeds.filter { URL(string: $0)?.scheme?.hasPrefix("http") == true }
        guard enabled, !self.feeds.isEmpty else { return }
        Task { await pollAll() }
        let interval = TimeInterval(max(5, minutes) * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.pollAll() }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func pollAll() async {
        for feed in feeds { await poll(feed) }
    }

    private func poll(_ feed: String) async {
        guard let url = URL(string: feed),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        let parsed = FeedParser.parse(data)
        let first = seen[feed] == nil
        var known = seen[feed] ?? []
        var fresh: [FeedParser.Entry] = []
        for e in parsed.entries where known.insert(e.id).inserted { fresh.append(e) }
        seen[feed] = known
        guard !first else { return }
        for e in fresh.prefix(5).reversed() {
            hub.post(.rss, kind: .rss, title: e.title, body: parsed.title, url: e.link.flatMap(URL.init(string:)))
        }
    }
}

/// Minimal RSS 2.0 / Atom parser: feed title + entries (id, title, link).
final class FeedParser: NSObject, XMLParserDelegate {
    struct Entry { var id = ""; var title = ""; var link: String? }

    private(set) var title: String?
    private(set) var entries: [Entry] = []
    private var current: Entry?
    private var text = ""

    static func parse(_ data: Data) -> (title: String?, entries: [Entry]) {
        let p = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return (p.title, p.entries)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "item" || name == "entry" { current = Entry() }
        if name == "link", current != nil, let href = attributes["href"],
           attributes["rel"] == nil || attributes["rel"] == "alternate" {
            current?.link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if var e = current {
            switch name {
            case "title": e.title = value
            case "link": if !value.isEmpty { e.link = value }
            case "guid", "id": e.id = value
            case "item", "entry":
                if e.id.isEmpty { e.id = e.link ?? e.title }
                if !e.title.isEmpty { entries.append(e) }
                current = nil
                return
            default: break
            }
            current = e
        } else if name == "title", title == nil {
            title = value
        }
    }
}

/// Alerts generated by the app itself (Claude usage thresholds, sleep prevention ending).
@MainActor
final class BuiltInAlerts {
    private let hub: NotificationHub
    private let settings: AppSettings
    private var lastFive: Double?
    private var wasAwake = false

    init(hub: NotificationHub, settings: AppSettings) {
        self.hub = hub
        self.settings = settings
    }

    func usageChanged(_ snapshot: UsageSnapshot?) {
        guard let five = snapshot?.fiveHour?.utilization else { return }
        defer { lastFive = five }
        guard settings.alertClaudeUsage, let prev = lastFive else { return }
        for threshold in [80.0, 100.0] where prev < threshold && five >= threshold {
            let reset = TimeText.untilReset(snapshot?.fiveHour?.resetsAt)
            hub.post(.system, kind: .aiUsage, title: String(localized: "Claude 5時間枠が \(Int(threshold))% に達しました"), body: String(localized: "リセット \(reset)"))
        }
        if prev >= 50 && five < 5 {
            hub.post(.system, kind: .aiUsage, title: String(localized: "Claude 5時間枠がリセットされました"))
        }
    }

    func awakeChanged(isActive: Bool) {
        defer { wasAwake = isActive }
        if settings.alertAwake, wasAwake, !isActive {
            hub.post(.system, kind: .awakeEnded, title: String(localized: "スリープ防止が終了しました"))
        }
    }
}
