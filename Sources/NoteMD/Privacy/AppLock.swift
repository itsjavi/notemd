import AppKit
import LocalAuthentication
import NoteMDCore
import Observation

/// The app unlock shared by hidden folders and secret notes (decision-6): one authentication with whatever the Mac
/// supports (Touch ID, an Apple Watch or the login password), valid until NoteMD has been idle for the chosen time,
/// Lock Now, screen lock, sleep or quit. Repository stores follow it through `.appLockChanged`.
@Observable final class AppLock {
    static let shared = AppLock()

    private(set) var isUnlocked = false
    /// An unlock prompt is up.
    private(set) var isUnlocking = false
    /// Hidden folders or secret notes were used on this Mac, so windows show the lock button.
    var isInUse: Bool { didSet { UserDefaults.standard.set(isInUse, forKey: Self.inUseKey) } }
    /// Secret notes have a key on this Mac.
    private(set) var secretsSetUp: Bool
    /// The age identity that decrypts secret notes, in memory only while unlocked.
    @ObservationIgnored private(set) var identity: AgeIdentity?

    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var started = false
    private static let inUseKey = "privacyFeaturesInUse"

    private init() {
        isInUse = UserDefaults.standard.bool(forKey: Self.inUseKey)
        secretsSetUp = SecretKeyStore.isSetUp
    }

    /// Watches activity in NoteMD windows and the events that lock immediately. Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        // Only NoteMD's own events: activity in other apps doesn't keep it unlocked.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved, .leftMouseDragged]) { event in
            AppLock.shared.lastActivity = Date()
            return event
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppLock.shared.lock() }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppLock.shared.lock() }
        }
    }

    // MARK: Unlocking

    private nonisolated static let reason = "show hidden folders and secret notes"

    /// Asks the user to authenticate. Returns whether NoteMD is unlocked; cancelling just leaves it locked.
    /// With secret notes set up, unwrapping their key is the authentication, so there is one prompt, not two.
    @discardableResult func unlock() async -> Bool {
        if isUnlocked { return true }
        guard !isUnlocking else { return false }
        isUnlocking = true
        defer { isUnlocking = false }
        if secretsSetUp {
            let allowingTestKey = AppVariant.name == "test"
            // The Secure Enclave blocks its thread while the system prompt is up.
            let result = await Task.detached { Result { try SecretKeyStore.unwrap(reason: AppLock.reason, allowingTestKey: allowingTestKey) } }.value
            switch result {
            case .success(let identity):
                self.identity = identity
                didUnlock()
                return true
            case .failure(let error):
                if !Self.isCancellation(error) { WindowManager.shared.presentError("Couldn't unlock NoteMD: \(error.localizedDescription)") }
                return false
            }
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            WindowManager.shared.presentError("NoteMD can't ask for Touch ID or your password on this Mac: \(error?.localizedDescription ?? "authentication isn't available").")
            return false
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: Self.reason) else { return false }
        } catch {
            return false
        }
        didUnlock()
        return true
    }

    func lock() {
        guard isUnlocked else { return }
        identity = nil
        isUnlocked = false
        idleTimer?.invalidate()
        idleTimer = nil
        NotificationCenter.default.post(name: .appLockChanged, object: nil)
    }

    private func didUnlock() {
        isUnlocked = true
        lastActivity = Date()
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { AppLock.shared.lockIfIdle() }
        }
        NotificationCenter.default.post(name: .appLockChanged, object: nil)
    }

    private func lockIfIdle() {
        if Date().timeIntervalSince(lastActivity) >= AppSettings.shared.lockAfter { lock() }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        let cancels = [LAError.userCancel, .systemCancel, .appCancel].map(\.rawValue)
        if error.domain == LAErrorDomain && cancels.contains(error.code) { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(isCancellation) ?? false
    }

    // MARK: Secret notes

    /// Secret notes were just set up, or a recovery key imported: NoteMD is unlocked with that identity.
    func didSetUpSecrets(_ identity: AgeIdentity) {
        secretsSetUp = true
        isInUse = true
        self.identity = identity
        if isUnlocked { NotificationCenter.default.post(name: .appLockChanged, object: nil) } else { didUnlock() }
    }

    /// Forgets the secret notes key on this Mac and locks.
    func removeSecrets() throws {
        try SecretKeyStore.remove()
        secretsSetUp = false
        lock()
    }

    #if DEBUG
    /// Test hooks: unlocks without LocalAuthentication, with the test key when secret notes are set up.
    func unlockWithoutAuthentication() {
        guard !isUnlocked else { return }
        if secretsSetUp { identity = try? SecretKeyStore.unwrap(reason: "", allowingTestKey: true) }
        didUnlock()
    }
    #endif

    // MARK: Wording

    /// What unlocking asks for on this Mac: "Touch ID", or "your password" without biometry.
    static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        default: return "your password"
        }
    }
}

extension Notification.Name {
    /// NoteMD was locked or unlocked.
    static let appLockChanged = Notification.Name("NoteMDAppLockChanged")
}
