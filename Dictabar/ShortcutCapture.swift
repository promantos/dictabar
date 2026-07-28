import Carbon
import SwiftUI

struct ShortcutCapture: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (KeyboardShortcut) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.parent = self
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncMonitoring()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator {
        var parent: ShortcutCapture
        private var monitor: Any?

        init(parent: ShortcutCapture) {
            self.parent = parent
        }

        func syncMonitoring() {
            if parent.isRecording {
                install()
            } else {
                stop()
            }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                let typeRaw = event.type.rawValue
                let keyCode = event.keyCode
                let flagsRaw = event.modifierFlags.rawValue
                let characters = event.charactersIgnoringModifiers ?? ""
                let consumed = MainActor.assumeIsolated {
                    self?.handle(typeRaw: typeRaw, keyCode: keyCode, flagsRaw: flagsRaw, characters: characters) ?? false
                }
                return consumed ? nil : event
            }
        }

        private func handle(
            typeRaw: UInt,
            keyCode: UInt16,
            flagsRaw: UInt,
            characters: String
        ) -> Bool {
            guard parent.isRecording else { return false }
            if typeRaw == NSEvent.EventType.keyDown.rawValue, keyCode == 53 {
                parent.isRecording = false
                return true
            }
            guard typeRaw == NSEvent.EventType.keyDown.rawValue else { return false }
            let flags = NSEvent.ModifierFlags(rawValue: flagsRaw)
            let mods = flags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else { return true }
            let shortcut = KeyboardShortcut(
                keyCode: UInt32(keyCode),
                carbonModifiers: carbonModifiers(from: flags),
                display: display(flags: flags, characters: characters)
            )
            parent.onCapture(shortcut)
            parent.isRecording = false
            return true
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
            var result: UInt32 = 0
            if flags.contains(.command) { result |= UInt32(cmdKey) }
            if flags.contains(.option) { result |= UInt32(optionKey) }
            if flags.contains(.control) { result |= UInt32(controlKey) }
            if flags.contains(.shift) { result |= UInt32(shiftKey) }
            return result
        }

        private func display(flags: NSEvent.ModifierFlags, characters: String) -> String {
            var parts: [String] = []
            if flags.contains(.control) { parts.append("Control") }
            if flags.contains(.option) { parts.append("Option") }
            if flags.contains(.shift) { parts.append("Shift") }
            if flags.contains(.command) { parts.append("Command") }
            let key = characters.uppercased()
            if !key.isEmpty { parts.append(key) }
            return parts.filter { !$0.isEmpty }.joined(separator: "-")
        }
    }
}
