import AppKit
import Foundation
import UserNotifications

enum AppStatus: Equatable {
    case starting
    case ready
    case recording
    case transcribing
    case summarising
    case error(String)
}

@MainActor
class AppState: ObservableObject {
    @Published var status: AppStatus = .starting
    @Published var isRecording = false
    @Published var lastMeetingPath: String? = nil

    let server   = PythonServer()
    let recorder = AudioRecorder()
    let client   = TranscribeClient()
    let hotkey   = HotkeyManager()

    var whisperModel: String = "mlx-community/whisper-large-v3-turbo"

    /// API key stored in UserDefaults.
    /// Set once from Terminal: defaults write com.sumitrk.transcribe-meeting anthropicApiKey "sk-ant-..."
    /// The Settings window (step 6) will let you set it via UI instead.
    var anthropicApiKey: String {
        UserDefaults.standard.string(forKey: "anthropicApiKey") ?? ""
    }

    private var recordingStartedAt: Date?

    init() {
        Task {
            await requestNotificationPermission()
            await startServer()
        }
        hotkey.start { [weak self] in self?.toggleRecording() }
    }

    var isReady: Bool { status == .ready }

    var statusLabel: String {
        switch status {
        case .starting:      return "Starting server…"
        case .ready:         return "Ready  (⌘⇧T to record)"
        case .recording:     return "Recording…  (⌘⇧T to stop)"
        case .transcribing:  return "Transcribing…"
        case .summarising:   return "Summarising…"
        case .error(let m):  return "Error: \(m)"
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        do {
            try await recorder.startRecording()
            isRecording = true
            status = .recording
            recordingStartedAt = Date()
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func stopRecording() async {
        let startedAt = recordingStartedAt ?? Date()
        isRecording = false
        status = .transcribing

        do {
            // 1. Stop capture → WAV file
            let wavURL = try await recorder.stopRecording()
            print("WAV saved: \(wavURL.path)")

            // 2. Whisper transcription
            let rawTranscript = try await client.transcribe(wavURL: wavURL, model: whisperModel)
            print("Transcript ready (\(rawTranscript.count) chars)")

            let duration = Int(Date().timeIntervalSince(startedAt) / 60)
            let mdURL = wavURL.deletingPathExtension().appendingPathExtension("md")

            // 3. Claude summarisation (skipped gracefully if no API key)
            let md: String
            if anthropicApiKey.isEmpty {
                print("No API key set — skipping summarisation. Set via: defaults write com.sumitrk.transcribe-meeting anthropicApiKey \"sk-ant-...\"")
                md = buildMarkdown(date: startedAt, duration: duration,
                                   cleanedTranscript: rawTranscript, summary: nil)
            } else {
                status = .summarising
                let result = try await client.summarise(transcript: rawTranscript,
                                                        apiKey: anthropicApiKey)
                print("Summary ready")
                md = buildMarkdown(date: startedAt, duration: duration,
                                   cleanedTranscript: result.cleaned_transcript,
                                   summary: result.summary)
            }

            // 4. Write markdown file
            try md.write(to: mdURL, atomically: true, encoding: .utf8)
            print("Saved: \(mdURL.path)")

            lastMeetingPath = mdURL.path
            status = .ready

            // 5. Reveal in Finder + send notification
            NSWorkspace.shared.selectFile(mdURL.path, inFileViewerRootedAtPath: "")
            sendNotification(mdURL: mdURL)

        } catch {
            isRecording = false
            status = .error(error.localizedDescription)
            print("Recording error: \(error.localizedDescription)")
        }
    }

    // MARK: - Markdown builder

    private func buildMarkdown(date: Date, duration: Int,
                               cleanedTranscript: String, summary: String?) -> String {
        var sections: [String] = [
            "# Meeting — \(formattedDate(date))",
            "**Duration:** ~\(max(1, duration)) min  |  **Model:** \(whisperModel)",
        ]

        if let summary {
            sections += ["", summary]
        }

        sections += [
            "",
            "## Transcript",
            "",
            cleanedTranscript,
        ]

        return sections.joined(separator: "\n")
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - Notifications

    private func requestNotificationPermission() async {
        try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    private func sendNotification(mdURL: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting saved"
        content.body  = mdURL.deletingPathExtension().lastPathComponent
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Server startup

    private func startServer() async {
        do {
            try await server.start()
            try await server.waitUntilHealthy()
            status = .ready
        } catch {
            status = .error(error.localizedDescription)
        }
    }
}
