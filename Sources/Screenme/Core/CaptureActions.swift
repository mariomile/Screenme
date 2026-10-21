import AppKit
import SwiftUI

/// What the user can do with a finished capture, from Quick Access, History, pins and the editors.
/// Every surface takes its titles, symbols, availability and confirmation toasts from here.
enum CaptureAction: CaseIterable {
    case copy, copyMarkdown, copyPath, save, saveAs, reveal, edit, pin, trash

    func title(for kind: CaptureItem.Kind) -> String {
        switch self {
        case .copy: "Copy"
        case .copyMarkdown: "Copy as Markdown"
        case .copyPath: "Copy Path"
        case .save: "Save"
        case .saveAs: "Save As…"
        case .reveal: "Show in Finder"
        case .edit: kind == .image ? "Annotate" : "Edit Video"
        case .pin: "Pin to Screen"
        case .trash: "Move to Trash"
        }
    }

    func symbol(for kind: CaptureItem.Kind) -> String {
        switch self {
        case .copy: "doc.on.doc"
        case .copyMarkdown: "doc.text"
        case .copyPath: "link"
        case .save: "square.and.arrow.down"
        case .saveAs: "square.and.arrow.down.on.square"
        case .reveal: "folder"
        case .edit: kind == .image ? "pencil.and.scribble" : "scissors"
        case .pin: "pin"
        case .trash: "trash"
        }
    }

    /// Images open in the annotation editor and videos in the video editor. GIFs have no editor:
    /// AVFoundation cannot read them and the annotation editor would flatten the animation.
    /// Only images pin. A Markdown image link does not play a video.
    func isAvailable(for kind: CaptureItem.Kind) -> Bool {
        switch self {
        case .copyMarkdown: kind != .video
        case .edit: kind != .gif
        case .pin: kind == .image
        default: true
        }
    }

    /// Runs the action and confirms it. Returns false when it did not happen (cancelled, failed, unavailable).
    @MainActor @discardableResult
    func perform(_ item: CaptureItem) async -> Bool {
        guard isAvailable(for: item.kind) else { return false }
        switch self {
        case .copy:
            Clipboard.copy(item)
            confirm()
        case .copyMarkdown:
            // The link points at the copy in the save folder: the capture itself may be pruned from History.
            guard let saved = Storage.savedCopy(of: item.url) ?? (try? Storage.save(item.url)) else { return failed() }
            Clipboard.copyText(Self.markdownImage(for: saved))
            confirm()
        case .copyPath:
            Clipboard.copyText((Storage.savedCopy(of: item.url) ?? item.url).path)
            confirm()
        case .save:
            guard let saved = try? Storage.save(item.url) else { return failed() }
            confirm(savedTo: saved)
        case .saveAs:
            do {
                guard let saved = try await Storage.saveAs(item.url, suggestedName: item.url.lastPathComponent) else { return false }
                confirm(savedTo: saved)
            } catch {
                return failed()
            }
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        case .edit:
            item.kind == .image ? AnnotationEditor.open(item) : VideoEditor.open(item)
        case .pin:
            PinWindow.pin(item)
        case .trash:
            withAnimation(.snappy) { CaptureHistory.shared.trash(item) }
            CaptureCoordinator.shared.forget(item)
            confirm()
        }
        return true
    }

    /// The one toast for this action, for code that did the work its own way (the editors).
    @MainActor
    func confirm(savedTo url: URL? = nil) {
        switch self {
        case .copy:
            Toast.show("Copied to clipboard", symbol: "doc.on.doc.fill")
        case .copyMarkdown:
            Toast.show("Markdown copied", symbol: "doc.text.fill")
        case .copyPath:
            Toast.show("Path copied", symbol: "link")
        case .save, .saveAs:
            Toast.show("Saved to \(url?.deletingLastPathComponent().lastPathComponent ?? "folder")", symbol: "square.and.arrow.down.fill")
        case .trash:
            Toast.show("Moved to Trash", symbol: "trash.fill")
        case .reveal, .edit, .pin:
            break
        }
    }

    /// `![name](path)`: the file name without its extension, and the path percent-encoded so spaces and
    /// parentheses cannot end the link early.
    static func markdownImage(for url: URL) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()")
        let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.path
        return "![\(url.deletingPathExtension().lastPathComponent)](\(path))"
    }

    @MainActor
    private func failed() -> Bool {
        Toast.show("Could not save", symbol: "exclamationmark.triangle.fill")
        return false
    }
}
