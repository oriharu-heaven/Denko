import AppKit
import ServiceManagement
import SwiftUI

/// The first-time setup, as a checklist (設定 → セットアップ, and a shortcut in the panel until
/// it's done). Each step knows whether it applies on this Mac, whether it's done, and what
/// its button does — either the change itself or the settings page where it's made.
@MainActor
enum SetupStep: String, CaseIterable, Identifiable {
    case place, trains, agents, claudeUsage, launchAtLogin
    nonisolated var id: String { rawValue }

    var title: String {
        switch self {
        case .place: return String(localized: "住んでいる地域")
        case .trains: return String(localized: "見る路線")
        case .agents: return String(localized: "コーディングエージェントと連携")
        case .claudeUsage: return String(localized: "Claude の使用量")
        case .launchAtLogin: return String(localized: "ログイン時に起動")
        }
    }

    var symbol: String {
        switch self {
        case .place: return "location.fill"
        case .trains: return "tram.fill"
        case .agents: return "terminal.fill"
        case .claudeUsage: return "gauge.with.dots.needle.67percent"
        case .launchAtLogin: return "power"
        }
    }

    var color: Color {
        switch self {
        case .place: return .blue
        case .trains: return .green
        case .agents: return .brown
        case .claudeUsage: return .pink
        case .launchAtLogin: return .gray
        }
    }

    /// Button label while the step isn't done.
    var action: String {
        switch self {
        case .place, .trains: return String(localized: "選ぶ…")
        case .agents, .claudeUsage: return String(localized: "連携する")
        case .launchAtLogin: return String(localized: "オンにする")
        }
    }

    private var endpoint: String { AppDelegate.shared.notifyServer.endpoint }

    func applies(_ s: AppSettings) -> Bool {
        switch self {
        case .place, .launchAtLogin: return true
        case .trains: return s.infoTrains
        case .agents: return AIProvider.claude.isDetected || CodexNotify.isAvailable
        case .claudeUsage: return AIProvider.claude.isDetected
        }
    }

    func isDone(_ s: AppSettings) -> Bool {
        switch self {
        // 東京 until the user picks another place, so there's always one.
        case .place: return true
        case .trains: return !s.trainLines.isEmpty
        case .agents:
            return (!AIProvider.claude.isDetected || ClaudeCodeHooks.isInstalled(endpoint: endpoint))
                && (!CodexNotify.isAvailable || CodexNotify.isInstalled(endpoint: endpoint))
        case .claudeUsage:
            return s.aiProviders.contains(.claude)
                && (s.experimentalRealtimeClaude || ClaudeStatusLine.isInstalled(endpoint: endpoint))
        case .launchAtLogin: return SMAppService.mainApp.status == .enabled
        }
    }

    /// Does the step. Changing another tool's settings file only happens from this button,
    /// which the user presses for exactly that (a backup is written first).
    func perform(_ s: AppSettings) throws {
        switch self {
        case .place:
            AppDelegate.shared.openSettings(tab: String(localized: "情報連携"), feed: .weather)
        case .trains:
            AppDelegate.shared.openSettings(tab: String(localized: "情報連携"), feed: .trains)
        case .agents:
            if AIProvider.claude.isDetected { try ClaudeCodeHooks.install(endpoint: endpoint) }
            if CodexNotify.isAvailable { try CodexNotify.install(endpoint: endpoint) }
        case .claudeUsage:
            if !s.aiProviders.contains(.claude) { s.aiProviders.append(.claude) }
            if !s.menuBarAI.contains(.claude) { s.menuBarAI.append(.claude) }
            try ClaudeStatusLine.install(endpoint: endpoint)
        case .launchAtLogin:
            try SMAppService.mainApp.register()
        }
    }

    static func remaining(_ s: AppSettings) -> [SetupStep] {
        allCases.filter { $0.applies(s) && !$0.isDone(s) }
    }

    /// For the panel, which redraws often: the count re-checked at most every few seconds.
    private static var cache: (date: Date, count: Int)?
    static func remainingCount(_ s: AppSettings) -> Int {
        if let c = cache, Date().timeIntervalSince(c.date) < 5 { return c.count }
        let n = remaining(s).count
        cache = (Date(), n)
        return n
    }
}

/// Lets a button elsewhere open a 情報連携 detail page.
@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var infoDetail: InfoHubPane.Feed?
}

/// 設定 → セットアップ: the steps in order, each with a check or the button that does it.
struct SetupPane: View {
    @ObservedObject var settings: AppSettings
    @State private var error: String?

    var body: some View {
        // Steps done elsewhere (a file changed, a login item) show up without reopening.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let steps = SetupStep.allCases.filter { $0.applies(settings) }
            Form {
                Section {
                    ForEach(steps) { step in
                        HStack(spacing: 10) {
                            SettingsIcon(symbol: step.symbol, color: step.color)
                            Text(step.title)
                            Spacer()
                            if step == .place {
                                Text(settings.weatherPlace).foregroundStyle(.secondary)
                            }
                            if step.isDone(settings) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    .accessibilityLabel(String(localized: "完了"))
                            } else {
                                Button(step.action) {
                                    do { try step.perform(settings); error = nil }
                                    catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                } header: {
                    Text("\(steps.filter { $0.isDone(settings) }.count) / \(steps.count)")
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
        }
    }
}
