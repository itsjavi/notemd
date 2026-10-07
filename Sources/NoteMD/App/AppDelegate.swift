import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchFinished = false
    private var openedAtLaunch = false
    /// A standalone file launched the app (Finder, Dock drop, Open With): show only that file.
    private var openedDocumentAtLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Create the shared document controller before any open events arrive.
        _ = NSDocumentController.shared
        // Under the SwiftUI lifecycle, Finder/Dock file opens bypass application(_:open:) and go straight
        // to NSDocumentController, which can't open folders or route notes to their repository window.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
        if AppVariant.isBackground { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchFinished = true
        // The open-documents event of a launch arrives before this point.
        if !openedDocumentAtLaunch { WindowManager.shared.restoreRepositories() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let hasWindows = WindowManager.shared.hasRepositoryWindows || !NSDocumentController.shared.documents.isEmpty
                if !hasWindows && !self.openedAtLaunch { WindowManager.shared.showWelcome() }
            }
        }
    }

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let files = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let urls = files.descriptorType == typeAEList
            ? (0..<files.numberOfItems).compactMap { files.atIndex($0 + 1)?.fileURLValue }
            : [files.fileURLValue].compactMap(\.self)
        application(NSApp, open: urls)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        for url in urls {
            if url.isFileURL {
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if !launchFinished && !isFolder { openedDocumentAtLaunch = true }
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
