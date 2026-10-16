import Foundation

/// One rate-limit window as returned by the usage endpoint.
struct UsageWindow: Decodable, Equatable {
    /// 0–100
    let utilization: Double
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = (try? c.decode(Double.self, forKey: .utilization)) ?? 0
        if let s = try? c.decode(String.self, forKey: .resetsAt) {
            resetsAt = UsageWindow.parseDate(s)
        } else {
            resetsAt = nil
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

struct UsageSnapshot: Decodable, Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

enum UsageSource: String {
    case claudeCode = "Claude Code"
    case claudeWeb = "claude.ai"
}

enum UsageError: LocalizedError {
    /// What happened and what to do, for an HTTP status (no raw response bodies).
    static func friendly(code: Int, service: String) -> String {
        switch code {
        case 401, 403: return "\(service) のログインの有効期限が切れたようです。ターミナルで一度 \(service == "Claude" ? "claude" : "gemini") を起動すると更新されます。"
        case 429: return "\(service) が混み合っています。しばらくしてから自動でもう一度取得します。"
        case 500...599: return "\(service) 側で一時的な問題が起きています。しばらくしてから自動でもう一度取得します。"
        default: return "\(service) の使用量を取得できませんでした（エラー \(code)）。しばらくしてから自動でもう一度取得します。"
        }
    }

    case noCredentials
    case tokenExpired
    case http(Int, String)
    case noOrganization
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "認証情報が見つかりません。設定で claude.ai のセッションキーを入れるか、ターミナルで `claude` にログインしてください。"
        case .tokenExpired:
            return "Claude Code のトークンが期限切れです。ターミナルで `claude` を一度起動すると更新されます（または設定でセッションキーを使用）。"
        case .http(let code, _):
            return UsageError.friendly(code: code, service: "Claude")
        case .noOrganization:
            return "claude.ai の組織情報を取得できませんでした。"
        case .decoding:
            return "使用量の形式が変わったため読み取れませんでした。Denko のアップデートをお待ちください。"
        }
    }
}
