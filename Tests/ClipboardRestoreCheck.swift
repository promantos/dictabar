import AppKit
import Foundation

@MainActor final class SettingsStore {
    var addTrailingSpace = false
    var addTrailingNewline = false
    var copyOnInsertionFailure = false
    var insertionMethod = InsertionMethod.paste
    var preserveClipboard = true
}
enum InsertionMethod { case paste, typing }
enum PermissionManager { static func hasAccessibilityAccess() -> Bool { true } }
final class DiagnosticsLogger { static let shared = DiagnosticsLogger(); func log(_ text: String) {} }
enum L10n { static func t(_ key: String) -> String { key } }

@main enum ClipboardRestoreCheck {
    @MainActor static func main() {
        let pb = NSPasteboard(name: .init("app.dictabar.test.\(UUID())"))
        defer { pb.releaseGlobally() }
        pb.declareTypes([.string, .rtf], owner: nil)
        pb.setString("previous", forType: .string)
        let rich = Data("{\\rtf1 original}".utf8)
        pb.setData(rich, forType: .rtf)
        let paste = ClipboardPasteTransaction.begin(text: "private dictation", pasteboard: pb)!
        precondition(pb.string(forType: .string) == "private dictation")
        for type in [ClipboardPasteTransaction.transient, ClipboardPasteTransaction.concealed, ClipboardPasteTransaction.generated] {
            precondition(pb.types?.contains(type) == true)
        }
        // Same filter used by compatible clipboard historians, e.g. Maccy.
        precondition(!Set(pb.types ?? []).isDisjoint(with: [ClipboardPasteTransaction.transient, ClipboardPasteTransaction.concealed, ClipboardPasteTransaction.generated]))
        paste.restoreIfOwned()
        precondition(pb.string(forType: .string) == "previous")
        precondition(pb.data(forType: .rtf) == rich)
        precondition(pb.types?.contains(ClipboardPasteTransaction.ownerType) == false)
        // A copy during the paste wait wins; even identical transcript text is new ownership.
        let changed = ClipboardPasteTransaction.begin(text: "same text", pasteboard: pb)!
        pb.clearContents(); pb.setString("same text", forType: .string)
        changed.restoreIfOwned()
        precondition(pb.string(forType: .string) == "same text")
        // A delayed callback from an older paste cannot restore over a newer paste.
        let old = ClipboardPasteTransaction.begin(text: "old", pasteboard: pb)!
        old.restoreIfOwned()
        let newer = ClipboardPasteTransaction.begin(text: "new", pasteboard: pb)!
        old.restoreIfOwned()
        precondition(pb.string(forType: .string) == "new")
        newer.restoreIfOwned()
        precondition(pb.string(forType: .string) == "same text")
        // Too-large data is left intact rather than silently dropping it during backup.
        pb.declareTypes([.png], owner: nil)
        let image = Data(repeating: 7, count: 8_000_001)
        pb.setData(image, forType: .png)
        let count = pb.changeCount
        precondition(ClipboardPasteTransaction.begin(text: "skip", pasteboard: pb) == nil)
        precondition(pb.changeCount == count && pb.data(forType: .png) == image)
        // Multiple items likewise never enter the destructive fallback path.
        let a = NSPasteboardItem(); a.setString("one", forType: .string)
        let b = NSPasteboardItem(); b.setString("two", forType: .string)
        pb.clearContents(); pb.writeObjects([a, b])
        precondition(ClipboardPasteTransaction.begin(text: "skip", pasteboard: pb) == nil)
        precondition(pb.pasteboardItems?.count == 2)
        pb.clearContents()
        let empty = ClipboardPasteTransaction.begin(text: "temporary", pasteboard: pb)!
        empty.restoreIfOwned()
        precondition(pb.types?.isEmpty != false && pb.string(forType: .string) == nil)
        print("Clipboard restoration/privacy: rich data, markers, external copy, stale callback, large/multi-item and empty cases OK")
    }
}
