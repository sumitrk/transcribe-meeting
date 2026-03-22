import AppKit
import SwiftUI

/// Key recorder for push-to-talk. Unlike KeyRecorderView it also captures
/// the Fn/Globe key (keyCode 63), which is a modifier and only appears in
/// flagsChanged events, not keyDown events.
struct PTTRecorderView: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int

    @State private var isRecording = false
    @State private var keyDownMonitor: Any?
    @State private var flagsMonitor: Any?

    var body: some View {
        Button(isRecording ? "Press key…" : label) {
            isRecording ? stopRecording() : startRecording()
        }
        .buttonStyle(.bordered)
        .foregroundStyle(isRecording ? Color.orange : Color.primary)
        .onDisappear { stopRecording() }
    }

    private var label: String {
        SettingsStore.shared.keyLabel(keyCode: keyCode, modifiers: modifiers)
    }

    private func startRecording() {
        isRecording = true

        // Catch Fn/Globe (modifier key — shows up in flagsChanged, not keyDown)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard event.keyCode == 63 else { return event }
            if event.modifierFlags.contains(.function) {
                keyCode = 63
                modifiers = 0
                stopRecording()
                return nil
            }
            return event
        }

        // Catch any regular modifier+key combo
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil } // Escape = cancel
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
                return event
            }
            keyCode = Int(event.keyCode)
            modifiers = Int(flags.rawValue)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = keyDownMonitor { NSEvent.removeMonitor(m); keyDownMonitor = nil }
        if let m = flagsMonitor   { NSEvent.removeMonitor(m); flagsMonitor   = nil }
    }
}
