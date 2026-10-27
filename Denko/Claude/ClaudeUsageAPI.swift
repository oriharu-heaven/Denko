import Foundation

/// 実験: Claude's usage straight from Anthropic every few minutes — with Claude Code's own
/// login (read-only from the keychain), or a claude.ai session key the user pastes in. The endpoint isn't documented, so it may stop working, and
/// using a subscription token outside Claude Code may go against Anthropic's terms — which is
/// why it's off by default (設定 → 実験的) and the status line stays the normal route.
@MainActor
enum ClaudeUsageAPI {
    static let sessionKeyAccount = "claude.ai-sessionKey"
    private static var tokenCache: Keychain.ClaudeCodeToken?
    private static var orgCache: (key: String, id: String)?
    /// Modification date of Claude Code's keychain item when we last read it.
    private static var tokenReadForItemDate: Date?

    /// With a session key, claude.ai's own usage; otherwise Claude Code's login.
    static func fetch(useSessionKey: Bool) async throws -> UsageSnapshot {
        if useSessionKey {
            guard let key = Keychain.load(account: sessionKeyAccount) else { throw AIUsageError(message: String(localized: "セッションキーが未設定")) }
            return try await fetchWeb(sessionKey: key)
        }
        return try await fetchWithClaudeCode()
    }

    private static func fetchWithClaudeCode() async throws -> UsageSnapshot {
        if tokenCache == nil || tokenCache!.expiresAt.map({ $0 < Date() }) == true {
            // Reading the secret may show a keychain password prompt, so only do it when
            // Claude Code has actually written a new token since our last read.
            guard let itemDate = Keychain.claudeCodeItemModified() else { throw AIUsageError(message: String(localized: "Claude Code にログインしていません")) }
            if itemDate != tokenReadForItemDate {
                tokenReadForItemDate = itemDate
                tokenCache = Keychain.loadClaudeCodeToken()
            }
        }
        guard let token = tokenCache else { throw AIUsageError(message: String(localized: "Claude Code にログインしていません")) }
        if let exp = token.expiresAt, exp < Date() { throw AIUsageError(message: String(localized: "ログインの期限切れ（claude を一度起動すると直ります）")) }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw AIUsageError(message: code == 401 ? String(localized: "ログインの期限切れ（claude を一度起動すると直ります）") : String(localized: "取得できませんでした（\(code)）"))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let snap = UsageSnapshot(api: json) else { throw AIUsageError(message: String(localized: "形式が変わったため読み取れません")) }
        return snap
    }

    // MARK: - claude.ai session key

    private static func webRequest(_ url: URL, sessionKey: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        return req
    }

    private static func fetchWeb(sessionKey: String) async throws -> UsageSnapshot {
        let org = try await organizationID(sessionKey: sessionKey)
        let data = try await get(webRequest(URL(string: "https://claude.ai/api/organizations/\(org)/usage")!, sessionKey: sessionKey))
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let snap = UsageSnapshot(api: json) else { throw AIUsageError(message: String(localized: "形式が変わったため読み取れません")) }
        return snap
    }

    /// The account's organization (the one with chat, i.e. the personal plan).
    private static func organizationID(sessionKey: String) async throws -> String {
        if let c = orgCache, c.key == sessionKey { return c.id }
        let data = try await get(webRequest(URL(string: "https://claude.ai/api/organizations")!, sessionKey: sessionKey))
        let orgs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let pick = orgs.first { ($0["capabilities"] as? [String])?.contains("chat") == true } ?? orgs.first
        guard let id = pick?["uuid"] as? String else { throw AIUsageError(message: String(localized: "アカウントを確認できません")) }
        orgCache = (sessionKey, id)
        return id
    }

    private static func get(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw AIUsageError(message: code == 401 || code == 403 ? String(localized: "セッションキーの期限切れ") : String(localized: "取得できませんでした（\(code)）"))
        }
        return data
    }
}
