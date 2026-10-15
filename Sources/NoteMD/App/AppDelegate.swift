import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchFinished = false
    /// Files or URLs launched the app (Finder, Dock, Share menu): no welcome window then.
    private var openedAtLaunch = false
    /// Files from the launch's open-documents event, opened once the notes folders are restored.
    private var launchFiles: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Under the SwiftUI lifecycle, Finder/Dock file opens bypass application(_:open:): route them ourselves.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
        if AppVariant.isBackground { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchFinished = true
        AppLock.shared.start()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // The open-documents event of a launch arrives before this point, URL events after it.
        WindowManager.shared.restoreRepositories()
        WindowManager.shared.open(launchFiles)
        launchFiles = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                if !WindowManager.shared.hasRepositoryWindows && !self.openedAtLaunch { WindowManager.shared.showWelcome() }
            }
        }
    }

    /// Services menu “New NoteMD Note” (NSServices in Info.plist).
    @objc(createNote:userData:error:)
    func createNote(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        WindowManager.shared.addNoteFromService(pasteboard)
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
        let files = urls.filter(\.isFileURL)
        if launchFinished { WindowManager.shared.open(files) } else { launchFiles += files }
        for url in urls where url.scheme == AppVariant.urlScheme { URLCommandHandler.handle(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let windows = WindowManager.shared
        if !flag && !windows.hasRepositoryWindows {
            if !(AppSettings.shared.alwaysOpenLastRepository && windows.openLastRepository()) { windows.showWelcome() }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WindowManager.shared.isTerminating = true
        // Closes secret notes and hidden folders (saving them) before anything else.
        AppLock.shared.lock()
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
