import Charts
import SwiftUI

/// Mac-wide usage for one resource: a donut of each app's share with a legend.
/// Tapping a slice or a legend row opens that app's detail.
struct SystemSection: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var apps: AppUsageMonitor
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: PanelState
    let metric: AppUsageMonitor.Metric


    private var accent: Color { settings.accent.color }
    private static let legendSlots = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = state.selectedApp {
                AppDetail(id: id, apps: apps, settings: settings) { state.selectedApp = nil }
            } else {
                summary
                // Network swings by orders of magnitude, so a share-of-a-ring chart says little;
                // a ranked list with bars compares apps directly.
                if metric == .network { networkBars } else { chartAndLegend }
            }
        }
    }

    // MARK: Slices

    private struct Slice: Identifiable {
        let id: String
        let name: String
        let value: Double
        let label: String
        let color: Color
        var isOthers: Bool { id == AppUsageMonitor.othersID || id == Self.freeID }
        static let freeID = "__free__"
    }

    /// Top 5 apps + the rest, colored with steps of the accent (others in gray).
    private var slices: [Slice] {
        let shades: [Double] = [1, 0.78, 0.6, 0.45, 0.32]
        func color(_ i: Int) -> Color { accent.opacity(shades[min(i, shades.count - 1)]) }
        var out: [Slice] = []
        switch metric {
        case .cpu:
            // Top 3 + the rest + idle, so the ring shows the whole CPU (like memory).
            let list = Array(apps.topCPU.prefix(3))
            out = list.enumerated().map { i, a in
                Slice(id: a.id, name: a.name, value: a.cpu, label: String(format: "%.1f%%", a.cpu), color: color(i))
            }
            let rest = monitor.cpu - list.reduce(0) { $0 + $1.cpu }
            if rest >= 0.5 {
                out.append(Slice(id: AppUsageMonitor.othersID, name: "その他", value: rest,
                                 label: String(format: "%.1f%%", rest), color: .gray.opacity(0.35)))
            }
            let idle = max(0, 100 - monitor.cpu)
            if idle > 0 {
                out.append(Slice(id: Slice.freeID, name: "空き", value: idle,
                                 label: String(format: "%.0f%%", idle), color: .gray.opacity(0.12)))
            }
        case .memory:
            // Top 3 + the rest + free memory, so the ring shows the whole of RAM.
            let list = Array(apps.topMemory.prefix(3))
            out = list.enumerated().map { i, a in
                Slice(id: a.id, name: a.name, value: Double(a.memory), label: ByteText.size(Int64(a.memory)), color: color(i))
            }
            let rest = Double(monitor.memoryUsed) - list.reduce(0) { $0 + Double($1.memory) }
            if rest > 100_000_000 {
                out.append(Slice(id: AppUsageMonitor.othersID, name: "その他", value: rest,
                                 label: ByteText.size(Int64(rest)), color: .gray.opacity(0.35)))
            }
            let free = Double(monitor.memoryTotal) - Double(monitor.memoryUsed)
            if free > 0 {
                out.append(Slice(id: Slice.freeID, name: "空き", value: free,
                                 label: ByteText.size(Int64(free)), color: .gray.opacity(0.12)))
            }
        case .network:
            let list = Array(apps.topNetwork.prefix(4))
            out = list.enumerated().map { i, a in
                Slice(id: a.id, name: a.name, value: a.net, label: ByteText.rate(a.net), color: color(i))
            }
            let total = monitor.netDown + monitor.netUp
            let rest = total - list.reduce(0) { $0 + $1.net }
            if rest > 1024 {
                out.append(Slice(id: AppUsageMonitor.othersID, name: "その他", value: rest,
                                 label: ByteText.rate(rest), color: .gray.opacity(0.35)))
            }
        }
        return out
    }

    // MARK: Layout

    @ViewBuilder
    private var summary: some View {
        switch metric {
        case .cpu:
            VStack(alignment: .leading, spacing: 4) {
                BigValue(value: String(format: "%.0f%%", monitor.cpu), caption: "CPU 全体",
                         high: monitor.cpu >= Theme.highUsage, accent: accent)
                Sparkline(values: monitor.cpuHistory, maxCount: SystemMonitor.historyLength, accent: accent)
                    .frame(height: 22)
            }
        case .memory:
            VStack(alignment: .leading, spacing: 4) {
                BigValue(value: ByteText.size(Int64(monitor.memoryUsed)),
                         caption: "/ \(ByteText.size(Int64(monitor.memoryTotal))) 使用中",
                         high: monitor.memoryPercent >= Theme.highUsage, accent: accent)
                // Memory moves slowly: zoom to the recent range (±5 points) so changes are visible.
                let lo = max(0, (monitor.memoryHistory.min() ?? 0) - 5)
                let hi = min(100, (monitor.memoryHistory.max() ?? 100) + 5)
                Sparkline(values: monitor.memoryHistory.map { ($0 - lo) / max(1, hi - lo) * 100 },
                          maxCount: SystemMonitor.historyLength, accent: accent)
                    .frame(height: 22)
            }
        case .network:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 18) {
                    BigValue(value: "↓ " + ByteText.rate(monitor.netDown), caption: "受信", high: false, accent: accent)
                    BigValue(value: "↑ " + ByteText.rate(monitor.netUp), caption: "送信", high: false, accent: accent)
                }
                // Scaled to the busiest moment in view (network has no fixed maximum).
                let peak = max(monitor.networkHistory.max() ?? 0, 1)
                Sparkline(values: monitor.networkHistory.map { $0 / peak * 100 },
                          maxCount: SystemMonitor.historyLength, accent: accent)
                    .frame(height: 22)
            }
        }
    }

    /// Apps by current traffic: name, ↓/↑ split, and a bar scaled to the busiest app.
    private var networkBars: some View {
        let list = Array(apps.topNetwork.prefix(Self.legendSlots))
        let peak = max(list.map(\.net).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<Self.legendSlots, id: \.self) { i in
                if i < list.count {
                    let a = list[i]
                    Button { state.selectedApp = a.id } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                AppIconView(icon: apps.icon(for: a.id), colorIcons: settings.colorAppIcons)
                                    .frame(width: 14, height: 14)
                                Text(a.name).font(.caption).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text("↓\(ByteText.rate(a.netIn))  ↑\(ByteText.rate(a.netOut))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Color.primary.opacity(0.06))
                                    Rectangle().fill(accent.opacity(i == 0 ? 1 : 0.6))
                                        .frame(width: max(3, geo.size.width * a.net / peak))
                                }
                            }
                            .frame(height: 5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(a.name) の詳細")
                } else if i == 0 {
                    Text("いま通信しているアプリはありません").font(.caption).foregroundStyle(.secondary)
                        .frame(height: 22)
                } else {
                    // Keep the height steady while apps come and go.
                    Color.clear.frame(height: 22)
                }
            }
        }
        .frame(minHeight: 150, alignment: .top)
    }

    private var chartAndLegend: some View {
        let data = slices
        return HStack(alignment: .center, spacing: 14) {
            ZStack {
                Chart(data) { s in
                    SectorMark(angle: .value("使用量", max(s.value, 0.0001)),
                               innerRadius: .ratio(0.62), angularInset: 1.2)
                        .cornerRadius(2)
                        .foregroundStyle(s.color)
                }
                .chartLegend(.hidden)
                // Click only: Swift Charts' angle selection also fires on hover on macOS,
                // which opened the details just by moving the pointer over the chart.
                .chartOverlay { _ in
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Circle())
                            .onTapGesture { location in
                                guard let hit = slice(at: location, size: geo.size, in: data), !hit.isOthers else { return }
                                state.selectedApp = hit.id
                            }
                    }
                }
                if data.isEmpty {
                    Circle().stroke(.quaternary, lineWidth: 14).padding(7)
                }
                VStack(spacing: 0) {
                    Text(centerValue).font(.callout.weight(.semibold).monospacedDigit())
                    Text(centerCaption).font(.caption2).foregroundStyle(.secondary)
                }
                .allowsHitTesting(false)
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<Self.legendSlots, id: \.self) { i in
                    if i < data.count {
                        LegendRow(slice: data[i], icon: data[i].isOthers ? nil : apps.icon(for: data[i].id),
                                  colorIcons: settings.colorAppIcons) {
                            if !data[i].isOthers { state.selectedApp = data[i].id }
                        }
                    } else {
                        // Reserve the row so the panel never changes height while data arrives.
                        LegendRow(slice: nil, icon: nil, colorIcons: false) {}
                            .opacity(i == 0 && data.isEmpty ? 1 : 0)
                    }
                }
            }
        }
    }

    private var centerValue: String {
        switch metric {
        case .cpu: return String(format: "%.0f%%", monitor.cpu)
        case .memory: return String(format: "%.0f%%", monitor.memoryPercent)
        case .network: return ByteText.compactRate(monitor.netDown + monitor.netUp)
        }
    }

    private var centerCaption: String {
        switch metric {
        case .cpu: return "全体"
        case .memory: return "使用中"
        case .network: return "合計"
        }
    }

    /// The slice under a click: angle from 12 o'clock, clockwise, as a share of the total.
    private func slice(at point: CGPoint, size: CGSize, in data: [Slice]) -> Slice? {
        let dx = point.x - size.width / 2, dy = point.y - size.height / 2
        guard dx * dx + dy * dy <= pow(min(size.width, size.height) / 2, 2) else { return nil }
        var fraction = atan2(dx, -dy) / (2 * .pi)
        if fraction < 0 { fraction += 1 }
        let total = data.reduce(0) { $0 + max($1.value, 0.0001) }
        var acc = 0.0
        for s in data {
            acc += max(s.value, 0.0001) / total
            if fraction <= acc { return s }
        }
        return data.last
    }

    // MARK: Rows

    private struct LegendRow: View {
        let slice: Slice?
        let icon: NSImage?
        let colorIcons: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Circle().fill(slice?.color ?? .clear).frame(width: 7, height: 7)
                    if slice?.id == Slice.freeID {
                        Color.clear.frame(width: 14, height: 14)
                    } else {
                        AppIconView(icon: icon, isOthers: slice?.isOthers ?? false, colorIcons: colorIcons)
                            .frame(width: 14, height: 14)
                    }
                    Text(slice?.name ?? "集計中…")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(slice == nil ? .secondary : .primary)
                    Spacer(minLength: 4)
                    Text(slice?.label ?? "")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(slice == nil || slice!.isOthers)
            .help(slice.map { $0.isOthers ? $0.name : "\($0.name) の詳細" } ?? "")
        }
    }
}

/// App icon: real icon (grayscale unless color is enabled), gear for "others", terminal for CLI tools.
struct AppIconView: View {
    let icon: NSImage?
    var isOthers = false
    let colorIcons: Bool

    var body: some View {
        if isOthers {
            Image(systemName: "gearshape.2").resizable().scaledToFit().foregroundStyle(.secondary)
        } else if let icon, icon.isTemplate {
            Image(nsImage: icon).resizable().scaledToFit().foregroundStyle(.secondary)
        } else if let icon {
            Image(nsImage: icon).resizable().interpolation(.high).grayscale(colorIcons ? 0 : 1)
        } else {
            Color.clear
        }
    }
}

/// One app's breakdown: its numbers, its biggest processes, and actions.
private struct AppDetail: View {
    let id: String
    @ObservedObject var apps: AppUsageMonitor
    @ObservedObject var settings: AppSettings
    let back: () -> Void
    @State private var confirmQuit = false

    var body: some View {
        let u = apps.usage(of: id)
        let procs = apps.processes[id] ?? []
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("戻る")
                AppIconView(icon: apps.icon(for: id), colorIcons: true).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(u?.name ?? id).font(.headline).lineLimit(1)
                    Text("\(procs.count) プロセス").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("CPU").foregroundStyle(.secondary)
                    Text("メモリ").foregroundStyle(.secondary)
                    Text("通信").foregroundStyle(.secondary)
                }
                .font(.caption)
                GridRow {
                    Text(String(format: "%.1f%%", u?.cpu ?? 0))
                    Text(ByteText.size(Int64(u?.memory ?? 0)))
                    Text((u?.net ?? 0) < 1 ? "—" : ByteText.rate(u?.net ?? 0))
                }
                .font(.callout.weight(.semibold).monospacedDigit())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("プロセス").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(0..<6, id: \.self) { i in
                    if i < procs.count {
                        let p = procs[i]
                        HStack {
                            Text(p.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(String(format: "%.1f%%", p.cpu)).font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                            Text(ByteText.size(Int64(p.memory))).font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                        }
                    } else {
                        Text(" ").font(.caption)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("アクティビティモニタ") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                if id.hasSuffix(".app") {
                    Button("Finder で表示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)])
                    }
                }
                Spacer()
                if let app = runningApp {
                    // Confirmed right here: a dialog would close this panel.
                    if confirmQuit {
                        Button("やめる") { confirmQuit = false }
                        Button("終了する", role: .destructive) { app.terminate(); back() }
                            .foregroundStyle(.red)
                    } else {
                        Button("終了…", role: .destructive) { confirmQuit = true }
                            .foregroundStyle(.red)
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .onExitCommand(perform: back)       // Esc goes back to the list
    }

    private var runningApp: NSRunningApplication? {
        guard id.hasSuffix(".app"), let bundle = Bundle(path: id)?.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
    }

}

private struct BigValue: View {
    let value: String
    let caption: String
    let high: Bool
    let accent: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(high ? accent : .primary)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct Sparkline: View {
    let values: [Double]
    let maxCount: Int
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let step = geo.size.width / CGFloat(max(1, maxCount - 1))
            let offset = CGFloat(maxCount - values.count) * step
            let points = values.enumerated().map { i, v in
                CGPoint(x: offset + CGFloat(i) * step,
                        y: geo.size.height * (1 - CGFloat(min(v, 100)) / 100))
            }
            ZStack {
                // Baseline only, no tile behind the line.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height - 0.5))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 0.5))
                }
                .stroke(.quaternary, lineWidth: 1)
                if let first = points.first, let last = points.last {
                    Path { p in
                        p.move(to: CGPoint(x: first.x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                    }
                    .fill(accent.opacity(0.18))
                    Path { p in p.addLines(points) }
                        .stroke(accent, lineWidth: 1.25)
                }
            }
            .clipped()
        }
        .accessibilityHidden(true)
    }
}
