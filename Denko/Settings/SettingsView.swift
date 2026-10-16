import AppKit
import ServiceManagement
import SwiftUI

/// Standard macOS settings window: toolbar tabs, one grouped Form per pane.
@MainActor
enum SettingsWindow {
    static func make(settings: AppSettings, ai: AIUsageStore, awake: SleepPreventer, hider: MenuBarHider?) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        // One height for every tab (no jumping when switching), small enough for a 13-inch screen.
        let paneHeight = min(680, (NSScreen.main?.visibleFrame.height ?? 800) - 140)
        func add<V: View>(_ title: String, _ symbol: String, height _: CGFloat, _ view: V, image: NSImage? = nil) {
            let height = paneHeight
            let host = NSHostingController(rootView: Tinted(settings: settings,
                                                            content: view.frame(width: 520, height: height)))
            host.sizingOptions = .preferredContentSize
            host.title = title          // window title follows the selected tab
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = image ?? NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        // 一般 → the board's look → what it shows while idle → what flows into it.
        add("一般", "gearshape", height: 600, GeneralPane(settings: settings))
        add("掲示板", "", height: 760, BoardLookPane(settings: settings), image: BoardIcon.image())
        add("メニューバー", "menubar.rectangle", height: 760, MenuBarPane(settings: settings))
        add("情報連携", "point.3.connected.trianglepath.dotted", height: 760, InfoHubPane(settings: settings))
        if Features.sleepPrevention {
            add("スリープ防止", "cup.and.saucer", height: 330, AwakePane(settings: settings, awake: awake))
        }
        if let hider {
            add("整理", "rectangle.split.3x1", height: 600, HiderPane(settings: settings, hider: hider))
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        return window
    }
}

/// Applies the current accent live, so changing it in 一般 updates every pane.
struct Tinted<Content: View>: View {
    @ObservedObject var settings: AppSettings
    let content: Content
    var body: some View { content.tint(settings.accent.color) }
}

// MARK: - 一般

struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater: Updater = AppDelegate.shared.updater
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("動作の軽さ", selection: $settings.performance) {
                    ForEach(PerformanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("パフォーマンス")
            } footer: {
                Text(settings.performance.detail + "地震・津波の情報は、どの設定でも1分ごとに確認します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("ストレージの分析", selection: $settings.storageMode) {
                    ForEach(StorageMode.allCases) { Text($0.label).tag($0) }
                }
                if settings.storageMode == .full {
                    Button("フルディスクアクセスの設定を開く…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
            } header: {
                Text("ストレージ")
            } footer: {
                Text(settings.storageMode == .full
                     ? "書類・デスクトップ・ダウンロードや他のアプリのデータも調べるため、macOS がアクセスの確認を出します。システム設定 → プライバシーとセキュリティ → フルディスクアクセス で Denko をオンにすると、確認が出なくなります。"
                     : "「かんたん」はアクセスの確認が出ない範囲（アプリ・キャッシュ・開発ツールなど）だけを調べます。「使わない」にするとパネルのディスクのタブを隠します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("アップデートを自動で確認", isOn: Binding(
                    get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                Toggle("アップデートを自動でダウンロード", isOn: Binding(
                    get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                    .disabled(!updater.automaticallyChecks)
                HStack {
                    Text("バージョン \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("今すぐ確認") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                }
            } header: {
                Text("アップデート")
            }
            Section {
                Toggle(isOn: $settings.showAdvanced) {
                    Text("詳細な設定を表示")
                    Text("更新頻度・ドットの細かい見た目・アクセストークンなど、細かい項目も表示します。")
                }
                Button("はじめにの画面をもう一度表示…") { AppDelegate.shared.showOnboarding() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - メニューバー

struct MenuBarPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    IconPreview(settings: settings)
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section {
                Picker("表示スタイル", selection: $settings.displayStyle) {
                    ForEach(DisplayStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("「アイコン」はふつうのメニューバーアイコンで、「電光掲示板」は使用状況も掲示板のドットで表示します。お知らせはどちらでも掲示板で流れます。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("お知らせがないとき", selection: $settings.boardIdle) {
                    ForEach(BoardIdle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(settings.displayStyle != .led)
                if settings.boardIdle == .message {
                    TextField("ひとこと", text: $settings.idleMessage, prompt: Text("DENKO"))
                }
            } header: {
                Text("待機中の表示")
            } footer: {
                if settings.displayStyle == .led {
                    Text("「Mac の使用状況」は CPU・メモリなどの使用量を掲示板に映します。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("表示スタイルが「電光掲示板」のときに使えます。").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(isOn: $settings.showCharacter) {
                    Text("キャラクター")
                    Text(settings.character.motion)
                }
                if settings.showCharacter {
                    Picker("種類", selection: $settings.character) {
                        ForEach(CharacterKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Toggle(isOn: $settings.openTabAtClick) {
                    Text("クリックした部分のタブを開く")
                    Text(settings.openTabAtClick
                         ? "CPU・メモリ・通信・AI のどこをクリックしたかで、パネルの対応するタブが開きます。"
                         : "どこをクリックしても、前回見ていたタブで開きます。")
                }
            } header: {
                Text("メニューバーに表示する情報")
            }

            Section {
                Toggle("CPU", isOn: $settings.showCPUGauge)
                Toggle("メモリ", isOn: $settings.showMemoryGauge)
                Toggle("通信（↑ 送信・↓ 受信）", isOn: $settings.showNetworkGauge)
                Picker("CPU・メモリの表示", selection: $settings.gaugeStyle) {
                    ForEach(GaugeStyle.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.showCPUGauge && !settings.showMemoryGauge)
                Toggle("数値（%）も表示", isOn: $settings.gaugeNumbers)
                    .disabled(!settings.showCPUGauge && !settings.showMemoryGauge)
                Toggle(isOn: $settings.showTopApp) {
                    Text("いちばん使っているアプリのアイコン")
                    Text("CPU・メモリ・通信の横に、いちばん使っているアプリを表示します。")
                }
                Toggle("アプリアイコンをカラーで表示", isOn: $settings.colorAppIcons)
                    .disabled(!settings.showTopApp)
            } header: {
                Text("Mac 全体の使用状況")
            }

            Section {
                if settings.aiProviders.isEmpty {
                    Text("AI の使用量は「情報連携」タブの「AI の使用量」でオンにできます。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(settings.aiProviders) { p in
                    Toggle(isOn: Binding(
                        get: { settings.menuBarAI.contains(p) },
                        set: { on in
                            if on { if !settings.menuBarAI.contains(p) { settings.menuBarAI.append(p) } }
                            else { settings.menuBarAI.removeAll { $0 == p } }
                        })) {
                        HStack(spacing: 6) {
                            ProviderMarkView(provider: p, color: settings.accent.color).frame(width: 14, height: 14)
                            Text("\(p.name) を表示")
                        }
                    }
                }
                if !settings.aiProviders.isEmpty {
                    Picker("リング横の数値", selection: $settings.claudeNumbers) {
                        ForEach(ClaudeNumbers.allCases) { Text($0.label).tag($0) }
                    }
                    if settings.showAdvanced {
                        Picker("AI の更新間隔", selection: Binding(
                            get: { AppDelegate.shared.ai.claude.refreshMinutes },
                            set: { AppDelegate.shared.ai.claude.refreshMinutes = $0 })) {
                            ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text("\($0)分").tag($0) }
                        }
                    }
                }
            } header: {
                Text("AI の使用量")
            } footer: {
                Text("オンにした AI を、メニューバーとパネルに表示します。リングの外側は短い枠（5時間など）、内側は長い枠（1週間など）です。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.showAdvanced {
            Section {
                Picker("メニューバー", selection: $settings.menuBarInterval) {
                    Text("1秒（頻繁）").tag(1.0)
                    Text("2秒").tag(2.0)
                    Text("3秒（標準）").tag(3.0)
                    Text("5秒").tag(5.0)
                    Text("10秒（省電力）").tag(10.0)
                }
                Picker("パネルを開いているとき", selection: $settings.panelInterval) {
                    Text("0.5秒（非常に頻繁）").tag(0.5)
                    Text("1秒（頻繁）").tag(1.0)
                    Text("2秒（標準）").tag(2.0)
                    Text("5秒").tag(5.0)
                }
            } header: {
                Text("更新頻度")
            } footer: {
                Text("短いほど反応が早くなり、そのぶん負荷が少し上がります。一般タブの「動作の軽さ」を変えると、ここも合わせて変わります。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("アニメーション", selection: $settings.animationMode) {
                    ForEach(AnimationMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("バッテリー駆動中は止める", isOn: $settings.pauseOnBattery)
                    .disabled(settings.animationMode == .still)
                Toggle(isOn: $settings.compatibleCatRendering) {
                    Text("互換描画")
                    Text("キャラクターが表示されないときだけオンにしてください（負荷が少し上がります）。")
                }
            } header: {
                Text("キャラクターのアニメーション")
            } footer: {
                Text("フルスクリーン中・画面スリープ中・低電力モードでは自動で止まります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!settings.showCharacter)
            }
        }
        .formStyle(.grouped)
    }
}

/// Renders the actual menu bar icon with sample values, on a menu-bar-like strip.
private struct IconPreview: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    private var previewApp: String? { settings.showTopApp ? "/Applications/Safari.app" : nil }

    private var previewAI: [AIGauge] {
        let shown = AIProvider.allCases.filter { settings.menuBarAI.contains($0) && settings.aiProviders.contains($0) }
        return shown.enumerated().map { i, p in
            AIGauge(provider: p, tag: shown.count > 1 ? p.tag : nil,
                    outer: [42, 65, 20][i % 3], inner: [18, 30, 8][i % 3], error: false)
        }
    }

    var body: some View {
        let content = IconContent(showCharacter: settings.showCharacter,
                                  cpu: settings.showCPUGauge ? Gauge(percent: 23, app: previewApp) : nil,
                                  memory: settings.showMemoryGauge ? Gauge(percent: 61, app: previewApp) : nil,
                                  network: settings.showNetworkGauge
                                      ? NetGauge(up: "34K", down: "1.2M", app: previewApp) : nil,
                                  showNumbers: settings.gaugeNumbers,
                                  gaugeStyle: settings.gaugeStyle,
                                  colorIcons: settings.colorAppIcons,
                                  ai: previewAI,
                                  numbers: settings.claudeNumbers,
                                  accent: settings.accent, awake: false, character: settings.character)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        let image = IconRenderer.render(content, appearance: appearance, compatible: true,
                                        icon: { NSWorkspace.shared.icon(forFile: $0) }).base
        Image(nsImage: image)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityLabel("メニューバーの表示プレビュー")
    }
}

// MARK: - 掲示板

enum Integrations {
    static func docs(anchor: String?) -> URL {
        URL(string: "https://github.com/oriharu-heaven/Denko/blob/main/INTEGRATIONS.md" + (anchor.map { "#\($0)" } ?? ""))!
    }
}

// MARK: - 今日

// MARK: - スリープ防止

private struct AwakePane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var awake: SleepPreventer

    var body: some View {
        Form {
            Section {
                LabeledContent("現在の状態", value: awake.remainingText())
                Picker("ワンクリックで防止する時間", selection: $settings.keepAwakeDefaultMinutes) {
                    ForEach(SleepPreventer.durations, id: \.self) { Text(SleepPreventer.label(minutes: $0)).tag($0) }
                }
            } footer: {
                Text("メニューバーのアイコンを ⌥クリックすると、この時間でオン / オフを切り替えます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $settings.allowDisplaySleep) {
                    Text("ディスプレイのスリープは許可する")
                    Text("画面は消えますが、Mac 本体はスリープしません。")
                }
                .onChange(of: settings.allowDisplaySleep) { _, _ in awake.reapplyIfActive() }
                Picker("バッテリー残量で自動解除", selection: $settings.keepAwakeBatteryLimit) {
                    Text("しない").tag(0)
                    ForEach([10, 20, 30, 50], id: \.self) { Text("\($0)% 以下").tag($0) }
                }
                Toggle("アプリ起動時にオンにする", isOn: $settings.keepAwakeOnLaunch)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 整理

private struct HiderPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var hider: MenuBarHider

    var body: some View {
        Form {
            Section {
                Toggle("メニューバー整理を有効にする", isOn: $settings.hiderEnabled)
                if !MenuBarHider.isModernMenuBar {
                    Toggle("「常に隠す」セクションを使う", isOn: $settings.alwaysHiddenEnabled)
                }
            } footer: {
                if MenuBarHider.isModernMenuBar {
                    Text("macOS 26 以降は、アクセシビリティを許可したときだけ隠します（アイコンの正確な位置が必要なため）。隠すときもアプリのメニューの右端までしか広げないので、メニューが欠けることはありません。入りきらない項目は macOS の「»」メニューに入ります。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("‹ をクリックで「隠す」項目を表示、⌥クリックで「常に隠す」項目も表示します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Group {
                itemsSection

                Section("表示のしかた") {
                    Toggle("‹ にポインタを乗せたら表示", isOn: $settings.showOnHover)
                    Toggle("一定時間後に自動で隠す", isOn: $settings.autoRehide)
                    if settings.autoRehide {
                        Stepper("\(Int(settings.autoRehideSeconds)) 秒後", value: $settings.autoRehideSeconds,
                                in: 3...60, step: 1)
                    }
                    Toggle("別のアプリに切り替えたら隠す", isOn: $settings.rehideOnAppSwitch)
                }

                Section {
                    Toggle("アプリ起動時に配置を自動で適用", isOn: $settings.autoArrange)
                    Picker("初めて見る項目", selection: $settings.newItemSection) {
                        ForEach(availableSections) { Text($0.label).tag($0) }
                    }
                    .disabled(!settings.autoArrange)
                } header: {
                    Text("自動配置")
                } footer: {
                    Text("アプリがメニューバーに項目を出したとき、上の一覧で決めた場所へ移動します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.hiderEnabled)
        }
        .formStyle(.grouped)
        .onAppear { hider.refreshItems() }
    }

    private var availableSections: [ItemSection] {
        settings.alwaysHiddenEnabled ? ItemSection.allCases : [.visible, .hidden]
    }

    @ViewBuilder
    private var itemsSection: some View {
        Section {
            if !hider.isTrusted {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "hand.raised")
                    Text("項目の一覧と移動にはアクセシビリティの許可が必要です。")
                        .font(.callout)
                    Spacer()
                    Button("許可…") { hider.requestAccessibility() }
                }
            } else if hider.items.isEmpty {
                Text("項目が見つかりません").foregroundStyle(.secondary)
            }
            ForEach(hider.items) { item in
                HStack(spacing: 8) {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app.dashed").frame(width: 18, height: 18)
                    }
                    Text(item.displayName).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Picker(item.displayName, selection: Binding(
                        get: { item.section },
                        set: { hider.setSection($0, for: item) })
                    ) {
                        ForEach(availableSections) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        } header: {
            HStack {
                Text("項目ごとの配置")
                Spacer()
                if hider.isArranging { ProgressView().controlSize(.small) }
                Button("再読み込み") { hider.refreshItems() }
                Button("すべて適用") { Task { await hider.applyAllRules() } }
                    .disabled(hider.isArranging)
            }
            .controlSize(.small)
        } footer: {
            Text("選ぶとその場で ⌘ドラッグ相当の操作で移動します（移動中はマウスに触れないでください）。時計など一部のシステム項目は動かせません。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(hider.isArranging)
    }
}

// MARK: - AI

