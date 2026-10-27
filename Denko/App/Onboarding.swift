import AppKit
import ServiceManagement
import SwiftUI

/// First-run "はじめに": pick what Denko is for, and the settings follow.
struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    let finish: (Choices) -> Void

    struct Choices {
        var today = true        // 天気・ニュース
        var trains = true
        var mac = true          // CPU・メモリ・通信
        var dev = false         // Claude Code・GitHub
        var ai = false
        var launchAtLogin = true
        var place = ""
    }

    @State private var c: Choices = {
        var c = Choices()
        c.dev = AIProvider.claude.isDetected || CodexNotify.isAvailable
        return c
    }()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Denko へようこそ").font(.title.weight(.semibold))
                Text("流したいものを選んでください")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.bottom, 8)

            Form {
                Section {
                    // Asked up front: weather and disaster info both depend on it, and a grey
                    // placeholder alone read as if it were already filled in.
                    LabeledContent {
                        TextField("住んでいる地域", text: $c.place, prompt: Text(settings.weatherPlace))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 200)
                    } label: {
                        Text("住んでいる地域")
                    }
                    row("cloud.sun.fill", .blue, "天気とニュース", $c.today)
                    row("tram.fill", .green, "電車の運行情報", $c.trains)
                    row("cpu", .gray, "Mac の状態", $c.mac)
                }
                Section {
                    row("terminal.fill", .brown, "コーディングエージェント", $c.dev)
                    row("gauge.with.dots.needle.67percent", .pink, "AI の使用量", $c.ai)
                }
                Section {
                    Toggle("ログイン時に Denko を起動", isOn: $c.launchAtLogin)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Button { finish(c) } label: {
                Text("はじめる").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 24)
        }
        .frame(width: 480, height: 580)
        .tint(settings.accent.color)
    }

    private func row(_ symbol: String, _ color: Color, _ title: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            HStack(spacing: 10) {
                SettingsIcon(symbol: symbol, color: color, size: 26)
                Text(title)
            }
        }
    }
}

extension AppDelegate {
    /// Bumped when はじめに gains a step existing users should see (2: Claude's usage via the
    /// status line). Earlier builds only stored `onboardingShown`, which counts as version 1.
    static let onboardingVersion = 2

    var needsOnboarding: Bool {
        let d = UserDefaults.standard
        let seen = d.object(forKey: "onboardingVersion") as? Int ?? (d.bool(forKey: "onboardingShown") ? 1 : 0)
        return seen < Self.onboardingVersion
    }

    /// Applies the choices from はじめに.
    func applyOnboarding(_ c: OnboardingView.Choices) {
        UserDefaults.standard.set(Self.onboardingVersion, forKey: "onboardingVersion")
        if c.launchAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        let s = settings
        s.infoWeather = c.today
        s.infoNews = c.today
        s.announceNews = c.today
        s.announceRain = c.today
        s.announceMorning = c.today
        s.infoTrains = c.trains
        s.announceTrains = c.trains
        s.infoRollMinutes = (c.today || c.trains) ? 60 : 0
        s.showCPUGauge = c.mac
        s.showMemoryGauge = c.mac
        s.showNetworkGauge = c.mac
        if !c.mac && s.boardIdle == .dashboard && !c.ai { s.boardIdle = .clock }
        let detected = AIProvider.offered(s).filter(\.isDetected)
        s.aiProviders = c.ai ? (detected.isEmpty ? [.claude] : detected) : []
        s.menuBarAI = s.aiProviders
        if c.dev { s.notifyServerEnabled = true }
        let place = c.place.trimmingCharacters(in: .whitespaces)
        if !place.isEmpty { Task { _ = await info.setPlace(place) } }
        Task { await info.refreshAll() }

        // Coding agents: these change the tools' own settings files, so ask first.
        let endpoint = notifyServer.endpoint
        var tools: [(String, String, () throws -> Void)] = []
        if c.dev && AIProvider.claude.isDetected && !ClaudeCodeHooks.isInstalled(endpoint: endpoint) {
            tools.append(("Claude Code", "~/.claude/settings.json", { try ClaudeCodeHooks.install(endpoint: endpoint) }))
        }
        if c.dev && CodexNotify.isAvailable && !CodexNotify.isInstalled(endpoint: endpoint) {
            tools.append(("Codex", "~/.codex/config.toml", { try CodexNotify.install(endpoint: endpoint) }))
        }
        // Claude's usage arrives through Claude Code's status line.
        if s.aiProviders.contains(.claude) && !ClaudeStatusLine.isInstalled(endpoint: endpoint) {
            tools.append(("Claude の使用量", "~/.claude/settings.json のステータスライン",
                          { try ClaudeStatusLine.install(endpoint: endpoint) }))
        }
        FullBarAnnouncer.debugLog("onboarding dev=\(c.dev) tools=\(tools.map(\.0)) claudeDetected=\(AIProvider.claude.isDetected)")
        if !tools.isEmpty {
            let alert = NSAlert()
            alert.messageText = "\(tools.map(\.0).joined(separator: "・")) と連携しますか？"
            alert.informativeText = "\(tools.map(\.1).joined(separator: "、")) に、Denko に知らせる設定（許可待ち・作業完了・使用量）を追加します。元のファイルは同じフォルダにバックアップされます。あとから 設定 → 情報連携 で解除できます。"
            alert.addButton(withTitle: "連携する")
            alert.addButton(withTitle: "あとで")
            if alert.runModal() == .alertFirstButtonReturn {
                for t in tools {
                    do { try t.2() } catch {
                        hub.post(.system, title: "\(t.0) と連携できませんでした",
                                 body: "設定 → 情報連携 → \(t.0) からもう一度お試しください", force: .normal)
                    }
                }
            }
        }
        hub.post(.system, title: "Denko の準備ができました", body: "設定 → 掲示板 で見た目を変えられます", force: .normal)
    }
}
