import Foundation

/// Claude's usage limits, the documented way: Claude Code hands its status line command the
/// session JSON, including `rate_limits.five_hour` / `seven_day` (Pro and Max plans).
/// Denko sets a small script as the status line in ~/.claude/settings.json. The script
/// forwards that JSON to the local endpoint, then runs the status line the user had before,
/// so their own status line keeps working. Only touched on the user's request; a
/// timestamped backup of settings.json is written first, and uninstalling puts the old
/// status line back.
enum ClaudeStatusLine {
    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Denko", isDirectory: true)
    }
    private static var scriptURL: URL { folder.appendingPathComponent("claude-statusline.sh") }
    /// The user's own status line command, run after forwarding (absent if they had none).
    private static var previousCommandURL: URL { folder.appendingPathComponent("claude-statusline-previous.sh") }
    /// The user's whole `statusLine` setting, restored on uninstall.
    private static var previousSettingURL: URL { folder.appendingPathComponent("claude-statusline-previous.json") }

    private static var command: String { "/bin/sh '\(scriptURL.path)'" }

    private static func script(endpoint: String) -> String {
        """
        #!/bin/sh
        # Denko: Claude Code の使用量（rate_limits）を Denko に渡してから、もとのステータスラインを表示します。
        input=$(cat)
        printf '%s' "$input" | curl -s -m 1 -X POST -H 'Content-Type: application/json' --data-binary @- '\(endpoint)?source=claude-statusline' >/dev/null 2>&1 &
        previous="$(dirname "$0")/claude-statusline-previous.sh"
        if [ -f "$previous" ]; then printf '%s' "$input" | /bin/sh "$previous"; fi
        exit 0

        """
    }

    /// True if Claude Code's status line is our script (for any port).
    static var isOurs: Bool {
        ((ClaudeCodeHooks.readSettings()?["statusLine"] as? [String: Any])?["command"] as? String) == command
    }

    /// True if Claude Code's status line is our script and it posts to this endpoint.
    static func isInstalled(endpoint: String) -> Bool {
        guard isOurs, let text = try? String(contentsOf: scriptURL, encoding: .utf8) else { return false }
        return text.contains(endpoint)
    }

    static func install(endpoint: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var root = ClaudeCodeHooks.readSettings() ?? [:]
        let current = root["statusLine"] as? [String: Any]
        let alreadyOurs = (current?["command"] as? String) == command
        if !alreadyOurs {
            // Remember the user's status line (or that there was none) before replacing it.
            try? fm.removeItem(at: previousCommandURL)
            try? fm.removeItem(at: previousSettingURL)
            if let current {
                try JSONSerialization.data(withJSONObject: current).write(to: previousSettingURL, options: .atomic)
                if let cmd = current["command"] as? String, !cmd.isEmpty {
                    try (cmd + "\n").write(to: previousCommandURL, atomically: true, encoding: .utf8)
                }
            }
        }
        try script(endpoint: endpoint).write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        guard !alreadyOurs else { return }
        try ClaudeCodeHooks.backup()
        // Keep the user's other options (padding, refreshInterval) and swap in our command.
        var line = current ?? [:]
        line["type"] = "command"
        line["command"] = command
        root["statusLine"] = line
        try ClaudeCodeHooks.write(root)
    }

    static func uninstall() throws {
        let fm = FileManager.default
        guard var root = ClaudeCodeHooks.readSettings(),
              ((root["statusLine"] as? [String: Any])?["command"] as? String) == command else { return }
        try ClaudeCodeHooks.backup()
        if let data = try? Data(contentsOf: previousSettingURL),
           let previous = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root["statusLine"] = previous
        } else {
            root["statusLine"] = nil
        }
        try ClaudeCodeHooks.write(root)
        try? fm.removeItem(at: scriptURL)
        try? fm.removeItem(at: previousCommandURL)
        try? fm.removeItem(at: previousSettingURL)
    }
}
