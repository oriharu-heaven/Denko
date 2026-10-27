import Foundation

/// One rate-limit window as Claude Code reports it to its status line.
struct UsageWindow: Codable, Equatable {
    /// 0–100
    let utilization: Double
    let resetsAt: Date?

    /// ISO 8601 with or without fractional seconds (Codex's session logs).
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

struct UsageSnapshot: Codable, Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?

    /// Reads `rate_limits` from Claude Code's status line JSON
    /// (`five_hour` / `seven_day`: `used_percentage` 0–100, `resets_at` in Unix seconds).
    init?(statusLine json: [String: Any]) {
        guard let limits = json["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let w = limits[key] as? [String: Any],
                  let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return UsageWindow(utilization: used, resetsAt: reset)
        }
        fiveHour = window("five_hour")
        sevenDay = window("seven_day")
        if fiveHour == nil && sevenDay == nil { return nil }
    }

    /// Reads the usage API's JSON (`five_hour` / `seven_day`: `utilization` 0–100,
    /// `resets_at` as ISO 8601). Used by 実験的 → リアルタイム.
    init?(api json: [String: Any]) {
        func window(_ key: String) -> UsageWindow? {
            guard let w = json[key] as? [String: Any],
                  let used = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(utilization: used, resetsAt: (w["resets_at"] as? String).flatMap(UsageWindow.parseDate))
        }
        fiveHour = window("five_hour")
        sevenDay = window("seven_day")
        if fiveHour == nil && sevenDay == nil { return nil }
    }
}
