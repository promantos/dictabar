import AppKit
import Foundation

@MainActor
enum TextInsertionService {
    /// Tracks an in-flight paste so cancel can still restore the previous clipboard.
    private static var pendingRestore: PendingClipboardRestore?

    private struct PendingClipboardRestore {
        let transcript: String
        let backup: PasteboardBackup
    }

    static func insert(_ text: String, settings: SettingsStore) async throws {
        var output = text
        if settings.addTrailingSpace { output += " " }
        if settings.addTrailingNewline { output += "\n" }

        guard PermissionManager.hasAccessibilityAccess() else {
            if settings.copyOnInsertionFailure {
                copy(output)
            }
            throw InsertionError.missingAccessibility
        }

        switch settings.insertionMethod {
        case .paste:
            try await paste(output, restoreClipboard: settings.preserveClipboard)
        case .typing:
            try type(output)
        }
    }

    /// Call when the dictation pipeline is cancelled so clipboard never leaks the transcript.
    static func restoreClipboardIfNeeded() {
        guard let pending = pendingRestore else { return }
        pendingRestore = nil
        let pb = NSPasteboard.general
        removeTranscriptAndRestore(pb: pb, transcript: pending.transcript, backup: pending.backup, pass: 0)
        DiagnosticsLogger.shared.log("clipboard: restored after cancel")
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Paste

    /// Paste via ⌘V. When restore is ON:
    /// 1) put transcript on pasteboard
    /// 2) paste
    /// 3) **delete transcript from pasteboard**
    /// 4) put previous clipboard back (or leave empty)
    private static func paste(_ text: String, restoreClipboard: Bool) async throws {
        let pb = NSPasteboard.general

        // --- snapshot OLD clipboard (before we touch it) ---
        let backup = PasteboardBackup.capture(from: pb)
        DiagnosticsLogger.shared.log(
            "clipboard: backup types=\(backup.stringValue != nil ? "str" : "-") items=\(backup.items.count) empty=\(backup.isEmpty)"
        )

        // Register restore target BEFORE mutating pasteboard so cancel is safe.
        if restoreClipboard {
            pendingRestore = PendingClipboardRestore(transcript: text, backup: backup)
        }

        // --- put transcript + paste ---
        pb.clearContents()
        pb.setString(text, forType: .string)
        postCommandV()

        guard restoreClipboard else {
            DiagnosticsLogger.shared.log("clipboard: keep transcript on pasteboard")
            return
        }

        // Always restore even if the task is cancelled mid-sleep.
        defer {
            if pendingRestore != nil {
                removeTranscriptAndRestore(pb: pb, transcript: text, backup: backup, pass: 1)
                pendingRestore = nil
            }
        }

        // Give the front app time to read pasteboard for ⌘V.
        // Use non-throwing sleep so CancellationError does not skip defer restore logic incorrectly;
        // defer still runs on cancel, but we also restore immediately after a cancelled wait.
        let slept = await sleepAllowingCancel(milliseconds: 550)
        if !slept {
            // Cancelled during wait — restore now (defer also covers this).
            DiagnosticsLogger.shared.log("clipboard: cancelled during paste wait; restoring")
            return
        }

        // --- CRITICAL: remove transcript, restore old ---
        removeTranscriptAndRestore(pb: pb, transcript: text, backup: backup, pass: 1)
        // Mark first restore done; scrub loop may re-apply if target app re-writes pasteboard.
        // Keep pendingRestore until scrub finishes so cancel mid-scrub still restores.

        // Keep scrubbing for ~2s in case the target app re-writes the pasteboard.
        for pass in 2...6 {
            let ok = await sleepAllowingCancel(milliseconds: 300)
            if !ok {
                DiagnosticsLogger.shared.log("clipboard: cancelled during scrub; restoring")
                removeTranscriptAndRestore(pb: pb, transcript: text, backup: backup, pass: pass)
                pendingRestore = nil
                return
            }
            let current = pb.string(forType: .string) ?? ""
            if current == text || (!text.isEmpty && current == text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                removeTranscriptAndRestore(pb: pb, transcript: text, backup: backup, pass: pass)
            } else if current.contains(text) && text.count > 8 {
                // Partial / combined content — still scrub.
                removeTranscriptAndRestore(pb: pb, transcript: text, backup: backup, pass: pass)
            } else {
                // Do NOT log clipboard contents (may be passwords/tokens).
                DiagnosticsLogger.shared.log(
                    "clipboard: scrub OK after pass \(pass - 1); len=\(current.count)"
                )
                break
            }
        }
        pendingRestore = nil
    }

    /// Sleep that returns false on cancellation instead of throwing.
    private static func sleepAllowingCancel(milliseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
            return true
        } catch {
            return false
        }
    }

    /// Deletes whatever is on the pasteboard (including transcript) and writes backup only.
    private static func removeTranscriptAndRestore(
        pb: NSPasteboard,
        transcript: String,
        backup: PasteboardBackup,
        pass: Int
    ) {
        // 1) Hard wipe — this is the "delete transcript" step.
        pb.clearContents()
        pb.declareTypes([], owner: nil)
        // clearContents again after declareTypes for stubborn pasteboard state
        pb.clearContents()

        // 2) Put ONLY the previous clipboard back.
        if backup.isEmpty {
            // Leave empty — transcript is gone.
            DiagnosticsLogger.shared.log("clipboard: pass \(pass) wiped; left empty")
            return
        }

        backup.restore(to: pb)

        // 3) Verify transcript is not still there.
        if let now = pb.string(forType: .string), now == transcript {
            pb.clearContents()
            pb.declareTypes([], owner: nil)
            // Try string-only restore as last resort.
            if let s = backup.stringValue, s != transcript {
                pb.setString(s, forType: .string)
            }
            DiagnosticsLogger.shared.log("clipboard: pass \(pass) emergency wipe+string restore")
        } else {
            DiagnosticsLogger.shared.log("clipboard: pass \(pass) restored backup")
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Backup

    private struct PasteboardBackup {
        var stringValue: String?
        var items: [[String: Data]]

        var isEmpty: Bool {
            items.isEmpty && (stringValue == nil || stringValue?.isEmpty == true)
        }

        static func capture(from pb: NSPasteboard) -> PasteboardBackup {
            var items: [[String: Data]] = []
            for item in pb.pasteboardItems ?? [] {
                var map: [String: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        map[type.rawValue] = data
                    }
                }
                if !map.isEmpty { items.append(map) }
            }
            let str = pb.string(forType: .string)
            if items.isEmpty, let str, let data = str.data(using: .utf8) {
                items.append([NSPasteboard.PasteboardType.string.rawValue: data])
            }
            return PasteboardBackup(stringValue: str, items: items)
        }

        func restore(to pb: NSPasteboard) {
            // Restore via setString/setData only (historical AppKit crash path avoided).
            // Restore primary string when available; otherwise first item types via setData.
            if let stringValue, !stringValue.isEmpty {
                pb.clearContents()
                pb.setString(stringValue, forType: .string)
                // Also restore non-string types from the first item when present.
                if let first = items.first {
                    for (type, data) in first where type != NSPasteboard.PasteboardType.string.rawValue {
                        _ = pb.setData(data, forType: NSPasteboard.PasteboardType(type))
                    }
                }
                return
            }
            if let first = items.first {
                pb.clearContents()
                var wrote = false
                for (type, data) in first {
                    if pb.setData(data, forType: NSPasteboard.PasteboardType(type)) {
                        wrote = true
                    }
                }
                if wrote { return }
            }
            pb.clearContents()
        }
    }

    // MARK: - Typing

    private static func type(_ text: String) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let source else { throw InsertionError.eventSourceUnavailable }
        for scalar in text.unicodeScalars {
            let string = String(scalar)
            var utf16 = Array(string.utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}

enum InsertionError: LocalizedError {
    case missingAccessibility
    case eventSourceUnavailable
    var errorDescription: String? {
        switch self {
        case .missingAccessibility: L10n.t("error.accessibility")
        case .eventSourceUnavailable: L10n.t("error.eventSource")
        }
    }
}
