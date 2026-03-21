import AppKit

/// Listens for ⌘⇧T globally and calls `onTrigger`.
///
/// Uses NSEvent global monitor — works without Accessibility permission.
/// The event is *observed* (not consumed), so it still reaches the focused app,
/// but ⌘⇧T has no standard macOS meaning so there's no conflict in practice.
final class HotkeyManager {
    private var monitor: Any?

    func start(onTrigger: @escaping @MainActor () -> Void) {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // keyCode 17 = 't'
            guard flags == [.command, .shift], event.keyCode == 17 else { return }
            Task { @MainActor in onTrigger() }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
