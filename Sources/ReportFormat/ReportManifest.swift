import Foundation

/// `report.json`: everything in a report for a program to read, the `screenme` command among them. Times are
/// seconds of the video; positions and crops are points from the top-left corner of the recorded area; files
/// are relative to the report folder.
struct ReportManifest: Codable, Equatable {
    /// What the recording shows and where it was made.
    struct Environment: Codable, Equatable {
        /// The main screen in points, and its scale (2 on a Retina screen).
        struct Screen: Codable, Equatable {
            var width: Double
            var height: Double
            var scale: Double
        }

        /// The video in pixels, and its length in seconds.
        struct Video: Codable, Equatable {
            var width: Int
            var height: Int
            var duration: Double
        }

        var app: String?
        var window: String?
        var page: String?
        /// The macOS version, "26.0.1".
        var system: String
        var screen: Screen?
        var video: Video
        /// When the recording was made, ISO 8601 in the file.
        var date: Date
    }

    struct Size: Codable, Equatable {
        var width: Double
        var height: Double
    }

    struct Rect: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    struct Crop: Codable, Equatable {
        var rect: Rect
        var apps: [String]
    }

    /// An event of a keyframe, with its line from the summary.
    struct KeyframeEvent: Codable, Equatable {
        /// Index into `events`.
        var index: Int
        var time: Double
        var kind: RecordingEvent.Kind
        var text: String
    }

    struct KeyframeEntry: Codable, Equatable {
        var number: Int
        var time: Double
        var moment: Double
        var reason: KeyframeReason
        var file: String
        var fullFile: String?
        var crop: Crop?
        /// What was said while it was on screen.
        var text: String
        var events: [KeyframeEvent]
    }

    struct Segment: Codable, Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    struct Transcript: Codable, Equatable {
        var segments: [Segment]
        var words: [Segment]
        /// Why there is no narration, when there is none.
        var noNarration: String?
    }

    /// A drawing, numbered as in the summary ("mark 2").
    struct Mark: Codable, Equatable {
        var number: Int
        var time: Double
        var kind: RecordingEvent.Kind
        var tool: LiveDrawTool
        var color: LiveDrawColor
        var box: RecordingEvent.Box
        /// An arrow's tip.
        var x: Double?
        var y: Double?
        /// The keyframe that owns it.
        var keyframe: Int
    }

    /// The version this Screenme writes and reads. Reports of an older version are made again, not converted.
    static let currentVersion = 2

    var version = currentVersion
    var title: String
    var environment: Environment
    /// The recorded area in points, when the recording has events.
    var area: Size?
    var video: String
    var summary: String
    var contactSheet: String
    var contactSheetFull: String?
    var croppedTo: String?
    var keyframes: [KeyframeEntry]
    var transcript: Transcript
    var marks: [Mark]
    var events: [RecordingEvent]
    /// The windows over the area through the recording (display and area recordings).
    var windows: [WindowSnapshot]?

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Reads `report.json`.
    static func decode(_ data: Data) throws -> ReportManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReportManifest.self, from: data)
    }
}

/// Why a keyframe was cut.
enum KeyframeReason: String, Codable {
    case start, drawing, pin, click, drag, scroll, app, change, cue
}
