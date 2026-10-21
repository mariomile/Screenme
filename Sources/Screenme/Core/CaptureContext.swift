import AppKit
import ScreenCaptureKit

/// Where a screenshot came from and what the user wrote on it, for Copy for AI: the app, its window,
/// the page when it is a browser, and the notes on annotations.
struct CaptureContext: Equatable {
    var app: String?
    var bundleID: String?
    var window: String?
    var page: String?
    /// One line per annotation note, naming what it points at: "Marker 2: make this bold".
    var notes: [String] = []

    /// The text that goes on the clipboard next to the image.
    func prompt(path: String, pixelSize: CGSize, text: String) -> String {
        var lines = ["Screenshot: \(path) (\(Int(pixelSize.width))×\(Int(pixelSize.height)) px)"]
        if let app { lines.append("App: \(app)") }
        if let window, !window.isEmpty { lines.append("Window: \(window)") }
        if let page { lines.append("Page: \(page)") }
        if !notes.isEmpty {
            lines.append("")
            lines.append("Notes on the screenshot:")
            lines += notes.enumerated().map { "\($0.offset + 1). \($0.element)" }
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            lines.append("")
            lines.append("Text in the screenshot:")
            lines.append("\"\"\"")
            lines.append(text)
            lines.append("\"\"\"")
        }
        return lines.joined(separator: "\n")
    }
}

/// The context of each capture this session, by file. Recorded when the screenshot is taken; the editor adds notes.
@MainActor
enum CaptureContexts {
    private static var contexts: [URL: CaptureContext] = [:]

    static func record(_ target: CaptureTarget, for url: URL) {
        contexts[url] = context(of: target)
    }

    static func setNotes(_ notes: [String], for url: URL) {
        contexts[url, default: CaptureContext()].notes = notes
    }

    static func forget(_ url: URL) {
        contexts[url] = nil
    }

    /// The recorded context, with the browser page looked up now: only when the browser still shows the
    /// captured page, so a tab switched since the capture never lends its address.
    static func context(for url: URL) async -> CaptureContext {
        var context = contexts[url] ?? CaptureContext()
        if let bundleID = context.bundleID, let page = await BrowserPage.current(in: bundleID),
           let window = context.window, !page.title.isEmpty, window.contains(page.title) || page.title.contains(window) {
            context.page = page.url
        }
        return context
    }

    // MARK: Window under the capture

    private static func context(of target: CaptureTarget) -> CaptureContext {
        switch target {
        case .window(let window):
            let app = window.owningApplication
            return CaptureContext(app: app?.applicationName, bundleID: app?.bundleIdentifier, window: window.title)
        case .area(let rect, _):
            // The window under the middle of the area, in top-left coordinates like the window list.
            let flipped = rect.cocoaFlipped
            return frontWindow { $0.contains(CGPoint(x: flipped.midX, y: flipped.midY)) } ?? CaptureContext()
        case .display(let screen):
            let frontPID = FocusKeeper.frontmostExternal()?.processIdentifier
            let bounds = screen.frame.cocoaFlipped
            return frontWindow(of: frontPID) { $0.intersects(bounds) } ?? CaptureContext()
        }
    }

    /// The frontmost normal window of another app, of `pid` when given, whose bounds pass `matches`.
    private static func frontWindow(of pid: pid_t? = nil, where matches: (CGRect) -> Bool) -> CaptureContext? {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        for info in list {
            guard info[kCGWindowLayer] as? Int == 0,
                  let owner = info[kCGWindowOwnerPID] as? pid_t, owner != own, pid == nil || owner == pid,
                  let boundsInfo = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo), matches(bounds) else { continue }
            let app = NSRunningApplication(processIdentifier: owner)
            return CaptureContext(app: app?.localizedName ?? info[kCGWindowOwnerName] as? String,
                                  bundleID: app?.bundleIdentifier, window: info[kCGWindowName] as? String)
        }
        return nil
    }
}

/// The front tab of a browser, read with AppleScript. macOS asks once for permission to control each browser.
enum BrowserPage {
    struct Page { let title: String; let url: String }

    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private static let chromium: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
                                                "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi"]

    static func current(in bundleID: String) async -> Page? {
        let script: String
        if safari.contains(bundleID) {
            script = "tell application id \"\(bundleID)\" to return (name of front document) & linefeed & (URL of front document)"
        } else if chromium.contains(bundleID) {
            script = "tell application id \"\(bundleID)\" to return (title of active tab of front window) & linefeed & (URL of active tab of front window)"
        } else {
            return nil
        }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            // The permission prompt holds osascript until the user answers: Copy for AI does not wait for it.
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate(); return nil }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard process.terminationStatus == 0, parts.count == 2, parts[1].hasPrefix("http") else { return nil }
            return Page(title: parts[0], url: parts[1])
        }.value
    }
}

/// Copy for AI: the image and, as text, where it came from, the notes and the text read from it.
/// Chat apps take the image, and text fields and terminals paste the text.
enum AIClipboard {
    @MainActor
    static func copy(image: CGImage, png: Data, path: URL, captureURL: URL) async {
        let context = await CaptureContexts.context(for: captureURL)
        let text = (try? await TextRecognizer.recognize(image)) ?? ""
        let prompt = context.prompt(path: path.path, pixelSize: CGSize(width: image.width, height: image.height), text: text)
        let entry = NSPasteboardItem()
        entry.setData(png, forType: .png)
        entry.setString(prompt, forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([entry])
    }

    /// Copies a capture file as it is.
    @MainActor
    static func copy(_ item: CaptureItem) async -> Bool {
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        await copy(image: image, png: png, path: item.url, captureURL: item.url)
        return true
    }
}
