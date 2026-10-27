import Foundation

/// Train service status.
/// Official open data (always):
/// - 都営: the public ODPT endpoint (CC BY 4.0, no key).
/// - With the user's own ODPT developer key: 東京メトロ, 横浜市営 and other operators that
///   publish under the ODPT basic license.
/// Experimental (設定 → 実験的, off by default, at the user's own risk): the companies' own
/// status pages, which have no published feed —
/// - JR東日本（関東・東北・信越）: the status pages (read by their CSS class names).
/// - JR西日本（近畿・北陸・岡山・広島・山陰）: the JSON behind the train guide.
/// - 東京メトロ: the JSON behind the status page.
/// - 京王・京急・近鉄: the status pages, read as one line per company ("平常通り" shown or not).
/// Only the sources for the regions / lines being watched are fetched.
enum TrainFeed {
    struct Line: Identifiable, Equatable {
        var id: String { railway }
        let railway: String       // unique per source, e.g. "jr-east:kanto:山手線"
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

    private static let agent = "Mozilla/5.0 (Macintosh) Denko"

    private static func get(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Lines for the given regions (nil = every region, for the settings list).
    @MainActor
    static func fetch(regions wanted: Set<String>?, unofficial: Bool) async -> Result? {
        func wants(_ r: String) -> Bool { wanted?.contains(r) ?? true }
        var tasks: [() async -> [Line]?] = []
        if wants("関東") { tasks.append { await odpt() } }
        if unofficial { addUnofficial(to: &tasks, wants: wants) }
        var all: [Line] = []
        var anyOK = false
        await withTaskGroup(of: [Line]?.self) { group in
            for t in tasks { group.addTask { await t() } }
            for await lines in group {
                if let lines { anyOK = true; all += lines }
            }
        }
        guard anyOK else { return nil }
        // ODPT (with a key) may also report メトロ; keep the status page's copy.
        var seen = Set<String>()
        let official = Set(all.filter { !$0.railway.hasPrefix("odpt") }.map { "\($0.company)|\($0.name)" })
        all = all.filter { line in
            if line.railway.hasPrefix("odpt"), official.contains("\(line.company)|\(line.name)") { return false }
            return seen.insert(line.railway).inserted
        }
        let order = Dictionary(uniqueKeysWithValues: regions.enumerated().map { ($1, $0) })
        return Result(all: all.sorted { (order[$0.region] ?? 9, $0.company) < (order[$1.region] ?? 9, $1.company) })
    }

    /// The companies' own status pages (no published feed).
    @MainActor
    private static func addUnofficial(to tasks: inout [() async -> [Line]?], wants: (String) -> Bool) {
        for (area, region) in [("kanto", "関東"), ("tohoku", "東北"), ("shinetsu", "信越")] where wants(region) {
            tasks.append { await jrEast(area: area, region: region) }
        }
        for (area, region) in [("kinki", "関西"), ("hokuriku", "北陸"), ("okayama", "中国"),
                               ("hiroshima", "中国"), ("sanin", "中国")] where wants(region) {
            tasks.append { await jrWest(area: area, region: region) }
        }
        if wants("関東") {
            tasks.append { await tokyoMetro() }
            tasks.append { await companyPage(company: "京王電鉄", name: "京王線・井の頭線", region: "関東",
                                             url: "https://www.keio.co.jp/unkou/unkou_pc.html",
                                             normal: "平常通り運転しています") }
            tasks.append { await companyPage(company: "京急電鉄", name: "京急線", region: "関東",
                                             url: "https://unkou.keikyu.co.jp/",
                                             normal: "平常通り運転しています") }
        }
        if wants("関西") {
            tasks.append { await companyPage(company: "近畿日本鉄道", name: "近鉄線", region: "関西",
                                             url: "https://www.kintetsu.jp/unkou/unkou.html",
                                             normal: "遅れはございません") }
        }
    }

    // MARK: JR東日本 (status pages, one per area)

    private static func jrEast(area: String, region: String) async -> [Line]? {
        let page = "https://traininfo.jreast.co.jp/train_info/\(area).aspx"
        guard let data = await get(page) else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        func value(_ cls: String, in chunk: String) -> String? {
            guard let r = chunk.range(of: "class=\"\(cls)"),
                  let gt = chunk[r.upperBound...].firstIndex(of: ">") else { return nil }
            let rest = chunk[chunk.index(after: gt)...]
            let text = rest.components(separatedBy: "</").first ?? ""
            return text.replacingOccurrences(of: "<span>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out: [Line] = []
        var seen = Set<String>()
        // One chunk per line row; normal lines have no note, so each row is read on its own.
        for chunk in html.components(separatedBy: "traininfo-routes__table__item").dropFirst() {
            guard let name = value("traininfo-routes__name", in: chunk), !name.isEmpty,
                  let statusRange = chunk.range(of: "traininfo-routes__status ") else { continue }
            let cls = String(chunk[statusRange.upperBound...].prefix { $0.isLetter })
            // Some areas put a time ("１４時３０分頃") in the status cell; fall back to a label then.
            var statusText = value("traininfo-routes__status \(cls)", in: chunk) ?? ""
            if statusText.isEmpty || statusText.range(of: "[0-9０-９]", options: .regularExpression) != nil {
                statusText = cls == "normal" ? "平常運転" : "運行情報あり"
            }
            let note = value("traininfo-routes__note", in: chunk) ?? ""
            let trouble = cls == "delay" || cls == "adjust"
            let id = "jr-east:\(area):\(name)"
            if seen.contains(name) {
                // A line can have several notices; keep the most serious one.
                if trouble, let i = out.firstIndex(where: { $0.name == name && !$0.isTrouble }) {
                    out[i] = Line(railway: id, company: "JR東日本", name: name, region: region,
                                  status: statusText, note: note, isTrouble: true, url: URL(string: page))
                }
                continue
            }
            seen.insert(name)
            out.append(Line(railway: id, company: "JR東日本", name: name, region: region,
                            status: cls == "normal" ? "平常運転" : statusText, note: cls == "normal" ? "" : note,
                            isTrouble: trouble, url: URL(string: page)))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: JR西日本 (train guide JSON: line list + current incidents per area)

    @MainActor private static var westMasters: [String: [String: String]] = [:]

    @MainActor
    private static func jrWest(area: String, region: String) async -> [Line]? {
        let base = "https://www.train-guide.westjr.co.jp/api/v3/area_\(area)"
        if westMasters[area] == nil,
           let data = await get(base + "_master.json"),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lines = j["lines"] as? [String: [String: Any]] {
            westMasters[area] = lines.compactMapValues { $0["name"] as? String }
        }
        guard let names = westMasters[area],
              let data = await get(base + "_trafficinfo.json"),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let incidents = j["lines"] as? [String: [String: Any]] ?? [:]
        let page = URL(string: "https://trafficinfo.westjr.co.jp/\(area).html")
        return names.map { id, name in
            if let inc = incidents[id] {
                let section = (inc["section"] as? [String: String]).map { "\($0["from"] ?? "")〜\($0["to"] ?? "")" } ?? ""
                let cause = inc["cause"] as? String ?? ""
                return Line(railway: "jr-west:\(area):\(id)", company: "JR西日本", name: name, region: region,
                            status: inc["status"] as? String ?? "遅延",
                            note: [section, cause].filter { !$0.isEmpty }.joined(separator: "　"),
                            isTrouble: true, url: page)
            }
            return Line(railway: "jr-west:\(area):\(id)", company: "JR西日本", name: name, region: region,
                        status: "平常運転", note: "", isTrouble: false, url: page)
        }
    }

    // MARK: 東京メトロ (JSON behind the official status page)

    private static func tokyoMetro() async -> [Line]? {
        guard let data = await get("https://www.tokyometro.jp/library/common/operation/status.json"),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jp = j["jp"] as? [String: Any], let lines = jp["lines"] as? [[String: Any]] else { return nil }
        let page = URL(string: "https://www.tokyometro.jp/unkou/")
        return lines.compactMap { l in
            guard let name = l["line_name"] as? String else { return nil }
            let normal = (l["status"] as? Int ?? 0) == 0
            let note = (l["contents"] as? String ?? "")
                .replacingOccurrences(of: "<br>", with: " ")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return Line(railway: "metro:\(name)", company: "東京メトロ", name: name, region: "関東",
                        status: normal ? "平常運転" : (l["status_info"] as? String ?? "遅延"),
                        note: normal ? "" : note, isTrouble: !normal, url: page)
        }
    }

    // MARK: Company pages (one line per company)

    /// Reads a company's status page: running normally if `normal` appears. If the page loads but
    /// the phrase is missing, there's an incident (details on the company's site).
    private static func companyPage(company: String, name: String, region: String, url: String, normal: String) async -> [Line]? {
        guard let data = await get(url), data.count > 5_000 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let ok = text.contains(normal) || text.replacingOccurrences(of: "１５", with: "15").contains(normal)
        return [Line(railway: "company:\(company)", company: company, name: name, region: region,
                     status: ok ? "平常運転" : "運行情報あり",
                     note: ok ? "" : "遅れや運転見合わせが出ています。詳しくは公式サイトをご覧ください。",
                     isTrouble: !ok, url: URL(string: url))]
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
