import Foundation
import Security

enum Keychain {
    // MARK: - App's own items (ODPT / GitHub tokens)

    private static let service = "com.haru.Denko"
    /// Where secrets lived before the app was renamed to Denko.
    private static let legacyService = "com.haru.ClaudeUsageOnBar"

    /// Moves secrets saved under the old name to the new one. Checks with attribute-only
    /// queries first, so nothing is read (and no prompt can appear) unless an old item exists.
    static func migrateLegacy(accounts: [String]) {
        for account in accounts where !exists(account: account) {
            let attrs: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: account,
                kSecReturnAttributes as String: true,
            ]
            var out: AnyObject?
            guard SecItemCopyMatching(attrs as CFDictionary, &out) == errSecSuccess else { continue }
            var read = attrs
            read[kSecReturnAttributes as String] = nil
            read[kSecReturnData as String] = true
            guard SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data, let value = String(data: data, encoding: .utf8) else { continue }
            save(value, account: account)
            let old: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(old as CFDictionary)
        }
    }

    /// Generic secret stored under this app's own keychain service.
    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    static func save(_ value: String?, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Whether our own item exists — attributes only, so it never shows a password prompt.
    static func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }

    // MARK: - Claude Code OAuth credentials (read-only)

    /// Last-modified date of Claude Code's keychain item, read without its secret.
    /// Attribute-only queries never trigger the "allow access" password prompt, so this
    /// can be checked freely; the secret itself is read only when this date changes.
    static func claudeCodeItemModified() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let attrs = out as? [String: Any]
        else { return nil }
        return attrs[kSecAttrModificationDate as String] as? Date ?? Date.distantPast
    }

    struct ClaudeCodeToken {
        let accessToken: String
        let expiresAt: Date?
    }

    /// Reads the token Claude Code stores in the login keychain.
    /// Goes through /usr/bin/security because that binary is already on the item's ACL,
    /// so no extra keychain prompt is shown.
    static func loadClaudeCodeToken() -> ClaudeCodeToken? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }
        let expires = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCodeToken(accessToken: token, expiresAt: expires)
    }
}
