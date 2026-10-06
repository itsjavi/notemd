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
        Task {
            // Flush saves and commits, but never hang the quit.
            let flush = Task { await WindowManager.shared.closeAll() }
            let timeout = Task { try? await Task.sleep(for: .seconds(8)) }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await flush.value }
                group.addTask { await timeout.value }
                await group.next()
                group.cancelAll()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
