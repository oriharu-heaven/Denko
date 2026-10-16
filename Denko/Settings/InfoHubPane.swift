import SwiftUI

/// 情報連携: everything that flows into Denko — today's info, coding agents & AI, and (in the
/// detailed settings) GitHub / RSS / Webhook. Each is a tile; the selected tile's options
/// open right under its group.
struct InfoHubPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var info: InfoStore = AppDelegate.shared.info
    @ObservedObject var ai: AIUsageStore = AppDelegate.shared.ai
    @ObservedObject var claude: UsageStore = AppDelegate.shared.ai.claude
    @StateObject private var place: PlaceService
    @State private var detail: Feed?
    @State private var odptKey = ""
    @State private var hasODPTKey = TrainFeed.hasKey
    @State private var hooksInstalled = false
    @State private var codexInstalled = false
    @State private var hookError: String?
    @State private var githubToken = ""
    @State private var hasGitHubToken = AppDelegate.shared.github.hasToken
    @State private var newFeed = ""
    @State private var sessionKey = ""
    @State private var copied: String?
    @State private var lineSearch = ""

    private var server: LocalNotifyServer { AppDelegate.shared.notifyServer }

    init(settings: AppSettings, detail: Feed? = nil) {
        self.settings = settings
        _detail = State(initialValue: detail)
        _place = StateObject(wrappedValue: PlaceService(settings: settings) {
            Task {
                await AppDelegate.shared.info.refreshWeather()
                AppDelegate.shared.info.schedule()
            }
        })
    }

    enum Feed: String, CaseIterable, Identifiable {
        case weather, disaster, news, trends, trains, fx
        case claudeCode, codex, otherAgents, aiUsage
        case github, rss, webhook
        var id: String { rawValue }

        static let today: [Feed] = [.weather, .disaster, .news, .trends, .trains, .fx]
        static let coding: [Feed] = [.claudeCode, .codex, .otherAgents, .aiUsage]
        static let others: [Feed] = [.github, .rss, .webhook]
        /// Tiles that only describe how to connect (no on/off of their own).
        var isGuide: Bool { self == .otherAgents }

        /// Filled glyph for the colored icon square (System Settings style).
        var filledSymbol: String {
            switch self {
            case .weather: return "cloud.sun.fill"
            case .disaster: return "exclamationmark.triangle.fill"
            case .news: return "newspaper.fill"
            case .trends: return "chart.line.uptrend.xyaxis"
            case .trains: return "tram.fill"
            case .fx: return "yensign"
            case .claudeCode, .codex: return "terminal.fill"
            case .otherAgents: return "puzzlepiece.extension.fill"
            case .aiUsage: return "gauge.with.dots.needle.67percent"
            case .github: return "arrow.triangle.branch"
            case .rss: return "dot.radiowaves.up.forward"
            case .webhook: return "link"
            }
        }

        var tint: Color {
            switch self {
            case .weather: return .blue
            case .disaster: return .red
            case .news: return .orange
            case .trends: return .purple
            case .trains: return .green
            case .fx: return .teal
            case .claudeCode: return .brown
            case .codex: return .gray
            case .otherAgents: return .indigo
            case .aiUsage: return .pink
            case .github: return Color(white: 0.2)
            case .rss: return .orange
            case .webhook: return .gray
            }
        }

        /// One sentence for the top of the detail page.
        var blurb: String {
            switch self {
            case .weather: return "いまの天気と、この先の雨をお知らせします。"
            case .disaster: return "気象庁の情報から、強い揺れ・津波・地元の警報をすぐに流します。"
            case .news: return "選んだ配信元の見出しを流します。NHK の速報は常に1分ごとに確認します。"
            case .trends: return "いま検索が急に増えている言葉を表示します。"
            case .trains: return "見ている路線で遅延や運転見合わせが出たら、すぐに流します。"
            case .fx: return "主な通貨の参考レートと、大きな値動きをお知らせします。"
            case .claudeCode: return "許可待ち・入力待ちと、応答の完了を掲示板に流します。"
            case .codex: return "作業の完了を掲示板に流します。"
            case .otherAgents: return "フックや作業後のコマンドから、どのエージェントでもつなげられます。"
            case .aiUsage: return "Claude・Codex・Gemini の利用枠を読み取ります。"
            case .github: return "レビュー依頼やメンションを流します。"
            case .rss: return "好きなサイトの新着を流します。"
            case .webhook: return "スクリプトやショートカットから掲示板に送れます（コーディングエージェントの連携とは別です）。"
            }
        }
        var title: String {
            switch self {
            case .weather: return "天気"
            case .disaster: return "防災"
            case .news: return "ニュース"
            case .trends: return "トレンド"
            case .trains: return "運行情報"
            case .fx: return "為替"
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            case .otherAgents: return "そのほかのエージェント"
            case .aiUsage: return "AI の使用量"
            case .github: return "GitHub"
            case .rss: return "RSS"
            case .webhook: return "Webhook"
            }
        }
        var symbol: String {
            switch self {
            case .weather: return "cloud.sun"
            case .disaster: return "exclamationmark.triangle"
            case .news: return "newspaper"
            case .trends: return "chart.line.uptrend.xyaxis"
            case .trains: return "tram"
            case .fx: return "yensign.circle"
            case .claudeCode, .codex: return "terminal"
            case .otherAgents: return "puzzlepiece.extension"
            case .aiUsage: return "gauge.with.dots.needle.67percent"
            case .github: return "arrow.triangle.branch"
            case .rss: return "dot.radiowaves.up.forward"
            case .webhook: return "link"
            }
        }
    }

    private var accent: Color { settings.accent.color }

    var body: some View {
        Group {
            if let detail {
                detailPage(detail)
            } else {
                overview
            }
        }
        .onAppear {
            hooksInstalled = ClaudeCodeHooks.isInstalled(endpoint: server.endpoint)
            codexInstalled = CodexNotify.isInstalled(endpoint: server.endpoint)
        }
    }

    // MARK: - Overview (System Settings style list)

    private var overview: some View {
        Form {
            Section {
                locationRow
            } header: {
                Text("地域")
            } footer: {
                Text("天気と防災情報に使います。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("今日の情報") {
                ForEach(Feed.today) { row($0) }
            }

            Section {
                Picker("定期的に流す", selection: $settings.infoRollMinutes) {
                    Text("流さない").tag(0)
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0)分ごと").tag($0) }
                }
                Button("今すぐ流す") { info.roll() }
            } footer: {
                Text("オンにした情報を、掲示板に順番に流します。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("コーディング・AI") {
                ForEach(Feed.coding) { row($0) }
            }

            Section("そのほか") {
                ForEach(Feed.others) { row($0) }
            }

            Section {
                DisclosureGroup("情報の出典") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("天気: Open-Meteo（open-meteo.com、CC BY 4.0）")
                        Text("防災: \(DisasterFeed.attribution)")
                        Text("ニュース: 選んだ配信元（NHK・Yahoo!ニュース・Google ニュース・BBC など）")
                        Text("トレンド: Google トレンド")
                        Text("運行情報: JR東日本 運行情報ページ、公共交通オープンデータセンター")
                        Text(TrainFeed.attribution).foregroundStyle(.tertiary)
                        Text("為替: Frankfurter（欧州中央銀行の参考レート）")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var locationRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SettingsIcon(symbol: "location.fill", color: .blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(settings.weatherPlace)
                    Text(settings.weatherPrefecture).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    place.useCurrentLocation()
                } label: {
                    if place.isLocating { ProgressView().controlSize(.small) } else { Text("現在地を使う") }
                }
                .disabled(place.isLocating)
            }
            TextField("地域を変更", text: $place.query, prompt: Text("市区町村名（例: 渋谷区、大阪市）"))
                .onSubmit { Task { await place.choose(place.query) } }
            if !place.suggestions.isEmpty && !place.query.isEmpty {
                ForEach(place.suggestions) { s in
                    Button {
                        Task { await place.choose([s.title, s.subtitle].filter { !$0.isEmpty }.joined(separator: " ")) }
                    } label: {
                        HStack {
                            Text(s.title)
                            Text(s.subtitle).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let error = place.error {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    if error.contains("許可") {
                        Button("システム設定を開く") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    /// One row: icon, name, current state, switch, and a chevron into the details. The name
    /// and the chevron are real buttons, so VoiceOver and keyboard users can open the details too.
    private func row(_ f: Feed) -> some View {
        let on = isOn(f).wrappedValue
        return HStack(spacing: 10) {
            Button { detail = f } label: {
                HStack(spacing: 10) {
                    SettingsIcon(symbol: f.filledSymbol, color: f.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.title)
                        Text(on || f.isGuide ? summary(f) : offText(f))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(f.title)、\(on || f.isGuide ? summary(f) : offText(f))")
            .accessibilityHint("詳しい設定を開きます")
            if !f.isGuide {
                Toggle(f.title, isOn: isOn(f)).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .disabled(!isAvailable(f))
            }
            Button { detail = f } label: {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(f.title)の詳しい設定")
        }
    }

    // MARK: - Detail page

    private func detailPage(_ f: Feed) -> some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    SettingsIcon(symbol: f.filledSymbol, color: f.tint, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.title).font(.title3.weight(.semibold))
                        Text(f.blurb).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !f.isGuide {
                        Toggle(f.title, isOn: isOn(f)).toggleStyle(.switch).labelsHidden()
                            .disabled(!isAvailable(f))
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Group {
                    switch f {
                    case .weather: weatherOptions
                    case .disaster: disasterOptions
                    case .news: newsOptions
                    case .trends:
                        note("Google トレンドの急上昇ワードを使います（X のトレンドは公式に取得できないため使っていません）。")
                    case .trains: trainOptions
                    case .fx: fxOptions
                    case .claudeCode:
                        note("連携すると ~/.claude/settings.json にフックを追加します。変更前に同じフォルダへバックアップを作ります。")
                    case .codex:
                        note("連携すると ~/.codex/config.toml に notify の設定を1行追加します。すでに別の notify 設定がある場合は上書きしません。")
                    case .otherAgents: otherAgentsOptions
                    case .aiUsage: aiOptions
                    case .github: githubOptions
                    case .rss: rssOptions
                    case .webhook: webhookOptions
                    }
                    if let hookError, f == .claudeCode || f == .codex {
                        Label(hookError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
                .disabled(!isOn(f).wrappedValue && !Self.optionsWhileOff.contains(f))
            }
        }
        .formStyle(.grouped)
        .onExitCommand { detail = nil }
        // Choosing lines needs every region's list (normally only the watched ones are read).
        .task(id: f) { if f == .trains { await info.refreshTrains(everything: true) } }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button { detail = nil } label: {
                    Label("情報連携", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("[", modifiers: .command)
                .help("戻る（⌘[ または esc）")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }

    // MARK: - State of each item

    private func isOn(_ f: Feed) -> Binding<Bool> {
        switch f {
        case .weather: return $settings.infoWeather
        case .disaster: return $settings.infoDisaster
        case .news: return $settings.infoNews
        case .trends: return $settings.infoTrends
        case .trains: return $settings.infoTrains
        case .fx: return $settings.infoFX
        case .claudeCode: return Binding(get: { hooksInstalled }, set: { $0 ? installHooks() : uninstallHooks() })
        case .codex: return Binding(get: { codexInstalled }, set: { $0 ? installCodex() : uninstallCodex() })
        case .otherAgents: return .constant(true)
        case .aiUsage: return Binding(get: { !settings.aiProviders.isEmpty }, set: { on in
            if on {
                let found = AIProvider.allCases.filter(\.isDetected)
                settings.aiProviders = found.isEmpty ? [.claude] : found
                settings.menuBarAI = settings.aiProviders   // turned on = shown; hide one in メニューバー
            } else {
                settings.aiProviders = []
                settings.menuBarAI = []
            }
        })
        case .github: return Binding(get: { settings.githubEnabled && hasGitHubToken }, set: { on in
            settings.githubEnabled = on && hasGitHubToken
            AppDelegate.shared.github.setEnabled(settings.githubEnabled)
        })
        case .rss: return $settings.rssEnabled
        case .webhook: return $settings.notifyServerEnabled
        }
    }

    private func summary(_ f: Feed) -> String {
        switch f {
        case .weather:
            return info.weather.map { "\(settings.weatherPlace)　\(Int($0.temperature.rounded()))° \(WeatherCode.text($0.code))" } ?? settings.weatherPlace
        case .disaster: return "地震・津波・\(settings.weatherPrefecture)の警報"
        case .news: return settings.newsFeed.label
        case .trends: return "Google 急上昇ワード"
        case .trains: return settings.trainLines.isEmpty ? "\(settings.effectiveTrainRegion)の全路線" : "\(settings.trainLines.count) 路線"
        case .fx: return settings.fxPairs.isEmpty ? "通貨ペア未選択" : settings.fxPairs.map { "\($0.prefix(3))/\($0.suffix(3))" }.joined(separator: "・")
        case .claudeCode, .codex: return "連携済み"
        case .otherAgents: return "Gemini CLI・Antigravity・Cursor など"
        case .aiUsage: return settings.aiProviders.map(\.name).joined(separator: "・")
        case .github: return "レビュー依頼・メンション"
        case .rss: return "\(settings.rssFeeds.count) 件のフィード"
        case .webhook: return "この Mac から受け付け"
        }
    }

    /// Agents not installed on this Mac can't be connected.
    private func isAvailable(_ f: Feed) -> Bool {
        switch f {
        case .claudeCode: return hooksInstalled || AIProvider.claude.isDetected
        case .codex: return codexInstalled || CodexNotify.isAvailable
        case .github: return hasGitHubToken
        default: return true
        }
    }

    private func offText(_ f: Feed) -> String {
        switch f {
        case .claudeCode: return AIProvider.claude.isDetected ? "未連携" : "この Mac では見つかりません"
        case .codex: return CodexNotify.isAvailable ? "未連携" : "この Mac では見つかりません"
        case .github: return hasGitHubToken ? "オフ" : "トークンが未設定"
        default: return "オフ"
        }
    }

    /// Tiles whose options are needed to turn them on (tokens, explanations).
    private static let optionsWhileOff: Set<Feed> = [.claudeCode, .codex, .otherAgents, .aiUsage, .github]

    // MARK: - Coding & AI

    private var otherAgentsOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            note("Gemini CLI・Antigravity・Cursor などは、フックや作業後に実行するコマンドから Denko に送れます。")
            HStack {
                Button(copyLabel("受け付け用の URL をコピー", server.endpoint)) { copy(server.endpoint) }
                Button(copyLabel("完了を送るコマンドをコピー", "curl -s -X POST '\(server.endpoint)?source=agent&agent=Gemini&event=done'")) {
                    copy("curl -s -X POST '\(server.endpoint)?source=agent&agent=Gemini&event=done'")
                }
                Spacer()
                Link("やり方を見る", destination: Integrations.docs(anchor: "coding-agents"))
            }
        }
    }

    @ViewBuilder
    private var aiOptions: some View {
        ForEach(AIProvider.allCases) { p in
            Toggle(isOn: Binding(
                get: { settings.aiProviders.contains(p) },
                set: { on in
                    if on {
                        settings.aiProviders.append(p)
                        if !settings.menuBarAI.contains(p) { settings.menuBarAI.append(p) }
                    }
                    else { settings.aiProviders.removeAll { $0 == p }; settings.menuBarAI.removeAll { $0 == p } }
                })) {
                Text(p.name)
                Text(p.isDetected ? "この Mac で使われています" : "この Mac では見つかりません")
            }
            if settings.aiProviders.contains(p), let e = ai.errors[p] {
                Text(e).font(.caption).foregroundStyle(.secondary)
            }
        }
        if settings.showAdvanced && settings.aiProviders.contains(.claude) {
            LabeledContent("claude.ai セッションキー") {
                HStack {
                    SecureField("セッションキー", text: $sessionKey,
                                prompt: Text(claude.hasSessionKey ? "保存済み" : "任意"))
                        .labelsHidden()
                    Button("保存") { claude.setSessionKey(sessionKey); sessionKey = "" }
                        .disabled(sessionKey.isEmpty)
                    if claude.hasSessionKey { Button("削除") { claude.setSessionKey("") } }
                }
            }
            note("Claude Code を使っていない場合だけ必要です。ブラウザで claude.ai にログインし、開発者ツールの Cookie にある「sessionKey」の値を貼り付けると、claude.ai の使用量を読み取ります。")
        }
        note("ログイン情報は読み取るだけで、外部には送りません。オンにした AI はメニューバーとパネルに表示されます（メニューバータブで個別に隠せます）。")
    }

    // MARK: - そのほか

    private var githubOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("トークン", text: $githubToken, prompt: Text(hasGitHubToken ? "保存済み" : "ghp_… / github_pat_…"))
                    .textFieldStyle(.roundedBorder)
                Button("保存") {
                    AppDelegate.shared.github.setToken(githubToken)
                    githubToken = ""
                    hasGitHubToken = AppDelegate.shared.github.hasToken
                    if hasGitHubToken { settings.githubEnabled = true }
                    AppDelegate.shared.github.setEnabled(settings.githubEnabled)
                }
                .disabled(githubToken.isEmpty)
                if hasGitHubToken {
                    Button("削除") {
                        AppDelegate.shared.github.setToken(nil)
                        hasGitHubToken = false
                        settings.githubEnabled = false
                    }
                }
            }
            note("notifications 権限のある Personal Access Token を入れると、レビュー依頼やメンションが流れます。キーチェーンに保存されます。")
        }
    }

    private var rssOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(settings.rssFeeds, id: \.self) { feed in
                HStack {
                    Text(feed).lineLimit(1).truncationMode(.middle).font(.callout)
                    Spacer()
                    Button { settings.rssFeeds.removeAll { $0 == feed } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("削除")
                }
            }
            HStack {
                TextField("フィード URL", text: $newFeed, prompt: Text("https://…/feed.xml"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addFeed)
                Button("追加", action: addFeed)
                    .disabled(URL(string: newFeed)?.scheme?.hasPrefix("http") != true)
            }
            Picker("確認する間隔", selection: $settings.rssMinutes) {
                ForEach([15, 30, 60, 180], id: \.self) { Text("\($0) 分").tag($0) }
            }
            .frame(maxWidth: 260)
        }
    }

    private var webhookOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(server.endpoint).font(.caption.monospaced()).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            HStack {
                Button(copyLabel("URL をコピー", server.endpoint)) { copy(server.endpoint) }
                Button(copyLabel("curl の例をコピー", "curl -X POST '\(server.endpoint)?title=ビルド完了'")) {
                    copy("curl -X POST '\(server.endpoint)?title=ビルド完了'")
                }
                Spacer()
                Link("やり方を見る", destination: Integrations.docs(anchor: nil))
            }
            note("この Mac の中からだけ受け付けます（127.0.0.1）。オフにしても、Claude Code・Codex などコーディングエージェントからのお知らせは届きます。")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == text { copied = nil } }
    }

    /// Button label that briefly says it worked.
    private func copyLabel(_ title: String, _ text: String) -> String { copied == text ? "コピーしました" : title }

    private func addFeed() {
        let f = newFeed.trimmingCharacters(in: .whitespaces)
        guard URL(string: f)?.scheme?.hasPrefix("http") == true, !settings.rssFeeds.contains(f) else { return }
        settings.rssFeeds.append(f)
        settings.rssEnabled = true
        newFeed = ""
    }

    private func confirm(_ title: String, _ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "連携する")
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func installHooks() {
        guard confirm("Claude Code と連携しますか？", "~/.claude/settings.json にフックを追加します。元のファイルは同じフォルダにバックアップされます。") else { return }
        do { try ClaudeCodeHooks.install(endpoint: server.endpoint); hookError = nil } catch { hookError = error.localizedDescription }
        hooksInstalled = ClaudeCodeHooks.isInstalled(endpoint: server.endpoint)
    }

    private func uninstallHooks() {
        do { try ClaudeCodeHooks.uninstall(); hookError = nil } catch { hookError = error.localizedDescription }
        hooksInstalled = ClaudeCodeHooks.isInstalled(endpoint: server.endpoint)
    }

    private func installCodex() {
        guard confirm("Codex と連携しますか？", "~/.codex/config.toml に、作業完了を Denko に知らせる notify の設定を1行追加します。元のファイルは同じフォルダにバックアップされます。") else { return }
        do { try CodexNotify.install(endpoint: server.endpoint); hookError = nil } catch { hookError = error.localizedDescription }
        codexInstalled = CodexNotify.isInstalled(endpoint: server.endpoint)
    }

    private func uninstallCodex() {
        do { try CodexNotify.uninstall(); hookError = nil } catch { hookError = error.localizedDescription }
        codexInstalled = CodexNotify.isInstalled(endpoint: server.endpoint)
    }

    // MARK: - Today

    private var weatherOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let w = info.weather {
                HStack(spacing: 10) {
                    Image(systemName: WeatherCode.symbol(w.code)).symbolRenderingMode(.hierarchical)
                        .font(.system(size: 26)).foregroundStyle(accent)
                    VStack(alignment: .leading) {
                        Text("\(settings.weatherPlace)　\(Int(w.temperature.rounded()))° \(WeatherCode.text(w.code))")
                        Text("最高 \(Int(w.high.rounded()))°　最低 \(Int(w.low.rounded()))°　降水 \(w.rainChance)%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            note("雨が近づくと掲示板でお知らせします。地域は前の画面の「地域」で変えられます。")
        }
    }

    @ViewBuilder
    private var disasterOptions: some View {
        LabeledContent("緊急で流すもの") {
            VStack(alignment: .trailing, spacing: 2) {
                Text("震度5弱以上の地震")
                Text("\(settings.weatherPrefecture)で震度3以上の地震")
                Text("津波警報・注意報、噴火速報")
                Text("\(settings.weatherPrefecture)の気象警報・土砂災害警戒情報")
            }
            .foregroundStyle(.secondary)
        }
        LabeledContent("ふつうに流すもの") { Text("震度4の地震").foregroundStyle(.secondary) }
        note("気象庁の情報を1分ごとに確認します。緊急地震速報（揺れる前の警報）には対応していません。流し方は「掲示板」タブで変えられます。")
    }

    @ViewBuilder
    private var newsOptions: some View {
        Picker("配信元", selection: Binding(
            get: { settings.newsFeed.sourceID },
            set: { settings.newsFeed = NewsChoice($0) })) {
            Section("国内") {
                ForEach(NewsCatalog.sources.filter { !$0.overseas }) { Text($0.name).tag($0.id) }
            }
            Section("海外") {
                ForEach(NewsCatalog.sources.filter(\.overseas)) { Text($0.name).tag($0.id) }
            }
        }
        let src = settings.newsFeed.source
        if src.categories.count > 1 {
            Picker("カテゴリ", selection: Binding(
                get: { settings.newsFeed.categoryID },
                set: { settings.newsFeed = NewsChoice("\(src.id)/\($0)") })) {
                ForEach(src.categories) { Text($0.label).tag($0.id) }
            }
        }
        if !info.news.isEmpty {
            LabeledContent("いまの見出し") {
                Text(info.news.first?.title ?? "").foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private var trainOptions: some View {
        Picker("見る路線", selection: Binding(
            get: { settings.trainLines.isEmpty },
            set: { settings.trainLines = $0 ? [] : TrainFeed.defaultLines })) {
            Text("地域の全路線").tag(true)
            Text("選んだ路線だけ").tag(false)
        }
        if settings.trainLines.isEmpty {
            Picker("地域", selection: Binding(
                get: { settings.effectiveTrainRegion },
                set: { settings.trainRegion = $0; Task { await info.refreshTrains() } })) {
                ForEach(TrainFeed.regions, id: \.self) { Text($0).tag($0) }
            }
        } else {
            linePicker
        }
        note("JR東日本・JR西日本・東京メトロ・都営・京王・京急・近鉄の公式の運行情報を使います（京王・京急・近鉄は会社ごとにまとめて表示）。")
        if settings.showAdvanced { odptKeyRow }
    }

    /// Picked lines first, then a search field, then region → company → line.
    @ViewBuilder
    private var linePicker: some View {
        LabeledContent("選んだ路線（\(settings.trainLines.count)）") {
            Text(settings.trainLines.prefix(4).joined(separator: "・") + (settings.trainLines.count > 4 ? " ほか" : ""))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        TextField("路線を探す", text: $lineSearch, prompt: Text("路線名（例: 山手線、大阪環状線、銀座線）"))
        if info.allTrainLines.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("全国の路線を読み込んでいます…").font(.caption).foregroundStyle(.secondary)
            }
        } else if !lineSearch.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = lineSearch.trimmingCharacters(in: .whitespaces)
            let hits = info.allTrainLines.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.company.contains(q) }
            if hits.isEmpty { note("「\(q)」に合う路線はありません。") }
            ForEach(hits.prefix(30)) { line in lineToggle(line, showPlace: true) }
        } else {
            ForEach(TrainFeed.regions, id: \.self) { region in
                let inRegion = info.allTrainLines.filter { $0.region == region }
                if !inRegion.isEmpty {
                    let picked = inRegion.filter { settings.trainLines.contains($0.name) }.count
                    DisclosureGroup {
                        let companies = Dictionary(grouping: inRegion, by: \.company)
                        ForEach(companies.keys.sorted(), id: \.self) { company in
                            let lines = companies[company] ?? []
                            if lines.count == 1, let only = lines.first {
                                lineToggle(only, showPlace: false, label: "\(company)：\(only.name)")
                            } else {
                                DisclosureGroup {
                                    ForEach(lines) { lineToggle($0, showPlace: false) }
                                } label: {
                                    LabeledContent(company) {
                                        Text("\(lines.filter { settings.trainLines.contains($0.name) }.count) / \(lines.count)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } label: {
                        LabeledContent(region) {
                            Text(picked > 0 ? "\(picked) 路線を選択中" : "\(inRegion.count) 路線").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func lineToggle(_ line: TrainFeed.Line, showPlace: Bool, label: String? = nil) -> some View {
        Toggle(isOn: Binding(
            get: { settings.trainLines.contains(line.name) },
            set: { on in
                if on { if !settings.trainLines.contains(line.name) { settings.trainLines.append(line.name) } }
                else { settings.trainLines.removeAll { $0 == line.name } }
            })) {
            Text(label ?? line.name)
            if showPlace { Text("\(line.region)・\(line.company)") }
        }
    }

    private var odptKeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField("ODPT アクセストークン", text: $odptKey,
                            prompt: Text(hasODPTKey ? "登録済み（変更する場合は入力）" : "東京メトロ・私鉄も見るとき（任意）"))
                    .textFieldStyle(.roundedBorder)
                Button("保存") {
                    Keychain.save(odptKey, account: TrainFeed.keychainAccount)
                    odptKey = ""
                    hasODPTKey = TrainFeed.hasKey
                    Task { await info.refreshTrains() }
                }
                .disabled(odptKey.isEmpty)
                if hasODPTKey {
                    Button("削除") {
                        Keychain.save(nil, account: TrainFeed.keychainAccount)
                        hasODPTKey = false
                        Task { await info.refreshTrains() }
                    }
                }
            }
            Link("トークンを無料で取得（公共交通オープンデータセンター）", destination: URL(string: "https://developer.odpt.org/")!)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var fxOptions: some View {
        ForEach(FXFeed.pairs, id: \.self) { pair in
            Toggle("\(pair.prefix(3)) / \(pair.suffix(3))", isOn: Binding(
                get: { settings.fxPairs.contains(pair) },
                set: { on in
                    settings.fxPairs = on ? FXFeed.pairs.filter { settings.fxPairs.contains($0) || $0 == pair }
                                          : settings.fxPairs.filter { $0 != pair }
                }))
        }
        Picker("大きく動いたらお知らせ", selection: $settings.fxAlertPercent) {
            Text("流さない").tag(0.0)
            ForEach([0.5, 1.0, 2.0], id: \.self) { Text(String(format: "前日比 %.1f%% 以上", $0)).tag($0) }
        }
        note("欧州中央銀行の参考レート（営業日ごとに1回更新）を使います。")
    }

    // MARK: - Small parts


    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }


}


/// Glyph in a colored rounded square, like the rows of System Settings.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}
