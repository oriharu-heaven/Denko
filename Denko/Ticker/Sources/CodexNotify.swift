import Foundation

/// Codex CLI's `notify` setting (~/.codex/config.toml): Codex runs the given program with a
/// JSON payload as its last argument after each turn. We point it at curl, which posts the
/// JSON to the local endpoint. Only changed on the user's request, with a backup first.
enum CodexNotify {
    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path)
    }

    static func line(endpoint: String) -> String {
        "notify = [\"curl\", \"-s\", \"-m\", \"2\", \"-X\", \"POST\", \"\(endpoint)?source=codex\", \"--data-binary\"]"
    }

    private static func read() -> String { (try? String(contentsOf: configURL, encoding: .utf8)) ?? "" }

    /// Index of the top-level `notify = …` line, if any (before the first [table]).
    private static func notifyLine(in lines: [String]) -> Int? {
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { return nil }
            if t.hasPrefix("notify") && t.dropFirst(6).trimmingCharacters(in: .whitespaces).hasPrefix("=") { return i }
        }
        return nil
    }

    static func isInstalled(endpoint: String) -> Bool { read().contains("\(endpoint)?source=codex") }

    enum InstallError: LocalizedError {
        case otherNotify
        var errorDescription: String? {
            String(localized: "~/.codex/config.toml にはすでに別の notify 設定があります。上書きしないので、INTEGRATIONS.md の手順で手動で追加してください。")
        }
    }

    static func install(endpoint: String) throws {
        var lines = read().components(separatedBy: "\n")
        if let i = notifyLine(in: lines) {
            guard lines[i].contains("/notify/") && lines[i].contains("127.0.0.1") else { throw InstallError.otherNotify }
            lines[i] = line(endpoint: endpoint)            // ours, maybe with an old token/port
        } else {
            lines.insert(line(endpoint: endpoint), at: 0)  // top level, before any [table]
        }
        try backup()
        try write(lines.joined(separator: "\n"))
    }

    static func uninstall() throws {
        var lines = read().components(separatedBy: "\n")
        guard let i = notifyLine(in: lines), lines[i].contains("/notify/"), lines[i].contains("127.0.0.1") else { return }
        try backup()
        lines.remove(at: i)
        try write(lines.joined(separator: "\n"))
    }

    private static func backup() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configURL.path) else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        try fm.copyItem(at: configURL, to: configURL.deletingLastPathComponent()
            .appendingPathComponent("config.toml.backup-\(f.string(from: Date()))"))
    }

    private static func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }
}
