import Sparkle

/// Checks the update feed and installs new versions (Sparkle, decision-10). Only builds with a feed and a public key
/// have one: build-app.sh keeps them for release builds, so the Dev and Test builds never update themselves.
enum AppUpdater {
    static let controller: SPUStandardUpdaterController? = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] is String, (info["SUPublicEDKey"] as? String)?.isEmpty == false else { return nil }
        return SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    /// Started after launch, so an update prompt never gets in the way of restoring windows.
    static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated { controller?.startUpdater() }
        }
    }

    static func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
