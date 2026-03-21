import Foundation

class PythonServer {
    private var process: Process?
    private let healthURL = URL(string: "http://127.0.0.1:8765/health")!

    // MARK: - Start

    func start() async throws {
        // Find server.py relative to this app bundle (dev mode: sibling of .app)
        let serverScript = findServerScript()

        guard let serverScript else {
            throw ServerError.serverScriptNotFound
        }

        // Find the python3 from the active uv venv, falling back to system python
        let python = findPython()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [serverScript]

        // Set working directory to the server/ folder so relative imports work
        proc.currentDirectoryURL = URL(fileURLWithPath: serverScript)
            .deletingLastPathComponent()

        // Suppress server stdout/stderr (it logs via uvicorn internally)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        self.process = proc
        print("PythonServer: started PID \(proc.processIdentifier) → \(serverScript)")
    }

    // MARK: - Health polling

    /// Polls /health every 500ms until 200 OK or timeout
    func waitUntilHealthy(timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await isHealthy() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ServerError.startupTimeout
    }

    func isHealthy() async -> Bool {
        do {
            let (_, response) = try await URLSession.shared.data(from: healthURL)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Stop

    func stop() {
        process?.terminate()
        process = nil
        print("PythonServer: stopped")
    }

    // MARK: - Path resolution

    private func findServerScript() -> String? {
        // 1. Bundled inside .app (production)
        if let bundled = Bundle.main.path(forResource: "server", ofType: "py",
                                          inDirectory: "scripts") {
            return bundled
        }

        // 2. Development: repo root is 3 levels above the built binary
        //    .../DerivedData/.../Build/Products/Debug/TranscribeMeeting.app/Contents/MacOS/TranscribeMeeting
        let binaryURL = URL(fileURLWithPath: Bundle.main.executablePath ?? "")
        let candidates = [
            // Walk up from binary to find server/server.py in the repo
            binaryURL
                .deletingLastPathComponent() // MacOS/
                .deletingLastPathComponent() // Contents/
                .deletingLastPathComponent() // TranscribeMeeting.app/
                .deletingLastPathComponent() // Debug/
                .deletingLastPathComponent() // Products/
                .deletingLastPathComponent() // Build/
                .deletingLastPathComponent() // DerivedData/<scheme>/
                .deletingLastPathComponent() // DerivedData/
                .deletingLastPathComponent() // repo root (hopefully)
                .appendingPathComponent("server/server.py")
                .path,
            // Fallback: hardcoded project path for dev
            "/Users/sumitkumar/Downloads/Projects/transcribe-meetings/server/server.py",
        ]

        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func findPython() -> String {
        // Prefer the venv python next to the project
        let venvPython = "/Users/sumitkumar/Downloads/Projects/transcribe-meetings/.venv/bin/python3"
        if FileManager.default.fileExists(atPath: venvPython) {
            return venvPython
        }
        // Fallback to Homebrew python
        return "/opt/homebrew/bin/python3"
    }
}

// MARK: - Errors

enum ServerError: LocalizedError {
    case serverScriptNotFound
    case startupTimeout

    var errorDescription: String? {
        switch self {
        case .serverScriptNotFound:
            return "Could not find server/server.py"
        case .startupTimeout:
            return "Python server failed to start within 15 seconds"
        }
    }
}
