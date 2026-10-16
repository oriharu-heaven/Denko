import Combine
import Sparkle

/// In-app updates with Sparkle. The feed (appcast.xml) is attached to the latest GitHub
/// Release; updates are signed with the EdDSA key whose public half is in Info.plist.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published var canCheck = false
    private var bag: AnyCancellable?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        bag = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }
}
