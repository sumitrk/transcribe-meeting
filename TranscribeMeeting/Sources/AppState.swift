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
