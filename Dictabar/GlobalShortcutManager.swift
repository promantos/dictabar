import Carbon
import Foundation

final class GlobalShortcutManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressed = false
    private var modifierKeyCode: CGKeyCode?
    private let onPressed: () -> Void
    private let onReleased: () -> Void
    private let onError: (String) -> Void

    init(
        onPressed: @escaping () -> Void,
        onReleased: @escaping () -> Void,
        onError: @escaping (String) -> Void = { _ in }
    ) {
        self.onPressed = onPressed
        self.onReleased = onReleased
        self.onError = onError
    }

    func start(preset: ShortcutPreset, customShortcut: KeyboardShortcut) {
        stop()
        if let keyCode = preset.keyCode {
            guard PermissionManager.hasInputMonitoringAccess() else {
                DiagnosticsLogger.shared.log("shortcut: waiting for Input Monitoring")
                onError("Enable Input Monitoring for the Right-modifier shortcut. Menu bar Start/Stop remains available.")
                return
            }
            if !startModifierTap(keyCode: CGKeyCode(keyCode)) {
                onError("Right-modifier shortcut could not start. Reopen Dictabar after enabling Input Monitoring.")
            }
        } else {
            startCarbon(shortcut: customShortcut)
        }
    }

    func update(preset: ShortcutPreset, customShortcut: KeyboardShortcut) {
        start(preset: preset, customShortcut: customShortcut)
    }

    private func startCarbon(shortcut: KeyboardShortcut) {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    manager.onReleased()
                } else {
                    manager.onPressed()
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            onError("Global shortcut handler failed to install: \(installStatus).")
            return
        }

        let id = EventHotKeyID(signature: OSType("FDCT".fourCharCode), id: 1)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            onError("Global shortcut failed to register: \(registerStatus).")
        }
    }

    @discardableResult
    private func startModifierTap(keyCode: CGKeyCode) -> Bool {
        modifierKeyCode = keyCode
        pressed = false
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userData in
            guard let userData else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let eventTap = manager.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
                DiagnosticsLogger.shared.log("shortcut event tap re-enabled")
                return Unmanaged.passUnretained(event)
            }
            guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
            manager.handleFlagsChanged(event)
            return Unmanaged.passUnretained(event)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        )

        guard let eventTap else {
            DiagnosticsLogger.shared.log("shortcut: listen-only event tap failed")
            return false
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        DiagnosticsLogger.shared.log("shortcut: modifier tap active key=\(keyCode)")
        return true
    }

    /// Drive press/release from real modifier state (not a flip-flop).
    /// Uses device-dependent side flags when available so Right ⌘ is independent of Left ⌘.
    private func handleFlagsChanged(_ event: CGEvent) {
        guard let modifierKeyCode else { return }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == modifierKeyCode else { return }

        let isDown = Self.isModifierDown(keyCode: keyCode, flags: event.flags)
        guard isDown != pressed else { return }
        pressed = isDown
        if isDown {
            onPressed()
        } else {
            onReleased()
        }
    }

    /// Device-dependent flag bits (IOKit NX_DEVICE* masks) for left/right modifiers.
    private static func isModifierDown(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        // From IOKit/events.h — present in CGEventFlags on macOS.
        let leftCommand: UInt64 = 0x00000008
        let rightCommand: UInt64 = 0x00000010
        let leftOption: UInt64 = 0x00000020
        let rightOption: UInt64 = 0x00000040
        let leftControl: UInt64 = 0x00000001
        let rightControl: UInt64 = 0x00002000

        switch keyCode {
        case 54: // Right Command
            if raw & rightCommand != 0 { return true }
            if raw & leftCommand != 0 { return false }
            return flags.contains(.maskCommand)
        case 55: // Left Command
            if raw & leftCommand != 0 { return true }
            if raw & rightCommand != 0 { return false }
            return flags.contains(.maskCommand)
        case 61: // Right Option
            if raw & rightOption != 0 { return true }
            if raw & leftOption != 0 { return false }
            return flags.contains(.maskAlternate)
        case 58: // Left Option
            if raw & leftOption != 0 { return true }
            if raw & rightOption != 0 { return false }
            return flags.contains(.maskAlternate)
        case 62: // Right Control
            if raw & rightControl != 0 { return true }
            if raw & leftControl != 0 { return false }
            return flags.contains(.maskControl)
        case 59: // Left Control
            if raw & leftControl != 0 { return true }
            if raw & rightControl != 0 { return false }
            return flags.contains(.maskControl)
        default:
            return false
        }
    }

    private func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
        pressed = false
        modifierKeyCode = nil
    }

    deinit {
        stop()
    }
}

private extension String {
    var fourCharCode: FourCharCode {
        utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }
}
