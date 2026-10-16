import SwiftUI

/// Usage of every enabled AI service, each as a double ring like the menu bar.
struct AISection: View {
    @ObservedObject var store: AIUsageStore
    @ObservedObject var settings: AppSettings

    private var accent: Color { settings.accent.color }
    /// Only the AIs chosen for display (設定 → メニューバー), same as the menu bar.
    private var shown: [AIProvider] { store.enabled.filter { settings.menuBarAI.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.enabled.isEmpty {
                AIPromo(settings: settings, accent: accent)
            } else if shown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("表示する AI が選ばれていません").font(.callout)
                    ForEach(store.enabled) { p in
                        HStack {
                            ProviderMarkView(provider: p, color: accent).frame(width: 14, height: 14)
                            Text(p.name)
                            Spacer()
                            Button("表示する") { settings.menuBarAI.append(p) }.controlSize(.small)
                        }
                    }
                    Text("あとから 設定 → メニューバー でも変えられます。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(shown) { p in
                            ProviderRow(provider: p, usage: store.usage[p], error: store.errors[p],
                                        now: ctx.date, accent: accent)
                        }
                    }
                }
                HStack {
                    Spacer()
                    if store.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label("更新", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    }
                }
            }
        }
    }
}

private struct ProviderRow: View {
    let provider: AIProvider
    let usage: AIUsage?
    let error: String?
    let now: Date
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderMarkView(provider: provider, color: accent).frame(width: 14, height: 14)
                Text(provider.name)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 14) {
                DoubleRing(outer: usage?.primary?.percent, inner: usage?.secondary?.percent,
                           accent: accent, lineWidth: 6)
                    .frame(width: 58, height: 58)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Legend(window: usage?.primary, placeholder: provider.defaultLabels.outer,
                           note: "外側", now: now, accent: accent)
                    if usage?.secondary != nil || usage == nil {
                        Legend(window: usage?.secondary, placeholder: provider.defaultLabels.inner,
                               note: "内側", now: now, accent: accent)
                    }
                }
            }

            ForEach(Array((usage?.extras ?? []).enumerated()), id: \.offset) { _, w in
                HStack {
                    Text(w.label).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    ProgressView(value: min(w.percent, 100), total: 100).frame(width: 80)
                    Text("\(Int(w.percent.rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let u = usage {
                Text("\(u.source)・\(TimeText.absolute(u.updatedAt)) 更新")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct Legend: View {
    let window: AIWindow?
    let placeholder: String
    let note: String
    let now: Date
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.map { "\(Int($0.percent.rounded()))%" } ?? "--")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle((window?.percent ?? 0) >= Theme.highUsage ? accent : .primary)
                Text(window?.label ?? placeholder).font(.callout)
                Text(note).font(.caption).foregroundStyle(.tertiary)
            }
            if let w = window, w.resetsAt != nil {
                Text("リセット \(TimeText.untilReset(w.resetsAt, now: now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(TimeText.absolute(w.resetsAt))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Concentric usage rings: outer = short window, inner = long window. Same shape as the menu bar.
struct DoubleRing: View {
    let outer: Double?
    let inner: Double?
    let accent: Color
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            ring(outer, inset: lineWidth / 2)
            ring(inner, inset: lineWidth * 1.5 + 3)
        }
    }

    private func ring(_ value: Double?, inset: CGFloat) -> some View {
        ZStack {
            Circle().inset(by: inset).stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .inset(by: inset)
                .trim(from: 0, to: CGFloat(min(value ?? 0, 100) / 100))
                .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Shown while no AI is enabled: what the feature does, with one-click enabling.
private struct AIPromo: View {
    @ObservedObject var settings: AppSettings
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 26))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI の使用量を掲示板に").font(.headline)
                    Text("Claude・Codex・Gemini の利用枠（5時間・1週間）を二重のリングで表示し、残りが少なくなったら掲示板でお知らせします。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(AIProvider.allCases) { p in
                HStack(spacing: 8) {
                    ProviderMarkView(provider: p, color: accent).frame(width: 14, height: 14)
                    Text(p.name).font(.callout)
                    if p.isDetected {
                        Text("この Mac で使われています").font(.caption2).foregroundStyle(accent)
                    }
                    Spacer()
                    Button("表示する") {
                        if !settings.aiProviders.contains(p) { settings.aiProviders.append(p) }
                        if !settings.menuBarAI.contains(p) { settings.menuBarAI.append(p) }
                    }
                        .controlSize(.small)
                }
            }
            Text("ログイン情報は読み取るだけで、外部に送ることはありません。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
