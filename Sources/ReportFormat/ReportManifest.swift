import Foundation

/// `report.json`: everything in a report for a program to read, the `screenme` command among them. Times are
/// seconds of the video; positions and crops are points from the top-left corner of the recorded area; files
/// are relative to the report folder.
struct ReportManifest: Codable, Equatable {
    /// What the recording shows and where it was made.
    struct Environment: Codable, Equatable {
        var app: String?
        var window: String?
        var page: String?
        var system: String
        var screen: String?
        var video: String
        var date: String
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
        var tool: String?
        var color: String?
        var box: RecordingEvent.Box?
        /// An arrow's tip.
        var x: Double?
        var y: Double?
        /// The keyframe that owns it.
        var keyframe: Int
    }

    var version = 1
    var title: String
    var environment: Environment
    var duration: Double
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
        return try encoder.encode(self)
    }
}

/// Why a keyframe was cut.
enum KeyframeReason: String, Codable {
    case start, drawing, pin, click, drag, scroll, app, change, cue
}
