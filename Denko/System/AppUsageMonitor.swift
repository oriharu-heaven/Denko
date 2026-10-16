import AppKit
import CoreImage
import Darwin

/// Which apps are using how much CPU / memory / network, Mac-wide.
///
/// Helper processes are folded into the app responsible for them (Chrome renderers →
/// Google Chrome, WebContent → Safari), like Activity Monitor does. Processes we can't
/// read (root daemons) end up in "その他（システム）", computed from the system totals.
@MainActor
final class AppUsageMonitor: ObservableObject {
    struct AppUsage: Identifiable, Equatable {
        let id: String           // bundle path or "proc:<name>"
        let name: String
        var cpu: Double = 0      // % of the whole machine (0–100)
        var memory: UInt64 = 0
        var netIn: Double = 0    // bytes/sec
        var netOut: Double = 0
        var net: Double { netIn + netOut }
    }

    enum Metric: String, CaseIterable, Identifiable {
        case cpu, memory, network
        var id: String { rawValue }
        var label: String {
            switch self {
            case .cpu: return "CPU"
            case .memory: return "メモリ"
            case .network: return "通信"
            }
        }
    }

    nonisolated static let othersID = "__others__"

    /// One process inside an app (for the app detail view).
    struct ProcessUsage: Identifiable, Equatable {
        let pid: pid_t
        let name: String
        var cpu: Double
        var memory: UInt64
        var id: pid_t { pid }
    }

    /// Processes per app, collected only while the panel is open.
    @Published private(set) var processes: [String: [ProcessUsage]] = [:]
    private var processNames: [pid_t: (start: UInt64, name: String)] = [:]

    func usage(of id: String) -> AppUsage? { lastByApp[id] }

    /// Apps sorted by each metric (top 8 each).
    @Published private(set) var topCPU: [AppUsage] = []
    @Published private(set) var topMemory: [AppUsage] = []
    @Published private(set) var topNetwork: [AppUsage] = []
    /// The app using the most of each, for the menu bar icons.
    @Published private(set) var leader: [Metric: String] = [:]

    private var menuBarNeedsNetwork = false
    private var active = false
    private var detailed = false
    private var timer: Timer?
    private var tick = 0

    private var prevCPU: [pid_t: (start: UInt64, ns: UInt64)] = [:]
    private var prevAt: UInt64 = 0
    private var appOf: [pid_t: (start: UInt64, key: String)] = [:]
    private var names: [String: String] = [:]
    private var icons: [String: NSImage] = [:]
    private var grayIcons: [String: NSImage] = [:]
    private var prevNet: [pid_t: (rx: UInt64, tx: UInt64)] = [:]
    private var prevNetAt: Date?
    private var netTaskRunning = false
    private var lastByApp: [String: AppUsage] = [:]
    /// Processes we may not read (root daemons); skipped until the next refresh.
    private var denied = Set<pid_t>()

    private let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(tb.denom))
    }()
    private let responsible: ((pid_t) -> pid_t)? = {
        typealias Fn = @convention(c) (pid_t) -> pid_t
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        return { fn($0) }
    }()

    /// menuBar: CPU + memory leaders every 3s (network every 6s if shown).
    /// detailed: full lists every 2s while the panel is open.
    private var menuBarInterval: TimeInterval = 6
    private var panelInterval: TimeInterval = 2

    func configure(menuBar: Bool, menuBarNetwork: Bool, detailed: Bool,
                   menuBarInterval: TimeInterval = 6, panelInterval: TimeInterval = 2) {
        menuBarNeedsNetwork = menuBarNetwork
        let wantActive = menuBar || detailed
        let intervalsChanged = menuBarInterval != self.menuBarInterval || panelInterval != self.panelInterval
        self.menuBarInterval = menuBarInterval
        self.panelInterval = panelInterval
        guard wantActive != active || detailed != self.detailed || intervalsChanged else { return }
        active = wantActive
        self.detailed = detailed
        timer?.invalidate()
        timer = nil
        guard wantActive else {
            prevCPU = [:]; prevNet = [:]; prevNetAt = nil
            return
        }
        sample()
        // Menu bar only needs the leading app, which rarely changes: scan less often.
        let interval: TimeInterval = detailed ? panelInterval : menuBarInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = interval * 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Icons

    func icon(for id: String) -> NSImage? {
        if let cached = icons[id] { return cached }
        let img: NSImage
        if id.hasSuffix(".app") {
            img = NSWorkspace.shared.icon(forFile: id)
        } else if id == Self.othersID {
            img = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? NSImage()
        } else {
            img = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        }
        icons[id] = img
        return img
    }

    /// Grayscale variant for the black + one accent palette (template symbols pass through).
    func icon(for id: String, grayscale: Bool) -> NSImage? {
        guard grayscale, let base = icon(for: id), !base.isTemplate else { return icon(for: id) }
        if let cached = grayIcons[id] { return cached }
        var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        guard let cg = base.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return base }
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let gray = Self.ciContext.createCGImage(output, from: output.extent)
        else { return base }
        let img = NSImage(cgImage: gray, size: NSSize(width: 32, height: 32))
        // macOS renders app icons lazily and may hand back a blank placeholder at first;
        // don't keep that, try again next time.
        if !Self.looksBlank(cg) { grayIcons[id] = img }
        return img
    }

    /// True for empty / single-tone placeholder icons (no visible detail).
    private static func looksBlank(_ cg: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: cg)
        var lum: [CGFloat] = []
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5,
                      let rgb = c.usingColorSpace(.sRGB) else { continue }
                lum.append(0.3 * rgb.redComponent + 0.59 * rgb.greenComponent + 0.11 * rgb.blueComponent)
            }
        }
        guard lum.count > 10 else { return true }
        let mean = lum.reduce(0, +) / CGFloat(lum.count)
        let variance = lum.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / CGFloat(lum.count)
        return variance < 0.002
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Sampling

    private func sample() {
        tick += 1
        let now = mach_absolute_time()
        let wallNs = prevAt == 0 ? 0 : (now - prevAt) * timebase.numer / timebase.denom
        prevAt = now

        let capacity = proc_listallpids(nil, 0) + 64
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = Int(proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.size)))

        var byApp: [String: AppUsage] = [:]
        var perApp: [String: [ProcessUsage]] = [:]
        var nextCPU: [pid_t: (start: UInt64, ns: UInt64)] = [:]
        nextCPU.reserveCapacity(count)
        if tick % 20 == 0 { denied.removeAll() }
        for pid in pids.prefix(max(0, count)) where pid > 0 && !denied.contains(pid) {
            var ri = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ri) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
                }
            }
            guard ok else { denied.insert(pid); continue }
            let start = ri.ri_proc_start_abstime
            let key = appKey(pid: pid, start: start)
            let cpuNs = (ri.ri_user_time + ri.ri_system_time) * timebase.numer / timebase.denom
            nextCPU[pid] = (start, cpuNs)

            var u = byApp[key] ?? AppUsage(id: key, name: names[key] ?? key)
            u.memory += ri.ri_phys_footprint
            var pcpu = 0.0
            if wallNs > 0, let prev = prevCPU[pid], prev.start == start, cpuNs >= prev.ns {
                pcpu = Double(cpuNs - prev.ns) / Double(wallNs) * 100 / cores
                u.cpu += pcpu
            }
            byApp[key] = u
            if detailed {
                perApp[key, default: []].append(ProcessUsage(pid: pid, name: processName(pid, start: start),
                                                             cpu: pcpu, memory: ri.ri_phys_footprint))
            }
        }
        prevCPU = nextCPU
        appOf = appOf.filter { nextCPU[$0.key] != nil || prevNet[$0.key] != nil }
        if detailed {
            processNames = processNames.filter { nextCPU[$0.key] != nil }
            processes = perApp.mapValues { list in
                Array(list.sorted { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) }.prefix(8))
            }
        } else if !processes.isEmpty {
            processes = [:]
        }

        // Carry network rates over until nettop answers.
        for (k, old) in lastByApp where old.net > 0 {
            byApp[k, default: AppUsage(id: k, name: old.name)].netIn = old.netIn
            byApp[k, default: AppUsage(id: k, name: old.name)].netOut = old.netOut
        }
        publish(byApp)

        let wantNet = detailed || menuBarNeedsNetwork
        if wantNet { sampleNetwork() }
    }

    private func publish(_ byApp: [String: AppUsage]) {
        lastByApp = byApp
        let apps = Array(byApp.values)
        let cpu = Array(apps.filter { $0.cpu >= 0.05 }.sorted { $0.cpu > $1.cpu }.prefix(8))
        let mem = Array(apps.sorted { $0.memory > $1.memory }.prefix(8))
        let net = Array(apps.filter { $0.net >= 1 }.sorted { $0.net > $1.net }.prefix(8))
        if cpu != topCPU { topCPU = cpu }
        if mem != topMemory { topMemory = mem }
        if net != topNetwork { topNetwork = net }
        var proposed: [Metric: String] = [:]
        proposed[.cpu] = cpu.first.flatMap { $0.cpu >= 1 ? $0.id : nil }
        proposed[.memory] = mem.first?.id
        proposed[.network] = netEMA.max { $0.value < $1.value }.flatMap { $0.value >= 1024 ? $0.key : nil }
        // Value of each app per metric, to judge whether a challenger clearly leads.
        let value: [Metric: (String) -> Double] = [
            .cpu: { id in byApp[id]?.cpu ?? 0 },
            .memory: { id in Double(byApp[id]?.memory ?? 0) },
            .network: { [netEMA] id in netEMA[id] ?? 0 },
        ]
        var l = leader
        for m in Metric.allCases { l[m] = stabilized(m, proposed: proposed[m], value: value[m]!) }
        if l != leader { leader = l }
    }

    /// Hysteresis so the menu bar icon doesn't flicker: a new leader must use clearly more
    /// (1.5×) than the current one twice in a row, and an idle leader lingers for 30s.
    private var challenger: [Metric: (id: String, wins: Int)] = [:]
    /// Smoothed network rate per app (EMA, ~20s), so bursty traffic doesn't reshuffle the leader.
    private var netEMA: [String: Double] = [:]
    private var lastActive: [Metric: Date] = [:]
    private static let linger: TimeInterval = 30

    private func stabilized(_ m: Metric, proposed: String?, value: (String) -> Double) -> String? {
        let current = leader[m]
        guard let proposed else {
            challenger[m] = nil
            if current != nil, Date().timeIntervalSince(lastActive[m] ?? .distantPast) < Self.linger {
                return current
            }
            return nil
        }
        if proposed == current {
            challenger[m] = nil
            lastActive[m] = Date()
            return current
        }
        // Still in use and only marginally behind? Keep the current leader.
        if let current, value(current) > 0, value(proposed) < value(current) * 1.5 {
            challenger[m] = nil
            lastActive[m] = Date()
            return current
        }
        let wins = challenger[m]?.id == proposed ? (challenger[m]!.wins + 1) : 1
        if current == nil || wins >= 2 {
            challenger[m] = nil
            lastActive[m] = Date()
            return proposed
        }
        challenger[m] = (proposed, wins)
        return current
    }

    /// Resolves the app a process belongs to (cached per pid + start time).
    private func appKey(pid: pid_t, start: UInt64) -> String {
        if let c = appOf[pid], c.start == start { return c.key }
        let owner = responsible?(pid) ?? pid
        let path = Self.path(of: owner > 0 ? owner : pid)
        let key: String
        if let r = path.range(of: ".app/") {
            key = String(path[..<r.lowerBound]) + ".app"
            if names[key] == nil {
                names[key] = NSRunningApplication(processIdentifier: owner)?.localizedName
                    ?? FileManager.default.displayName(atPath: key).replacingOccurrences(of: ".app", with: "")
            }
        } else {
            let name = path.isEmpty ? "pid \(pid)" : (path as NSString).lastPathComponent
            key = "proc:" + name
            names[key] = name
        }
        let bare = key.hasPrefix("proc:") ? String(key.dropFirst(5)) : key
        if let friendly = Self.friendlyNames[((bare as NSString).lastPathComponent as NSString).deletingPathExtension] {
            names[key] = friendly
        }
        appOf[pid] = (start, key)
        return key
    }

    /// Readable names for helpers whose bundle / binary name is internal.
    private static let friendlyNames: [String: String] = [
        "SimulatorTrampoline": "iOS シミュレータ",
        "claude": "Claude Code",
        "com.apple.WebKit.WebContent": "Safari（Web ページ）",
        "WindowServer": "WindowServer（画面描画）",
        "kernel_task": "kernel_task（システム）",
        "mds_stores": "Spotlight（索引作成）",
        "photoanalysisd": "写真の解析",
        "spotlightknowledged": "Spotlight",
        "mediaanalysisd": "写真・ビデオの解析",
    ]

    private func processName(_ pid: pid_t, start: UInt64) -> String {
        if let c = processNames[pid], c.start == start { return c.name }
        let path = Self.path(of: pid)
        var name = path.isEmpty ? "pid \(pid)" : (path as NSString).lastPathComponent
        // Helpers are named after their bundle ("Google Chrome Helper (Renderer)").
        if let r = path.range(of: ".app/Contents/MacOS/", options: .backwards) {
            name = (String(path[..<r.lowerBound]) as NSString).lastPathComponent
        }
        processNames[pid] = (start, name)
        return name
    }

    private static func path(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    // MARK: - Network (nettop snapshot, ~10 ms, off the main thread)

    private func sampleNetwork() {
        guard !netTaskRunning else { return }
        netTaskRunning = true
        Task.detached(priority: .utility) {
            let counters = Self.readNettop()
            await MainActor.run { self.applyNetwork(counters) }
        }
    }

    private func applyNetwork(_ counters: [pid_t: (rx: UInt64, tx: UInt64)]) {
        netTaskRunning = false
        let now = Date()
        defer { prevNet = counters; prevNetAt = now }
        guard let prevAt = prevNetAt else { return }
        let dt = now.timeIntervalSince(prevAt)
        guard dt > 0 else { return }

        var rates: [String: (Double, Double)] = [:]
        for (pid, c) in counters {
            guard let p = prevNet[pid] else { continue }
            let rx = c.rx >= p.rx ? Double(c.rx - p.rx) / dt : 0
            let tx = c.tx >= p.tx ? Double(c.tx - p.tx) / dt : 0
            guard rx + tx > 0 else { continue }
            let key = appOf[pid]?.key ?? appKey(pid: pid, start: 0)
            rates[key, default: (0, 0)].0 += rx
            rates[key, default: (0, 0)].1 += tx
        }
        let alpha = 0.3
        var ema: [String: Double] = [:]
        for k in Set(netEMA.keys).union(rates.keys) {
            let now = (rates[k]?.0 ?? 0) + (rates[k]?.1 ?? 0)
            let v = alpha * now + (1 - alpha) * (netEMA[k] ?? 0)
            if v >= 1 { ema[k] = v }
        }
        netEMA = ema

        var byApp = lastByApp
        for k in byApp.keys { byApp[k]!.netIn = 0; byApp[k]!.netOut = 0 }
        for (k, r) in rates {
            byApp[k, default: AppUsage(id: k, name: names[k] ?? k)].netIn = r.0
            byApp[k, default: AppUsage(id: k, name: names[k] ?? k)].netOut = r.1
        }
        publish(byApp)
    }

    nonisolated private static func readNettop() -> [pid_t: (rx: UInt64, tx: UInt64)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [pid_t: (UInt64, UInt64)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, let dot = cols[0].lastIndex(of: "."),
                  let pid = pid_t(cols[0][cols[0].index(after: dot)...]),
                  let rx = UInt64(cols[1]), let tx = UInt64(cols[2])
            else { continue }
            out[pid] = (rx, tx)
        }
        return out
    }
}
