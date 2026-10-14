import Foundation
import Observation
#if canImport(Sparkle) && !SWIFT_PACKAGE && !APP_STORE
import Combine
import Sparkle
#endif

/// The installed external edition uses Sparkle's verified updater and native UI.
/// Scanning remains local. Headless tools and a future App Store edition never
/// start an external updater.
@Observable @MainActor
final class AppUpdater {
    private(set) var canCheckForUpdates = false
    private(set) var isAvailable = false
    private(set) var started = false
    var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Version \(info["CFBundleShortVersionString"] as? String ?? "unknown") (\(info["CFBundleVersion"] as? String ?? "unknown"))"
    }
    #if canImport(Sparkle) && !SWIFT_PACKAGE && !APP_STORE
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: AnyCancellable?

    init() {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed),
              Self.permitsFeed(url),
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        isAvailable = true
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
    }
    private static func permitsFeed(_ url: URL) -> Bool {
        if url.scheme == "https" { return true }
        #if DEBUG
        // Disposable local upgrade checks only. Release has no HTTP override.
        return url.scheme == "http" && url.host == "127.0.0.1"
            && CommandLine.arguments.contains("--test-local-updates")
        #else
        return false
        #endif
    }
    func start() {
        guard !started, let controller else { return }
        started = true
        controller.startUpdater()
    }
    func checkForUpdates() { controller?.checkForUpdates(nil) }
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
    #else
    init() {}
    func start() {}
    func checkForUpdates() {}
    var automaticallyChecksForUpdates: Bool {
        get { false }
        set {}
    }
    #endif
}
