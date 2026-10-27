import AppKit
import SwiftUI

/// 実験: sources without a published feed or API, off by default. The first switch turned
/// on asks once for the user's agreement that they use these at their own risk.
struct ExperimentalPane: View {
    @ObservedObject var settings: AppSettings
    @State private var sessionKey = ""
    @State private var hasSessionKey = Keychain.exists(account: ClaudeUsageAPI.sessionKeyAccount)

    var body: some View {
        Form {
            Section("Claude") {
                Toggle(String(localized: "使用量をリアルタイムで取得"), isOn: gated($settings.experimentalRealtimeClaude) {
                    add(.claude)
                })
                if settings.experimentalRealtimeClaude {
                    Picker(String(localized: "ログイン"), selection: $settings.experimentalClaudeSessionKey) {
                        Text("Claude Code").tag(false)
                        Text("claude.ai").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if settings.experimentalClaudeSessionKey {
                        LabeledContent {
                            HStack {
                                SecureField(String(localized: "セッションキー"), text: $sessionKey,
                                            prompt: Text(hasSessionKey ? String(localized: "保存済み") : "sessionKey"))
                                    .labelsHidden()
                                    .frame(width: 180)
                                Button(String(localized: "保存")) {
                                    Keychain.save(sessionKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  account: ClaudeUsageAPI.sessionKeyAccount)
                                    sessionKey = ""
                                    hasSessionKey = Keychain.exists(account: ClaudeUsageAPI.sessionKeyAccount)
                                    Task { await AppDelegate.shared.usageStore.fetchNow() }
                                }
                                .disabled(sessionKey.isEmpty)
                            }
                        } label: {
                            Text(String(localized: "セッションキー"))
                        }
                    }
                }
            }
            Section("Gemini") {
                Toggle(String(localized: "使用量を表示"), isOn: gated($settings.experimentalGemini) {
                    add(.gemini)
                })
            }
            Section(String(localized: "運行情報")) {
                Toggle(String(localized: "JR・東京メトロ・私鉄"), isOn: gated($settings.experimentalTrainPages) {
                    Task { await AppDelegate.shared.info.refreshTrains(everything: true) }
                })
            }
            Section(String(localized: "ニュース")) {
                Toggle(String(localized: "NHK のニュース速報"), isOn: gated($settings.experimentalNHKFlash) {
                    settings.infoNews = true
                })
            }
        }
        .formStyle(.grouped)
    }

    /// Turning one on: ask once, then switch on and do what the feature needs to show up.
    private func gated(_ value: Binding<Bool>, onEnable: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { on in
            guard on else { value.wrappedValue = false; return }
            guard settings.experimentalAccepted || Self.confirm() else { return }
            settings.experimentalAccepted = true
            value.wrappedValue = true
            onEnable()
        })
    }

    /// Shows the AI service in the menu bar and panel.
    private func add(_ p: AIProvider) {
        if !settings.aiProviders.contains(p) { settings.aiProviders.append(p) }
        if !settings.menuBarAI.contains(p) { settings.menuBarAI.append(p) }
    }

    private static func confirm() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "実験的な機能を使いますか？")
        alert.informativeText = String(localized: "公開されていない方法で情報を取得します。予告なく動かなくなったり、各サービスの規約に反したりすることがあります。自己責任で使ってください。")
        alert.addButton(withTitle: String(localized: "自己責任で使う"))
        alert.addButton(withTitle: String(localized: "やめる"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
