import AppKit
import Combine

@MainActor
final class AccessibilityController: ObservableObject {
    @Published private(set) var isTrusted = AXIsProcessTrusted()

    private var activationObserver: (any NSObjectProtocol)?
    private var pollTimer: Timer?
    private var isMonitoring = false
    private var pollDeadline = Date.distantPast

    func startMonitoring(promptOnLaunch: Bool) {
        guard !isMonitoring else { return }
        isMonitoring = true

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        refresh(prompt: promptOnLaunch)
    }

    func refresh(prompt: Bool = false) {
        let trusted: Bool
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        } else {
            trusted = AXIsProcessTrusted()
        }

        updateTrustState(trusted)

        if prompt && !trusted {
            startPolling()
        }
    }

    func requestPrompt() {
        refresh(prompt: true)
    }

    func openSystemAccessibilitySettingsAndWatch() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
        startPolling()
    }

    private func updateTrustState(_ trusted: Bool) {
        isTrusted = trusted

        if trusted {
            stopPolling()
        }
    }

    private func startPolling() {
        stopPolling()
        pollDeadline = Date().addingTimeInterval(15)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                if self.isTrusted || Date() >= self.pollDeadline {
                    self.stopPolling()
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
