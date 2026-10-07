import AVFoundation
import Speech
import SwiftUI

/// On-device speech-to-text for audio files (macOS 26 Speech framework); audio never leaves the Mac.
enum Transcriber {
    enum Failure: LocalizedError {
        case unavailable, unsupportedLanguage(String), noSpeech

        var errorDescription: String? {
            switch self {
            case .unavailable: "On-device transcription isn't available on this Mac."
            case .unsupportedLanguage(let name): "\(name) can't be transcribed on this Mac."
            case .noSpeech: "No speech was recognized in this clip."
            }
        }
    }

    /// Languages that can be transcribed, sorted by display name.
    static func supportedLocales() async -> [Locale] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales.sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
    }

    static func displayName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// The supported locale for a saved identifier (empty = the system language).
    static func preferredLocale(identifier: String, among locales: [Locale]) -> Locale? {
        let wanted = Locale(identifier: identifier.isEmpty ? Locale.current.identifier : identifier)
        return locales.first { $0.identifier(.bcp47) == wanted.identifier(.bcp47) }
            ?? locales.first { $0.language.languageCode == wanted.language.languageCode && $0.region == wanted.region }
            ?? locales.first { $0.language.languageCode == wanted.language.languageCode }
    }

    /// Transcribes `url` in `locale`, downloading the language model first when needed.
    /// `onDownload` receives the model download's progress.
    static func transcribe(_ url: URL, locale: Locale, onDownload: (Progress) -> Void = { _ in }) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupportedLanguage(displayName(locale))
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onDownload(request.progress)
            try await request.downloadAndInstall()
        }
        let audio = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let segments = transcriber.results.reduce(into: [String]()) { segments, result in
            segments.append(String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let end = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let text = try await segments.filter { !$0.isEmpty }.joined(separator: " ")
        try Task.checkCancellation()
        guard !text.isEmpty else { throw Failure.noSpeech }
        return text
    }
}

/// Picks a language and transcribes one clip; the transcript goes to `onInsert`.
struct TranscriptionSheet: View {
    let audioURL: URL
    let onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var locales: [Locale] = []
    @State private var selection = ""
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var download: Progress?
    @State private var errorMessage: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcribe Voice Note").font(.headline)
            Label(audioURL.lastPathComponent, systemImage: "waveform").foregroundStyle(.secondary)
            if isLoading {
                ProgressView().controlSize(.small)
            } else if locales.isEmpty {
                Text(Transcriber.Failure.unavailable.localizedDescription).foregroundStyle(.secondary)
            } else {
                Picker("Language", selection: $selection) {
                    ForEach(locales, id: \.identifier) { Text(Transcriber.displayName($0)).tag($0.identifier) }
                }
                .disabled(isWorking)
            }
            if isWorking {
                if let download, !download.isFinished {
                    Text("Downloading the language model…").font(.callout)
                    ProgressView(download)
                } else {
                    ProgressView { Text("Transcribing on this Mac…") }.progressViewStyle(.linear)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The transcript is added below the clip as a quote. Audio is processed on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    work?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Transcribe", action: run)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || selection.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onDisappear { work?.cancel() }
        .task {
            locales = await Transcriber.supportedLocales()
            selection = Transcriber.preferredLocale(identifier: AppSettings.shared.transcriptionLanguage, among: locales)?.identifier
                ?? locales.first?.identifier ?? ""
            isLoading = false
        }
    }

    private func run() {
        guard let locale = locales.first(where: { $0.identifier == selection }) else { return }
        isWorking = true
        errorMessage = nil
        work = Task {
            do {
                let text = try await Transcriber.transcribe(audioURL, locale: locale) { download = $0 }
                try Task.checkCancellation()
                onInsert(text)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
            download = nil
        }
    }
}

/// Settings row choosing the language preselected for transcriptions.
struct TranscriptionLanguagePicker: View {
    @State private var locales: [Locale] = []

    var body: some View {
        @Bindable var settings = AppSettings.shared
        Picker("Transcription language", selection: $settings.transcriptionLanguage) {
            Text("System Language").tag("")
            if !locales.isEmpty { Divider() }
            ForEach(locales, id: \.identifier) { Text(Transcriber.displayName($0)).tag($0.identifier) }
        }
        .task { locales = await Transcriber.supportedLocales() }
    }
}
