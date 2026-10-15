import AppKit
import NoteMDCore
import SwiftUI

/// Secret notes (decision-6): whole notes encrypted on disk in the age format, decrypted one at a time when opened.
enum SecretNotes {
    #if DEBUG
    /// Decryptions since launch: the Test build checks that listing thousands of secret notes decrypts none.
    static var decryptions = 0
    #endif

    static func decrypt(_ data: Data, with identity: AgeIdentity) -> String? {
        #if DEBUG
        decryptions += 1
        #endif
        guard let plaintext = try? Age.decrypt(data, with: identity) else { return nil }
        return String(decoding: plaintext, as: UTF8.self)
    }

    static let explanation: [(symbol: String, text: String)] = [
        ("lock.doc", "A secret note is encrypted before it's saved: its title, tags and text can't be read from the file, backups or the git history without your key."),
        ("textformat", "Its file name stays readable, in Finder and in version history. Choose names that don't give anything away."),
        ("clock.arrow.circlepath", "Making an existing note secret doesn't rewrite history: its earlier versions stay readable there."),
        ("paperclip", "Files you attach to a secret note aren't encrypted."),
        ("touchid", "Unlock NoteMD with \(AppLock.methodName) to open secret notes and hidden folders. They lock again after the idle time chosen in Settings (5 minutes at most), and right away with Lock Now, screen lock, sleep or quit."),
        ("key", "Your recovery key opens your secret notes on another Mac, or with the age tool. It's shown once: keep it in a password manager. Without it, losing this Mac means losing your secret notes."),
    ]

    /// Asks before adding files to a secret note, since attachments aren't encrypted. Background (Test) builds never
    /// show the alert and count the warning instead.
    static func confirmUnencryptedAttachments(for noteName: String) -> Bool {
        guard !AppVariant.isBackground else {
            #if DEBUG
            unencryptedWarnings += 1
            #endif
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Attachments aren't encrypted"
        alert.informativeText = "Files added to the secret note “\(noteName)” are stored unencrypted in the assets folder, where anyone with the files can open them."
        alert.addButton(withTitle: "Add Unencrypted")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    #if DEBUG
    static var unencryptedWarnings = 0
    #endif
}

/// First setup of secret notes: what they protect, then a new recovery key shown once, or an existing one imported.
struct SecretNotesSetupView: View {
    @Environment(\.dismiss) private var dismiss
    private enum Step { case intro, newKey, importKey }
    @State private var step = Step.intro
    @State private var identity: AgeIdentity?
    @State private var savedKey = false
    @State private var importedKey = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .intro: intro
            case .newKey: newKey
            case .importKey: importKey
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Secret Notes", systemImage: "lock.doc.fill").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SecretNotes.explanation, id: \.text) { item in
                    Label {
                        Text(item.text).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: item.symbol).foregroundStyle(.tint).frame(width: 22)
                    }
                }
            }
            HStack {
                Button("Use Existing Recovery Key…") { step = .importKey }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Key") {
                    identity = AgeIdentity()
                    step = .newKey
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var newKey: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your Recovery Key").font(.title2.weight(.semibold))
            Text("Save it in a password manager now. NoteMD won't show it again.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top) {
                Text(identity?.string ?? "")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(identity?.string ?? "", forType: .string)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            Toggle("I saved my recovery key somewhere safe", isOn: $savedKey)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Turn On Secret Notes") { if let identity { finish(identity) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!savedKey)
            }
        }
    }

    private var importKey: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use Existing Recovery Key").font(.title2.weight(.semibold))
            Text("Paste the recovery key you saved when you set up secret notes on another Mac. It starts with AGE-SECRET-KEY-1.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("AGE-SECRET-KEY-1…", text: $importedKey)
                .font(.system(.body, design: .monospaced))
                .onSubmit(importIdentity)
            HStack {
                Button("Back") { step = .intro; error = nil }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Key", action: importIdentity)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(importedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func importIdentity() {
        guard let identity = try? AgeIdentity(string: importedKey) else {
            error = "That isn't a recovery key. It should look like AGE-SECRET-KEY-1 followed by letters and digits."
            return
        }
        finish(identity)
    }

    private func finish(_ identity: AgeIdentity) {
        do {
            try SecretKeyStore.save(identity)
        } catch {
            self.error = "Couldn't store the key with this Mac's Secure Enclave: \(error.localizedDescription)"
            return
        }
        AppLock.shared.didSetUpSecrets(identity)
        dismiss()
    }
}
