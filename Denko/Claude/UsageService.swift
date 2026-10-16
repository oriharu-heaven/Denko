import Foundation

enum UsageService {
    private static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    // Keychain reads are cached so a refresh doesn't spawn /usr/bin/security every time.
    private static var sessionKeyLoaded = false
    private static var sessionKeyCache: String?
    private static var tokenCache: Keychain.ClaudeCodeToken?
    /// Modification date of Claude Code's keychain item when we last read it.
    private static var tokenReadForItemDate: Date?

    static var cachedSessionKey: String? {
        if !sessionKeyLoaded {
            // Only read (which can prompt) when a key was actually saved.
            sessionKeyCache = Keychain.exists(account: "claude.ai-sessionKey") ? Keychain.loadSessionKey() : nil
            sessionKeyLoaded = true
        }
        return sessionKeyCache
    }

    static func setSessionKey(_ key: String?) {
        Keychain.saveSessionKey(key)
        sessionKeyCache = key
        sessionKeyLoaded = true
    }

    /// claude.ai session key takes priority when set; otherwise falls back to Claude Code's OAuth token.
    static func fetch() async throws -> (UsageSnapshot, UsageSource) {
        if let key = cachedSessionKey {
            return (try await fetchWeb(sessionKey: key), .claudeWeb)
        }
        if tokenCache == nil || tokenCache!.expiresAt.map({ $0 < Date() }) == true {
            // Reading the secret may show a keychain password prompt, so only do it when
            // Claude Code has actually written a new token since our last read.
            guard let itemDate = Keychain.claudeCodeItemModified() else { throw UsageError.noCredentials }
            if itemDate != tokenReadForItemDate {
                tokenReadForItemDate = itemDate
                tokenCache = Keychain.loadClaudeCodeToken()
            }
        }
        guard let token = tokenCache else { throw UsageError.noCredentials }
        if let exp = token.expiresAt, exp < Date() { throw UsageError.tokenExpired }
        do {
            return (try await fetchOAuth(token: token.accessToken), .claudeCode)
        } catch UsageError.tokenExpired {
            // Keep the cached (expired) token: it's re-read only after Claude Code updates the item.
            throw UsageError.tokenExpired
        }
    }

    // MARK: - Claude Code OAuth

    private static func fetchOAuth(token: String) async throws -> UsageSnapshot {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await send(req, expiredOn401: true)
        return try decode(data)
    }

    // MARK: - claude.ai web

    private static func webRequest(_ url: URL, sessionKey: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private static func fetchWeb(sessionKey: String) async throws -> UsageSnapshot {
        let orgID = try await organizationID(sessionKey: sessionKey)
        let url = URL(string: "https://claude.ai/api/organizations/\(orgID)/usage")!
        let data = try await send(webRequest(url, sessionKey: sessionKey), expiredOn401: false)
        return try decode(data)
    }

    private static var cachedOrg: (key: String, id: String)?

    private static func organizationID(sessionKey: String) async throws -> String {
        if let c = cachedOrg, c.key == sessionKey { return c.id }
        let url = URL(string: "https://claude.ai/api/organizations")!
        let data = try await send(webRequest(url, sessionKey: sessionKey), expiredOn401: false)
        guard let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UsageError.noOrganization
        }
        // Prefer an org that has chat capability (personal plan), else the first one.
        let pick = orgs.first { ($0["capabilities"] as? [String])?.contains("chat") == true } ?? orgs.first
        guard let id = pick?["uuid"] as? String else { throw UsageError.noOrganization }
        cachedOrg = (sessionKey, id)
        return id
    }

    // MARK: - Helpers

    private static func send(_ req: URLRequest, expiredOn401: Bool) async throws -> Data {
        var req = req
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401, expiredOn401 { throw UsageError.tokenExpired }
            throw UsageError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func decode(_ data: Data) throws -> UsageSnapshot {
        do {
            return try JSONDecoder().decode(UsageSnapshot.self, from: data)
        } catch {
            throw UsageError.decoding(error.localizedDescription)
        }
    }
}
