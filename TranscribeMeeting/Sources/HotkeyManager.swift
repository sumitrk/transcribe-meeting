import AppKit

/// Manages two hotkey modes:
///
/// 1. **Toggle** (configurable, default ⌘⇧T): press once to start, press again to stop.
/// 2. **Push-to-talk** (Fn): hold to record, release to stop.
///
/// Global monitors fire when OTHER apps are active.
/// Local monitors fire when THIS app is active (e.g. Settings window is open).
/// Both are registered together so the hotkey works everywhere.
final class HotkeyManager {
    private var toggleGlobalMonitor: Any?
    private var toggleLocalMonitor: Any?
    private var pttMonitor: Any?

    // MARK: - Toggle mode (configurable, default ⌘⇧T)

    func start(keyCode: Int, modifiers: NSEvent.ModifierFlags,
               onTrigger: @escaping @MainActor () -> Void) {
        if let m = toggleGlobalMonitor { NSEvent.removeMonitor(m); toggleGlobalMonitor = nil }
        if let m = toggleLocalMonitor  { NSEvent.removeMonitor(m); toggleLocalMonitor  = nil }

        // Fires when another app is frontmost
        toggleGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == modifiers, event.keyCode == UInt16(keyCode) else { return }
            Task { @MainActor in onTrigger() }
        }

        // Fires when this app is frontmost (e.g. Settings window focused)
        toggleLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == modifiers, event.keyCode == UInt16(keyCode) else { return event }
            Task { @MainActor in onTrigger() }
            return nil // consume so the system doesn't beep
        }
    }

    // MARK: - Push-to-talk mode (Fn key, keyCode 63)

    func startPushToTalk(
        onPress:   @escaping @MainActor () -> Void,
        onRelease: @escaping @MainActor () -> Void
    ) {
        var isFnDown = false
        pttMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            guard event.keyCode == 63 else { return }  // 63 = Fn/Globe key
            let nowDown = event.modifierFlags.contains(.function)
            if nowDown && !isFnDown {
                isFnDown = true
                Task { @MainActor in onPress() }
            } else if !nowDown && isFnDown {
                isFnDown = false
                Task { @MainActor in onRelease() }
            }
        }
    }

    // MARK: - Cleanup

    func stop() {
        if let m = toggleGlobalMonitor { NSEvent.removeMonitor(m); toggleGlobalMonitor = nil }
        if let m = toggleLocalMonitor  { NSEvent.removeMonitor(m); toggleLocalMonitor  = nil }
        if let m = pttMonitor          { NSEvent.removeMonitor(m); pttMonitor          = nil }
    }
}
