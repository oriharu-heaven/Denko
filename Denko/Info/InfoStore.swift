import CoreLocation
import Foundation

/// "今日" feed: weather (Open-Meteo), top news (Yahoo!ニュース), and trending searches
/// (Google トレンド). New news / coming rain / the morning forecast are also announced on
/// the board through the notification hub.
@MainActor
final class InfoStore: ObservableObject {
    struct Weather: Equatable {
        var temperature: Double
        var code: Int
        var high: Double
        var low: Double
        var rainChance: Int
        /// e.g. "15時ごろから雨（60%）"
        var rainSoon: String?
        var updated: Date
        /// The next 12 hours.
        var hourly: [Hour] = []
    }

    struct Hour: Equatable, Identifiable {
        var id: Int { hour }
        let hour: Int
        let temperature: Double
        let rain: Int
        let code: Int
    }

    /// Last disaster notice that was posted (for the panel's status card).
    @Published private(set) var lastDisaster: (title: String, date: Date)?

    struct NewsItem: Identifiable, Equatable {
        let id: String
        let title: String
        let url: URL?
        let date: Date?
    }

    struct Trend: Identifiable, Equatable {
        let id: String
        let word: String
        let traffic: String?
    }

    @Published private(set) var weather: Weather?
    @Published private(set) var news: [NewsItem] = []
    @Published private(set) var trends: [Trend] = []
    @Published private(set) var error: String?
    /// Feeds whose last fetch failed ("news", "trains"), so the panel can say so instead of
    /// showing "読み込み中…" forever.
    @Published private(set) var failed: Set<String> = []
    /// Watched lines that aren't running normally (nil = not loaded yet / failed).
    @Published private(set) var trains: [TrainFeed.Line]?
    @Published private(set) var fx: [FXFeed.Quote] = []
    /// Every line the train source reports (for choosing lines in settings).
    @Published private(set) var allTrainLines: [TrainFeed.Line] = []

    private let settings: AppSettings
    private let hub: NotificationHub
    private var timers: [Timer] = []
    private var seenNews = Set<String>()
    private var newsPrimed = false
    private var lastRainAlert: Date?
    private var trainsPrimed = false
    private var troubleKeys = Set<String>()

    init(settings: AppSettings, hub: NotificationHub) {
        self.settings = settings
        self.hub = hub
        schedule()
    }

    func schedule() {
        timers.forEach { $0.invalidate() }
        timers = []
        func every(_ seconds: TimeInterval, _ work: @escaping () async -> Void) {
            Task { await work() }
            let t = Timer(timeInterval: seconds, repeats: true) { _ in Task { await work() } }
            t.tolerance = seconds * 0.1
            RunLoop.main.add(t, forMode: .common)
            timers.append(t)
        }
        if settings.infoWeather { every(30 * 60) { [weak self] in await self?.refreshWeather() } }
        if settings.infoNews {
            every(settings.performance.newsSeconds) { [weak self] in await self?.refreshNews() }
        }
        if settings.infoTrends { every(30 * 60) { [weak self] in await self?.refreshTrends() } }
        if settings.infoDisaster {
            // Quakes / tsunami every minute (an unchanged feed is a tiny 304), warnings less often.
            every(60) { [weak self] in await self?.refreshDisaster(feed: "eqvol.xml") }
            every(settings.performance.disasterWarningSeconds) { [weak self] in await self?.refreshDisaster(feed: "extra.xml") }
        }
        if settings.infoTrains { every(settings.performance.trainSeconds) { [weak self] in await self?.refreshTrains() } }
        if settings.infoFX { every(60 * 60) { [weak self] in await self?.refreshFX() } }
        scheduleRoll()
    }

    // MARK: - Periodic roll on the board

    private var rollTimer: Timer?

    func scheduleRoll() {
        rollTimer?.invalidate()
        rollTimer = nil
        guard settings.infoRollMinutes > 0 else { return }
        let interval = TimeInterval(settings.infoRollMinutes * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.roll() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        rollTimer = t
    }

    private var rollIndex = 0

    /// Headlines already played on the board (by id), so each one appears only once. Kept
    /// across launches; trimmed to the most recent 500.
    private var shownNews: [String] = UserDefaults.standard.stringArray(forKey: "shownNews") ?? []

    private var unshownNews: [NewsItem] { news.filter { !shownNews.contains($0.id) } }

    private func markShown(_ items: [NewsItem]) {
        let ids = items.map(\.id).filter { !shownNews.contains($0) }
        guard !ids.isEmpty else { return }
        shownNews = Array((shownNews + ids).suffix(500))
        UserDefaults.standard.set(shownNews, forKey: "shownNews")
    }

    /// One pass of "today". Not added to the history. Every few minutes or more often, one
    /// short topic at a time in rotation (weather → a headline → trains → FX → …);
    /// less often, everything in one go.
    func roll() {
        if settings.infoRollMinutes > 0 && settings.infoRollMinutes <= 5 {
            let cards = rollCards()
            guard !cards.isEmpty else { return }
            let card = cards[rollIndex % cards.count]
            rollIndex += 1
            hub.post(card.source, kind: .todayRoll, title: card.text, url: card.source == .news ? news.first { $0.title == card.text }?.url : nil,
                     record: false)
            if card.source == .news { markShown(news.filter { $0.title == card.text }) }
            return
        }
        let text = rollText()
        guard !text.isEmpty else { return }
        hub.post(.today, kind: .todayRoll, title: text, record: false)
        if settings.infoNews { markShown(Array(unshownNews.prefix(3))) }
    }

    /// Short single topics for the rotating roll; headlines advance one by one.
    private func rollCards() -> [(source: TickerSource, text: String)] {
        var cards: [(TickerSource, String)] = []
        if settings.infoWeather, let w = weather {
            cards.append((.weather, "\(settings.weatherPlace) \(Int(w.temperature.rounded()))° \(WeatherCode.text(w.code))"
                + "（最高\(Int(w.high.rounded()))° 最低\(Int(w.low.rounded()))° 降水\(w.rainChance)%）"
                + (w.rainSoon.map { " \($0)" } ?? "")))
        }
        // Headlines: only ones not played yet (two slots per rotation).
        let fresh = settings.infoNews ? unshownNews : []
        if let first = fresh.first { cards.append((.news, first.title)) }
        if settings.infoTrains, let trains {
            let trouble = Self.uniqueLines(trains.filter(\.isTrouble))
            cards.append((.train, trouble.isEmpty ? "登録した路線は平常運転です" : trouble.joined(separator: "・")))
        }
        if settings.infoFX, !fx.isEmpty {
            cards.append((.fx, fx.map { "\($0.label) \(Self.price($0))（\(Self.percent($0.changePercent))）" }
                .joined(separator: "  ")))
        }
        if fresh.count > 1 { cards.append((.news, fresh[1].title)) }
        if settings.infoTrends, !trends.isEmpty {
            cards.append((.today, "トレンド " + trends.prefix(5).map(\.word).joined(separator: "・")))
        }
        return cards
    }

    func rollText() -> String {
        var cards: [String] = []
        if settings.infoWeather, let w = weather {
            cards.append("天気 \(settings.weatherPlace) \(Int(w.temperature.rounded()))° \(WeatherCode.text(w.code))"
                + "（最高\(Int(w.high.rounded()))° 最低\(Int(w.low.rounded()))° 降水\(w.rainChance)%）"
                + (w.rainSoon.map { " \($0)" } ?? ""))
        }
        if settings.infoNews, !unshownNews.isEmpty {
            cards.append("ニュース " + unshownNews.prefix(3).map(\.title).joined(separator: " ／ "))
        }
        if settings.infoTrends, !trends.isEmpty {
            cards.append("トレンド " + trends.prefix(5).map(\.word).joined(separator: "・"))
        }
        if settings.infoTrains, let trains {
            let trouble = trains.filter(\.isTrouble)
            cards.append(trouble.isEmpty
                ? "運行情報 \(settings.trainLines.isEmpty ? "首都圏の" : "登録した")路線は平常運転"
                : "運行情報 " + Self.uniqueLines(trouble).joined(separator: "・"))
        }
        if settings.infoFX, !fx.isEmpty {
            cards.append("為替 " + fx.map { "\($0.label) \(Self.price($0))（\(Self.percent($0.changePercent))）" }
                .joined(separator: "  "))
        }
        return cards.joined(separator: "　◆　")
    }

    func refreshAll() async {
        if settings.infoWeather { await refreshWeather() }
        if settings.infoNews { await refreshNews() }
        if settings.infoTrends { await refreshTrends() }
        if settings.infoTrains { await refreshTrains() }
        if settings.infoFX { await refreshFX() }
    }

    // MARK: - 防災 (気象庁)

    private let disaster = DisasterFeed()

    func refreshDisaster(feed: String) async {
        for n in await disaster.poll(feed: feed, prefecture: settings.weatherPrefecture) {
            hub.post(.weather, kind: n.kind, title: n.title, body: n.body, url: n.url)
            lastDisaster = (n.title, Date())
        }
    }

    // MARK: - Trains

    func isWatched(_ line: TrainFeed.Line) -> Bool { settings.trainLines.contains(line.name) }

    /// Stop watching a line (from the panel's menu).
    func unwatch(_ name: String) {
        settings.trainLines.removeAll { $0 == name }
        trains?.removeAll { $0.name == name }
    }

    /// Regions whose sources must be read for the watched lines (nil = all, when unknown).
    private var watchedRegions: Set<String>? {
        let known = allTrainLines.filter { settings.trainLines.contains($0.name) }
        guard Set(known.map(\.name)).count == Set(settings.trainLines).count else { return nil }
        return Set(known.map(\.region))
    }

    /// `everything`: read every region (for choosing lines in Settings).
    func refreshTrains(everything: Bool = false) async {
        // Nothing picked yet: nothing to read until the user chooses lines.
        if !everything && settings.trainLines.isEmpty { trains = []; troubleKeys = []; return }
        let regions = everything ? nil : watchedRegions
        guard let result = await TrainFeed.fetch(regions: regions) else { failed.insert("trains"); return }
        failed.remove("trains")
        if let regions {
            // Keep the other regions' lines for the settings list.
            allTrainLines = allTrainLines.filter { !regions.contains($0.region) } + result.all
        } else {
            allTrainLines = result.all
        }
        let lines = result.all.filter(isWatched)
        trains = lines
        // A watched line newly in trouble → urgent; a line back to normal → plain notice.
        let keys = Set(lines.filter(\.isTrouble).map { "\($0.company)|\($0.name)|\($0.status)" })
        defer { troubleKeys = keys; trainsPrimed = true }
        guard settings.announceTrains else { return }
        let fresh = lines.filter { $0.isTrouble && !troubleKeys.contains("\($0.company)|\($0.name)|\($0.status)") }
        let names = Self.uniqueLines(fresh)
        if names.count == 1 {
            hub.post(.train, kind: .trainDelay, title: names[0], body: fresh.first?.note)
        } else if !names.isEmpty {
            hub.post(.train, kind: .trainDelay, title: names.joined(separator: "・"))
        }
        guard trainsPrimed else { return }
        let nowTrouble = Set(lines.filter(\.isTrouble).map(\.name))
        let recovered = Set(troubleKeys.compactMap { $0.split(separator: "|").dropFirst().first.map(String.init) })
            .subtracting(nowTrouble)
        for name in recovered.sorted() {
            hub.post(.train, kind: .trainRecovered, title: "\(name)は平常運転に戻りました")
        }
    }

    /// "総武本線 一部運休" once per line+status.
    static func uniqueLines(_ lines: [TrainFeed.Line]) -> [String] {
        var seen = Set<String>()
        return lines.map { "\($0.name) \($0.status)" }.filter { seen.insert($0).inserted }
    }

    // MARK: - FX

    func refreshFX() async {
        let quotes = await FXFeed.fetch(settings.fxPairs)
        guard !quotes.isEmpty else { return }
        fx = quotes
        // Big move from the previous fixing: urgent, once per pair and fixing date.
        guard settings.fxAlertPercent > 0 else { return }
        for q in quotes where abs(q.changePercent) >= settings.fxAlertPercent {
            let key = "fxAlert-\(q.pair)-\(q.date)"
            guard !UserDefaults.standard.bool(forKey: key) else { continue }
            UserDefaults.standard.set(true, forKey: key)
            let word = q.pair.hasSuffix("JPY") ? (q.change > 0 ? "円安" : "円高") : (q.change > 0 ? "上昇" : "下落")
            hub.post(.fx, kind: .fxMove, title: "\(q.label) \(Self.price(q))　前日比 \(Self.percent(q.changePercent))の\(word)",
                     body: "前営業日 \(String(format: "%.\(q.decimals)f", q.previousClose))（ECB 参考レート）")
        }
    }

    static func price(_ q: FXFeed.Quote) -> String { String(format: "%.\(q.decimals)f", q.price) }
    static func percent(_ p: Double) -> String { String(format: "%+.2f%%", p) }

    // MARK: - Weather (Open-Meteo, no account needed)

    func refreshWeather() async {
        let lat = settings.weatherLatitude, lon = settings.weatherLongitude
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "hourly", value: "precipitation_probability,temperature_2m,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code"),
            .init(name: "forecast_days", value: "2"), .init(name: "timezone", value: "auto"),
        ]
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = j["current"] as? [String: Any], let daily = j["daily"] as? [String: Any]
        else { error = "天気を取得できませんでした"; return }

        func first(_ key: String) -> Double? { (daily[key] as? [Double])?.first ?? (daily[key] as? [Int])?.first.map(Double.init) }
        var rainSoon: String?
        var hours: [Hour] = []
        if let hourly = j["hourly"] as? [String: Any], let times = hourly["time"] as? [String],
           let probs = hourly["precipitation_probability"] as? [Int] {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd'T'HH:mm"
            f.timeZone = TimeZone(secondsFromGMT: (j["utc_offset_seconds"] as? Int) ?? 0)
            let now = Date()
            let temps = hourly["temperature_2m"] as? [Double] ?? []
            let codes = hourly["weather_code"] as? [Int] ?? []
            for (i, t) in times.enumerated() where hours.count < 12 {
                guard let d = f.date(from: t), d > now.addingTimeInterval(-3600) else { continue }
                hours.append(Hour(hour: Calendar.current.component(.hour, from: d),
                                  temperature: i < temps.count ? temps[i] : 0,
                                  rain: i < probs.count ? probs[i] : 0, code: i < codes.count ? codes[i] : 0))
            }
            for (t, p) in zip(times, probs) {
                guard let d = f.date(from: t), d > now, d < now.addingTimeInterval(6 * 3600) else { continue }
                if p >= 50 {
                    let h = Calendar.current.component(.hour, from: d)
                    rainSoon = "\(h)時ごろから雨（\(p)%）"
                    break
                }
            }
        }
        let w = Weather(temperature: cur["temperature_2m"] as? Double ?? 0,
                        code: cur["weather_code"] as? Int ?? 0,
                        high: first("temperature_2m_max") ?? 0, low: first("temperature_2m_min") ?? 0,
                        rainChance: Int(first("precipitation_probability_max") ?? 0),
                        rainSoon: rainSoon, updated: Date(), hourly: hours)
        let previous = weather
        weather = w
        error = nil
        announceWeather(w, previous: previous)
    }

    private func announceWeather(_ w: Weather, previous: Weather?) {
        // Coming rain: at most once every 3 hours.
        if settings.announceRain, let soon = w.rainSoon,
           lastRainAlert.map({ Date().timeIntervalSince($0) > 3 * 3600 }) ?? true {
            lastRainAlert = Date()
            hub.post(.weather, kind: .weatherRain, title: "\(settings.weatherPlace)：\(soon)", body: "傘を忘れずに")
        }
        // Morning forecast: first update after 6:00 each day.
        let cal = Calendar.current
        let key = "morningWeather-\(cal.component(.year, from: Date()))-\(cal.ordinality(of: .day, in: .year, for: Date()) ?? 0)"
        if settings.announceMorning, cal.component(.hour, from: Date()) >= 6,
           !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            hub.post(.weather, kind: .weatherMorning, title: "今日の\(settings.weatherPlace)は\(WeatherCode.text(w.code))",
                     body: "最高\(Int(w.high.rounded()))° 最低\(Int(w.low.rounded()))° 降水\(w.rainChance)%")
        }
    }

    /// Looks up a place name (Japanese works) with Apple's geocoder — no location permission needed.
    func setPlace(_ name: String) async -> Bool {
        guard let placemark = try? await CLGeocoder().geocodeAddressString(name).first,
              let loc = placemark.location else { return false }
        settings.weatherPlace = placemark.locality ?? placemark.name ?? name
        settings.weatherLatitude = loc.coordinate.latitude
        settings.weatherLongitude = loc.coordinate.longitude
        if let pref = placemark.administrativeArea { settings.weatherPrefecture = pref }
        await refreshWeather()
        return true
    }

    // MARK: - News (Yahoo!ニュース トピックス)

    func refreshNews() async {
        guard let url = URL(string: settings.newsFeed.url),
              let (data, _) = try? await URLSession.shared.data(from: url) else { failed.insert("news"); return }
        failed.remove("news")
        let parsed = FeedParser.parse(data)
        let items = parsed.entries.prefix(10).map { e in
            NewsItem(id: e.id, title: e.title, url: e.link.flatMap(URL.init(string:)), date: nil)
        }
        news = Array(items)
        // Announce headlines that appear after the first load.
        let fresh = items.filter { seenNews.insert($0.id).inserted }
        if newsPrimed && settings.announceNews {
            for item in fresh.prefix(3).reversed() {
                // Breaking news (速報) gets the whole bar.
                hub.post(.news, kind: item.title.contains("速報") ? .newsBreaking : .newsNew, title: item.title, url: item.url)
            }
            markShown(Array(fresh.prefix(3)))
        }
        newsPrimed = true
    }

    // MARK: - Trends (Google トレンド の急上昇ワード)

    func refreshTrends() async {
        guard let url = URL(string: "https://trends.google.co.jp/trending/rss?geo=JP"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        // The JP feed also carries foreign match-ups ("persib bandung vs dewa united"):
        // drop Latin-only phrases of three or more words.
        let looksForeign: (String) -> Bool = { w in
            let latinOnly = w.unicodeScalars.allSatisfy { $0.isASCII }
            return latinOnly && w.split(separator: " ").count >= 3
        }
        trends = TrendParser.parse(data).filter { !looksForeign($0.word) }.prefix(12)
            .map { Trend(id: $0.word, word: $0.word, traffic: $0.traffic) }
    }
}

/// Major news sources (Japan and overseas) with their public RSS / Atom feeds.
enum NewsCatalog {
    struct Category: Identifiable, Hashable {
        let id: String
        let label: String
        let url: String
    }

    struct Source: Identifiable, Hashable {
        let id: String
        let name: String
        let overseas: Bool
        let categories: [Category]
    }

    private static func c(_ id: String, _ label: String, _ url: String) -> Category { Category(id: id, label: label, url: url) }

    static let sources: [Source] = {
        let nhk = "https://news.web.nhk/n-data/conf/na/rss/"
        let yahoo = "https://news.yahoo.co.jp/rss/topics/"
        let google = "https://news.google.com/rss/headlines/section/topic/"
        let ja = "?hl=ja&gl=JP&ceid=JP:ja"
        let bbc = "https://feeds.bbci.co.uk/news/"
        let nyt = "https://rss.nytimes.com/services/xml/rss/nyt/"
        return [
            // 国内
            Source(id: "nhk", name: "NHK", overseas: false, categories: [
                c("top", "主要", nhk + "cat0.xml"), c("society", "社会", nhk + "cat1.xml"),
                c("politics", "政治", nhk + "cat4.xml"), c("economy", "経済", nhk + "cat5.xml"),
                c("world", "国際", nhk + "cat6.xml"), c("science", "科学・文化", nhk + "cat3.xml"),
                c("sports", "スポーツ", nhk + "cat7.xml"),
            ]),
            Source(id: "yahoo", name: "Yahoo!ニュース", overseas: false, categories: [
                c("top", "主要", yahoo + "top-picks.xml"), c("domestic", "国内", yahoo + "domestic.xml"),
                c("world", "国際", yahoo + "world.xml"), c("economy", "経済", yahoo + "business.xml"),
                c("it", "IT", yahoo + "it.xml"), c("science", "科学", yahoo + "science.xml"),
                c("entertainment", "エンタメ", yahoo + "entertainment.xml"), c("sports", "スポーツ", yahoo + "sports.xml"),
            ]),
            Source(id: "google", name: "Google ニュース", overseas: false, categories: [
                c("top", "主要", "https://news.google.com/rss" + ja), c("economy", "経済", google + "BUSINESS" + ja),
                c("tech", "テクノロジー", google + "TECHNOLOGY" + ja), c("science", "科学", google + "SCIENCE" + ja),
                c("entertainment", "エンタメ", google + "ENTERTAINMENT" + ja), c("sports", "スポーツ", google + "SPORTS" + ja),
            ]),
            Source(id: "asahi", name: "朝日新聞", overseas: false, categories: [
                c("top", "主要", "https://www.asahi.com/rss/asahi/newsheadlines.rdf"),
            ]),
            Source(id: "mainichi", name: "毎日新聞", overseas: false, categories: [
                c("top", "速報", "https://mainichi.jp/rss/etc/mainichi-flash.rss"),
            ]),
            Source(id: "jiji", name: "時事通信", overseas: false, categories: [
                c("top", "注目", "https://www.jiji.com/rss/ranking.rdf"),
            ]),
            Source(id: "toyokeizai", name: "東洋経済", overseas: false, categories: [
                c("top", "最新", "https://toyokeizai.net/list/feed/rss"),
            ]),
            Source(id: "itmedia", name: "ITmedia", overseas: false, categories: [
                c("top", "総合", "https://rss.itmedia.co.jp/rss/2.0/itmedia_all.xml"),
            ]),
            Source(id: "gigazine", name: "GIGAZINE", overseas: false, categories: [
                c("top", "最新", "https://gigazine.net/news/rss_2.0/"),
            ]),
            Source(id: "hatena", name: "はてなブックマーク", overseas: false, categories: [
                c("top", "人気", "https://b.hatena.ne.jp/hotentry/all.rss"),
                c("it", "テクノロジー", "https://b.hatena.ne.jp/hotentry/it.rss"),
            ]),
            // 海外
            Source(id: "bbc", name: "BBC News", overseas: true, categories: [
                c("top", "Top", bbc + "rss.xml"), c("world", "World", bbc + "world/rss.xml"),
                c("business", "Business", bbc + "business/rss.xml"), c("tech", "Technology", bbc + "technology/rss.xml"),
            ]),
            Source(id: "nyt", name: "The New York Times", overseas: true, categories: [
                c("top", "Top", nyt + "HomePage.xml"), c("world", "World", nyt + "World.xml"),
                c("business", "Business", nyt + "Business.xml"), c("tech", "Technology", nyt + "Technology.xml"),
            ]),
            Source(id: "guardian", name: "The Guardian", overseas: true, categories: [
                c("world", "World", "https://www.theguardian.com/world/rss"),
                c("tech", "Technology", "https://www.theguardian.com/uk/technology/rss"),
            ]),
            Source(id: "aljazeera", name: "Al Jazeera", overseas: true, categories: [
                c("top", "All", "https://www.aljazeera.com/xml/rss/all.xml"),
            ]),
            Source(id: "npr", name: "NPR", overseas: true, categories: [
                c("top", "News", "https://feeds.npr.org/1001/rss.xml"),
            ]),
            Source(id: "cnbc", name: "CNBC", overseas: true, categories: [
                c("top", "Top", "https://www.cnbc.com/id/100003114/device/rss/rss.html"),
            ]),
            Source(id: "japantimes", name: "The Japan Times", overseas: true, categories: [
                c("top", "Latest", "https://www.japantimes.co.jp/feed/"),
            ]),
            Source(id: "techcrunch", name: "TechCrunch", overseas: true, categories: [
                c("top", "Latest", "https://techcrunch.com/feed/"),
            ]),
            Source(id: "verge", name: "The Verge", overseas: true, categories: [
                c("top", "Latest", "https://www.theverge.com/rss/index.xml"),
            ]),
            Source(id: "hn", name: "Hacker News", overseas: true, categories: [
                c("top", "Front page", "https://hnrss.org/frontpage"),
            ]),
        ]
    }()

    static func source(_ id: String) -> Source { sources.first { $0.id == id } ?? sources[0] }
}

/// The chosen news feed, stored as "source/category" (e.g. "nhk/top").
struct NewsChoice: Equatable {
    var sourceID: String
    var categoryID: String

    init(_ raw: String?) {
        let parts = (raw ?? "").split(separator: "/").map(String.init)
        let src = parts.first.flatMap { id in NewsCatalog.sources.first { $0.id == id } } ?? NewsCatalog.sources[0]
        sourceID = src.id
        categoryID = parts.count > 1 && src.categories.contains { $0.id == parts[1] } ? parts[1] : src.categories[0].id
    }

    var raw: String { "\(sourceID)/\(categoryID)" }
    var source: NewsCatalog.Source { NewsCatalog.source(sourceID) }
    var category: NewsCatalog.Category { source.categories.first { $0.id == categoryID } ?? source.categories[0] }
    var url: String { category.url }
    var label: String { source.categories.count > 1 ? "\(source.name)・\(category.label)" : source.name }
}

/// WMO weather codes → Japanese text and SF Symbol.
enum WeatherCode {
    static func text(_ code: Int) -> String {
        switch code {
        case 0: return "快晴"
        case 1: return "晴れ"
        case 2: return "晴れ時々くもり"
        case 3: return "くもり"
        case 45, 48: return "霧"
        case 51, 53, 55, 56, 57: return "霧雨"
        case 61, 63, 80, 81: return "雨"
        case 65, 82: return "強い雨"
        case 66, 67: return "凍雨"
        case 71, 73, 75, 77, 85, 86: return "雪"
        case 95, 96, 99: return "雷雨"
        default: return "—"
        }
    }

    static func symbol(_ code: Int) -> String {
        switch code {
        case 0, 1: return "sun.max"
        case 2: return "cloud.sun"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51, 53, 55, 56, 57: return "cloud.drizzle"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow"
        case 95, 96, 99: return "cloud.bolt.rain"
        default: return "questionmark"
        }
    }
}

/// Google Trends RSS: <item><title>word</title><ht:approx_traffic>2000+</ht:approx_traffic>…
final class TrendParser: NSObject, XMLParserDelegate {
    private var out: [(word: String, traffic: String?)] = []
    private var inItem = false
    private var title = "", traffic: String?
    private var text = ""

    static func parse(_ data: Data) -> [(word: String, traffic: String?)] {
        let p = TrendParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.out
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { inItem = true; title = ""; traffic = nil }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inItem else { return }
        switch qName ?? name {
        case "title": if title.isEmpty { title = v }
        case "ht:approx_traffic": traffic = v
        case "item":
            if !title.isEmpty { out.append((title, traffic)) }
            inItem = false
        default: break
        }
    }
}
