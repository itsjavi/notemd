import SwiftUI

/// Toolbar button showing whether NoteMD is locked: unlocks, or locks now.
struct LockButton: View {
    private let lock = AppLock.shared

    var body: some View {
        Button {
            if lock.isUnlocked { lock.lock() } else { Task { await lock.unlock() } }
        } label: {
            Label(lock.isUnlocked ? "Lock Now" : "Unlock", systemImage: lock.isUnlocked ? "lock.open.fill" : "lock.fill")
        }
        .disabled(lock.isUnlocking)
        .help(lock.isUnlocked
            ? "Unlocked: hidden folders and secret notes are showing. Click to lock now."
            : "Locked: hidden folders and secret notes are kept out of sight. Click to unlock with \(AppLock.methodName).")
    }
}

enum HiddenFolderText {
    static let explanation = "Hidden folders and their notes only show in NoteMD after you unlock it with \(AppLock.methodName), and hide again when it locks. Hiding doesn't encrypt anything: the files stay visible in Finder and in git."
}
