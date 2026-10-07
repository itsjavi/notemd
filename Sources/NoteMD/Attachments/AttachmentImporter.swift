import AppKit
import NoteMDCore

/// Turns files dropped or pasted into a note into Markdown links (decision-5): files from outside `rootURL`
/// are copied into its `assets/` folder or linked by absolute path, files inside it are linked relatively.
struct AttachmentImporter {
    /// The repository root, or a standalone document's folder.
    let rootURL: URL
    /// Folder of the note the links are relative to.
    let noteDirectory: URL
    /// Called after files were written into `assets/`.
    var didAddAssets: () -> Void = {}

    var assetsURL: URL { rootURL.appendingPathComponent(Attachments.folderName, isDirectory: true) }

    // MARK: Files

    /// Markdown for `urls` (one link per line), or nil when the user cancelled or nothing could be added.
    /// Files from outside follow `mode`, or the Settings choice (possibly asking) when nil.
    func markdown(forFiles urls: [URL], mode forcedMode: AttachmentImportMode? = nil) -> String? {
        let urls = urls.map(\.canonical)
        let outside = urls.filter { !isInside($0) }
        var mode = AttachmentImportMode.copy
        if !outside.isEmpty {
            guard let chosen = forcedMode ?? chooseMode(for: outside) else { return nil }
            mode = chosen
        }
        var links: [String] = []
        var failures: [String] = []
        for url in urls {
            let kind = isDirectory(url) ? AttachmentKind.file : AttachmentKind(pathExtension: url.pathExtension)
            let name = url.deletingPathExtension().lastPathComponent
            if isInside(url) {
                links.append(Attachments.markdownLink(name: name, destination: relativeDestination(to: url), kind: kind))
            } else if mode == .link || isDirectory(url) {
                links.append(Attachments.markdownLink(name: name, destination: Attachments.encodeDestination(url.path), kind: kind))
            } else if let copy = copyIntoAssets(url) {
                links.append(Attachments.markdownLink(name: name, destination: relativeDestination(to: copy), kind: kind))
            } else {
                failures.append(url.lastPathComponent)
            }
        }
        if !failures.isEmpty { showError("Couldn't copy \(failures.joined(separator: ", ")) into the assets folder.") }
        return links.isEmpty ? nil : links.joined(separator: "\n")
    }

    // MARK: Generated files

    /// Saves pasted image data as a PNG in `assets/` and returns its image link.
    func markdown(forImageData data: Data) -> String? {
        guard let png = Self.pngData(data) else { return nil }
        let name = Attachments.timestampedName(prefix: "image", pathExtension: "png")
        guard let url = newAssetURL(fileName: name) else { return nil }
        do {
            try png.write(to: url, options: .withoutOverwriting)
        } catch {
            showError("Couldn't save the pasted image: \(error.localizedDescription)")
            return nil
        }
        didAddAssets()
        return Attachments.markdownLink(name: "Pasted image", destination: relativeDestination(to: url), kind: .image)
    }

    /// A free URL in `assets/` for a file the app is about to create (the folder is created).
    func newAssetURL(fileName: String) -> URL? {
        do {
            try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        } catch {
            showError("Couldn't create the assets folder: \(error.localizedDescription)")
            return nil
        }
        return Attachments.uniqueURL(in: assetsURL, fileName: fileName)
    }

    /// Link destination for `url` relative to the note's folder.
    func relativeDestination(to url: URL) -> String {
        Attachments.encodeDestination(Attachments.relativePath(fromDirectory: relative(noteDirectory), to: relative(url)))
    }

    // MARK: Private

    private func copyIntoAssets(_ url: URL) -> URL? {
        guard let target = newAssetURL(fileName: url.lastPathComponent) else { return nil }
        do {
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            return nil
        }
        didAddAssets()
        return target
    }

    private func chooseMode(for files: [URL]) -> AttachmentImportMode? {
        let settings = AppSettings.shared
        guard settings.attachmentImportMode == .ask else { return settings.attachmentImportMode }
        let alert = NSAlert()
        alert.messageText = files.count == 1
            ? "Copy “\(files[0].lastPathComponent)” into the note’s assets?"
            : "Copy \(files.count) files into the note’s assets?"
        alert.informativeText = "A copy lives in the assets folder and is versioned with your notes. A link points to the file where it is now: it isn't versioned and breaks if the file moves."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Link to Original")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let mode: AttachmentImportMode
        switch alert.runModal() {
        case .alertFirstButtonReturn: mode = .copy
        case .alertSecondButtonReturn: mode = .link
        default: return nil
        }
        if alert.suppressionButton?.state == .on { settings.attachmentImportMode = mode }
        return mode
    }

    private func isInside(_ url: URL) -> Bool {
        url.path.hasPrefix(rootURL.canonical.path + "/")
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Path of `url` relative to `rootURL` (both canonical).
    private func relative(_ url: URL) -> String {
        let root = rootURL.canonical.path
        let path = url.canonical.path
        return path == root ? "" : String(path.dropFirst(root.count + 1))
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        if !AppVariant.isBackground { alert.runModal() }
    }

    /// PNG bytes for pasted image data (TIFF and other formats are converted).
    static func pngData(_ data: Data) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }
}
