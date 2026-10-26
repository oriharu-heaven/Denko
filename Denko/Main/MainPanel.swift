import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case cpu, memory, network, disk, ai, today
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "メモリ"
        case .network: return "通信"
        case .disk: return "ディスク"
        case .ai: return "AI"
        case .today: return "今日"
        }
    }
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .ai: return "gauge.with.dots.needle.67percent"
        case .today: return "sun.max"
        }
    }

    var metric: AppUsageMonitor.Metric? {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .network: return .network
        case .disk, .ai, .today: return nil
        }
    }
}

/// Which tab the panel shows; set from the part of the menu bar icon that was clicked.
@MainActor
final class PanelState: ObservableObject {
    @Published var tab: PanelTab = .cpu {
        didSet { if tab != oldValue { selectedApp = nil } }
    }
    /// App whose detail is shown (tapped in the chart / legend).
    @Published var selectedApp: String?
}

/// Menu bar panel. Monochrome text with a single accent; system fonts, SF Symbols
/// and standard controls. Tabs at the top match the parts of the menu bar icon.
struct MainPanel: View {
    @ObservedObject var state: PanelState
    @ObservedObject var ai: AIUsageStore
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var apps: AppUsageMonitor
    @ObservedObject var awake: SleepPreventer
    @ObservedObject var settings: AppSettings
    let storage: StorageAnalyzer

    static func intervalLabel(_ s: Double) -> String {
        s < 1 ? "\(Int(s * 1000))ms" : "\(Int(s))秒ごと"
    }

    private var tabs: [PanelTab] {
        PanelTab.allCases.filter {
            $0 != .disk || settings.storageMode != .off
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Icon + word for every tab: icons alone (a chip, a globe …) didn't say what they were.
            PanelTabBar(tabs: tabs, selection: $state.tab, accent: settings.accent.color)
                .padding(.horizontal, 10)
                .padding(.top, 10)

            Group {
                if let metric = state.tab.metric {
                    SystemSection(monitor: monitor, apps: apps, settings: settings, state: state, metric: metric)
                } else if state.tab == .disk {
                    StorageSection(analyzer: storage, settings: settings)
                } else if state.tab == .today {
                    TodaySection(info: AppDelegate.shared.info, hub: AppDelegate.shared.hub, settings: settings)
                } else {
                    AISection(store: ai, settings: settings)
                }
            }
            .panelSection()

            Divider()
            if Features.sleepPrevention {
                AwakeSection(awake: awake, settings: settings)
                    .panelSection()
                Divider()
            }
            HStack {
                Button("設定…") { AppDelegate.shared.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                // Activity Monitor only makes sense for CPU / memory / network.
                if state.tab.metric != nil {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("アクティビティモニタを開く")
                    .accessibilityLabel("アクティビティモニタを開く")
                }
                Spacer()
                // Quick pause for meetings: only urgent notices play until then.
                if settings.isPaused, let until = settings.pausedUntil {
                    Text("\(until, format: .dateTime.hour().minute()) まで緊急だけ")
                        .font(.caption)
                    Button("再開") { settings.pausedUntil = nil }
                } else {
                    Menu("お知らせを止める") {
                        Button("30分") { settings.pause(minutes: 30) }
                        Button("1時間") { settings.pause(minutes: 60) }
                        Button("明日の朝まで") { settings.pause(minutes: nil) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("止めている間も、「緊急」にしたお知らせ（初期設定では強い地震・津波）は流れます")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        // 今日 is a small dashboard and gets more room.
        .frame(width: state.tab == .today ? 540 : 320)
        .tint(settings.accent.color)
        .onAppear { if !tabs.contains(state.tab) { state.tab = .cpu } }
    }
}

/// Tabs drawn as small icon-over-label buttons, so each one says what it is and they still
/// fit in the 320pt panel (a segmented picker with text was squeezed on a later layout pass).
private struct PanelTabBar: View {
    let tabs: [PanelTab]
    @Binding var selection: PanelTab
    let accent: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, t in
                let on = t == selection
                Button { selection = t } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.symbol).font(.system(size: 14))
                            .frame(height: 18)
                        Text(t.label).font(.system(size: 10, weight: on ? .semibold : .regular))
                            .lineLimit(1).fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .foregroundStyle(on ? accent : .secondary)
                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? accent.opacity(0.14) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .help("\(t.label)（⌘\(index + 1)）")
                .accessibilityLabel(t.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Section header: small, secondary, with an optional trailing control.
struct PanelHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Spacer()
            trailing
        }
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, systemImage: String) {
        self.init(title: title, systemImage: systemImage) { EmptyView() }
    }
}

extension View {
    func panelSection() -> some View {
        padding(.horizontal, 14).padding(.vertical, 12)
    }
}

// MARK: - Sleep prevention

private struct AwakeSection: View {
    @ObservedObject var awake: SleepPreventer
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: "スリープ防止", systemImage: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer") {
                Toggle("スリープ防止", isOn: Binding(
                    get: { awake.isActive },
                    set: { $0 ? awake.start(minutes: settings.keepAwakeDefaultMinutes) : awake.stop() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            HStack {
                if awake.isActive {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text(awake.remainingText(now: ctx.date))
                            .font(.callout.monospacedDigit())
                    }
                } else {
                    Text("Mac はいつも通りスリープします")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(SleepPreventer.durations, id: \.self) { m in
                        Button(SleepPreventer.label(minutes: m)) { awake.start(minutes: m) }
                    }
                } label: {
                    Text(awake.isActive ? "延長" : "時間を選ぶ")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.callout)
            }
        }
    }
}
