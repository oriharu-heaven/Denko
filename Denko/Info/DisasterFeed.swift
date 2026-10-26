import Foundation

/// 気象庁 防災情報XML (official, free). Two "high frequency" Atom feeds, polled with
/// If-Modified-Since so an unchanged feed costs one tiny 304 response:
/// - eqvol.xml: 震度速報・震源・震度情報・津波・噴火速報
/// - extra.xml: 気象警報・特別警報・土砂災害警戒情報・記録的短時間大雨情報
/// Not 緊急地震速報 (the early warning before shaking): it isn't available in time this way.
@MainActor
final class DisasterFeed {
    struct Notice {
        let kind: NoticeKind
        let title: String
        let body: String?
        let url: URL?
    }

    static let attribution = "出典：気象庁（防災情報XML）"
    private static let base = "https://www.data.jma.go.jp/developer/xml/feed/"

    private var lastModified: [String: String] = [:]
    private var seenEntries = Set<String>()
    private var seenEvents = Set<String>()
    private var primed: Set<String> = []

    /// New notices since the last call. The first call per feed only remembers what's there.
    func poll(feed: String, prefecture: String) async -> [Notice] {
        guard let url = URL(string: Self.base + feed) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        if let lm = lastModified[feed] { req.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        lastModified[feed] = http.value(forHTTPHeaderField: "Last-Modified")

        let entries = Self.entries(String(decoding: data, as: UTF8.self))
        let fresh = entries.filter { seenEntries.insert($0.id).inserted }
        guard primed.contains(feed) else { primed.insert(feed); return [] }

        var out: [Notice] = []
        for e in fresh.reversed() {   // oldest first
            if feed == "eqvol.xml" {
                if let n = await quakeOrTsunami(e, prefecture: prefecture) { out.append(n) }
            } else if let n = warning(e, prefecture: prefecture) {
                out.append(n)
            }
        }
        return out
    }

    // MARK: - Earthquakes, tsunami, eruptions

    private func quakeOrTsunami(_ e: Entry, prefecture: String) async -> Notice? {
        let jmaURL = URL(string: "https://www.jma.go.jp/bosai/map.html")
        if e.title.contains("津波") {
            guard (e.content.contains("警報") || e.content.contains("注意報")), !e.content.contains("解除") else { return nil }
            return Notice(kind: .tsunami, title: Self.headline(e.content), body: nil, url: jmaURL)
        }
        if e.title.contains("噴火速報") {
            return Notice(kind: .tsunami, title: Self.headline(e.content), body: nil, url: jmaURL)
        }
        guard e.title == "震度速報" || e.title == "震源・震度に関する情報",
              let link = e.link, let (data, _) = try? await URLSession.shared.data(from: link) else { return nil }
        let xml = String(decoding: data, as: UTF8.self)
        // One notice per earthquake (震度速報 and the later 震源・震度情報 share the EventID).
        let event = Self.first("EventID", in: xml) ?? e.id
        guard let maxInt = Self.first("MaxInt", in: xml) else { return nil }
        let level = Self.intensityValue(maxInt)
        let prefs = Self.all("Name", after: "<Pref>", in: xml)
        let local = prefs.contains(prefecture)
        // 震度5弱以上 anywhere, or 4以上 where the user is → strong; 震度4, or 3 locally → other.
        let kind: NoticeKind
        if level >= 5 || (local && level >= 4) { kind = .quakeStrong }
        else if level >= 4 || (local && level >= 3) { kind = .quakeOther }
        else { return nil }
        guard seenEvents.insert(event).inserted else { return nil }
        let area = Self.first("Name", after: "<Hypocenter>", in: xml)
        let mag = Self.first("jmx_eb:Magnitude", in: xml)
        var title = "最大震度\(Self.intensityLabel(maxInt))"
        if let area { title += "　震源 \(area)" }
        if let mag, mag != "NaN" { title += "　M\(mag)" }
        let body = prefs.isEmpty ? nil : "揺れた地域: " + prefs.prefix(6).joined(separator: "・")
        return Notice(kind: kind, title: "地震　" + title, body: body, url: jmaURL)
    }

    // MARK: - Weather warnings for the user's prefecture

    private func warning(_ e: Entry, prefecture: String) -> Notice? {
        let jmaURL = URL(string: "https://www.jma.go.jp/bosai/warning/")
        switch e.title {
        case "気象特別警報・警報・注意報":
            guard e.content.contains("【\(prefecture)") || e.content.contains("【\(prefecture.dropLast())") else { return nil }
            // Drop the "【東京都気象警報・注意報】" header; what's left names the warnings.
            let text = e.content.components(separatedBy: "】").dropFirst().joined(separator: "】")
            guard text.contains("警報"), !text.contains("警報を解除") || text.contains("発表") else { return nil }
            return Notice(kind: .weatherWarning, title: Self.headline(e.content), body: nil, url: jmaURL)
        case "土砂災害警戒情報", "記録的短時間大雨情報", "竜巻注意情報":
            guard e.content.contains(prefecture) || e.content.contains(String(prefecture.dropLast())) else { return nil }
            return Notice(kind: .weatherWarning, title: Self.headline(e.content), body: nil, url: jmaURL)
        default:
            return nil
        }
    }

    // MARK: - Parsing

    struct Entry {
        let id: String
        let title: String
        let content: String
        let link: URL?
    }

    private static func entries(_ xml: String) -> [Entry] {
        xml.components(separatedBy: "<entry>").dropFirst().compactMap { chunk in
            let body = chunk.components(separatedBy: "</entry>").first ?? chunk
            guard let id = first("id", in: body), let title = first("title", in: body) else { return nil }
            let link = body.range(of: #"<link[^>]*href="([^"]+)""#, options: .regularExpression)
                .flatMap { r -> URL? in
                    let s = String(body[r])
                    guard let h = s.range(of: #"href=""#) else { return nil }
                    return URL(string: String(s[h.upperBound...].dropLast()))
                }
            return Entry(id: id, title: title, content: first("content", in: body) ?? "", link: link)
        }
    }

    /// Text of the first <tag …>…</tag>.
    private static func first(_ tag: String, in s: String) -> String? {
        guard let open = s.range(of: "<\(tag)"),
              let gt = s[open.upperBound...].firstIndex(of: ">"),
              let close = s.range(of: "</\(tag)>", range: s.index(after: gt)..<s.endIndex) else { return nil }
        return String(s[s.index(after: gt)..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func first(_ tag: String, after marker: String, in s: String) -> String? {
        guard let m = s.range(of: marker) else { return nil }
        return first(tag, in: String(s[m.upperBound...]))
    }

    private static func all(_ tag: String, after marker: String, in s: String) -> [String] {
        s.components(separatedBy: marker).dropFirst().compactMap { first(tag, in: $0) }
    }

    /// "【…】" header removed, first sentence only.
    private static func headline(_ content: String) -> String {
        var t = content
        if let r = t.range(of: "】") { t = String(t[r.upperBound...]) }
        if let r = t.range(of: "。") { t = String(t[..<r.upperBound]) }
        return String(t.trimmingCharacters(in: .whitespaces).prefix(120))
    }

    private static func intensityValue(_ s: String) -> Double {
        switch s {
        case "5-": return 5
        case "5+": return 5.5
        case "6-": return 6
        case "6+": return 6.5
        default: return Double(s) ?? 0
        }
    }

    private static func intensityLabel(_ s: String) -> String {
        switch s {
        case "5-": return "5弱"
        case "5+": return "5強"
        case "6-": return "6弱"
        case "6+": return "6強"
        default: return s
        }
    }
}
