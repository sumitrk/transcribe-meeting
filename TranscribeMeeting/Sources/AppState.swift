import AppKit
import CoreGraphics
import Foundation

enum AppStatus: Equatable {
    case ready
    case recording
    case transcribing
    case summarising
    case error(String)
}

/// Tracks how the current recording was triggered.
fileprivate enum RecordingMode {
    case markdown   // ⌘⇧T: Parakeet → Claude → .md file → Finder
    case paste      // Fn:   Parakeet only → clipboard + auto-paste
}

@MainActor
class AppState: ObservableObject {
    @Published var status: AppStatus = .ready
    @Published var isRecording = false
    @Published var lastMeetingPath: String? = nil

    let recorder = AudioRecorder()
    let stt      = STTClient()
    let claude   = ClaudeClient()
    let hotkey   = HotkeyManager()

    var anthropicApiKey: String {
        UserDefaults.standard.string(forKey: "anthropicApiKey") ?? ""
    }

    private var recordingStartedAt: Date?
    private var currentMode: RecordingMode = .markdown

    init() {
        // ⌘⇧T — toggle: full markdown pipeline
        hotkey.start { [weak self] in self?.toggleMarkdown() }

        // Fn (hold) — push-to-talk: paste only, no markdown
        hotkey.startPushToTalk(
            onPress: { [weak self] in
                guard let self, !self.isRecording else { return }
                Task { await self.startRecording(mode: .paste) }
            },
            onRelease: { [weak self] in
                guard let self, self.isRecording else { return }
                Task { await self.stopRecording() }
            }
        )

        requestAccessibilityOnce()
    }

    var isReady: Bool { status == .ready }

    var statusLabel: String {
        switch status {
        case .ready:         return "Ready  (⌘⇧T to record | hold Fn to dictate)"
        case .recording:
            return currentMode == .paste
                ? "Dictating…  (release Fn to stop)"
                : "Recording…  (⌘⇧T to stop)"
        case .transcribing:  return "Transcribing…"
        case .summarising:   return "Summarising…"
        case .error(let m):  return "Error: \(m)"
        }
    }

    // MARK: - Toggle (⌘⇧T)

    func toggleMarkdown() {
        if isRecording && currentMode == .markdown {
            Task { await stopRecording() }
        } else if !isRecording {
            Task { await startRecording(mode: .markdown) }
        }
        // ignore ⌘⇧T while in PTT mode
    }

    // MARK: - Recording core

    fileprivate func startRecording(mode: RecordingMode) async {
        do {
            currentMode = mode
            try await recorder.startRecording()
            isRecording = true
            status = .recording
            recordingStartedAt = Date()
            playSound("Blow")  // start cue
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func stopRecording() async {
        let startedAt = recordingStartedAt ?? Date()
        let mode = currentMode
        isRecording = false
        status = .transcribing

        do {
            let wavURL = try await recorder.stopRecording()
            print("WAV saved: \(wavURL.path)")

            // Transcribe using on-device Parakeet (downloads model on first use)
            let rawTranscript = try await stt.transcribe(wavURL: wavURL)
            print("Transcript ready (\(rawTranscript.count) chars)")

            switch mode {

            case .paste:
                // PTT: paste raw transcript, no markdown file
                status = .ready
                playSound("Bottle")  // done cue
                copyAndPaste(rawTranscript)
                try? FileManager.default.removeItem(at: wavURL)

            case .markdown:
                // Toggle: Claude → .md → Finder
                let duration = Int(Date().timeIntervalSince(startedAt) / 60)
                let mdURL = wavURL.deletingPathExtension().appendingPathExtension("md")

                let md: String
                if anthropicApiKey.isEmpty {
                    print("No API key — skipping summarisation")
                    md = buildMarkdown(date: startedAt, duration: duration,
                                       cleanedTranscript: rawTranscript, summary: nil)
                } else {
                    status = .summarising
                    let result = try await claude.summarise(transcript: rawTranscript,
                                                            apiKey: anthropicApiKey)
                    print("Summary ready")
                    md = buildMarkdown(date: startedAt, duration: duration,
                                       cleanedTranscript: result.cleaned_transcript,
                                       summary: result.summary.isEmpty ? nil : result.summary)
                }

                try md.write(to: mdURL, atomically: true, encoding: .utf8)
                print("Saved: \(mdURL.path)")

                lastMeetingPath = mdURL.path
                status = .ready
                playSound("Bottle")  // done cue

                NSWorkspace.shared.selectFile(mdURL.path, inFileViewerRootedAtPath: "")
            }

        } catch {
            isRecording = false
            status = .error(error.localizedDescription)
            print("Recording error: \(error.localizedDescription)")
        }
    }

    // MARK: - Sound

    private func playSound(_ name: String) {
        NSSound(named: name)?.play()
    }

    // MARK: - Clipboard + paste

    private func copyAndPaste(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("Copied to clipboard (\(text.count) chars)")
        print("AXIsProcessTrusted = \(AXIsProcessTrusted())")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let src = CGEventSource(stateID: .combinedSessionState)

            let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
            down?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)

            usleep(10_000)  // 10ms

            let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
            up?.flags = .maskCommand
            up?.post(tap: .cghidEventTap)

            print("Auto-paste attempted via ⌘V (events: down=\(down != nil), up=\(up != nil))")
        }
    }

    // MARK: - Accessibility

    private func requestAccessibilityOnce() {
        let key = "hasPromptedAccessibility"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
    }

    // MARK: - Markdown builder

    private func buildMarkdown(date: Date, duration: Int,
                               cleanedTranscript: String, summary: String?) -> String {
        var sections: [String] = [
            "# Meeting — \(formattedDate(date))",
            "**Duration:** ~\(max(1, duration)) min  |  **Model:** Parakeet TDT 0.6B",
        ]
        if let summary { sections += ["", summary] }
        sections += ["", "## Transcript", "", cleanedTranscript]
        return sections.joined(separator: "\n")
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
