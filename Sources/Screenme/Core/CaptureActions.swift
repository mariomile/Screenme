import AppKit
import SwiftUI

/// What the user can do with a finished capture, from Quick Access, History, pins and the editors.
/// Every surface takes its titles, symbols, availability and confirmation toasts from here.
enum CaptureAction: CaseIterable {
    case copy, copyForAI, reportForAI, copyMarkdown, copyPath, save, saveAs, reveal, share, uploadLink, edit, pin, trash

    func title(for kind: CaptureItem.Kind) -> String {
        switch self {
        case .copy: "Copy"
        case .copyForAI: "Copy for AI"
        case .reportForAI: "Report for AI"
        case .copyMarkdown: "Copy as Markdown"
        case .copyPath: "Copy Path"
        case .save: "Save"
        case .saveAs: "Save As…"
        case .reveal: "Show in Finder"
        case .share: "Share…"
        case .uploadLink: "Upload & Copy Link"
        case .edit: kind == .image ? "Annotate" : "Edit Video"
        case .pin: "Pin to Screen"
        case .trash: "Move to Trash"
        }
    }

    /// What it does, shown when the pointer rests on it.
    func help(for kind: CaptureItem.Kind) -> String {
        let noun = kind == .image ? "image" : kind == .gif ? "GIF" : "video"
        switch self {
        case .copy: return "Puts the \(noun) on the clipboard, ready to paste into any app."
        case .copyForAI: return "Copies the image with its context for Claude, ChatGPT or Cursor: the app, window and page it came from, your notes on annotations and the text in it." + Self.hidingNote
        case .reportForAI: return "Turns the recording into a report an AI agent can act on: numbered keyframes with what you said, clicked, pressed and drew on each, a contact sheet of them all, and a prompt. Saved as a folder; the summary and the contact sheet are copied."
        case .copyMarkdown: return "Saves the \(noun) to your save folder and copies a Markdown image link to it, for notes and docs."
        case .copyPath: return "Copies the file path of the \(noun), for scripts or the terminal."
        case .save: return "Saves a copy to your save folder (Settings > General)."
        case .saveAs: return "Saves a copy where you choose, with the name you choose."
        case .reveal: return "Shows the file in Finder."
        case .share: return "Sends it with AirDrop, Messages, Mail and more." + (kind == .image ? Self.hidingNote : "")
        case .uploadLink: return "Uploads the \(noun) to your own S3-compatible bucket (Settings > Upload) and copies a public link." + (kind == .image ? Self.hidingNote : "")
        case .edit: return kind == .image ? "Opens the editor: arrows, text, blur, highlights, crop and backgrounds." : "Opens the video editor: trim, mute, and export as video or GIF."
        case .pin: return "Keeps the image floating above all windows, as a reference while you work."
        case .trash: return "Moves the file to the Trash and removes it from History."
        }
    }

    /// Added to the tooltips of the actions the setting applies to, while it is on.
    private static var hidingNote: String {
        Prefs[Pref.hideSensitiveWhenSharing] ? " Sensitive info and faces are hidden in the copy." : ""
    }

    /// Title and what it does, for a tooltip.
    func tooltip(for kind: CaptureItem.Kind) -> String {
        Tooltip.text(title(for: kind), help(for: kind))
    }

    func symbol(for kind: CaptureItem.Kind) -> String {
        switch self {
        case .copy: "doc.on.doc"
        case .copyForAI: "sparkles"
        case .reportForAI: "doc.text.magnifyingglass"
        case .copyMarkdown: "doc.text"
        case .copyPath: "link"
        case .save: "square.and.arrow.down"
        case .saveAs: "square.and.arrow.down.on.square"
        case .reveal: "folder"
        case .share: "square.and.arrow.up"
        case .uploadLink: "link.icloud"
        case .edit: kind == .image ? "pencil.and.scribble" : "scissors"
        case .pin: "pin"
        case .trash: "trash"
        }
    }

    /// Images open in the annotation editor and videos in the video editor. GIFs have no editor:
    /// AVFoundation cannot read them and the annotation editor would flatten the animation.
    /// Only images pin or go to Copy for AI. A Markdown image link does not play a video. Report for AI needs a recording
    /// with its sound, which a GIF does not have.
    func isAvailable(for kind: CaptureItem.Kind) -> Bool {
        switch self {
        case .copyForAI: kind == .image
        case .reportForAI: kind == .video
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
        case .copyForAI:
            guard let hidden = await AIClipboard.copy(item) else {
                Feedback.failure("Could not copy")
                return false
            }
            confirm(hidden: hidden)
        case .reportForAI:
            guard await AIReporter.make(item) else { return false }
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
        case .share:
            Share.show(item.url)
        case .uploadLink:
            let settings: UploadSettings
            do {
                settings = try UploadSettings.load()
            } catch {
                Feedback.failure(error.localizedDescription, duration: 2.4)
                SettingsWindow.show(tab: .upload)
                return false
            }
            let progress = Toast.progress("Uploading")
            do {
                let shared = try await S3Upload.share(item.url, settings: settings) { value in
                    Task { @MainActor in progress.update(value) }
                }
                progress.finish()
                Clipboard.copyText(shared.link)
                confirm(hidden: shared.hidden)
            } catch {
                progress.finish()
                Feedback.failure(error.localizedDescription, duration: 3.2)
                return false
            }
        case .edit:
            item.kind == .image ? AnnotationEditor.open(item) : VideoEditor.open(item)
        case .pin:
            PinWindow.pin(item)
        case .trash:
            withAnimation(.snappy) { CaptureHistory.shared.trash(item) }
            confirm()
        }
        return true
    }

    /// The one toast for this action, for code that did the work its own way (the editors).
    @MainActor
    func confirm(savedTo url: URL? = nil, hidden: Int = 0) {
        switch self {
        case .copy:
            Toast.show("Copied to clipboard", symbol: "doc.on.doc.fill")
        case .copyForAI:
            Toast.show(hidden > 0 ? "Copied for AI, \(Self.hiddenItems(hidden)) hidden" : "Copied for AI", symbol: "sparkles")
        case .reportForAI:
            Toast.show("Report for AI copied", symbol: "doc.text.magnifyingglass")
        case .copyMarkdown:
            Toast.show("Markdown copied", symbol: "doc.text.fill")
        case .copyPath:
            Toast.show("Path copied", symbol: "link")
        case .save, .saveAs:
            Toast.show("Saved to \(url?.deletingLastPathComponent().lastPathComponent ?? "folder")", symbol: "square.and.arrow.down.fill")
        case .share:
            // The share menu itself confirms; only a redacted copy needs saying.
            if hidden > 0 { Toast.show("Sharing a copy, \(Self.hiddenItems(hidden)) hidden", symbol: "eye.slash.fill") }
        case .uploadLink:
            Toast.show(hidden > 0 ? "Link copied, \(Self.hiddenItems(hidden)) hidden" : "Link copied", symbol: "link.icloud.fill")
        case .trash:
            Toast.show("Moved to Trash", symbol: "trash.fill")
        case .reveal, .edit, .pin:
            break
        }
    }

    /// "1 item", "3 items".
    static func hiddenItems(_ count: Int) -> String {
        "\(count) \(count == 1 ? "item" : "items")"
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
        Feedback.failure("Could not save")
        return false
    }

    // MARK: Menus

    /// AppKit menu items for the `actions` available for `item`, with their symbols and tooltips, in that order.
    /// Share lists the services as a submenu, unless what is shared must be redacted first: then it is a plain item and
    /// `perform(.share)` opens the share menu once the copy is ready. `keys`: ⌘ key equivalents.
    @MainActor
    static func menuItems(_ actions: [CaptureAction], for item: CaptureItem, keys: [CaptureAction: String] = [:],
                          perform: @escaping (CaptureAction) -> Void) -> [NSMenuItem] {
        actions.filter { $0.isAvailable(for: item.kind) }.map { action in
            if action == .share, !Prefs[Pref.hideSensitiveWhenSharing] {
                return NSSharingServicePicker(items: [item.url]).standardShareMenuItem
            }
            let entry = NSMenuItem(title: action.title(for: item.kind), symbol: action.symbol(for: item.kind),
                                   toolTip: action.help(for: item.kind)) { perform(action) }
            if let key = keys[action] {
                entry.keyEquivalent = key
                entry.keyEquivalentModifierMask = .command
            }
            return entry
        }
    }
}

/// Before & After: two screenshots in one image labelled Before and After, from a Quick Access card (with the
/// previous screenshot) or from two selected in History.
enum BeforeAfter {
    static let title = "Before & After"
    static let symbol = "rectangle.split.2x1"
}

extension NSMenuItem {
    /// An item that runs `handler`. The item holds its target, which `target` alone would not keep alive.
    convenience init(title: String, symbol: String, toolTip: String, handler: @escaping () -> Void) {
        let target = MenuHandler(handler)
        self.init(title: title, action: #selector(MenuHandler.run), keyEquivalent: "")
        self.target = target
        representedObject = target
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.toolTip = toolTip
    }
}

private final class MenuHandler: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}
