import AppKit
import UniformTypeIdentifiers

/// NoteMD in the Share menu: hands what was shared to the app, which imports Markdown files and makes notes of the
/// rest, as the Services menu does. The extension is sandboxed and the app isn't, so it leaves file URLs, text and
/// images on a private pasteboard named after this extension's bundle id (`<app id>.share`), then wakes its app
/// with `<scheme>://share`.
final class ShareViewController: NSViewController {
    override func loadView() {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let stack = NSStackView(views: [spinner, NSTextField(labelWithString: "Sending to NoteMD…")])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task {
            var items: [SharedItem] = []
            for provider in providers {
                if let item = await SharedItem.load(from: provider) { items.append(item) }
            }
            handOver(items)
        }
    }

    private func handOver(_ items: [SharedItem]) {
        // The extension lives in NoteMD.app/Contents/PlugIns: wake that copy of the app, not whichever claims the scheme.
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard !items.isEmpty, let pasteboardName = Bundle.main.bundleIdentifier,
              let scheme = Bundle.main.object(forInfoDictionaryKey: "AppURLScheme") as? String,
              let wakeURL = URL(string: scheme + "://share")
        else {
            extensionContext?.cancelRequest(withError: CocoaError(.featureUnsupported))
            return
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        pasteboard.clearContents()
        let files = items.compactMap { item -> NSURL? in if case .file(let url) = item { url as NSURL } else { nil } }
        if !files.isEmpty { pasteboard.writeObjects(files) }
        let texts = items.compactMap { item -> String? in if case .text(let text) = item { text } else { nil } }
        if !texts.isEmpty { pasteboard.setString(texts.joined(separator: "\n\n"), forType: .string) }
        if let image = items.lazy.compactMap({ item -> Data? in if case .image(let data) = item { data } else { nil } }).first {
            pasteboard.setData(image, forType: .tiff)
        }
        NSWorkspace.shared.open([wakeURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// One shared thing, in the form the app's Services handler reads.
enum SharedItem: Sendable {
    case file(URL)
    case text(String)
    /// TIFF data.
    case image(Data)

    /// The most useful form a provider offers: a file, then a web link, an image or text.
    @MainActor static func load(from provider: NSItemProvider) async -> SharedItem? {
        let preferred: [UTType] = [.fileURL, .url, .image, .plainText]
        let registered = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        let type = preferred.lazy.compactMap { wanted in registered.first { $0.conforms(to: wanted) } }.first ?? registered.first
        guard let type else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                continuation.resume(returning: classify(item, type: type))
            }
        }
    }

    private nonisolated static func classify(_ item: (any NSSecureCoding)?, type: UTType) -> SharedItem? {
        switch item {
        case let url as URL:
            return url.isFileURL ? .file(url) : .text(url.absoluteString)
        case let text as String:
            return .text(text)
        case let text as NSAttributedString:
            return .text(text.string)
        case let image as NSImage:
            return image.tiffRepresentation.map(SharedItem.image)
        case let data as Data:
            if type.conforms(to: .fileURL) || type.conforms(to: .url) {
                return URL(dataRepresentation: data, relativeTo: nil).flatMap { classify($0 as NSURL, type: type) }
            }
            if type.conforms(to: .image) { return NSImage(data: data)?.tiffRepresentation.map(SharedItem.image) }
            return String(data: data, encoding: .utf8).map(SharedItem.text)
        default:
            return nil
        }
    }
}
