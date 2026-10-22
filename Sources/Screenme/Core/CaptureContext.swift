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
        return await run(script, timeout: 1)
    }

    /// Runs osascript without blocking any thread. The permission prompt holds osascript until the user answers:
    /// after `timeout` seconds it is stopped and Copy for AI goes on without the page.
    private static func run(_ script: String, timeout: Double) async -> Page? {
        await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
                guard process.terminationStatus == 0, parts.count == 2, parts[1].hasPrefix("http") else { return answer.give(nil) }
                answer.give(Page(title: parts[0], url: parts[1]))
            }
            do {
                try process.run()
            } catch {
                return answer.give(nil)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
                answer.give(nil)
            }
        }
    }

    /// Resumes the continuation with the first answer, the page or the timeout, and ignores the other.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Page?, Never>?

        init(_ continuation: CheckedContinuation<Page?, Never>) { self.continuation = continuation }

        func give(_ page: Page?) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: page)
        }
    }
}

/// Copy for AI: the image and, as text, where it came from, the notes and the text read from it.
/// Chat apps take the image, and text fields and terminals paste the text.
/// With "Hide sensitive info when sharing" the image and the text are redacted, and the text names a file holding the redacted image.
enum AIClipboard {
    /// Puts the screenshot on the clipboard. Returns how many sensitive items were hidden (0 when the setting is off),
    /// or nil when they could not be checked: nothing is copied then. `unit` is the image's pixels per point.
    @MainActor
    static func copy(image: CGImage, png: Data, path: URL, captureURL: URL, unit: CGFloat) async -> Int? {
        let context = await CaptureContexts.context(for: captureURL)
        var text = (try? await TextRecognizer.recognize(image)) ?? ""
        var image = image, png = png, path = path
        var hidden = 0
        if Prefs[Pref.hideSensitiveWhenSharing] {
            do {
                if let result = try await Redaction.hidingSensitive(in: image, unit: unit),
                   let data = NSBitmapImageRep(cgImage: result.image).representation(using: .png, properties: [:]),
                   let file = Redaction.write(result.image, like: path.deletingPathExtension().appendingPathExtension("png")) {
                    // The editor's unredacted temporary file must not stay behind; a capture file stays.
                    if path != captureURL { try? FileManager.default.removeItem(at: path) }
                    (image, png, path, hidden) = (result.image, data, file, result.count)
                }
            } catch {
                return nil
            }
            let masked = SensitiveInfo.mask(text)
            text = masked.text
            hidden = max(hidden, masked.count)
        }
        let prompt = context.prompt(path: path.path, pixelSize: CGSize(width: image.width, height: image.height), text: text)
        let entry = NSPasteboardItem()
        entry.setData(png, forType: .png)
        entry.setString(prompt, forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([entry])
        return hidden
    }

    /// Copies a capture file as it is. Returns how many items were hidden, or nil when it did not happen.
    @MainActor
    static func copy(_ item: CaptureItem) async -> Int? {
        guard let source = ImageSource.load(url: item.url),
              let png = NSBitmapImageRep(cgImage: source.image).representation(using: .png, properties: [:]) else { return nil }
        return await copy(image: source.image, png: png, path: item.url, captureURL: item.url, unit: source.unit)
    }
}
