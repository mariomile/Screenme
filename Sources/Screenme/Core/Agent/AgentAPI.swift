import AppKit

/// What an agent can ask the running app for, over the agent socket (`AgentServer`). The `screenme` tool and its MCP
/// server are the clients: the commands here are theirs, and each answers with plain JSON an agent can read.
/// Work the tool can do without the app (reading captures and reports) stays in the tool.
@MainActor
enum AgentAPI {
    enum Command: String, CaseIterable {
        case status
        case capture
        case recordStart = "record_start"
        case recordStop = "record_stop"
        case makeReport = "make_report"
        case settings
        case setSetting = "set_setting"
        case upload
        case testUpload = "test_upload"
        case recognizeText = "recognize_text"
        case redact
        case searchHistory = "search_history"
        case listWindows = "list_windows"
        case act
    }

    /// The reply to one request, as the socket sends it.
    static func reply(to data: Data) async -> AgentChannel.Reply {
        do {
            let request = try AgentChannel.decodeRequest(data)
            guard let command = Command(rawValue: request.command) else {
                return .error("unknown command \(request.command); Screenme knows \(Command.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return .result(try await run(command, AgentArguments(request.arguments), within: request.timeout))
        } catch {
            return .error(message(for: error))
        }
    }

    /// Runs the command, cancelled 2 s before the tool stops waiting: an upload or a scrolling capture then stops
    /// instead of finishing after the tool gave up, and the tool hears so. Work that does not stop when cancelled
    /// still finishes.
    static func run(_ command: Command, _ arguments: AgentArguments, within timeout: TimeInterval?) async throws -> [String: Any] {
        guard let timeout else { return try await run(command, arguments) }
        let seconds = max(timeout - 2, 1)
        let work = Task { try await run(command, arguments) }
        let deadline = Task {
            try await Task.sleep(for: .seconds(seconds))
            work.cancel()
        }
        defer { deadline.cancel() }
        do {
            return try await work.value
        } catch where work.isCancelled {
            throw AgentError("Screenme stopped \(command.rawValue) after \(Int(seconds)) s, before it finished")
        }
    }

    static func run(_ command: Command, _ arguments: AgentArguments) async throws -> [String: Any] {
        switch command {
        case .status:
            return status()

        case .capture:
            let item = try await CaptureCoordinator.shared.agentScreenshot(try target(arguments),
                                                                           scrolling: try arguments.bool("scrolling") ?? false)
            return ["path": item.url.path]

        case .recordStart:
            try await CaptureCoordinator.shared.agentStartRecording(try target(arguments))
            return ["recording": true]

        case .recordStop:
            let item = try await CaptureCoordinator.shared.agentStopRecording()
            var result: [String: Any] = ["path": item.url.path]
            // The recording is saved by now: a report that fails is reported next to its path, not instead of it.
            if try arguments.bool("report") ?? false {
                do {
                    guard item.kind == .video else { throw AgentError("A Report for AI needs a video; this recording is a \(item.kind.rawValue)") }
                    result.merge(try await report(for: item)) { $1 }
                } catch {
                    result["report_error"] = message(for: error)
                }
            }
            return result

        case .makeReport:
            let item = try capture(at: arguments)
            guard item.kind == .video else { throw AgentError("A Report for AI needs a video recording (MP4), not \(item.url.lastPathComponent)") }
            return try await report(for: item)

        case .settings:
            return ["settings": AgentSetting.all.map(\.listing)]

        case .setSetting:
            guard let key = try arguments.string("key") else { throw AgentError("set_setting needs key") }
            guard let setting = AgentSetting.named(key) else {
                throw AgentError("unknown setting \(key); list them with the settings command")
            }
            guard let value = arguments.value("value") else { throw AgentError("set_setting needs value") }
            return ["key": key, "value": try setting.set(value)]

        case .upload:
            let item = try capture(at: arguments)
            let shared = try await S3Upload.share(item.url, settings: try UploadSettings.load())
            return ["url": shared.link, "hidden": shared.hidden]

        case .testUpload:
            try await S3Upload.test(settings: try UploadSettings.load())
            return ["ok": true]

        case .recognizeText:
            let item = try capture(at: arguments)
            guard item.kind == .image, let image = Thumbnails.decodeImage(at: item.url, maxPixelSize: nil) else {
                throw AgentError("Could not read \(item.url.lastPathComponent) as an image")
            }
            return ["text": try await TextRecognizer.recognize(image)]

        case .redact:
            let item = try capture(at: arguments)
            guard item.kind == .image else { throw AgentError("Only images can be redacted") }
            guard let copy = try await Redaction.redactedCopy(of: item.url) else { return ["path": item.url.path, "hidden": 0] }
            return ["path": copy.url.path, "hidden": copy.count]

        case .searchHistory:
            let query = try arguments.string("query") ?? ""
            let limit = try arguments.integer("limit") ?? 20
            let tokens = HistorySearch.tokens(query)
            let history = CaptureHistory.shared
            let found = history.items.filter { item in
                tokens.isEmpty || HistorySearch.matches(tokens, details: searchText(for: item), imageText: history.recognizedText[item.url])
            }
            return ["results": found.prefix(max(limit, 1)).map { item -> [String: Any] in
                var entry: [String: Any] = ["path": item.url.path, "kind": item.kind.rawValue, "date": item.date.ISO8601Format()]
                if let excerpt = HistorySearch.excerpt(of: history.recognizedText[item.url], matching: tokens) { entry["excerpt"] = excerpt }
                return entry
            }]

        case .listWindows:
            return ["windows": OnScreenWindow.others().map { window -> [String: Any] in
                ["app": window.app ?? "", "title": window.title ?? "",
                 "x": window.bounds.minX, "y": window.bounds.minY, "width": window.bounds.width, "height": window.bounds.height]
            }]

        case .act:
            let item = try capture(at: arguments)
            guard let name = try arguments.string("action"), let action = actions[name] else {
                throw AgentError("act needs action: one of \(actions.keys.sorted().joined(separator: ", "))")
            }
            guard action.isAvailable(for: item.kind) else {
                throw AgentError("\(name) does not apply to a \(item.kind.rawValue)")
            }
            return ["done": await action.perform(item)]
        }
    }

    /// What `act` can do with a capture, by the name an agent uses. Each runs as its button in Quick Access does.
    static let actions: [String: CaptureAction] = [
        "copy": .copy, "copy_for_ai": .copyForAI, "copy_markdown": .copyMarkdown, "save": .save,
        "reveal": .reveal, "edit": .edit, "pin": .pin,
    ]

    // MARK: Helpers

    private static func status() -> [String: Any] {
        [
            "recording": RecordingController.shared.isRecording,
            "permissions": Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0.title, statusName($0.status)) }),
            "captures_folder": ScreenmePaths.captures.path,
            "save_folder": Storage.saveDirectory.path,
            "upload_configured": (try? UploadSettings.load()) != nil,
            "commit": Updater.Source.installed?.commit ?? "",
        ]
    }

    private static func statusName(_ status: Permission.Status) -> String {
        switch status {
        case .granted: "granted"
        case .notDetermined: "not asked yet"
        case .denied: "denied"
        }
    }

    /// The area, window or screen a capture or recording takes. Area: global points, top-left origin.
    private static func target(_ arguments: AgentArguments) throws -> ActionLink.Target? {
        switch try arguments.string("mode") ?? "fullscreen" {
        case "fullscreen":
            return nil
        case "area":
            guard let x = try arguments.number("x"), let y = try arguments.number("y"),
                  let width = try arguments.number("width"), let height = try arguments.number("height"), width > 0, height > 0 else {
                throw AgentError("mode area needs x, y, width and height, with a width and height above 0")
            }
            return .area(CGRect(x: x, y: y, width: width, height: height))
        case "window":
            guard let app = try arguments.string("app"), !app.isEmpty else { throw AgentError("mode window needs app") }
            return .window(app: app)
        case let mode:
            throw AgentError("mode must be fullscreen, area or window, not \(mode)")
        }
    }

    /// The capture at `path`: the History entry when there is one, so the date and context are the capture's.
    private static func capture(at arguments: AgentArguments) throws -> CaptureItem {
        guard let path = try arguments.string("path"), !path.isEmpty else { throw AgentError("path is missing") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw AgentError("No file at \(url.path)") }
        if let item = CaptureHistory.shared.items.first(where: { $0.url.standardizedFileURL == url }) { return item }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "tiff": return CaptureItem(url: url, kind: .image, date: date)
        case "mp4", "mov", "m4v": return CaptureItem(url: url, kind: .video, date: date)
        case "gif": return CaptureItem(url: url, kind: .gif, date: date)
        default: throw AgentError("\(url.lastPathComponent) is not an image, a video or a GIF")
        }
    }

    private static func report(for item: CaptureItem) async throws -> [String: Any] {
        let report = try await AIReporter.create(item)
        return ["report": report.folder.path, "summary": report.summary]
    }

    private static func message(for error: Error) -> String {
        error is LocalizedError ? error.localizedDescription : String(describing: error)
    }
}

/// A failure an agent hears about as a sentence.
struct AgentError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
