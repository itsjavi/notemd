import AppKit
import NoteMDCore
import SwiftUI
import WebKit

/// Renders an HTML document as is (no Markdown pipeline) for the document window's preview.
///
/// Relative CSS, images and scripts load through `notemd-file:` URLs confined to the file's folder. Unless
/// `allowsActiveContent` is set, the page's JavaScript is off and remote loads are blocked by a content rule list.
/// Links open in the default browser; the preview never navigates away from the document.
struct HTMLPreview: NSViewRepresentable {
    var html: String
    /// The document's folder: relative URLs resolve against it and nothing outside it can be loaded.
    var directory: URL
    var allowsActiveContent: Bool
    var onOpenNote: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator.fileHandler, forURLScheme: LocalFileSchemeHandler.scheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        context.coordinator.webView = webView
        context.coordinator.update(self)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        webView.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        let fileHandler = LocalFileSchemeHandler()
        var loadTask: Task<Void, Never>?
        private var parent: HTMLPreview?
        private var base: URL?
        private var shown: (html: String, base: URL?, active: Bool)?
        private var restoreScrollY: Double?

        func update(_ preview: HTMLPreview) {
            parent = preview
            fileHandler.accessRoot = preview.directory.canonical
            base = LocalFileSchemeHandler.url(for: preview.directory, isDirectory: true)
            guard shown?.html != preview.html || shown?.base != base || shown?.active != preview.allowsActiveContent else { return }
            // Typing reloads after a pause; the first load and permission changes go at once.
            let immediate = shown == nil || shown?.active != preview.allowsActiveContent
            shown = (preview.html, base, preview.allowsActiveContent)
            scheduleLoad(immediate: immediate)
        }

        private func scheduleLoad(immediate: Bool) {
            loadTask?.cancel()
            loadTask = Task {
                if !immediate { try? await Task.sleep(for: .milliseconds(300)) }
                guard !Task.isCancelled, let webView, let parent, let base else { return }
                let rules = webView.configuration.userContentController
                if parent.allowsActiveContent {
                    rules.removeAllContentRuleLists()
                } else {
                    // Fail closed: without the blocker, show nothing rather than load remote content.
                    guard let blocker = await RemoteContentBlocker.ruleList() else {
                        webView.loadHTMLString("<p>Couldn't turn on remote content blocking, so the preview is off.</p>", baseURL: nil)
                        return
                    }
                    rules.removeAllContentRuleLists()
                    rules.add(blocker)
                }
                restoreScrollY = try? await webView.callAsyncJavaScript("return window.scrollY", arguments: [:], in: nil, contentWorld: .defaultClient) as? Double
                guard !Task.isCancelled else { return }
                webView.loadHTMLString(parent.html, baseURL: base)
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let y = restoreScrollY, y > 0 else { return }
            restoreScrollY = nil
            webView.callAsyncJavaScript("window.scrollTo(0, y)", arguments: ["y": y], in: nil, in: .defaultClient)
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences
        ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            preferences.allowsContentJavaScript = parent?.allowsActiveContent ?? false
            guard let url = navigationAction.request.url else { return (.cancel, preferences) }
            let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
            if isMainFrame && navigationAction.navigationType == .other && url == base { return (.allow, preferences) }
            if isSameDocument(url) { return (.allow, preferences) }
            // Frames inside the page may load local files and inline content.
            if !isMainFrame, navigationAction.targetFrame != nil, ["notemd-file", "about", "data"].contains(url.scheme?.lowercased() ?? "") {
                return (.allow, preferences)
            }
            if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
                open(url)
            }
            return (.cancel, preferences)
        }

        private func isSameDocument(_ url: URL) -> Bool {
            guard url.fragment != nil, let base else { return false }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.url == base
        }

        private func open(_ url: URL) {
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto":
                NSWorkspace.shared.open(url)
            case LocalFileSchemeHandler.scheme:
                guard let fileURL = fileHandler.fileURL(for: url) else { return }
                let ext = fileURL.pathExtension.lowercased()
                if NoteMDCore.noteExtensions.contains(ext), let onOpenNote = parent?.onOpenNote {
                    onOpenNote(fileURL)
                } else if ["html", "htm"].contains(ext), let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) {
                    NSWorkspace.shared.open([fileURL], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    // Never launch other local files from a link (could be executables); show them instead.
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            default:
                break
            }
        }

        // MARK: WKUIDelegate

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { open(url) }
            return nil
        }

        func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
            .deny
        }
    }
}

/// A content rule list that blocks every remote load (the page's own files come through `notemd-file:`).
@MainActor enum RemoteContentBlocker {
    private static var cached: WKContentRuleList?

    static func ruleList() async -> WKContentRuleList? {
        if let cached { return cached }
        // Content blocker url-filters don't support alternation, hence one rule per scheme.
        let rules = ["^https?://", "^wss?://", "^ftp://"].map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
        cached = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "NoteMDBlockRemoteContent", encodedContentRuleList: "[" + rules.joined(separator: ",") + "]")
        return cached
    }
}
