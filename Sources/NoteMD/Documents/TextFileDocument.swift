import AppKit
import NoteMDCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Text shown by a standalone document window.
@Observable final class DocumentModel {
    var text = ""
    /// Bumped when the text is replaced from disk (revert, external change).
    var revision = 0
    var isMarkdown = true
    /// Set when the file's encoding couldn't be decoded faithfully; saving would corrupt it.
    var isReadOnly = false
    @ObservationIgnored weak var document: NSDocument?
    @ObservationIgnored var onEdit: (() -> Void)?

    var fileURL: URL? { document?.fileURL }

    func edit(_ newText: String) {
        guard newText != text else { return }
        text = newText
        onEdit?()
    }
}

/// A standalone Markdown or plain-text file (Finder "Open With", Open…, Dock drops).
@objc(TextFileDocument)
final class TextFileDocument: NSDocument {
    let model = DocumentModel()
    private var encoding: String.Encoding = .utf8

    override init() {
        super.init()
        model.document = self
        model.onEdit = { [weak self] in self?.updateChangeCount(.changeDone) }
    }

    nonisolated override class var autosavesInPlace: Bool { true }

    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        let (text, encoding, lossy) = try Self.decode(data)
        // Documents aren't read concurrently, so this runs on the main thread.
        MainActor.assumeIsolated {
            self.encoding = encoding
            model.isReadOnly = lossy
            model.isMarkdown = Self.isMarkdown(typeName: typeName, url: fileURL)
            model.text = text
            model.revision += 1
        }
    }

    private nonisolated static func decode(_ data: Data) throws -> (String, String.Encoding, Bool) {
        if let utf8 = String(data: data, encoding: .utf8) { return (utf8, .utf8, false) }
        var converted: NSString?
        var usedLossy: ObjCBool = false
        let detected = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: &usedLossy)
        guard let converted, detected != 0 else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return (converted as String, String.Encoding(rawValue: detected), usedLossy.boolValue)
    }

    override func data(ofType typeName: String) throws -> Data {
        guard !model.isReadOnly else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        guard let data = model.text.data(using: encoding) ?? model.text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return data
    }

    override var shouldRunSavePanelWithAccessoryView: Bool { false }

    nonisolated static func isMarkdown(typeName: String, url: URL?) -> Bool {
        if let ext = url?.pathExtension.lowercased(), !ext.isEmpty {
            return ["md", "markdown", "mdown", "mkd", "mdx"].contains(ext)
        }
        if typeName == "Markdown Document" { return true }
        return UTType(typeName)?.conforms(to: UTType("net.daringfireball.markdown") ?? .plainText) ?? false
    }

    override func makeWindowControllers() {
        if let fileURL { model.isMarkdown = Self.isMarkdown(typeName: fileType ?? "", url: fileURL) }
        let hosting = NSHostingController(rootView: DocumentEditorView(model: model))
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.tabbingMode = .automatic
        window.setContentSize(NSSize(width: 980, height: 760))
        let controller = NSWindowController(window: window)
        controller.shouldCascadeWindows = true
        addWindowController(controller)
        window.setFrameAutosaveName("TextDocument")
    }
}

struct DocumentEditorView: View {
    let model: DocumentModel
    private let settings = AppSettings.shared
    @State private var mode: EditorMode = AppSettings.shared.editorMode
    @State private var scrollLine: Int?
    @State private var showTemplateForm = false

    private var directory: URL {
        model.fileURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private var isTemplate: Bool {
        model.isMarkdown && (MarkdownText(model.text).frontMatter?.isTemplate ?? false)
    }

    var body: some View {
        Group {
            if !model.isMarkdown {
                editor(sync: false)
            } else {
                switch mode {
                case .edit: editor(sync: false)
                case .preview: preview
                case .split:
                    HSplitView {
                        editor(sync: true).frame(minWidth: 260, maxWidth: .infinity)
                        preview.frame(minWidth: 260, maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .toolbar {
            if model.isMarkdown {
                if isTemplate {
                    ToolbarItem {
                        Button {
                            showTemplateForm = true
                        } label: {
                            Label("Use Template", systemImage: "wand.and.stars")
                        }
                        .help("Fill in the template parameters")
                    }
                }
                ToolbarItem {
                    Picker("Mode", selection: $mode) {
                        ForEach(EditorMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                }
            }
            if model.isReadOnly {
                ToolbarItem {
                    Label("Read Only", systemImage: "lock")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .help("This file's text encoding couldn't be read exactly, so editing is off to avoid damaging it")
                }
            }
            if !model.isMarkdown {
                ToolbarItem {
                    Label("Plain Text", systemImage: "doc.plaintext")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .help("Markdown formatting and preview are off for this file type")
                }
            }
        }
        .onChange(of: settings.editorMode) { _, newValue in mode = newValue }
        .sheet(isPresented: $showTemplateForm) {
            TemplateFormView(source: .document(title: model.fileURL?.deletingPathExtension().lastPathComponent ?? "Template", markdown: model.text, fileURL: model.fileURL))
        }
    }

    private func editor(sync: Bool) -> some View {
        MarkdownEditor(
            text: model.text,
            revision: model.revision,
            isMarkdown: model.isMarkdown,
            isEditable: !model.isReadOnly,
            font: settings.editorFont(monospacedOverride: !model.isMarkdown),
            indentation: settings.indentation,
            readableWidth: model.isMarkdown && settings.readableLineWidth && mode != .split ? 760 : 0,
            spellChecking: settings.spellChecking,
            onChange: { model.edit($0) },
            onScroll: sync ? { scrollLine = $0 } : nil
        )
    }

    private var preview: some View {
        MarkdownPreview(
            markdown: model.text,
            baseDirectory: directory,
            accessRoot: directory,
            frontMatter: .table,
            scrollLine: mode == .split ? scrollLine : nil,
            onOpenNote: { url in WindowManager.shared.openFile(url) }
        )
    }
}
