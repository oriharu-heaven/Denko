import SwiftUI

/// Disk tab: what's using the space, and what could be cleaned up.
struct StorageSection: View {
    @ObservedObject var analyzer: StorageAnalyzer
    @ObservedObject var settings: AppSettings

    private var accent: Color { settings.accent.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary

            if !analyzer.categories.isEmpty {
                breakdown
            }

            if analyzer.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(analyzer.progress).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let msg = analyzer.trashMessage {
                Label(msg, systemImage: msg.contains("できませんでした") ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(msg.contains("できませんでした") ? Color.orange : Color.secondary)
            }

            if !analyzer.findings.isEmpty {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text("減らせそうなもの").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("合計 \(ByteText.size(analyzer.reclaimable))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(accent)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(analyzer.findings.enumerated()), id: \.element.id) { i, f in
                            if i > 0 { Divider() }
                            FindingRow(finding: f, accent: accent, analyzer: analyzer)
                        }
                    }
                }
                .frame(maxHeight: 300)
            } else if analyzer.lastScan != nil && !analyzer.isScanning {
                Label("大きく減らせそうなものは見つかりませんでした", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            modeFooter
        }
        .onAppear {
            analyzer.refreshVolume()
            analyzer.scanIfStale(mode: settings.storageMode)   // loads by itself, cached for a day
        }
    }

    /// かんたん / 詳しく. 詳しく reads Desktop, Documents etc., which macOS guards with prompts.
    /// Switching to 詳しく makes macOS ask for folder access, so it's done in Settings (where
    /// the reason is explained and the dialogs don't close this panel), not from here.
    private var modeFooter: some View {
        HStack(spacing: 8) {
            Text(settings.storageMode == .full ? "書類やデスクトップも含めて調べています" : "アプリ・キャッシュなどを調べています")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if settings.storageMode != .full {
                Button("詳しく調べる…") { AppDelegate.shared.openSettings() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    /// Used / total / free, a stacked bar of what's using the space, and its legend.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("使用中 \(ByteText.size(analyzer.used))")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(lowSpace ? accent : .primary)
                Text("/ 全体 \(ByteText.size(analyzer.total))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(analyzer.isScanning ? "分析中…" : "再分析") { Task { await analyzer.scan(mode: settings.storageMode) } }
                    .controlSize(.small)
                    .disabled(analyzer.isScanning)
            }
            stackedBar.frame(height: 12)
            HStack {
                Text("空き \(ByteText.size(analyzer.available))（\(Int((1 - usedFraction) * 100))%）")
                    .foregroundStyle(lowSpace ? accent : .secondary)
                Spacer()
                if let last = analyzer.lastScan, !analyzer.isScanning {
                    Text("内訳は \(last, style: .relative)前に分析").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
        }
    }

    /// Segments in steps of the accent, "システム・その他" in gray, free space as the track.
    private var segments: [(name: String, size: Int64, color: Color)] {
        let shades: [Double] = [1, 0.78, 0.6, 0.45, 0.32, 0.22]
        var out: [(String, Int64, Color)] = []
        var i = 0
        for c in analyzer.categories where c.size > 0 {
            let isOther = c.id == "other"
            out.append((c.name, c.size, isOther ? Color.gray.opacity(0.45) : accent.opacity(shades[min(i, shades.count - 1)])))
            if !isOther { i += 1 }
        }
        return out
    }

    private var stackedBar: some View {
        GeometryReader { geo in
            let total = max(1, Double(analyzer.total))
            HStack(spacing: 1) {
                if segments.isEmpty {
                    // Before the breakdown arrives: just used vs free.
                    Rectangle().fill(accent.opacity(0.6))
                        .frame(width: geo.size.width * usedFraction)
                } else {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                        Rectangle().fill(s.color)
                            .frame(width: max(1, geo.size.width * Double(s.size) / total))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary)
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(segments.prefix(8).enumerated()), id: \.offset) { _, s in
                HStack(spacing: 6) {
                    Rectangle().fill(s.color).frame(width: 9, height: 9)
                    Text(s.name).font(.caption).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(ByteText.size(s.size))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("\(Int((Double(s.size) / Double(max(1, analyzer.total)) * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
            HStack(spacing: 6) {
                Rectangle().strokeBorder(.tertiary).frame(width: 9, height: 9)
                Text("空き").font(.caption)
                Spacer(minLength: 6)
                Text(ByteText.size(analyzer.available)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("\(Int(((1 - usedFraction) * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }

    private var usedFraction: Double {
        guard analyzer.total > 0 else { return 0 }
        return Double(analyzer.total - analyzer.available) / Double(analyzer.total)
    }

    private var lowSpace: Bool { analyzer.total > 0 && Double(analyzer.available) / Double(analyzer.total) < 0.1 }

    private func fraction(_ size: Int64) -> Double {
        guard analyzer.total > 0 else { return 0 }
        return min(1, Double(size) / Double(analyzer.total - analyzer.available))
    }
}

private struct FindingRow: View {
    let finding: StorageFinding
    let accent: Color
    let analyzer: StorageAnalyzer
    @State private var copied = false
    @State private var confirmTrash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(finding.title).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(ByteText.size(finding.size))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(finding.size >= 5_000_000_000 ? accent : .primary)
            }
            Text(finding.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                switch finding.action {
                case .trash:
                    // Asked in place (a dialog would close the panel). Reversible from the Trash.
                    if confirmTrash {
                        Button("やめる") { confirmTrash = false }
                        Button("ゴミ箱に入れる", role: .destructive) { analyzer.moveToTrash(finding) }
                            .foregroundStyle(.red)
                    } else {
                        Button("ゴミ箱に入れる…") { confirmTrash = true }
                    }
                case .reveal:
                    EmptyView()
                case .command(let cmd):
                    Button(copied ? "コピーしました" : "コマンドをコピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                        copied = true
                    }
                    .help(cmd)
                    Text(cmd).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                if let url = finding.revealURL {
                    Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.vertical, 9)
    }
}
