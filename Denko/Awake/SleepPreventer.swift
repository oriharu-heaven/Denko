import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake with an IOPM assertion (like `caffeinate`).
@MainActor
final class SleepPreventer: ObservableObject {
    static let durations: [Int] = [15, 30, 60, 120, 240, 0]   // minutes; 0 = 無期限

    static func label(minutes: Int) -> String {
        switch minutes {
        case 0: return "無期限"
        case let m where m < 60: return "\(m)分"
        default: return "\(minutes / 60)時間"
        }
    }

    @Published private(set) var isActive = false
    @Published private(set) var endsAt: Date?

    private let settings: AppSettings
    private var assertionID: IOPMAssertionID = 0
    private var endTimer: Timer?
    private var batteryTimer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
        if Features.sleepPrevention && settings.keepAwakeOnLaunch {
            start(minutes: settings.keepAwakeDefaultMinutes)
        }
    }

    func toggle() {
        isActive ? stop() : start(minutes: settings.keepAwakeDefaultMinutes)
    }

    func start(minutes: Int) {
        releaseAssertion()
        // Preventing display sleep also prevents idle system sleep.
        let type = settings.allowDisplaySleep
            ? kIOPMAssertionTypePreventUserIdleSystemSleep
            : kIOPMAssertionTypePreventUserIdleDisplaySleep
        let ok = IOPMAssertionCreateWithName(type as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Denko スリープ防止" as CFString,
                                             &assertionID) == kIOReturnSuccess
        guard ok else { stop(); return }
        isActive = true

        endTimer?.invalidate()
        if minutes > 0 {
            let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
            endsAt = end
            endTimer = Timer.scheduledTimer(withTimeInterval: end.timeIntervalSinceNow, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
            endTimer?.tolerance = 5
        } else {
            endsAt = nil
        }

        batteryTimer?.invalidate()
        if settings.keepAwakeBatteryLimit > 0 {
            batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkBattery() }
            }
            batteryTimer?.tolerance = 10
            checkBattery()
        }
    }

    func stop() {
        releaseAssertion()
        endTimer?.invalidate()
        batteryTimer?.invalidate()
        endTimer = nil
        batteryTimer = nil
        isActive = false
        endsAt = nil
    }

    /// Re-apply when the display-sleep option changes while active.
    func reapplyIfActive() {
        guard isActive else { return }
        let remaining = endsAt.map { max(1, Int($0.timeIntervalSinceNow / 60)) } ?? 0
        start(minutes: remaining)
    }

    private func checkBattery() {
        guard let b = SystemMonitor.batteryLevel(), b.onBattery,
              b.percent <= settings.keepAwakeBatteryLimit
        else { return }
        stop()
    }

    private func releaseAssertion() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    func remainingText(now: Date = Date()) -> String {
        guard isActive else { return "オフ" }
        guard let endsAt else { return "無期限" }
        return "\(TimeText.untilReset(endsAt, now: now))（\(TimeText.absolute(endsAt))まで）"
    }
}

/// Features held back from the current release (kept in the code for a later update).
enum Features {
    /// Sleep prevention: set aside for now — dedicated apps (Amphetamine etc.) cover it.
    static let sleepPrevention = false
}
