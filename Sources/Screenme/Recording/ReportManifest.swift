import Foundation

/// `report.json`: everything in a report for a program to read, the `screenme` command among them. Times are
/// seconds of the video; positions and crops are points from the top-left corner of the recorded area; files
/// are relative to the report folder.
struct ReportManifest: Codable, Equatable {
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
        var reason: Keyframe.Reason
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
    var environment: AIReport.Environment
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

extension AIReport {
    var manifest: ReportManifest {
        let recorded = events?.events ?? []
        let texts = eventTexts
        func owner(_ event: Int) -> Int {
            (keyframes.firstIndex { $0.events.contains(event) } ?? 0) + 1
        }
        let entries = keyframes.enumerated().map { index, keyframe in
            ReportManifest.KeyframeEntry(
                number: index + 1, time: keyframe.time, moment: keyframe.moment, reason: keyframe.reason,
                file: Self.frameName(index), fullFile: isCropped ? Self.fullFrameName(index) : nil,
                crop: crops.indices.contains(index) ? crops[index].map {
                    ReportManifest.Crop(rect: ReportManifest.Rect(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height),
                                        apps: $0.apps)
                } : nil,
                text: keyframe.text,
                events: keyframe.events.map { ReportManifest.KeyframeEvent(index: $0, time: recorded[$0].time, kind: recorded[$0].kind, text: texts[$0]) })
        }
        let marks = marks.map { mark in
            let event = recorded[mark.event]
            return ReportManifest.Mark(number: mark.number, time: event.time, kind: event.kind, tool: event.tool, color: event.color,
                                       box: event.box, x: event.x, y: event.y, keyframe: owner(mark.event))
        }
        func segments(_ list: [TranscriptSegment]) -> [ReportManifest.Segment] {
            list.map { ReportManifest.Segment(start: $0.start, end: $0.end, text: $0.text) }
        }
        return ReportManifest(
            title: title, environment: environment, duration: duration,
            area: events.map { ReportManifest.Size(width: $0.width, height: $0.height) },
            video: Self.videoName, summary: Self.summaryName, contactSheet: Self.contactSheetName,
            contactSheetFull: isCropped ? Self.fullContactSheetName : nil,
            croppedTo: isCropped ? AutoCrop.appNames(crops) : nil,
            keyframes: entries,
            transcript: ReportManifest.Transcript(segments: segments(transcript.segments), words: segments(transcript.words),
                                                  noNarration: transcript.segments.isEmpty ? noNarration : nil),
            marks: marks, events: recorded, windows: events?.windows)
    }
}
