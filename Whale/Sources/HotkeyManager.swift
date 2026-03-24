import AppKit

enum HotkeyRegistrationMode {
    case full
    case localRecoveryOnly
    case stopped
}

/// Manages two hotkey modes:
///
/// 1. **Toggle** (configurable, default ⌘⇧T): press once to start, press again to stop.
/// 2. **Push-to-talk** (configurable, default Fn): hold to record, release to stop.
///
/// Fn/Globe (keyCode 63) is a modifier key — detected via flagsChanged.
/// All other keys use keyDown + keyUp global+local monitors.
final class HotkeyManager {
    private var toggleGlobalMonitor: Any?
    private var toggleLocalMonitor:  Any?
    private var pttGlobalFlagsMonitor: Any?
    private var pttLocalFlagsMonitor: Any?
    private var pttGlobalDownMonitor: Any?
    private var pttLocalDownMonitor: Any?
    private var pttGlobalUpMonitor: Any?
    private var pttLocalUpMonitor: Any?

    func rebuild(toggleKeyCode: Int,
                 toggleModifiers: NSEvent.ModifierFlags,
                 pttKeyCode: Int,
                 pttModifiers: NSEvent.ModifierFlags,
                 mode: HotkeyRegistrationMode,
                 onToggle: @escaping @MainActor () -> Void,
                 onPTTPress: @escaping @MainActor () -> Void,
                 onPTTRelease: @escaping @MainActor () -> Void) {
        stop()

        switch mode {
        case .full:
            installToggle(
                keyCode: toggleKeyCode,
                modifiers: toggleModifiers,
                includeGlobal: true,
                includeLocal: true,
                action: onToggle
            )
            installPushToTalk(
                keyCode: pttKeyCode,
                modifiers: pttModifiers,
                includeGlobal: true,
                includeLocal: true,
                onPress: onPTTPress,
                onRelease: onPTTRelease
            )

        case .localRecoveryOnly:
            installToggle(
                keyCode: toggleKeyCode,
                modifiers: toggleModifiers,
                includeGlobal: false,
                includeLocal: true,
                action: onToggle
            )
            installPushToTalk(
                keyCode: pttKeyCode,
                modifiers: pttModifiers,
                includeGlobal: false,
                includeLocal: true,
                onPress: onPTTPress,
                onRelease: onPTTRelease
            )

        case .stopped:
            break
        }
    }

    private func installToggle(keyCode: Int,
                               modifiers: NSEvent.ModifierFlags,
                               includeGlobal: Bool,
                               includeLocal: Bool,
                               action: @escaping @MainActor () -> Void) {
        if includeGlobal {
            toggleGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags == modifiers, event.keyCode == UInt16(keyCode) else { return }
                Task { @MainActor in action() }
            }
        }

        if includeLocal {
            toggleLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags == modifiers, event.keyCode == UInt16(keyCode) else { return event }
                Task { @MainActor in action() }
                return nil
            }
        }
    }

    private func installPushToTalk(keyCode: Int,
                                   modifiers: NSEvent.ModifierFlags,
                                   includeGlobal: Bool,
                                   includeLocal: Bool,
                                   onPress: @escaping @MainActor () -> Void,
                                   onRelease: (@MainActor () -> Void)?) {
        if let flag = modifierFlag(for: keyCode) {
            var isGlobalDown = false
            var isLocalDown = false

            if includeGlobal {
                pttGlobalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                    guard event.keyCode == UInt16(keyCode) else { return }
                    let nowDown = event.modifierFlags.contains(flag)
                    if nowDown && !isGlobalDown {
                        isGlobalDown = true
                        Task { @MainActor in onPress() }
                    } else if !nowDown && isGlobalDown {
                        isGlobalDown = false
                        if let onRelease {
                            Task { @MainActor in onRelease() }
                        }
                    }
                }
            }

            if includeLocal {
                pttLocalFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    guard event.keyCode == UInt16(keyCode) else { return event }
                    let nowDown = event.modifierFlags.contains(flag)
                    if nowDown && !isLocalDown {
                        isLocalDown = true
                        Task { @MainActor in onPress() }
                    } else if !nowDown && isLocalDown {
                        isLocalDown = false
                        if let onRelease {
                            Task { @MainActor in onRelease() }
                        }
                    }
                    return nil
                }
            }
        } else {
            var isGlobalDown = false
            var isLocalDown = false

            if includeGlobal {
                pttGlobalDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    guard flags == modifiers, event.keyCode == UInt16(keyCode), !isGlobalDown else { return }
                    isGlobalDown = true
                    Task { @MainActor in onPress() }
                }

                pttGlobalUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { event in
                    guard event.keyCode == UInt16(keyCode), isGlobalDown else { return }
                    isGlobalDown = false
                    if let onRelease {
                        Task { @MainActor in onRelease() }
                    }
                }
            }

            if includeLocal {
                pttLocalDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    guard flags == modifiers, event.keyCode == UInt16(keyCode), !isLocalDown else {
                        return event
                    }
                    isLocalDown = true
                    Task { @MainActor in onPress() }
                    return nil
                }

                pttLocalUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
                    guard event.keyCode == UInt16(keyCode) else { return event }
                    defer { isLocalDown = false }
                    guard isLocalDown else { return event }
                    if let onRelease {
                        Task { @MainActor in onRelease() }
                    }
                    return nil
                }
            }
        }
    }

    // MARK: - Cleanup

    func stop() {
        [toggleGlobalMonitor, toggleLocalMonitor,
         pttGlobalFlagsMonitor, pttLocalFlagsMonitor,
         pttGlobalDownMonitor, pttLocalDownMonitor,
         pttGlobalUpMonitor, pttLocalUpMonitor]
            .compactMap { $0 }.forEach { NSEvent.removeMonitor($0) }
        toggleGlobalMonitor = nil; toggleLocalMonitor = nil
        pttGlobalFlagsMonitor = nil; pttLocalFlagsMonitor = nil
        pttGlobalDownMonitor = nil; pttLocalDownMonitor = nil
        pttGlobalUpMonitor = nil; pttLocalUpMonitor = nil
    }
}
