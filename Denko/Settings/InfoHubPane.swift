import SwiftUI

/// 情報連携: everything that flows into Denko — today's info, coding agents & AI, and
/// GitHub / RSS / Webhook. Each is a tile; the selected tile's options
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
    @State private var statusLineInstalled = false
    @State private var statusLineError: String?
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
        case weather, disaster, news, trains, fx
        case claudeCode, codex, aiUsage
        case github, rss
        var id: String { rawValue }

        static let today: [Feed] = [.weather, .disaster, .news, .trains, .fx]
        static let coding: [Feed] = [.claudeCode, .codex, .aiUsage]
        static let others: [Feed] = [.github, .rss]

        /// Filled glyph for the colored icon square (System Settings style).
        var filledSymbol: String {
            switch self {
            case .weather: return "cloud.sun.fill"
            case .disaster: return "exclamationmark.triangle.fill"
            case .news: return "newspaper.fill"
            case .trains: return "tram.fill"
            case .fx: return "yensign"
            case .claudeCode, .codex: return "terminal.fill"
            case .aiUsage: return "gauge.with.dots.needle.67percent"
            case .github: return "arrow.triangle.branch"
            case .rss: return "dot.radiowaves.up.forward"
            }
        }

        var tint: Color {
            switch self {
            case .weather: return .blue
            case .disaster: return .red
            case .news: return .orange
            case .trains: return .green
            case .fx: return .teal
            case .claudeCode: return .brown
            case .codex: return .gray
            case .aiUsage: return .pink
            case .github: return Color(white: 0.2)
            case .rss: return .orange
            }
        }

        /// One sentence for the top of the detail page.
        var blurb: String {
            switch self {
            case .weather: return String(localized: "いまの天気と、この先の雨をお知らせします。")
            case .disaster: return String(localized: "気象庁の情報から、強い揺れ・津波・地元の警報をすぐに流します。")
            case .news: return String(localized: "選んだ配信元の見出しを一覧に表示します。")
            case .trains: return String(localized: "見ている路線で遅延や運転見合わせが出たら、すぐに流します。")
            case .fx: return String(localized: "主な通貨の参考レートと、大きな値動きをお知らせします。")
            case .claudeCode: return String(localized: "許可待ち・入力待ちと、応答の完了を掲示板に流します。")
            case .codex: return String(localized: "作業の完了を掲示板に流します。")
            case .aiUsage: return String(localized: "Claude・Codex の利用枠を表示します。")
            case .github: return String(localized: "レビュー依頼やメンションを流します。")
            case .rss: return String(localized: "好きなサイトの新着を流します。")
            }
        }
        var title: String {
            switch self {
            case .weather: return String(localized: "天気")
            case .disaster: return String(localized: "防災")
            case .news: return String(localized: "ニュース")
            case .trains: return String(localized: "運行情報")
            case .fx: return String(localized: "為替")
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            case .aiUsage: return String(localized: "AI の使用量")
            case .github: return "GitHub"
            case .rss: return "RSS"
            }
        }
        var symbol: String {
            switch self {
            case .weather: return "cloud.sun"
            case .disaster: return "exclamationmark.triangle"
            case .news: return "newspaper"
            case .trains: return "tram"
            case .fx: return "yensign.circle"
            case .claudeCode, .codex: return "terminal"
            case .aiUsage: return "gauge.with.dots.needle.67percent"
            case .github: return "arrow.triangle.branch"
            case .rss: return "dot.radiowaves.up.forward"
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
        // セットアップ (or another button) asked for a particular page.
        .onReceive(SettingsRouter.shared.$infoDetail.compactMap { $0 }) { feed in
            detail = feed
            SettingsRouter.shared.infoDetail = nil
        }
        .onAppear {
            hooksInstalled = ClaudeCodeHooks.isInstalled(endpoint: server.endpoint)
            statusLineInstalled = ClaudeStatusLine.isInstalled(endpoint: server.endpoint)
            codexInstalled = CodexNotify.isInstalled(endpoint: server.endpoint)
        }
    }

    // MARK: - Overview (System Settings style list)

    private var overview: some View {
        Form {
            Section(String(localized: "今日の情報")) {
                ForEach(Feed.today) { row($0) }
            }

            Section(String(localized: "コーディング・AI")) {
                ForEach(Feed.coding) { row($0) }
            }

            Section(String(localized: "そのほか")) {
                ForEach(Feed.others) { row($0) }
            }

            Section {
                DisclosureGroup(String(localized: "情報の出典")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "天気: Open-Meteo（open-meteo.com、CC BY 4.0）"))
                        Text(String(localized: "防災: \(DisasterFeed.attribution)"))
                        Text(String(localized: "ニュース: 選んだ配信元（NHK・Yahoo!ニュース・Google ニュース・BBC など）"))
                        Text(String(localized: "運行情報: 公共交通オープンデータセンター"))
                        Text(TrainFeed.attribution).foregroundStyle(.tertiary)
                        Text(String(localized: "為替: Frankfurter（欧州中央銀行の参考レート）"))
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
                    if place.isLocating { ProgressView().controlSize(.small) } else { Text(String(localized: "現在地を使う")) }
                }
                .disabled(place.isLocating)
            }
            TextField(String(localized: "地域を変更"), text: $place.query, prompt: Text(String(localized: "市区町村名（例: 渋谷区、大阪市）")))
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
                        Button(String(localized: "システム設定を開く")) {
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
                        if let caption = on ? summary(f) : offText(f) {
                            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([f.title, on ? summary(f) : offText(f)].compactMap { $0 }.joined(separator: "、"))
            .accessibilityHint(String(localized: "詳しい設定を開きます"))
            Toggle(f.title, isOn: isOn(f)).toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(!isAvailable(f))
            Button { detail = f } label: {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "\(f.title)の詳しい設定"))
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
                    Toggle(f.title, isOn: isOn(f)).toggleStyle(.switch).labelsHidden()
                        .disabled(!isAvailable(f))
                }
                .padding(.vertical, 4)
            }
            Section {
                Group {
                    switch f {
                    case .weather: weatherOptions
                    case .disaster: disasterOptions
                    case .news: newsOptions
                    case .trains: trainOptions
                    case .fx: fxOptions
                    case .claudeCode: LabeledContent(String(localized: "変更するファイル"), value: "~/.claude/settings.json")
                    case .codex: LabeledContent(String(localized: "変更するファイル"), value: "~/.codex/config.toml")
                    case .aiUsage: aiOptions
                    case .github: githubOptions
                    case .rss: rssOptions
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
                    Label(String(localized: "情報連携"), systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("[", modifiers: .command)
                .help(String(localized: "戻る（⌘[ または esc）"))
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
        case .trains: return $settings.infoTrains
        case .fx: return $settings.infoFX
        case .claudeCode: return Binding(get: { hooksInstalled }, set: { $0 ? installHooks() : uninstallHooks() })
        case .codex: return Binding(get: { codexInstalled }, set: { $0 ? installCodex() : uninstallCodex() })
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
        }
    }

    /// What's on, chosen or wrong — nil when the row's title and switch already say it.
    private func summary(_ f: Feed) -> String? {
        switch f {
        case .trains: return settings.trainLines.isEmpty ? String(localized: "路線が未設定") : nil
        case .fx: return settings.fxPairs.isEmpty ? String(localized: "通貨ペアが未設定") : nil
        case .rss: return settings.rssFeeds.isEmpty ? String(localized: "フィードが未設定") : nil
        default: return nil
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

    private func offText(_ f: Feed) -> String? {
        switch f {
        case .claudeCode: return AIProvider.claude.isDetected ? String(localized: "未連携") : String(localized: "この Mac では見つかりません")
        case .codex: return CodexNotify.isAvailable ? String(localized: "未連携") : String(localized: "この Mac では見つかりません")
        case .github: return hasGitHubToken ? String(localized: "オフ") : String(localized: "トークンが未設定")
        default: return nil
        }
    }

    /// Tiles whose options are needed to turn them on (tokens, explanations).
    private static let optionsWhileOff: Set<Feed> = [.claudeCode, .codex, .aiUsage, .github]

    // MARK: - Coding & AI

    @ViewBuilder
    private var aiOptions: some View {
        ForEach(AIProvider.offered(settings)) { p in
            Toggle(isOn: Binding(
                get: { settings.aiProviders.contains(p) },
                set: { on in
                    if on {
                        settings.aiProviders.append(p)
                        if !settings.menuBarAI.contains(p) { settings.menuBarAI.append(p) }
                    }
                    else { settings.aiProviders.removeAll { $0 == p }; settings.menuBarAI.removeAll { $0 == p } }
                    if p == .claude { setStatusLine(on) }
                })) {
                Text(p.name)
            }
            .disabled(!p.isDetected && !settings.aiProviders.contains(p))
            if settings.aiProviders.contains(p), let e = ai.errors[p] {
                Text(e).font(.caption).foregroundStyle(.secondary)
            }
        }
        if settings.aiProviders.contains(.claude) {
            LabeledContent(String(localized: "Claude Code のステータスライン")) {
                if statusLineInstalled { Text(String(localized: "連携済み")).foregroundStyle(.secondary) }
                else { Button(String(localized: "連携する")) { setStatusLine(true) } }
            }
        }
        if let statusLineError { Text(statusLineError).font(.caption).foregroundStyle(.secondary) }
    }

    private func setStatusLine(_ on: Bool) {
        do {
            if on { try ClaudeStatusLine.install(endpoint: server.endpoint) } else { try ClaudeStatusLine.uninstall() }
            statusLineError = nil
        } catch {
            statusLineError = String(localized: "Claude Code の設定を変更できませんでした: \(error.localizedDescription)")
        }
        statusLineInstalled = ClaudeStatusLine.isInstalled(endpoint: server.endpoint)
    }

    // MARK: - そのほか

    private var githubOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(String(localized: "トークン"), text: $githubToken, prompt: Text(hasGitHubToken ? String(localized: "保存済み") : "ghp_… / github_pat_…"))
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "保存")) {
                    AppDelegate.shared.github.setToken(githubToken)
                    githubToken = ""
                    hasGitHubToken = AppDelegate.shared.github.hasToken
                    if hasGitHubToken { settings.githubEnabled = true }
                    AppDelegate.shared.github.setEnabled(settings.githubEnabled)
                }
                .disabled(githubToken.isEmpty)
                if hasGitHubToken {
                    Button(String(localized: "削除")) {
                        AppDelegate.shared.github.setToken(nil)
                        hasGitHubToken = false
                        settings.githubEnabled = false
                    }
                }
            }
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
                        .accessibilityLabel(String(localized: "削除"))
                }
            }
            HStack {
                TextField(String(localized: "フィード URL"), text: $newFeed, prompt: Text("https://…/feed.xml"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addFeed)
                Button(String(localized: "追加"), action: addFeed)
                    .disabled(URL(string: newFeed)?.scheme?.hasPrefix("http") != true)
            }
            Picker(String(localized: "確認する間隔"), selection: $settings.rssMinutes) {
                ForEach([15, 30, 60, 180], id: \.self) { Text(String(localized: "\($0) 分")).tag($0) }
            }
            .frame(maxWidth: 260)
        }
    }

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
        alert.addButton(withTitle: String(localized: "連携する"))
        alert.addButton(withTitle: String(localized: "キャンセル"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func installHooks() {
        guard confirm(String(localized: "Claude Code と連携しますか？"), String(localized: "~/.claude/settings.json にフックを追加します。元のファイルは同じフォルダにバックアップされます。")) else { return }
        do { try ClaudeCodeHooks.install(endpoint: server.endpoint); hookError = nil } catch { hookError = error.localizedDescription }
        hooksInstalled = ClaudeCodeHooks.isInstalled(endpoint: server.endpoint)
    }

    private func uninstallHooks() {
        do { try ClaudeCodeHooks.uninstall(); hookError = nil } catch { hookError = error.localizedDescription }
        hooksInstalled = ClaudeCodeHooks.isInstalled(endpoint: server.endpoint)
    }

    private func installCodex() {
        guard confirm(String(localized: "Codex と連携しますか？"), String(localized: "~/.codex/config.toml に、作業完了を Denko に知らせる notify の設定を1行追加します。元のファイルは同じフォルダにバックアップされます。")) else { return }
        do { try CodexNotify.install(endpoint: server.endpoint); hookError = nil } catch { hookError = error.localizedDescription }
        codexInstalled = CodexNotify.isInstalled(endpoint: server.endpoint)
    }

    private func uninstallCodex() {
        do { try CodexNotify.uninstall(); hookError = nil } catch { hookError = error.localizedDescription }
        codexInstalled = CodexNotify.isInstalled(endpoint: server.endpoint)
    }

    // MARK: - Today

    private var weatherOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            locationRow
            if let w = info.weather {
                HStack(spacing: 10) {
                    Image(systemName: WeatherCode.symbol(w.code)).symbolRenderingMode(.hierarchical)
                        .font(.system(size: 26)).foregroundStyle(accent)
                    VStack(alignment: .leading) {
                        Text("\(settings.weatherPlace)　\(Int(w.temperature.rounded()))° \(WeatherCode.text(w.code))")
                        Text(String(localized: "最高 \(Int(w.high.rounded()))°　最低 \(Int(w.low.rounded()))°　降水 \(w.rainChance)%"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var disasterOptions: some View {
note(String(localized: "緊急地震速報には対応していません"))
    }

    @ViewBuilder
    private var newsOptions: some View {
        Picker(String(localized: "配信元"), selection: Binding(
            get: { settings.newsFeed.sourceID },
            set: { settings.newsFeed = NewsChoice($0) })) {
            Section(String(localized: "国内")) {
                ForEach(NewsCatalog.sources.filter { !$0.overseas }) { Text($0.name).tag($0.id) }
            }
            Section(String(localized: "海外")) {
                ForEach(NewsCatalog.sources.filter(\.overseas)) { Text($0.name).tag($0.id) }
            }
        }
        let src = settings.newsFeed.source
        if src.categories.count > 1 {
            Picker(String(localized: "カテゴリ"), selection: Binding(
                get: { settings.newsFeed.categoryID },
                set: { settings.newsFeed = NewsChoice("\(src.id)/\($0)") })) {
                ForEach(src.categories) { Text($0.label).tag($0.id) }
            }
        }
        if !info.news.isEmpty {
            LabeledContent(String(localized: "いまの見出し")) {
                Text(info.news.first?.title ?? "").foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private var trainOptions: some View {
        watchedLines
        linePicker
        DisclosureGroup(String(localized: "東京メトロ・横浜市営など")) { odptKeyRow }
    }

    /// The lines being watched, each with a button to stop watching it.
    @ViewBuilder
    private var watchedLines: some View {
        if settings.trainLines.isEmpty {
        } else {
            LabeledContent(String(localized: "見ている路線（\(settings.trainLines.count)）")) {
                Button(String(localized: "すべて外す")) { settings.trainLines = [] }.controlSize(.small)
            }
        }
        ForEach(settings.trainLines, id: \.self) { name in
            let line = info.allTrainLines.first { $0.name == name }
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                    if let line {
                        Text(String(localized: "\(line.company)・\(line.status)")).font(.caption).foregroundStyle(.secondary)
                    } else if !info.allTrainLines.isEmpty {
                        Text(String(localized: "公開データなし"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    settings.trainLines.removeAll { $0 == name }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "この路線を見ない"))
                .accessibilityLabel(String(localized: "\(name)を見ない"))
            }
        }
    }

    /// A search field, then region → company → line.
    @ViewBuilder
    private var linePicker: some View {
        TextField(String(localized: "路線を探す"), text: $lineSearch, prompt: Text(String(localized: "路線名（例: 山手線、大阪環状線、銀座線）")))
        if info.allTrainLines.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "全国の路線を読み込んでいます…")).font(.caption).foregroundStyle(.secondary)
            }
        } else if !lineSearch.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = lineSearch.trimmingCharacters(in: .whitespaces)
            let hits = info.allTrainLines.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.company.contains(q) }
            if hits.isEmpty { note(String(localized: "「\(q)」に合う路線はありません。")) }
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
                            Text(picked > 0 ? String(localized: "\(picked) 路線を選択中") : String(localized: "\(inRegion.count) 路線")).foregroundStyle(.secondary)
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
            if showPlace { Text(String(localized: "\(line.region)・\(line.company)")) }
        }
    }

    private var odptKeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(String(localized: "ODPT アクセストークン"), text: $odptKey,
                            prompt: Text(hasODPTKey ? String(localized: "登録済み（変更する場合は入力）") : String(localized: "東京メトロ・私鉄も見るとき（任意）")))
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "保存")) {
                    Keychain.save(odptKey, account: TrainFeed.keychainAccount)
                    odptKey = ""
                    hasODPTKey = TrainFeed.hasKey
                    Task { await info.refreshTrains() }
                }
                .disabled(odptKey.isEmpty)
                if hasODPTKey {
                    Button(String(localized: "削除")) {
                        Keychain.save(nil, account: TrainFeed.keychainAccount)
                        hasODPTKey = false
                        Task { await info.refreshTrains() }
                    }
                }
            }
            Link(String(localized: "トークンを無料で取得（公共交通オープンデータセンター）"), destination: URL(string: "https://developer.odpt.org/")!)
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
        Picker(String(localized: "大きく動いたらお知らせ"), selection: $settings.fxAlertPercent) {
            Text(String(localized: "流さない")).tag(0.0)
            ForEach([0.5, 1.0, 2.0], id: \.self) { Text(String(format: String(localized: "前日比 %.1f%% 以上"), $0)).tag($0) }
        }
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
