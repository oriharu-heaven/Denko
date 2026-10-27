import Darwin
import Foundation
import IOKit.ps

struct BatteryInfo: Equatable {
    let percent: Int
    let isCharging: Bool
    let onAC: Bool
}

/// Samples CPU / memory / network every `interval` seconds, disk and battery less often.
@MainActor
final class SystemMonitor: ObservableObject {
    static let historyLength = 60

    @Published private(set) var cpu: Double = 0            // 0–100
    @Published private(set) var cpuHistory: [Double] = []
    /// Memory used (%) and total network rate (bytes/s) over time, for the panel's wave graphs.
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var networkHistory: [Double] = []
    @Published private(set) var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    var memoryPercent: Double { Double(memoryUsed) / Double(max(1, memoryTotal)) * 100 }
    @Published private(set) var diskFree: Int64 = 0
    @Published private(set) var diskTotal: Int64 = 0
    @Published private(set) var netDown: Double = 0       // bytes/sec
    @Published private(set) var netUp: Double = 0
    @Published private(set) var battery: BatteryInfo?

    /// Light mode (panel closed): CPU only, every 3s — just enough to drive the cat.
    /// Detailed mode (panel open): everything, every 1.5s.
    private var detailed = false
    /// Paused while displays are asleep or the session is locked.
    private var paused = false
    /// Seconds between samples with only the menu bar / with the panel open (user-adjustable).
    private var lightInterval: TimeInterval = 3
    private var detailedInterval: TimeInterval = 2

    func setIntervals(menuBar: TimeInterval, panel: TimeInterval) {
        guard menuBar != lightInterval || panel != detailedInterval else { return }
        lightInterval = menuBar
        detailedInterval = panel
        schedule()
    }
    /// Set when the menu bar shows memory %, so it's sampled even with the panel closed.
    var sampleMemoryAlways = false
    /// Set when the menu bar shows network speed.
    var sampleNetworkAlways = false
    private var prevTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    private var prevNet: (rx: UInt64, tx: UInt64, at: Date)?
    private var timer: Timer?

    init() {
        // Disk and battery are cheap and change slowly: have them ready before the panel
        // first opens so its layout doesn't grow a moment after appearing.
        readDisk()
        battery = readBattery()
        if let m = readMemoryUsed() { memoryUsed = m }
        sample()
        schedule()
    }

    func setDetailed(_ on: Bool) {
        guard on != detailed else { return }
        detailed = on
        if on {
            prevNet = nil
            readNetwork()
            readDisk()
            battery = readBattery()
        }
        schedule()
    }

    func setPaused(_ on: Bool) {
        guard on != paused else { return }
        paused = on
        if on {
            timer?.invalidate()
            timer = nil
            prevTicks = nil
            prevNet = nil
        } else {
            sample()
            schedule()
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard !paused else { return }
        let interval: TimeInterval = detailed ? detailedInterval : lightInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = interval * 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        if let c = readCPU() {
            cpu = c
            cpuHistory.append(c)
            if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst() }
        }
        if detailed || sampleMemoryAlways, let m = readMemoryUsed() {
            if m != memoryUsed { memoryUsed = m }
            append(&memoryHistory, memoryPercent)
        }
        if detailed || sampleNetworkAlways {
            readNetwork()
            append(&networkHistory, netDown + netUp)
        }
    }

    private func append(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst() }
    }

    /// Battery percent and whether we're running on it (nil on desktops).
    static func batteryLevel() -> (percent: Int, onBattery: Bool)? {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return (cur * 100 / max, (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue)
        }
        return nil
    }

    /// Cheap check used to pause animation on battery.
    static var isOnBattery: Bool {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snap)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPSBatteryPowerValue
    }

    // MARK: CPU

    private func readCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let now = (user: t.0, sys: t.1, idle: t.2, nice: t.3)
        defer { prevTicks = now }
        guard let p = prevTicks else { return nil }
        let busy = Double(now.user &- p.user) + Double(now.sys &- p.sys) + Double(now.nice &- p.nice)
        let total = busy + Double(now.idle &- p.idle)
        return total > 0 ? busy / total * 100 : nil
    }

    // MARK: Memory (same definition as Activity Monitor's "Memory Used")

    private func readMemoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    // MARK: Network (physical en* interfaces only, so VPN tunnels aren't double counted)

    private func readNetwork() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: a.ifa_name).hasPrefix("en"),
                  let data = a.ifa_data?.assumingMemoryBound(to: if_data.self)
            else { continue }
            rx += UInt64(data.pointee.ifi_ibytes)
            tx += UInt64(data.pointee.ifi_obytes)
        }
        let now = Date()
        if let prev = prevNet {
            let dt = now.timeIntervalSince(prev.at)
            if dt > 0 {
                netDown = rx >= prev.rx ? Double(rx - prev.rx) / dt : 0
                netUp = tx >= prev.tx ? Double(tx - prev.tx) / dt : 0
            }
        }
        prevNet = (rx, tx, now)
    }

    // MARK: Disk

    private func readDisk() {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                        .volumeTotalCapacityKey])
        else { return }
        diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
        diskTotal = Int64(v.volumeTotalCapacity ?? 0)
    }

    // MARK: Battery

    private func readBattery() -> BatteryInfo? {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return BatteryInfo(percent: cur * 100 / max,
                               isCharging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                               onAC: (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }
}

enum ByteText {
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let rateFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.allowsNonnumericFormatting = false
        return f
    }()

    /// Very short rate for the menu bar: "0K", "34K", "1.2M".
    static func compactRate(_ bytesPerSec: Double) -> String {
        // Two significant digits so the text (and the menu bar image) changes less often.
        let k = bytesPerSec / 1000
        if k < 1 { return "0K" }
        if k < 10 { return "\(Int(k))K" }
        if k < 1000 {
            let step: Double = k < 100 ? 1 : 10
            return "\(Int((k / step).rounded() * step))K"
        }
        let m = k / 1000
        return m < 10 ? String(format: "%.1fM", m) : "\(Int(m.rounded()))M"
    }

    static func size(_ bytes: Int64) -> String {
        sizeFormatter.string(fromByteCount: bytes)
    }

    static func rate(_ bytesPerSec: Double) -> String {
        if bytesPerSec > 0 && bytesPerSec < 1000 { return String(localized: "1 KB/s 未満") }
        return rateFormatter.string(fromByteCount: Int64(bytesPerSec)) + "/s"
    }
}
