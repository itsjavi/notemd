import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchFinished = false
    private var openedAtLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Create the shared document controller before any open events arrive.
        _ = NSDocumentController.shared
        if AppVariant.isBackground { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchFinished = true
        WindowManager.shared.restoreOpenRepositories()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let hasWindows = WindowManager.shared.hasRepositoryWindows || !NSDocumentController.shared.documents.isEmpty
                if !hasWindows && !self.openedAtLaunch { WindowManager.shared.showWelcome() }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        for url in urls {
            if url.isFileURL {
                WindowManager.shared.openFile(url)
            } else if url.scheme == AppVariant.urlScheme {
                URLCommandHandler.handle(url)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && !WindowManager.shared.hasRepositoryWindows {
            WindowManager.shared.showWelcome()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WindowManager.shared.isTerminating = true
        WindowManager.shared.rememberOpenRepositories()
        // Reply as soon as saves and commits finish, or after a cap so a stuck git never blocks quitting.
        // (A task group would wait for the timer child too, delaying every quit by the full cap.)
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        Task {
            await WindowManager.shared.closeAll()
            reply()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            MainActor.assumeIsolated { reply() }
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
