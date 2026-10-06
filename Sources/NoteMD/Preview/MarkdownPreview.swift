import AppKit
import NoteMDCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Live GitHub-style preview of Markdown in a WKWebView.
///
/// Note content never runs scripts (CSP `script-src 'none'`); the app updates the page
/// from an isolated content world. Local resources load through `notemd-file:` URLs
/// confined to `accessRoot`.
struct MarkdownPreview: NSViewRepresentable {
    var markdown: String
    /// Directory relative links and images resolve against.
    var baseDirectory: URL
    /// Files outside this folder can't be loaded by the page.
    var accessRoot: URL
    var frontMatter: MarkdownRenderer.FrontMatterStyle = .hidden
    /// Source line to scroll to (split mode sync); nil leaves scrolling alone.
    var scrollLine: Int?
    var onOpenNote: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator.fileHandler, forURLScheme: LocalFileSchemeHandler.scheme)
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        context.coordinator.webView = webView
        context.coordinator.update(self)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.renderTask?.cancel()
        webView.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        let fileHandler = LocalFileSchemeHandler()
        var renderTask: Task<Void, Never>?
        private var parent: MarkdownPreview?
        private var loadedBase: URL?
        private var isPageReady = false
        private var isLoading = false
        private var pendingHTML: String?
        private var lastMarkdown: String?
        private var lastScrollLine: Int?

        func update(_ preview: MarkdownPreview) {
            parent = preview
            fileHandler.accessRoot = preview.accessRoot.canonical
            let base = LocalFileSchemeHandler.url(for: preview.baseDirectory, isDirectory: true)
            if base != loadedBase {
                loadedBase = base
                lastMarkdown = nil
                isPageReady = false
                isLoading = false
                pendingHTML = nil
            }
            if preview.markdown != lastMarkdown {
                lastMarkdown = preview.markdown
                scheduleRender(preview.markdown, frontMatter: preview.frontMatter, immediate: !isPageReady && !isLoading)
            }
            if let line = preview.scrollLine, line != lastScrollLine {
                lastScrollLine = line
                scroll(to: line)
            }
        }

        private func scheduleRender(_ markdown: String, frontMatter: MarkdownRenderer.FrontMatterStyle, immediate: Bool) {
            renderTask?.cancel()
            renderTask = Task {
                if !immediate { try? await Task.sleep(for: .milliseconds(90)) }
                guard !Task.isCancelled else { return }
                let html = await Task.detached(priority: .userInitiated) {
                    MarkdownRenderer.html(from: markdown, options: .init(frontMatter: frontMatter))
                }.value
                guard !Task.isCancelled else { return }
                self.show(html)
            }
        }

        private func show(_ html: String) {
            guard let webView, let base = loadedBase else { return }
            if isPageReady {
                setContent(html)
            } else if isLoading {
                pendingHTML = html
            } else {
                isLoading = true
                webView.loadHTMLString(PreviewPage.html(body: html), baseURL: base)
            }
        }

        private func setContent(_ html: String) {
            webView?.callAsyncJavaScript("document.getElementById('content').innerHTML = html;", arguments: ["html": html], in: nil, in: .defaultClient)
        }

        private func scroll(to line: Int) {
            guard isPageReady, let webView else { return }
            let script = """
            let best = null;
            for (const el of document.querySelectorAll('[data-sourcepos]')) {
              const start = parseInt(el.getAttribute('data-sourcepos'));
              if (start <= line) best = el; else break;
            }
            if (best) window.scrollTo({top: Math.max(0, best.getBoundingClientRect().top + window.scrollY - 12)});
            else if (line <= 1) window.scrollTo({top: 0});
            """
            webView.callAsyncJavaScript(script, arguments: ["line": line], in: nil, in: .defaultClient)
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageReady = true
            isLoading = false
            if let html = pendingHTML {
                pendingHTML = nil
                setContent(html)
            }
            if let line = lastScrollLine { scroll(to: line) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true && url == loadedBase {
                return .allow
            }
            if isSameDocument(url) { return .allow }
            if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
                open(url)
            }
            return .cancel
        }

        private func isSameDocument(_ url: URL) -> Bool {
            guard url.fragment != nil, let current = loadedBase else { return false }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.url == current
        }

        private func open(_ url: URL) {
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto":
                NSWorkspace.shared.open(url)
            case LocalFileSchemeHandler.scheme:
                guard let fileURL = fileHandler.fileURL(for: url) else { return }
                if NoteMDCore.noteExtensions.contains(fileURL.pathExtension.lowercased()), let onOpenNote = parent?.onOpenNote {
                    onOpenNote(fileURL)
                } else {
                    // Never launch local files from a link (could be executables); show them instead.
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

/// Serves `notemd-file://local/<absolute path>` from disk, only inside `accessRoot`.
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "notemd-file"
    var accessRoot: URL?

    static func url(for fileURL: URL, isDirectory: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "local"
        var path = fileURL.standardizedFileURL.path
        if isDirectory && !path.hasSuffix("/") { path += "/" }
        components.path = path
        return components.url
    }

    func fileURL(for url: URL) -> URL? {
        guard url.scheme == Self.scheme, let root = accessRoot else { return nil }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        let fileURL = URL(fileURLWithPath: path).canonical
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard fileURL.path.hasPrefix(rootPath) || fileURL.path == root.path else { return nil }
        return fileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let fileURL = fileURL(for: url),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
