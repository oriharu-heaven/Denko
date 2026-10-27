import AppKit
import CoreServices
import Foundation

/// One place on disk that could be cleaned up, with how and why.
struct StorageFinding: Identifiable, Codable {
    enum Action: Codable {
        /// Move these to the Trash (reversible) after confirming.
        case trash([URL])
        /// Only show it in Finder; the user decides.
        case reveal(URL)
        /// Irreversible clean-ups are offered as a command to copy, never run for the user.
        case command(String)
    }

    let id: String
    let title: String
    let detail: String
    let size: Int64
    let action: Action
    let revealURL: URL?
}

/// Breakdown of the startup disk plus clean-up suggestions.
/// Everything runs off the main thread and only when the user presses "分析する".
@MainActor
final class StorageAnalyzer: ObservableObject {
    struct Category: Identifiable, Codable {
        let id: String
        let name: String
        let size: Int64
    }

    @Published private(set) var categories: [Category] = []
    @Published private(set) var findings: [StorageFinding] = []
    @Published private(set) var isScanning = false
    @Published private(set) var progress = ""
    @Published private(set) var lastScan: Date?
    /// Result of the last move to the Trash, shown in the panel.
    @Published var trashMessage: String?
    @Published private(set) var total: Int64 = 0
    @Published private(set) var available: Int64 = 0

    var reclaimable: Int64 { findings.reduce(0) { $0 + $1.size } }
    var used: Int64 { max(0, total - available) }

    /// Results are kept for a day (and survive restarts): disk usage changes slowly and a
    /// full analysis takes about a minute.
    static let cacheLifetime: TimeInterval = 24 * 3600

    /// Mode of the last scan; a different mode re-scans.
    private var scannedMode: String?

    func scanIfStale(mode: StorageMode) {
        guard !isScanning, mode != .off else { return }
        if let last = lastScan, Date().timeIntervalSince(last) < Self.cacheLifetime,
           scannedMode == mode.rawValue { return }
        Task { await scan(mode: mode) }
    }

    private struct Saved: Codable {
        let date: Date
        let categories: [Category]
        let findings: [StorageFinding]
        var mode: String?
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Denko", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("storage.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            categories = saved.categories
            // Drop suggestions whose files are already gone.
            findings = saved.findings.filter { f in
                f.revealURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
            }
            lastScan = saved.date
            scannedMode = saved.mode
        }
        refreshVolume()
    }

    private func save() {
        guard let date = lastScan else { return }
        let saved = Saved(date: date, categories: categories, findings: findings, mode: scannedMode)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.cacheURL, options: .atomic) }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let gb: Int64 = 1_000_000_000

    func refreshVolume() {
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            total = Int64(v.volumeTotalCapacity ?? 0)
            available = v.volumeAvailableCapacityForImportantUsage ?? 0
        }
    }

    func scan(mode: StorageMode) async {
        guard !isScanning, mode != .off else { return }
        let full = mode == .full
        isScanning = true
        defer { isScanning = false; progress = "" }
        refreshVolume()
        categories = []
        findings = []

        // 1. Breakdown of the main folders (du is much faster than walking in Swift).
        let home = Self.home
        // かんたん mode skips places macOS guards with a permission prompt: Desktop,
        // Documents, Downloads, media folders and other apps' containers.
        let basicFolders: [(String, String, URL)] = [
            ("apps", String(localized: "アプリケーション"), URL(fileURLWithPath: "/Applications")),
            ("library", String(localized: "ライブラリ（キャッシュ・アプリのデータ）"), home.appendingPathComponent("Library")),
        ]
        let folders: [(String, String, URL)] = full ? [
            ("apps", String(localized: "アプリケーション"), URL(fileURLWithPath: "/Applications")),
            ("library", String(localized: "ライブラリ（キャッシュ・アプリのデータ）"), home.appendingPathComponent("Library")),
            ("documents", String(localized: "書類"), home.appendingPathComponent("Documents")),
            ("desktop", String(localized: "デスクトップ"), home.appendingPathComponent("Desktop")),
            ("downloads", String(localized: "ダウンロード"), home.appendingPathComponent("Downloads")),
            ("pictures", String(localized: "ピクチャ"), home.appendingPathComponent("Pictures")),
            ("movies", String(localized: "ムービー"), home.appendingPathComponent("Movies")),
            ("music", String(localized: "ミュージック"), home.appendingPathComponent("Music")),
        ] : basicFolders
        // All folders at once: the slowest one (usually ~/Library) sets the pace.
        progress = String(localized: "フォルダごとの容量を集計中…")
        var cats: [Category] = []
        await withTaskGroup(of: Category?.self) { group in
            for (id, name, url) in folders {
                group.addTask {
                    let size = await Self.du(url, exclude: full ? [] : Self.guardedInLibrary)
                    return size > 0 ? Category(id: id, name: name, size: size) : nil
                }
            }
            for await c in group {
                if let c { cats.append(c) }
                categories = cats.sorted { $0.size > $1.size }
            }
        }
        let used = total - available
        let other = used - cats.reduce(0) { $0 + $1.size }
        if other > Self.gb {
            cats.append(Category(id: "other", name: full ? String(localized: "システム・その他（隠しフォルダ・スナップショット等）")
                                                    : String(localized: "その他（書類・写真・システムなど）"), size: other))
            categories = cats.sorted { $0.size > $1.size }
        }

        // 2. Clean-up suggestions.
        var found: [StorageFinding] = []
        func add(_ f: StorageFinding?) {
            guard let f, f.size >= 200_000_000 else { return }   // ignore < 200 MB
            found.append(f)
            findings = found.sorted { $0.size > $1.size }
        }

        progress = String(localized: "開発ツールのファイルを確認中…")
        let dev = home.appendingPathComponent("Library/Developer")
        add(await folderFinding("derived", String(localized: "Xcode のビルド中間ファイル（DerivedData）"),
                                String(localized: "ビルドのたびに作られる一時ファイルです。消しても次のビルドで自動的に作り直されます。"),
                                dev.appendingPathComponent("Xcode/DerivedData"), trashContents: true))
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            add(await folderFinding("support-\(platform)", "\(platform) DeviceSupport",
                                    String(localized: "実機をつないだときに作られるデバッグ用ファイルです。古い OS 版のフォルダは消して大丈夫です。"),
                                    dev.appendingPathComponent("Xcode/\(platform) DeviceSupport"), trashContents: false))
        }
        add(await folderFinding("archives", String(localized: "Xcode のアーカイブ"),
                                String(localized: "過去にアーカイブしたビルドです。配布済みで不要なものだけ手動で削除してください。"),
                                dev.appendingPathComponent("Xcode/Archives"), trashContents: false))
        if let sims = await sizeFinding("simulators", String(localized: "iOS シミュレータ"),
                                        String(localized: "使わなくなった OS 版のシミュレータは、右のコマンドでまとめて削除できます。"),
                                        dev.appendingPathComponent("CoreSimulator/Devices"),
                                        action: .command("xcrun simctl delete unavailable")) {
            add(sims)
        }

        progress = String(localized: "キャッシュを確認中…")
        for f in await cacheFindings() { add(f) }

        progress = String(localized: "開発用キャッシュを確認中…")
        let devCaches: [(String, String, String, String)] = [
            ("npm", String(localized: "npm のキャッシュ"), ".npm/_cacache", "npm cache clean --force"),
            ("pnpm", String(localized: "pnpm のストア"), "Library/pnpm/store", "pnpm store prune"),
            ("gradle", String(localized: "Gradle のキャッシュ"), ".gradle/caches", "rm -rf ~/.gradle/caches"),
            ("cargo", String(localized: "Cargo のレジストリ"), ".cargo/registry", "cargo cache --autoclean"),
            ("docker", String(localized: "Docker のディスクイメージ"), "Library/Containers/com.docker.docker/Data/vms", "docker system prune -a"),
        ]
        for (id, title, rel, cmd) in devCaches where full || !rel.contains("Containers") {
            add(await sizeFinding(id, title, String(localized: "開発ツールが溜めたファイルです。右のコマンドで、ツール自身に安全に整理させられます。"),
                                  home.appendingPathComponent(rel), action: .command(cmd)))
        }

        if full {
            progress = String(localized: "ダウンロードを確認中…")
            add(await oldDownloadsFinding())
        }

        progress = String(localized: "しばらく使っていないアプリを確認中…")
        for f in await unusedApps() { add(f) }

        if full {
            progress = String(localized: "大きなファイルを探しています…")
            for f in await largeFiles() { add(f) }

            progress = String(localized: "ゴミ箱を確認中…")
            add(await sizeFinding("trash", String(localized: "ゴミ箱"), String(localized: "ゴミ箱に入っているファイルも容量を使っています。Finder でゴミ箱を空にすると解放されます。"),
                                  home.appendingPathComponent(".Trash"), action: .reveal(home.appendingPathComponent(".Trash"))))
        }

        scannedMode = mode.rawValue
        lastScan = Date()
        save()
    }

    // MARK: - Individual checks

    private func folderFinding(_ id: String, _ title: String, _ detail: String,
                               _ url: URL, trashContents: Bool) async -> StorageFinding? {
        let size = await Self.du(url)
        guard size > 0 else { return nil }
        let action: StorageFinding.Action
        if trashContents {
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            action = .trash(items)
        } else {
            action = .reveal(url)
        }
        return StorageFinding(id: id, title: title, detail: detail, size: size, action: action, revealURL: url)
    }

    private func sizeFinding(_ id: String, _ title: String, _ detail: String,
                             _ url: URL, action: StorageFinding.Action) async -> StorageFinding? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = await Self.du(url)
        guard size > 0 else { return nil }
        return StorageFinding(id: id, title: title, detail: detail, size: size, action: action, revealURL: url)
    }

    /// ~/Library/Caches, per app. Caches are rebuilt by their apps, so they can go to the Trash.
    private func cacheFindings() async -> [StorageFinding] {
        let caches = Self.home.appendingPathComponent("Library/Caches")
        let children = (try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? []
        var out: [StorageFinding] = []
        for child in children {
            let size = await Self.du(child)
            guard size >= 300_000_000 else { continue }
            let name = Self.friendlyCacheName(child.lastPathComponent)
            let isBrew = child.lastPathComponent == "Homebrew"
            out.append(StorageFinding(
                id: "cache-\(child.lastPathComponent)",
                title: name.hasSuffix("の更新ファイル") ? name : String(localized: "\(name) のキャッシュ"),
                detail: isBrew ? String(localized: "古いパッケージのダウンロードです。右のコマンドで Homebrew 自身に整理させるのが安全です。")
                               : String(localized: "一時保存されたデータで、アプリが必要に応じて作り直します。アプリを終了してから削除してください。"),
                size: size, action: isBrew ? .command("brew cleanup --prune=all") : .trash([child]), revealURL: child))
        }
        return out
    }

    private func oldDownloadsFinding() async -> StorageFinding? {
        let downloads = Self.home.appendingPathComponent("Downloads")
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let result: (Int64, Int) = await Task.detached(priority: .utility) {
            let keys: [URLResourceKey] = [.contentAccessDateKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .isDirectoryKey]
            let items = (try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: keys)) ?? []
            var size: Int64 = 0, count = 0
            for item in items {
                guard let v = try? item.resourceValues(forKeys: Set(keys)) else { continue }
                let last = max(v.contentAccessDate ?? .distantPast, v.contentModificationDate ?? .distantPast)
                guard last < cutoff else { continue }
                let s = v.isDirectory == true ? Int64(0) : Int64(v.totalFileAllocatedSize ?? 0)
                size += s
                count += 1
            }
            return (size, count)
        }.value
        guard result.1 > 0 else { return nil }
        return StorageFinding(id: "downloads-old", title: String(localized: "30日以上開いていないダウンロード（\(result.1)件）"),
                              detail: String(localized: "インストーラ（.dmg / .zip）など、一度使ったら不要なものが多い場所です。Finder で確認して削除してください。"),
                              size: result.0, action: .reveal(downloads), revealURL: downloads)
    }

    /// Apps in /Applications not opened for 90 days (Spotlight's last-used date).
    private func unusedApps() async -> [StorageFinding] {
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        let apps = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"),
                                                                 includingPropertiesForKeys: nil)) ?? []
        var out: [StorageFinding] = []
        for app in apps where app.pathExtension == "app" {
            guard let item = MDItemCreateWithURL(nil, app as CFURL) else { continue }
            let last = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            guard last == nil || last! < cutoff else { continue }
            // Skip Apple's own apps.
            if let bundle = Bundle(url: app)?.bundleIdentifier, bundle.hasPrefix("com.apple.") { continue }
            let size = await Self.du(app)
            guard size >= 500_000_000 else { continue }
            let when = last.map { String(localized: "最後に開いたのは \(Self.relative($0))") } ?? String(localized: "開いた記録がありません")
            out.append(StorageFinding(id: "app-\(app.lastPathComponent)",
                                      title: app.deletingPathExtension().lastPathComponent,
                                      detail: String(localized: "\(when)。使っていなければゴミ箱へ（App Store アプリはあとで再ダウンロードできます）。"),
                                      size: size, action: .trash([app]), revealURL: app))
        }
        return out
    }

    /// Files over 1 GB in the home folder, via Spotlight (fast, no walking).
    private func largeFiles() async -> [StorageFinding] {
        let home = Self.home
        let paths: [String] = await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            p.arguments = ["-onlyin", home.path, "kMDItemFSSize > 1000000000"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }.value
        var out: [StorageFinding] = []
        for path in paths where !path.contains("/Library/") && !path.contains(".app/") {
            let url = URL(fileURLWithPath: path)
            let size = Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            guard size > 0 else { continue }
            out.append(StorageFinding(id: "big-\(path)", title: url.lastPathComponent,
                                      detail: String(localized: "1GB を超えるファイルです（\(url.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~"))）。不要なら削除、残したいなら外部ストレージへ。"),
                                      size: size, action: .reveal(url), revealURL: url))
        }
        return Array(out.sorted { $0.size > $1.size }.prefix(8))
    }

    // MARK: - Actions

    /// Moves the finding's items to the Trash after confirmation. Reversible from the Trash.
    func moveToTrash(_ f: StorageFinding) {
        guard case .trash(let urls) = f.action, !urls.isEmpty else { return }
        var failed = 0
        for url in urls {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { failed += 1 }
        }
        findings.removeAll { $0.id == f.id }
        refreshVolume()
        save()
        trashMessage = failed > 0
            ? String(localized: "\(failed) 個の項目を移動できませんでした。使っているアプリを終了してから、もう一度お試しください。")
            : String(localized: "「\(f.title)」をゴミ箱に入れました。ゴミ箱を空にすると容量が空きます。")

    }

    // MARK: - Helpers

    /// Allocated size of a folder via `du -sk` (fast, C implementation), off the main thread.
    /// Folders inside ~/Library that hold other apps' data (macOS asks before letting us in).
    nonisolated static let guardedInLibrary = ["Containers", "Group Containers", "Mail", "Messages",
                                               "Safari", "Mobile Documents", "Calendars", "Reminders"]

    nonisolated static func du(_ url: URL, exclude: [String] = []) async -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            p.arguments = ["-sk"] + exclude.flatMap { ["-I", $0] } + [url.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return Int64(0) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let kb = String(decoding: data, as: UTF8.self).split(separator: "\t").first.flatMap { Int64($0) } ?? 0
            return kb * 1024
        }.value
    }

    private static func friendlyCacheName(_ folder: String) -> String {
        // "<bundle id>.ShipIt" folders hold downloaded app updates.
        if folder.hasSuffix(".ShipIt") {
            return friendlyCacheName(String(folder.dropLast(".ShipIt".count))) + String(localized: " の更新ファイル")
        }
        if folder.hasSuffix("-updater") {
            return friendlyCacheName(String(folder.dropLast("-updater".count))) + String(localized: " の更新ファイル")
        }
        let known = ["org.swift.swiftpm": "Swift Package Manager", "Unity": "Unity", "UnityHub": "Unity Hub",
                     "unityhub": "Unity Hub", "antigravity": "Antigravity", "com.google.antigravity": "Antigravity",
                     "vscode-cpptools": "VS Code C/C++ 拡張", "com.apple.dt.Xcode": "Xcode",
                     "JetBrains": "JetBrains IDE", "node-gyp": "node-gyp", "typescript": "TypeScript",
                     "electron": "Electron", "com.anthropic.claudefordesktop": "Claude",
"com.google.Chrome": "Google Chrome", "Google": "Google", "com.apple.Safari": "Safari",
                     "com.spotify.client": "Spotify", "pip": "pip（Python）", "Yarn": "Yarn", "Homebrew": "Homebrew",
                     "com.microsoft.VSCode.ShipIt": "VS Code 更新", "com.tinyspeck.slackmacgap": "Slack",
                     "CocoaPods": "CocoaPods", "ms-playwright": "Playwright のブラウザ", "go-build": "Go のビルド"]
        let known2 = known
        if let k = known2[folder] { return k }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: folder) {
            return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        }
        return folder
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        return f
    }()

    private static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
