import Foundation

/// Train service status from published open data only (公共交通オープンデータセンター):
/// - 都営: the public ODPT endpoint (CC BY 4.0, no key).
/// - With the user's own ODPT developer key: 東京メトロ, 横浜市営 and other operators that
///   publish under the ODPT basic license.
enum TrainFeed {
    struct Line: Identifiable, Equatable {
        var id: String { railway }
        let railway: String       // unique per source, e.g. "odpt:odpt.Railway:Toei.Asakusa"
        let company: String
        let name: String
        let region: String        // 関東 / 東北 / 信越 / 北陸 / 関西 / 中国
        /// "遅延", "運転見合わせ", … ("平常運転" when running normally)
        let status: String
        let note: String
        let isTrouble: Bool
        var url: URL? = nil
    }

    struct Result {
        /// Every line the sources reported, running normally or not (for the settings list).
        let all: [Line]
        var trouble: [Line] { all.filter(\.isTrouble) }
    }

    static let regions = ["関東", "東北", "信越", "北陸", "関西", "中国"]

    static let keychainAccount = "odptConsumerKey"
    static var hasKey: Bool { Keychain.exists(account: keychainAccount) }

    static let attribution = "このアプリケーション等が利用する公共交通データは、公共交通オープンデータセンターにおいて提供されるものです。公共交通事業者により提供されたデータを元にしていますが、必ずしも正確・完全なものとは限りません。本アプリケーションの表示内容について、公共交通事業者への直接の問合せは行わないでください。"

    /// Lines for the given regions (nil = every region, for the settings list).
    @MainActor
    static func fetch(regions wanted: Set<String>?) async -> Result? {
        guard wanted?.contains("関東") ?? true else { return Result(all: []) }
        guard let lines = await odpt() else { return nil }
        var seen = Set<String>()
        let all = lines.filter { seen.insert($0.railway).inserted }
        let order = Dictionary(uniqueKeysWithValues: regions.enumerated().map { ($1, $0) })
        return Result(all: all.sorted { (order[$0.region] ?? 9, $0.company) < (order[$1.region] ?? 9, $1.company) })
    }

    // MARK: ODPT (都営 without a key; more operators with the user's own key)

    /// Railway / operator titles, fetched once per key.
    @MainActor private static var titles: [String: String] = [:]
    @MainActor private static var titlesKey: String?

    @MainActor
    private static func odpt() async -> [Line]? {
        let key = Keychain.load(account: keychainAccount)
        let base = key == nil ? "https://api-public.odpt.org/api/v4/" : "https://api.odpt.org/api/v4/"
        func url(_ type: String) -> URL? {
            var c = URLComponents(string: base + type)
            if let key { c?.queryItems = [.init(name: "acl:consumerKey", value: key)] }
            return c?.url
        }
        guard let infoURL = url("odpt:TrainInformation"),
              let (data, resp) = try? await URLSession.shared.data(from: infoURL),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }

        if titlesKey != key || titles.isEmpty {
            titles = [:]
            for type in ["odpt:Railway", "odpt:Operator"] {
                guard let u = url(type), let (d, _) = try? await URLSession.shared.data(from: u),
                      let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { continue }
                for r in list {
                    guard let id = r["owl:sameAs"] as? String else { continue }
                    let ja = (r["odpt:railwayTitle"] as? [String: String])?["ja"]
                        ?? (r["odpt:operatorTitle"] as? [String: String])?["ja"]
                        ?? r["dc:title"] as? String
                    if let ja { titles[id] = ja }
                }
            }
            titlesKey = key
        }

        let lines: [Line] = items.compactMap { item in
            guard let railway = item["odpt:railway"] as? String else { return nil }
            let operatorID = item["odpt:operator"] as? String ?? ""
            let text = (item["odpt:trainInformationText"] as? [String: String])?["ja"] ?? ""
            let statusText = (item["odpt:trainInformationStatus"] as? [String: String])?["ja"]
            let normal = text.isEmpty || text.contains("遅延はありません") || text.contains("平常")
                || (statusText?.contains("平常") ?? false)
            let status = statusText
                ?? (text.contains("見合わせ") ? "運転見合わせ" : text.contains("運休") ? "運休" : "遅延")
            return Line(railway: "odpt:" + railway,
                        company: titles[operatorID] ?? fallbackOperator(operatorID),
                        name: titles[railway] ?? fallbackRailway(railway), region: "関東",
                        status: normal ? "平常運転" : status, note: text, isTrouble: !normal)
        }
        return lines
    }

    private static let toeiNames = [
        "Asakusa": "浅草線", "Mita": "三田線", "Shinjuku": "新宿線", "Oedo": "大江戸線",
        "Arakawa": "東京さくらトラム", "NipporiToneri": "日暮里・舎人ライナー",
    ]

    private static func fallbackRailway(_ id: String) -> String {
        let key = id.components(separatedBy: ".").last ?? id
        return toeiNames[key] ?? key
    }

    private static func fallbackOperator(_ id: String) -> String {
        id.hasSuffix("Toei") ? "東京都交通局" : (id.components(separatedBy: ":").last ?? id)
    }
}

/// Exchange rates from Frankfurter (European Central Bank reference rates; free, no key,
/// open data). Updated once each business day around 16:00 CET, so changes are day-on-day.
enum FXFeed {
    struct Quote: Identifiable, Equatable {
        var id: String { pair }
        let pair: String          // "USDJPY"
        let price: Double
        let previousClose: Double
        let date: String          // ECB fixing date, "2026-10-12"
        var change: Double { price - previousClose }
        var changePercent: Double { previousClose > 0 ? change / previousClose * 100 : 0 }
        var label: String { pair.count == 6 ? "\(pair.prefix(3))/\(pair.suffix(3))" : pair }
        var decimals: Int { pair.hasSuffix("JPY") ? 2 : 4 }
    }

    static let pairs = ["USDJPY", "EURJPY", "GBPJPY", "AUDJPY", "CNYJPY", "EURUSD"]

    static func fetch(_ pairs: [String]) async -> [Quote] {
        // One request per base currency, covering the last ~10 days (to get the previous fixing).
        let byBase = Dictionary(grouping: pairs.filter { $0.count == 6 }) { String($0.prefix(3)) }
        let from = Calendar.current.date(byAdding: .day, value: -10, to: Date()) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        var quotes: [String: Quote] = [:]
        for (base, list) in byBase {
            let symbols = list.map { String($0.suffix(3)) }.joined(separator: ",")
            guard let url = URL(string: "https://api.frankfurter.dev/v1/\(f.string(from: from))..?base=\(base)&symbols=\(symbols)"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rates = j["rates"] as? [String: [String: Double]] else { continue }
            let days = rates.keys.sorted()
            guard let last = days.last else { continue }
            let prev = days.count >= 2 ? days[days.count - 2] : last
            for pair in list {
                let quote = String(pair.suffix(3))
                guard let p = rates[last]?[quote] else { continue }
                quotes[pair] = Quote(pair: pair, price: p, previousClose: rates[prev]?[quote] ?? p, date: last)
            }
        }
        return pairs.compactMap { quotes[$0] }
    }
}
