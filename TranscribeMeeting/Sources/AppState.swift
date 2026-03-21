import Foundation

enum AppStatus: Equatable {
    case starting
    case ready
    case recording
    case processing
    case error(String)
}

@MainActor
class AppState: ObservableObject {
    @Published var status: AppStatus = .starting
    @Published var isRecording = false
    @Published var lastMeetingPath: String? = nil

    let server = PythonServer()
    let recorder = AudioRecorder()
    let client = TranscribeClient()
    var whisperModel: String = "mlx-community/whisper-large-v3-turbo"

    private var recordingStartedAt: Date?

    init() {
        Task {
            await startServer()
        }
    }

    var isReady: Bool {
        status == .ready
    }

    var statusLabel: String {
        switch status {
        case .starting:        return "Starting server..."
        case .ready:           return "Ready"
        case .recording:       return "Recording..."
        case .processing:      return "Processing..."
        case .error(let msg):  return "Error: \(msg)"
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
        do {
            let wavURL = try await recorder.stopRecording()
            isRecording = false
            status = .ready

            // Debug: transcribe and print to console (full pipeline wired in Step 4)
            print("WAV saved: \(wavURL.path)")
            let transcript = try await client.transcribe(wavURL: wavURL, model: whisperModel)
            print("Transcript: \(transcript)")
            let duration = Int(Date().timeIntervalSince(startedAt) / 60)
            print("Duration: ~\(max(1, duration)) min")
        } catch {
            isRecording = false
            status = .error(error.localizedDescription)
            print("Recording error: \(error.localizedDescription)")
        }
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
