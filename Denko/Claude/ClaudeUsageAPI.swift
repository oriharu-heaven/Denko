import Foundation

/// 実験的: Claude's usage straight from Anthropic every minute, with Claude Code's own login
/// (read-only from the keychain). The endpoint isn't documented, so it may stop working, and
/// using a subscription token outside Claude Code may go against Anthropic's terms — which is
/// why it's off by default (設定 → 実験的) and the status line stays the normal route.
@MainActor
enum ClaudeUsageAPI {
    private static var tokenCache: Keychain.ClaudeCodeToken?
    /// Modification date of Claude Code's keychain item when we last read it.
    private static var tokenReadForItemDate: Date?

    static func fetch() async throws -> UsageSnapshot {
        if tokenCache == nil || tokenCache!.expiresAt.map({ $0 < Date() }) == true {
            // Reading the secret may show a keychain password prompt, so only do it when
            // Claude Code has actually written a new token since our last read.
            guard let itemDate = Keychain.claudeCodeItemModified() else { throw AIUsageError(message: "Claude Code にログインしていません") }
            if itemDate != tokenReadForItemDate {
                tokenReadForItemDate = itemDate
                tokenCache = Keychain.loadClaudeCodeToken()
            }
        }
        guard let token = tokenCache else { throw AIUsageError(message: "Claude Code にログインしていません") }
        if let exp = token.expiresAt, exp < Date() { throw AIUsageError(message: "ログインの期限切れ（claude を一度起動すると直ります）") }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw AIUsageError(message: code == 401 ? "ログインの期限切れ（claude を一度起動すると直ります）" : "取得できませんでした（\(code)）")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let snap = UsageSnapshot(api: json) else { throw AIUsageError(message: "形式が変わったため読み取れません") }
        return snap
    }
}
