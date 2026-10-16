import Charts
import SwiftUI

/// "今日" tab: a small dashboard — weather with the next hours, the state of disasters and
/// trains at a glance, exchange rates, headlines, trends, and recent notices.
struct TodaySection: View {
    @ObservedObject var info: InfoStore
    @ObservedObject var hub: NotificationHub
    @ObservedObject var settings: AppSettings

    private var accent: Color { settings.accent.color }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if settings.infoWeather { weatherCard.dashSection(first: true) }
                // Status and rates side by side, split by a hairline.
                if settings.infoDisaster || settings.infoTrains || (settings.infoFX && !info.fx.isEmpty) {
                    HStack(alignment: .top, spacing: 14) {
                        if settings.infoDisaster || settings.infoTrains { statusCard }
                        if (settings.infoDisaster || settings.infoTrains) && settings.infoFX && !info.fx.isEmpty {
                            Divider()
                        }
                        if settings.infoFX && !info.fx.isEmpty { fxCard.frame(width: 220) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .dashSection(first: !settings.infoWeather)
                }
                if settings.infoNews { newsCard.dashSection() }
                if settings.infoTrends && !info.trends.isEmpty { trendCard.dashSection() }
                noticesCard.dashSection()
            }
            .padding(.vertical, 2)
        }
        .frame(height: 540)
        .onAppear {
            if info.weather == nil || info.news.isEmpty { Task { await info.refreshAll() } }
            hub.markRead()
        }
    }

    // MARK: Weather

    /// Now on the left, the next 12 hours as a temperature curve with rain chances underneath.
    private var weatherCard: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label(settings.weatherPlace, systemImage: "location").font(.caption).foregroundStyle(.secondary)
                if let w = info.weather {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: WeatherCode.symbol(w.code))
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 34))
                            .foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(Int(w.temperature.rounded()))°").font(.system(size: 34, weight: .semibold).monospacedDigit())
                            Text(WeatherCode.text(w.code)).font(.callout)
                        }
                    }
                    HStack(spacing: 12) {
                        stat("最高", "\(Int(w.high.rounded()))°")
                        stat("最低", "\(Int(w.low.rounded()))°")
                        stat("降水", "\(w.rainChance)%")
                    }
                    if let soon = w.rainSoon {
                        Label(soon, systemImage: "umbrella.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                } else {
                    Text(info.error ?? "読み込み中…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 170, alignment: .leading)

            if let w = info.weather, w.hourly.count >= 4 {
                forecastChart(w.hourly)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
        }
    }

    /// Temperature line (labelled every 2 hours) over a band of rain-chance bars.
    private func forecastChart(_ hours: [InfoStore.Hour]) -> some View {
        let temps = hours.map(\.temperature)
        let lo = (temps.min() ?? 0) - 4, hi = (temps.max() ?? 0) + 2
        let band = (hi - lo) * 0.3            // bottom 30% shows rain chance
        return VStack(alignment: .leading, spacing: 2) {
            Text("この先 12 時間").font(.caption2).foregroundStyle(.secondary)
            Chart {
                ForEach(Array(hours.enumerated()), id: \.offset) { i, h in
                    BarMark(x: .value("時刻", i), yStart: .value("降水", lo),
                            yEnd: .value("降水", lo + band * Double(h.rain >= 5 ? h.rain : 0) / 100),
                            width: .fixed(10))
                        .foregroundStyle(accent.opacity(h.rain >= 50 ? 0.6 : 0.28))
                        .annotation(position: .top, spacing: 1) {
                            if h.rain >= 30 {
                                Text("\(h.rain)%").font(.system(size: 9).monospacedDigit()).foregroundStyle(accent)
                            }
                        }
                    LineMark(x: .value("時刻", i), y: .value("気温", h.temperature))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    if i % 2 == 0 {
                        PointMark(x: .value("時刻", i), y: .value("気温", h.temperature))
                            .symbolSize(18)
                            .foregroundStyle(accent)
                            .annotation(position: .top, spacing: 3) {
                                Text("\(Int(h.temperature.rounded()))°").font(.caption2.monospacedDigit())
                            }
                    }
                }
            }
            .chartYScale(domain: lo...hi)
            .chartYAxis(.hidden)
            .chartXScale(domain: -0.5...Double(hours.count) - 0.5)
            .chartXAxis {
                AxisMarks(values: Array(stride(from: 0, to: hours.count, by: 2))) { v in
                    AxisValueLabel {
                        if let i = v.as(Int.self), i < hours.count {
                            Text("\(hours[i].hour)時").font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 130)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Status

    /// Disasters and trains as two rows of one card: calm when all is well, highlighted when not.
    private var statusCard: some View {
        let recent = info.lastDisaster.flatMap { Date().timeIntervalSince($0.date) < 6 * 3600 ? $0 : nil }
        let trouble = InfoStore.uniqueLines((info.trains ?? []).filter(\.isTrouble))
        return VStack(alignment: .leading, spacing: 8) {
            heading("いまの状況")
            if settings.infoDisaster {
                statusRow(icon: recent == nil ? "checkmark.shield" : "exclamationmark.triangle.fill",
                          alert: recent != nil,
                          text: recent?.title ?? "\(settings.weatherPrefecture)に警報や強い揺れはありません")
            }
            if settings.infoTrains {
                statusRow(icon: trouble.isEmpty ? "tram" : "tram.fill", alert: !trouble.isEmpty,
                          text: info.trains == nil
                            ? (info.failed.contains("trains") ? "運行情報を取得できませんでした" : "運行情報を読み込み中…")
                            : (trouble.isEmpty ? "見ている路線は平常運転" : trouble.prefix(3).joined(separator: "\n")))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func statusRow(icon: String, alert: Bool, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(alert ? accent : .secondary).frame(width: 16)
            Text(text).font(alert ? .callout.weight(.semibold) : .callout)
                .foregroundStyle(alert ? accent : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fxCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            heading("為替")
            ForEach(info.fx) { q in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(q.label).font(.caption).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 4)
                    Text(InfoStore.price(q)).font(.callout.weight(.semibold).monospacedDigit()).fixedSize()
                    Text(InfoStore.percent(q.changePercent))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(abs(q.changePercent) >= max(0.5, settings.fxAlertPercent) ? accent : .secondary)
                        .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: News & trends

    private var newsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(settings.newsFeed.label)
            if info.news.isEmpty {
                if info.failed.contains("news") {
                    Label("ニュースを取得できませんでした。インターネットにつながっているか確かめてください。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("読み込み中…").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(info.news.prefix(5)) { item in
                Button {
                    if let url = item.url { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title).font(.callout).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("トレンド")
            FlowLayout(spacing: 4) {
                ForEach(Array(info.trends.prefix(10).enumerated()), id: \.element.id) { i, t in
                    Button {
                        let q = t.word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t.word
                        if let url = URL(string: "https://www.google.com/search?q=\(q)") { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(i + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            Text(t.word).font(.callout).lineLimit(1)
                        }
                        .padding(.trailing, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var noticesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                heading("最近のお知らせ")
                Spacer()
                if !hub.history.isEmpty {
                    Button("消去") { hub.clear() }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                }
            }
            if hub.history.isEmpty {
                Text("掲示板に流れたお知らせはここに残ります").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(Array(hub.history.prefix(5))) { msg in
                Button {
                    if let url = msg.url { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: msg.source.symbol).font(.caption).foregroundStyle(accent).frame(width: 14)
                        Text(msg.title).font(.caption).lineLimit(1)
                        if msg.url != nil {
                            Image(systemName: "arrow.up.forward").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        Text(msg.date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(msg.url == nil)
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

private extension View {
    /// A plain section: a hairline above (except the first), no box around it.
    func dashSection(first: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first { Divider() }
            self.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
        }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
