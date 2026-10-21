import Foundation

// What each command is for, shown when the pointer rests on it. One line: what it does, then why you would.

extension ShortcutAction {
    var help: String {
        switch self {
        case .allInOne: "Opens a bar with every capture mode, so you can pick one without remembering its shortcut."
        case .captureArea: "Drag to capture part of the screen. Press Space to switch to window capture."
        case .captureWindow: "Click a window to capture just that window, with its shadow if turned on."
        case .captureFullscreen: "Captures the whole screen the pointer is on, right away."
        case .capturePreviousArea: "Captures the same area as your last area capture, without selecting again."
        case .captureText: "Select an area and its text is copied to the clipboard. Reads QR codes too."
        case .translateText: "Select an area: its text is recognized, translated on this Mac and copied."
        case .pickColor: "Click any pixel on screen to copy its color, as HEX or the format chosen in Settings."
        case .measure: "Shows the distance between edges under the pointer; drag to measure a box. Click or ⌘C copies it."
        case .scrollingCapture: "Select an area, then scroll: the pages are stitched into one tall image."
        case .selfTimer: "Select an area; the capture happens after a countdown, so you can open a menu or hover something first."
        case .recordScreen: "Record an area, a window or the screen as a video or a GIF. Press again to stop."
        case .pinLastCapture: "Keeps your last screenshot floating above all windows, as a reference while you work."
        case .openHistory: "Browse, reopen, share or combine everything you captured recently."
        case .toggleDesktopIcons: "Hides the icons on your desktop for clean screenshots. Run it again to show them."
        }
    }

    /// Title, shortcut and what it does, for a tooltip.
    var tooltip: String {
        let shortcut = ShortcutStore.combo(for: self).map { "  \($0.display)" } ?? ""
        return "\(title)\(shortcut)\n\(help)"
    }
}

extension CaptureAction {
    func help(for kind: CaptureItem.Kind) -> String {
        let noun = kind == .image ? "image" : kind == .gif ? "GIF" : "video"
        switch self {
        case .copy: return "Puts the \(noun) on the clipboard, ready to paste into any app."
        case .copyForAI: return "Copies the image with its context for Claude, ChatGPT or Cursor: the app, window and page it came from, your notes on annotations and the text in it." + Self.hidingNote
        case .copyMarkdown: return "Saves the \(noun) to your save folder and copies a Markdown image link to it, for notes and docs."
        case .copyPath: return "Copies the file path of the \(noun), for scripts or the terminal."
        case .save: return "Saves a copy to your save folder (Settings > General)."
        case .saveAs: return "Saves a copy where you choose, with the name you choose."
        case .reveal: return "Shows the file in Finder."
        case .share: return "Sends it with AirDrop, Messages, Mail and more." + (kind == .image ? Self.hidingNote : "")
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
        "\(title(for: kind))\n\(help(for: kind))"
    }
}

extension ToolKind {
    var help: String {
        switch self {
        case .arrow: "Point at something. Drag to draw; bend it from the middle handle."
        case .line: "A straight line, solid or dashed."
        case .rectangle: "Frame an area with an outline or a fill."
        case .ellipse: "Circle something with an outline or a fill."
        case .text: "Click to type a note on the image."
        case .pen: "Draw freehand."
        case .highlighter: "Mark text or an area with a translucent marker."
        case .counter: "Number steps 1, 2, 3 with each click."
        case .pixelate: "Hide private information behind large pixels."
        case .blur: "Hide private information behind a blur."
        case .spotlight: "Dim everything except the area you drag, to draw the eye."
        }
    }
}

extension ToolChoice {
    var help: String {
        switch self {
        case .select: "Select, move, resize and restyle what you drew."
        case .draw(let kind): kind.help
        case .crop: "Trim the image to the part that matters."
        }
    }
}
