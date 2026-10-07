import AVFoundation
import AppKit
import Observation
import SwiftUI

/// Records one voice note at a time as a mono AAC `.m4a` file.
@Observable final class VoiceRecorder {
    enum Event {
        /// Recording began (microphone access granted, file open).
        case started
        /// The finished clip.
        case finished(URL)
        /// Recording was cancelled and its file deleted.
        case cancelled
    }

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// Input level for the meter, 0…1.
    private(set) var level: Double = 0
    private(set) var permissionDenied = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var onEvent: ((Event) -> Void)?
    #if DEBUG
    /// Test builds: when set, recording skips the microphone and `stop()` writes the clip with it instead.
    @ObservationIgnored var simulatedClip: ((URL) -> Bool)?
    @ObservationIgnored private var simulatedURL: URL?
    #endif

    /// Starts recording into `url`, asking for microphone access first if needed.
    func start(saving url: URL, onEvent: @escaping (Event) -> Void) {
        guard !isRecording else { return }
        errorMessage = nil
        permissionDenied = false
        #if DEBUG
        if simulatedClip != nil {
            simulatedURL = url
            self.onEvent = onEvent
            isRecording = true
            onEvent(.started)
            return
        }
        #endif
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin(url, onEvent)
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .audio) {
                    begin(url, onEvent)
                } else {
                    permissionDenied = true
                }
            }
        default:
            permissionDenied = true
        }
    }

    /// Stops recording and hands the clip over.
    func stop() {
        #if DEBUG
        if let url = simulatedURL, let onEvent, let simulatedClip {
            simulatedURL = nil
            let written = simulatedClip(url)
            reset()
            onEvent(written ? .finished(url) : .cancelled)
            return
        }
        #endif
        guard let recorder, let onEvent else { return }
        recorder.stop()
        let url = recorder.url
        reset()
        onEvent(.finished(url))
    }

    /// Stops recording and deletes the clip.
    func cancel() {
        #if DEBUG
        if simulatedURL != nil, let onEvent {
            simulatedURL = nil
            reset()
            onEvent(.cancelled)
            return
        }
        #endif
        guard let recorder, let onEvent else { return }
        recorder.stop()
        recorder.deleteRecording()
        reset()
        onEvent(.cancelled)
    }

    private func begin(_ url: URL, _ onEvent: @escaping (Event) -> Void) {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            self.onEvent = onEvent
            isRecording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            onEvent(.started)
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    private func tick() {
        guard let recorder else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        // dBFS to a 0…1 scale that moves visibly for speech.
        level = max(0, min(1, pow(10, Double(recorder.averagePower(forChannel: 0)) / 40)))
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        onEvent = nil
        isRecording = false
        level = 0
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Toolbar button that starts a voice note, or shows the running recording.
struct VoiceNoteButton: View {
    let recorder: VoiceRecorder
    @Binding var showsPanel: Bool
    let start: () -> Void

    var body: some View {
        Button {
            if recorder.isRecording { showsPanel = true } else { start() }
        } label: {
            if recorder.isRecording {
                Label {
                    Text(VoiceRecorder.format(recorder.elapsed)).monospacedDigit()
                } icon: {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                }
                .labelStyle(.titleAndIcon)
            } else {
                Label("Record Voice Note", systemImage: "mic")
            }
        }
        .help(recorder.isRecording ? "Recording a voice note" : "Record a voice note into this note (⌃⌘R)")
        .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
            VoiceRecorderPanel(recorder: recorder)
        }
    }
}

/// Timer, input level and Stop/Cancel for the running recording.
struct VoiceRecorderPanel: View {
    let recorder: VoiceRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recorder.permissionDenied {
                Label("NoteMD can't use the microphone", systemImage: "mic.slash").font(.headline)
                Text("Allow NoteMD in System Settings › Privacy & Security › Microphone, then try again.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Microphone Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else if let error = recorder.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true)
            } else if recorder.isRecording {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red).symbolEffect(.pulse)
                    Text(VoiceRecorder.format(recorder.elapsed)).font(.title2.monospacedDigit())
                    Spacer()
                }
                LevelMeter(level: recorder.level)
                HStack {
                    Button("Cancel", role: .cancel) { recorder.cancel() }
                    Spacer()
                    Button("Stop") { recorder.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Starting…").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

private struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.red.gradient).frame(width: max(6, geometry.size.width * level))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
