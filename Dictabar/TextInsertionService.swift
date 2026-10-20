import AppKit
import Foundation

@MainActor
enum TextInsertionService {
    /// Tracks an in-flight paste so cancel can still restore the previous clipboard.
    private static var pendingRestore: ClipboardPasteTransaction?

    private struct AccessibilityTextTarget {
        let element: AXUIElement
        let originalValue: String
        let expectedValue: String
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
            if insertViaAccessibility(output) {
                DiagnosticsLogger.shared.log("insertion: verified accessibility write")
                return
            }
            try await paste(output, restoreClipboard: settings.preserveClipboard)
        case .typing:
            try await type(output)
        }
    }

    /// Call when the dictation pipeline is cancelled so clipboard never leaks the transcript.
    static func restoreClipboardIfNeeded() {
        guard let pending = pendingRestore else { return }
        pendingRestore = nil
        pending.restoreIfOwned()
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Exercises the actual clipboard fallback with harmless test text, without
    /// recording or using provider credentials. Used by the release UI check.
    static func runClipboardSmokeTest(_ text: String) async throws {
        guard PermissionManager.hasAccessibilityAccess() else { throw InsertionError.missingAccessibility }
        try await paste(text, restoreClipboard: true)
    }

    // MARK: - Paste

    /// Paste via ⌘V. When restore is ON:
    /// 1) put transcript on pasteboard
    /// 2) paste
    /// 3) **delete transcript from pasteboard**
    /// 4) put previous clipboard back (or leave empty)
    private static func paste(_ text: String, restoreClipboard: Bool) async throws {
        let pb = NSPasteboard.general
        let target = accessibilityTextTarget(replacingWith: text)
        let transaction: ClipboardPasteTransaction?
        if restoreClipboard {
            // Complex/large clipboard contents cannot be restored losslessly with
            // setData. Insert without touching the clipboard in that case.
            guard let captured = ClipboardPasteTransaction.begin(text: text, pasteboard: pb) else {
                try await type(text)
                return
            }
            transaction = captured
            pendingRestore = captured
        } else {
            transaction = nil
            copy(text)
        }
        defer {
            if let transaction, pendingRestore === transaction {
                transaction.restoreIfOwned()
                pendingRestore = nil
            }
        }
        postCommandV()
        guard let transaction else { return }
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        // Restore on failure too: Copy Last Transcript is an explicit user action
        // when manual insertion is needed, not a reason to leave private text behind.
        if let target, !accessibilityTargetMatches(target) {
            throw InsertionError.pasteNotVerified
        }
        transaction.restoreIfOwned()
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

    // MARK: - Typing

    private static func type(_ text: String) async throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let source else { throw InsertionError.eventSourceUnavailable }
        for string in text.unicodeChunks(maxUTF16Count: 32) {
            try Task.checkCancellation()
            var units = Array(string.utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            await Task.yield()
        }
    }

    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard let element = focusedUIElement() else { return false }
        let target = accessibilityTextTarget(element: element, replacingWith: text)
        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success else { return false }

        guard let target else { return true }
        guard let value = accessibilityValue(of: target.element) else { return true }
        if value == target.expectedValue { return true }
        // A transformed value (smart quotes/autocorrect) means the target changed;
        // do not paste again and duplicate the transcript.
        if value != target.originalValue { return true }
        DiagnosticsLogger.shared.log("insertion: accessibility write was not applied")
        return false
    }

    private static func focusedUIElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success,
        let focused,
        CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    private static func accessibilityTextTarget(
        replacingWith text: String
    ) -> AccessibilityTextTarget? {
        guard let element = focusedUIElement() else { return nil }
        return accessibilityTextTarget(element: element, replacingWith: text)
    }

    private static func accessibilityTextTarget(
        element: AXUIElement,
        replacingWith text: String
    ) -> AccessibilityTextTarget? {
        guard let original = accessibilityValue(of: element) else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
        let rangeRef,
        CFGetTypeID(rangeRef) == AXValueGetTypeID(),
        AXValueGetType(rangeRef as! AXValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range),
              range.location >= 0,
              range.length >= 0 else { return nil }
        let nsOriginal = original as NSString
        guard range.location + range.length <= nsOriginal.length else { return nil }
        let expected = nsOriginal.replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: text
        )
        return AccessibilityTextTarget(
            element: element,
            originalValue: original,
            expectedValue: expected
        )
    }

    private static func accessibilityValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func accessibilityTargetMatches(_ target: AccessibilityTextTarget) -> Bool {
        accessibilityValue(of: target.element) == target.expectedValue
    }
}

/// A private, temporary paste with ownership-aware, lossless restoration.
/// Clipboard historians supporting NSPasteboard.org markers skip these values.
@MainActor
final class ClipboardPasteTransaction {
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let generated = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    static let ownerType = NSPasteboard.PasteboardType("app.dictabar.paste-owner")
    private let pasteboard: NSPasteboard
    private let backup: [NSPasteboard.PasteboardType: Data]
    private let owner: String
    private let changeCount: Int
    private var finished = false

    private init(pasteboard: NSPasteboard, backup: [NSPasteboard.PasteboardType: Data], owner: String) {
        self.pasteboard = pasteboard
        self.backup = backup
        self.owner = owner
        self.changeCount = pasteboard.changeCount
    }

    /// Returns nil before mutation if the complete clipboard cannot be preserved.
    static func begin(text: String, pasteboard pb: NSPasteboard) -> ClipboardPasteTransaction? {
        let before = pb.changeCount
        let items = pb.pasteboardItems ?? []
        guard items.count <= 1 else { return nil }
        var backup: [NSPasteboard.PasteboardType: Data] = [:]
        var bytes = 0
        for type in pb.types ?? [] {
            guard let data = pb.data(forType: type), data.count <= 8_000_000 - bytes else { return nil }
            backup[type] = data
            bytes += data.count
        }
        guard pb.changeCount == before else { return nil }
        let owner = UUID().uuidString
        // Advertise privacy markers before publishing any transcript bytes.
        pb.declareTypes([.string, transient, concealed, generated, ownerType], owner: nil)
        for type in [transient, concealed, generated] {
            pb.setData(Data(), forType: type)
        }
        pb.setString(owner, forType: ownerType)
        guard pb.setString(text, forType: .string) else {
            pb.declareTypes(Array(backup.keys), owner: nil)
            for (type, data) in backup { pb.setData(data, forType: type) }
            return nil
        }
        return ClipboardPasteTransaction(pasteboard: pb, backup: backup, owner: owner)
    }

    func restoreIfOwned() {
        guard !finished else { return }
        finished = true
        // Another copy belongs to the user, even if it has the same text.
        guard pasteboard.changeCount == changeCount,
              pasteboard.string(forType: Self.ownerType) == owner else { return }
        pasteboard.declareTypes(Array(backup.keys), owner: nil)
        for (type, data) in backup { pasteboard.setData(data, forType: type) }
    }
}

private extension String {
    func unicodeChunks(maxUTF16Count: Int) -> [String] {
        var result: [String] = []
        var chunk = ""
        var count = 0
        for scalar in unicodeScalars {
            let value = String(scalar)
            let nextCount = value.utf16.count
            if !chunk.isEmpty, count + nextCount > maxUTF16Count {
                result.append(chunk)
                chunk = ""
                count = 0
            }
            chunk.append(value)
            count += nextCount
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}

enum InsertionError: LocalizedError {
    case missingAccessibility
    case eventSourceUnavailable
    case pasteNotVerified
    var errorDescription: String? {
        switch self {
        case .missingAccessibility: L10n.t("error.accessibility")
        case .eventSourceUnavailable: L10n.t("error.eventSource")
        case .pasteNotVerified: L10n.t("error.pasteNotVerified")
        }
    }
}
