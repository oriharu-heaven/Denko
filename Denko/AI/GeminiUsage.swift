import Foundation

// MARK: - Gemini (Code Assist quota) — 実験的, off by default

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
            throw AIUsageError(message: String(localized: "Gemini の利用枠情報を取得できませんでした。"))
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
        guard let top = windows.first else { throw AIUsageError(message: String(localized: "Gemini の利用枠情報が空です。")) }
        // Outer ring: the most-used model's daily quota; inner: the next one.
        return AIUsage(primary: AIWindow(label: String(localized: "1日（\(top.label)）"), percent: top.percent, resetsAt: top.resetsAt),
                       secondary: windows.dropFirst().first.map {
                           AIWindow(label: String(localized: "1日（\($0.label)）"), percent: $0.percent, resetsAt: $0.resetsAt) },
                       extras: Array(windows.dropFirst(2).prefix(4)),
                       updatedAt: Date(), source: String(localized: "Gemini CLI のログイン"))
    }

    @MainActor
    private static func accessToken() async throws -> String {
        if let c = cachedToken, c.expires > Date().addingTimeInterval(60) { return c.token }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: url),
              let creds = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AIUsageError(message: String(localized: "Gemini CLI にログインしていません（~/.gemini/oauth_creds.json がありません）。")) }

        if let token = creds["access_token"] as? String, let ms = creds["expiry_date"] as? Double,
           Date(timeIntervalSince1970: ms / 1000) > Date().addingTimeInterval(60) {
            cachedToken = (token, Date(timeIntervalSince1970: ms / 1000))
            return token
        }
        guard let refresh = creds["refresh_token"] as? String else {
            throw AIUsageError(message: String(localized: "Gemini のログインが期限切れです。Gemini CLI を一度起動してください。"))
        }
        guard let client = await GeminiCLIClient.find() else {
            throw AIUsageError(message: String(localized: "Gemini のログインを更新するには、Gemini CLI がインストールされている必要があります。Gemini CLI を一度起動すると、しばらくは表示されます。"))
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
        else { throw AIUsageError(message: String(localized: "Gemini のログインを更新できませんでした。Gemini CLI を一度起動してください。")) }
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
        guard let project else { throw AIUsageError(message: String(localized: "Gemini の利用枠を確かめられませんでした。Gemini CLI で一度 Code Assist を使うと表示されるようになります。")) }
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
            throw AIUsageError(message: code == 401 || code == 403 ? String(localized: "ログインの期限切れ（gemini を一度起動すると直ります）") : String(localized: "取得できませんでした（\(code)）"))
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
