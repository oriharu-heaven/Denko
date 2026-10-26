import Foundation

/// Adds / removes the Claude Code hooks (in ~/.claude/settings.json) that post
/// Notification and Stop events to the local endpoint. Only touched on the user's request;
/// a timestamped backup is written first.
enum ClaudeCodeHooks {
    static let events = ["Notification", "Stop"]
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static func command(endpoint: String) -> String {
        "curl -s -m 2 -X POST -H 'Content-Type: application/json' --data-binary @- '\(endpoint)?source=claude-code' >/dev/null 2>&1 || true"
    }

    /// True if every event has a hook pointing at this endpoint.
    static func isInstalled(endpoint: String) -> Bool {
        guard let root = readSettings(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains(endpoint) == true
                }
            }
        }
    }

    static func install(endpoint: String) throws {
        var root = readSettings() ?? [:]
        try backup()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = stripOurs(hooks[event] as? [[String: Any]] ?? [])
            groups.append(["hooks": [["type": "command", "command": command(endpoint: endpoint)]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try write(root)
    }

    static func uninstall() throws {
        guard var root = readSettings(), var hooks = root["hooks"] as? [String: Any] else { return }
        try backup()
        for event in events {
            let groups = stripOurs(hooks[event] as? [[String: Any]] ?? [])
            hooks[event] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try write(root)
    }

    /// Removes hook entries created by this app (any port / token) so reinstalling doesn't duplicate.
    private static func stripOurs(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            var g = group
            let kept = ((group["hooks"] as? [[String: Any]]) ?? []).filter {
                !(($0["command"] as? String)?.contains("127.0.0.1") == true
                  && ($0["command"] as? String)?.contains("/notify/") == true)
            }
            if kept.isEmpty { return nil }
            g["hooks"] = kept
            return g
        }
    }

    static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func backup() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "settings.json.backup-\(f.string(from: Date()))"
        let folder = settingsURL.deletingLastPathComponent()
        // Hooks and the status line can be changed in the same second (はじめに does both).
        var dest = folder.appendingPathComponent(base)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        try fm.copyItem(at: settingsURL, to: dest)
    }

    static func write(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
