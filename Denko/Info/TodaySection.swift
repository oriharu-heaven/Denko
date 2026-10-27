import SwiftUI

/// "今日" tab: weather in one line, the state of disasters and trains, a few headlines,
/// and recent notices — sized to fit the panel without scrolling.
struct TodaySection: View {
    @ObservedObject var info: InfoStore
    @ObservedObject var hub: NotificationHub
    @ObservedObject var settings: AppSettings

    private var accent: Color { settings.accent.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.infoWeather { weatherRow.dashSection(first: true) }
            if settings.infoDisaster || settings.infoTrains { statusCard.dashSection(first: !settings.infoWeather) }
            if settings.infoNews { newsCard.dashSection() }
            noticesCard.dashSection()
        }
        .onAppear {
            if info.weather == nil || info.news.isEmpty { Task { await info.refreshAll() } }
            hub.markRead()
        }
    }

    // MARK: Weather

    private var weatherRow: some View {
        HStack(alignment: .center, spacing: 10) {
            if let w = info.weather {
                Image(systemName: WeatherCode.symbol(w.code))
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 26))
                    .foregroundStyle(accent)
                Text("\(Int(w.temperature.rounded()))°").font(.system(size: 26, weight: .semibold).monospacedDigit())
                VStack(alignment: .leading, spacing: 0) {
                    Text(WeatherCode.text(w.code)).font(.callout)
                    Text(settings.weatherPlace).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let soon = w.rainSoon {
                    Label(soon.replacingOccurrences(of: " ?[（(][0-9]+%[）)]", with: "", options: .regularExpression),
                          systemImage: "umbrella.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
            } else {
                Text(info.error ?? String(localized: "読み込み中…")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Status

    /// Disasters and trains as two rows of one card: calm when all is well, highlighted when not.
    private var statusCard: some View {
        let recent = info.lastDisaster.flatMap { Date().timeIntervalSince($0.date) < 6 * 3600 ? $0 : nil }
        let trouble = InfoStore.uniqueLines((info.trains ?? []).filter(\.isTrouble))
        return VStack(alignment: .leading, spacing: 8) {
            if settings.infoDisaster {
                statusRow(icon: recent == nil ? "checkmark.shield" : "exclamationmark.triangle.fill",
                          alert: recent != nil,
                          text: recent?.title ?? String(localized: "\(settings.weatherPrefecture)：警報・強い揺れなし"))
            }
            if settings.infoTrains && settings.trainLines.isEmpty {
                Button {
                    AppDelegate.shared.openSettings(tab: String(localized: "情報連携"), feed: .trains)
                } label: {
                    HStack {
                        statusRow(icon: "tram", alert: false, text: String(localized: "見る路線を選ぶ…"))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if settings.infoTrains {
                statusRow(icon: trouble.isEmpty ? "tram" : "tram.fill", alert: !trouble.isEmpty,
                          text: settings.trainLines.isEmpty ? String(localized: "路線が未設定")
                            : info.trains == nil ? (info.failed.contains("trains") ? String(localized: "運行情報を取得できません") : String(localized: "読み込み中…"))
                            : (trouble.isEmpty ? String(localized: "平常運転") : trouble.joined(separator: String(localized: "・"))))
                .contextMenu {
                    // Quick way to drop a line that keeps showing up.
                    let names = Array(Set((info.trains ?? []).filter(\.isTrouble).map(\.name))).sorted()
                    ForEach(names, id: \.self) { name in
                        Button(String(localized: "「\(name)」を見ない")) { info.unwatch(name) }
                    }
                    if !names.isEmpty { Divider() }
                    Button(String(localized: "見る路線を選ぶ…")) { AppDelegate.shared.openSettings(tab: String(localized: "情報連携")) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func statusRow(icon: String, alert: Bool, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(alert ? accent : .secondary).frame(width: 16)
            Text(text).font(alert ? .callout.weight(.semibold) : .callout)
                .foregroundStyle(alert ? accent : .primary)
                .lineLimit(1)
        }
    }

    // MARK: News

    private var newsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(settings.newsFeed.label)
            if info.news.isEmpty {
                if info.failed.contains("news") {
                    Label(String(localized: "ニュースを取得できませんでした"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text(String(localized: "読み込み中…")).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(info.news.prefix(3)) { item in
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

    private var noticesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                heading(String(localized: "最近のお知らせ"))
                Spacer()
                if !hub.history.isEmpty {
                    Button(String(localized: "消去")) { hub.clear() }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(hub.history.prefix(3))) { msg in
                Button {
                    msg.open()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: msg.source.symbol).font(.caption).foregroundStyle(accent).frame(width: 14)
                        Text(msg.title).font(.caption).lineLimit(1)
                        if msg.canOpen {
                            Image(systemName: "arrow.up.forward").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        Text(msg.date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!msg.canOpen)
                .help(msg.url?.absoluteString ?? (msg.canOpen ? msg.openLabel : ""))
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
