import SwiftUI

/// History of announcements (the panel's bell tab).
struct NoticesSection: View {
    @ObservedObject var hub: NotificationHub
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: String(localized: "お知らせ"), systemImage: "text.bubble") {
                if !hub.history.isEmpty {
                    Button(String(localized: "消去")) { hub.clear() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }

            if hub.history.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "お知らせはありません"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "連携は 設定 → 掲示板 で追加できます"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(hub.history) { msg in
                            MessageRow(msg: msg, accent: settings.accent.color)
                            Divider().padding(.leading, 28)
                        }
                    }
                }
                .frame(height: 300)
            }

        }
        .onAppear { hub.markRead() }
    }
}

private struct MessageRow: View {
    let msg: TickerMessage
    let accent: Color

    var body: some View {
        Button {
            msg.open()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: msg.source.symbol)
                    .foregroundStyle(accent)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(msg.source.label).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(msg.date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(msg.title).font(.callout).lineLimit(2)
                    if let body = msg.body, !body.isEmpty {
                        Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!msg.canOpen)
        .help(msg.url?.absoluteString ?? (msg.canOpen ? msg.openLabel : ""))
    }
}
