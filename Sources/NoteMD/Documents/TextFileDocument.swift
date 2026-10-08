import AppKit
import NoteMDCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What a document window offers: Markdown and HTML get a preview, other text is edited as is.
enum DocumentKind: Sendable {
    case markdown, html, plainText

    nonisolated static func detect(typeName: String, url: URL?) -> DocumentKind {
        if let ext = url?.pathExtension.lowercased(), !ext.isEmpty {
            if ["md", "markdown", "mdown", "mkd", "mdx"].contains(ext) { return .markdown }
            return ["html", "htm"].contains(ext) ? .html : .plainText
        }
        if typeName == "Markdown Document" { return .markdown }
        if typeName == "HTML Document" { return .html }
        guard let type = UTType(typeName) else { return .plainText }
        if type.conforms(to: UTType("net.daringfireball.markdown") ?? .plainText) { return .markdown }
        return type.conforms(to: .html) ? .html : .plainText
    }
}

/// Text shown by a standalone document window.
@Observable final class DocumentModel {
    var text = ""
    /// Bumped when the text is replaced from disk (revert, external change).
    var revision = 0
    var kind = DocumentKind.markdown
    var isMarkdown: Bool { kind == .markdown }
    var hasPreview: Bool { kind != .plainText }
    /// HTML preview: run the page's scripts and load remote content (this window only, off by default).
    var allowsActiveContent = false
    /// Set when the file's encoding couldn't be decoded faithfully; saving would corrupt it.
    var isReadOnly = false
    @ObservationIgnored weak var document: NSDocument?
    @ObservationIgnored var onEdit: (() -> Void)?
    /// The on-screen text view, for undoable insertions (voice notes, transcripts).
    @ObservationIgnored let textBridge = EditorTextBridge()
    let voiceRecorder = VoiceRecorder()
    var showsVoiceRecorder = false
    /// Clip being transcribed (its link destination), shown as a sheet.
    var transcribeSource: String?

    var fileURL: URL? { document?.fileURL }

    func edit(_ newText: String) {
        guard newText != text else { return }
        text = newText
        onEdit?()
    }

    // MARK: Attachments

    /// Attachments of a standalone document go to an `assets/` folder next to it.
    var attachmentImporter: AttachmentImporter? {
        guard isMarkdown, !isReadOnly, let directory = fileURL?.deletingLastPathComponent() else { return nil }
        return AttachmentImporter(rootURL: directory, noteDirectory: directory)
    }

    /// Replaces a UTF-16 range: one undoable edit when the editor is on screen.
    func replace(_ range: NSRange, with replacement: String) {
        guard !textBridge.replace(range, with: replacement) else { return }
        let ns = text as NSString
        let location = min(max(range.location, 0), ns.length)
        edit(ns.replacingCharacters(in: NSRange(location: location, length: min(range.length, ns.length - location)), with: replacement))
        revision += 1
    }

    func insert(_ insertion: String, at offset: Int) {
        replace(NSRange(location: offset, length: 0), with: insertion)
    }

    /// Records a voice note at the caret: a placeholder embed goes in when recording starts and is finished
    /// (or removed on cancel) by its file name, however the text changed meanwhile.
    func startVoiceNote() {
        showsVoiceRecorder = true
        guard !voiceRecorder.isRecording, let importer = attachmentImporter else { return }
        let offset = textBridge.selectedLocation ?? (text as NSString).length
        guard let url = importer.newAssetURL(fileName: Attachments.timestampedName(prefix: "voice", pathExtension: "m4a")) else { return }
        voiceRecorder.start(saving: url) { [weak self] event in
            guard let self else { return }
            let fileName = url.lastPathComponent
            if case .started = event {} else { showsVoiceRecorder = false }
            switch event {
            case .started:
                let placeholder = Attachments.markdownLink(name: RepositoryStore.recordingLabel, destination: importer.relativeDestination(to: url), kind: .audio)
                insert(Attachments.ownLine(placeholder, in: text, at: offset), at: offset)
            case .finished:
                let label = "Voice note " + Date().formatted(date: .abbreviated, time: .shortened)
                if let ranges = Attachments.embedRanges(linkingFileNamed: fileName, in: text) {
                    replace(ranges.label, with: Attachments.escapeLabel(label))
                } else {
                    let link = Attachments.markdownLink(name: label, destination: importer.relativeDestination(to: url), kind: .audio)
                    insert(Attachments.ownLine(link, in: text, at: (text as NSString).length), at: (text as NSString).length)
                }
            case .cancelled:
                if let ranges = Attachments.embedRanges(linkingFileNamed: fileName, in: text) {
                    replace(Attachments.removalRange(of: ranges.embed, in: text), with: "")
                }
            }
        }
    }

    /// Links an existing clip at `offset` (test hooks).
    func insertVoiceNote(_ clip: URL, at offset: Int) {
        guard let importer = attachmentImporter else { return }
        let name = "Voice note " + Date().formatted(date: .abbreviated, time: .shortened)
        let link = Attachments.markdownLink(name: name, destination: importer.relativeDestination(to: clip), kind: .audio)
        insert(Attachments.ownLine(link, in: text, at: offset), at: offset)
    }

    func insertTranscript(_ transcript: String, forSource source: String) {
        let offset = Attachments.endOfLine(linking: source, in: text)
        insert(Attachments.ownLine(Attachments.quote(transcript), in: text, at: offset), at: offset)
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
            model.kind = DocumentKind.detect(typeName: typeName, url: fileURL)
            model.text = text
            model.revision += 1
        }
    }

    private nonisolated static func decode(_ data: Data) throws -> (String, String.Encoding, Bool) {
        // Any file type can be opened, so refuse binary content.
        if !TextDetection.isText(data) {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadCorruptFile.rawValue, userInfo: [
                NSLocalizedDescriptionKey: "This file isn't text.",
                NSLocalizedRecoverySuggestionErrorKey: "NoteMD opens Markdown and other text files.",
            ])
        }
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

    override func close() {
        // Keep a running voice note: link it and write the document before the window goes.
        if model.voiceRecorder.isRecording, let fileURL, let fileType {
            model.voiceRecorder.stop()
            try? write(to: fileURL, ofType: fileType)
        }
        super.close()
    }

    override func makeWindowControllers() {
        if let fileURL { model.kind = DocumentKind.detect(typeName: fileType ?? "", url: fileURL) }
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
            if !model.hasPreview {
                editor(sync: false)
            } else {
                switch mode {
                case .edit: editor(sync: false)
                case .preview: preview
                case .split:
                    HSplitView {
                        // Scroll sync needs Markdown source positions; HTML previews scroll on their own.
                        editor(sync: model.isMarkdown).frame(minWidth: 260, maxWidth: .infinity)
                        preview.frame(minWidth: 260, maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .toolbar {
            if model.attachmentImporter != nil {
                ToolbarItem {
                    VoiceNoteButton(recorder: model.voiceRecorder, showsPanel: Bindable(model).showsVoiceRecorder) {
                        model.startVoiceNote()
                    }
                }
            }
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
            if model.kind == .html && mode != .edit {
                ToolbarItem {
                    Toggle(isOn: Bindable(model).allowsActiveContent) {
                        Label("Scripts and Remote Content", systemImage: model.allowsActiveContent ? "lock.open" : "lock.shield")
                    }
                    .toggleStyle(.button)
                    .help(model.allowsActiveContent
                        ? "Scripts and remote content are on for this window. Click to block them again."
                        : "The preview blocks this page's scripts and remote content. Click to allow them for this window.")
                }
            }
            if model.hasPreview {
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
            if !model.hasPreview {
                ToolbarItem {
                    Label("Plain Text", systemImage: "doc.plaintext")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .help("Markdown formatting and preview are off for this file type")
                }
            }
        }
        .onChange(of: settings.editorMode) { _, newValue in mode = newValue }
        .sheet(isPresented: Binding(get: { model.transcribeSource != nil }, set: { if !$0 { model.transcribeSource = nil } })) {
            if let source = model.transcribeSource, let audio = Attachments.fileURL(forDestination: source, relativeTo: directory) {
                TranscriptionSheet(audioURL: audio) { text in model.insertTranscript(text, forSource: source) }
            }
        }
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
            attachmentImporter: model.attachmentImporter,
            bridge: model.textBridge,
            onChange: { model.edit($0) },
            onScroll: sync ? { scrollLine = $0 } : nil
        )
    }

    @ViewBuilder private var preview: some View {
        if model.kind == .html {
            HTMLPreview(html: model.text, directory: directory, allowsActiveContent: model.allowsActiveContent) { url in
                WindowManager.shared.openFile(url)
            }
        } else {
            markdownPreview
        }
    }

    private var markdownPreview: some View {
        MarkdownPreview(
            markdown: model.text,
            baseDirectory: directory,
            accessRoot: directory,
            frontMatter: .table,
            scrollLine: mode == .split ? scrollLine : nil,
            onOpenNote: { url in WindowManager.shared.openFile(url) },
            onTranscribe: model.isMarkdown ? { source in model.transcribeSource = source } : nil
        )
    }
}
