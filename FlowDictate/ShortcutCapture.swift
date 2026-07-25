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

    final class Coordinator {
        var parent: ShortcutCapture
        private var monitor: Any?

        init(parent: ShortcutCapture) {
            self.parent = parent
        }

        deinit {
            stop()
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
                guard let self, parent.isRecording else { return event }

                // Escape aborts capture without saving.
                if event.type == .keyDown, event.keyCode == 53 {
                    parent.isRecording = false
                    return nil
                }

                guard event.type == .keyDown else { return event }

                // Bare keys (no modifier) are almost always accidental while capturing.
                let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard !mods.isEmpty else { return nil }

                let shortcut = KeyboardShortcut(
                    keyCode: UInt32(event.keyCode),
                    carbonModifiers: carbonModifiers(from: event.modifierFlags),
                    display: display(for: event)
                )
                parent.onCapture(shortcut)
                parent.isRecording = false
                return nil
            }
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

        private func display(for event: NSEvent) -> String {
            var parts: [String] = []
            if event.modifierFlags.contains(.control) { parts.append("Control") }
            if event.modifierFlags.contains(.option) { parts.append("Option") }
            if event.modifierFlags.contains(.shift) { parts.append("Shift") }
            if event.modifierFlags.contains(.command) { parts.append("Command") }
            let key = (event.charactersIgnoringModifiers ?? "").uppercased()
            if !key.isEmpty { parts.append(key) }
            return parts.filter { !$0.isEmpty }.joined(separator: "-")
        }
    }
}
