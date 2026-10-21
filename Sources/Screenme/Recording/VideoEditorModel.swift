import AppKit
import AVFoundation
import SwiftUI

enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4 = "MP4"
    case gif = "GIF"

    var id: String { rawValue }
}

@MainActor
final class VideoEditorModel: ObservableObject {
    let item: CaptureItem
    let player = AVPlayer()
    private let asset: AVURLAsset
    private weak var window: NSWindow?
    private var timeObserver: Any?
    private var observers: [NSObjectProtocol] = []
    private var exportTask: Task<Void, Never>?
    private var isScrubbing = false
    private var videoTrackID = kCMPersistentTrackID_Invalid
    private var fps = 30

    @Published private(set) var duration = 0.0
    @Published private(set) var videoSize = CGSize.zero
    @Published private(set) var hasAudio = false
    @Published private(set) var loadFailed = false
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    @Published var currentTime = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var thumbnails: [CGImage?] = Array(repeating: nil, count: 24)

    @Published var format = ExportFormat.mp4 {
        didSet {
            if format == .gif, oldValue != .gif, resolution == .original { resolution = .gif(for: videoSize) }
        }
    }
    @Published var resolution = ExportResolution.original
    @Published var quality = VideoQuality.high
    @Published var gifFPS = 15
    @Published var mute = false {
        didSet { player.isMuted = mute }
    }
    @Published var codec = VideoCodec.h264
    @Published private(set) var exportProgress: Double?
    @Published private(set) var exportTitle = ""

    /// What the editor draws on the recording. Every change redraws the preview; the canvas is remembered for next time.
    @Published var edit = VideoEdit() {
        didSet {
            guard edit != oldValue else { return }
            if edit.canvas != oldValue.canvas { VideoCanvas.saved = edit.canvas }
            if edit.zoomStrength != oldValue.zoomStrength { Prefs[Pref.videoZoomStrength] = edit.zoomStrength }
            updatePreview()
        }
    }
    /// Zooms made from the recording's clicks. Remembered for next time.
    @Published var autoZoom = Prefs[Pref.videoAutoZoom] {
        didSet {
            guard autoZoom != oldValue else { return }
            Prefs[Pref.videoAutoZoom] = autoZoom
            applyAutoZoom()
        }
    }
    @Published var selectedZoom: UUID?
    /// The zoom whose region is being dragged out on the preview.
    @Published private(set) var pickingZoom: UUID? {
        didSet { if pickingZoom != oldValue { updatePreview() } }
    }
    /// The recording's clicks and cursor, when it was recorded with them.
    let events: RecordingEvents?
    private let cursorPath: CursorPath?

    var source: VideoSource { VideoSource(size: videoSize, events: events, cursor: cursorPath) }

    init(item: CaptureItem) {
        self.item = item
        events = RecordingEvents.events(for: item.url)
        cursorPath = VideoSource.cursorPath(of: events)
        asset = AVURLAsset(url: item.url)
        edit.canvas = VideoCanvas.saved
        edit.zoomStrength = min(max(Prefs[Pref.videoZoomStrength], AutoZoom.strengthRange.lowerBound), AutoZoom.strengthRange.upperBound)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        })
        Task { await load() }
    }

    func attach(to window: NSWindow) {
        guard self.window == nil else { return }
        self.window = window
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.teardown() }
        })
    }

    private func teardown() {
        exportTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        player.replaceCurrentItem(with: nil)
    }

    private func load() async {
        do {
            let length = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first, length > 0 else {
                loadFailed = true
                return
            }
            let natural = try await track.load(.naturalSize).applying(track.load(.preferredTransform))
            videoSize = CGSize(width: abs(natural.width), height: abs(natural.height))
            videoTrackID = track.trackID
            let nominal = try await track.load(.nominalFrameRate)
            fps = nominal > 1 ? Int(min(max(nominal, 24), 60).rounded()) : 30
            hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
            duration = length
            trimStart = 0
            trimEnd = length
            applyEnd()
            if autoZoom { applyAutoZoom() }
            updatePreview()
        } catch {
            loadFailed = true
            return
        }
        await loadThumbnails()
    }

    private func loadThumbnails() async {
        let count = thumbnails.count
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 200)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        for await result in generator.images(for: times) {
            guard let image = try? result.image,
                  let index = times.firstIndex(where: { CMTimeCompare($0, result.requestedTime) == 0 }) else { continue }
            thumbnails[index] = image
        }
    }

    // MARK: Playback

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard duration > 0 else { return }
        if currentTime >= trimEnd - 0.05 || currentTime < trimStart { seek(to: trimStart) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to time: Double) {
        let clamped = min(max(time, 0), duration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        pause()
        seek(to: min(max(currentTime + Double(frames) / 30, trimStart), trimEnd))
    }

    /// Moves the playhead inside the selection and holds it there until `endScrub`.
    func scrub(to time: Double) {
        if isPlaying { pause() }
        isScrubbing = true
        seek(to: min(max(time, trimStart), trimEnd))
    }

    func endScrub() {
        isScrubbing = false
    }

    private func tick(_ time: Double) {
        guard !isScrubbing else { return }
        currentTime = time
        if isPlaying, time >= trimEnd - 0.02 { reachedEnd() }
    }

    private func reachedEnd() {
        pause()
        seek(to: trimStart)
    }

    private func applyEnd() {
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
    }

    // MARK: Trimming

    private let minimumClip = 0.2

    func setTrimStart(_ time: Double) {
        trimStart = min(max(time, 0), trimEnd - minimumClip)
        scrub(to: trimStart)
    }

    func setTrimEnd(_ time: Double) {
        trimEnd = max(min(time, duration), trimStart + minimumClip)
        applyEnd()
        scrub(to: max(trimEnd - 0.05, trimStart))
    }

    // MARK: Export

    var outputSize: CGSize { edit.outputSize(for: source, resolution: resolution) }
    var clipDuration: Double { trimEnd - trimStart }

    /// True when the output would be a byte-for-byte copy of the recording.
    private var isUnmodified: Bool {
        format == .mp4 && trimStart <= 0.001 && trimEnd >= duration - 0.001 && resolution == .original
            && (!mute || !hasAudio) && quality == .high && codec == .h264 && edit.isPlain
    }

    enum Action {
        case copy, save, saveAs, done
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// Exports the edit unless nothing changed, then copies, saves or closes. Copy and Save run the shared
    /// capture actions on the result; Save As offers the recording's own name.
    func perform(_ action: Action) {
        guard exportProgress == nil, duration > 0 else { return }
        pause()
        exportTask = Task {
            defer {
                exportProgress = nil
                exportTask = nil
            }
            do {
                switch action {
                case .copy:
                    let output = try await renderOutput(title: "Preparing")
                    await CaptureAction.copy.perform(output)

                case .save:
                    let output = try await renderOutput(title: "Saving")
                    if await CaptureAction.save.perform(output), output.url != item.url {
                        CaptureCoordinator.shared.afterCapture(output)
                    }

                case .saveAs:
                    // Where first, so a cancel costs nothing and a long export is not wasted.
                    let name = item.url.deletingPathExtension().lastPathComponent + (format == .gif ? ".gif" : ".mp4")
                    guard let destination = await Storage.chooseDestination(suggestedName: name) else { return }
                    let output = try await renderOutput(title: "Saving")
                    try Storage.copy(output.url, to: destination)
                    CaptureAction.saveAs.confirm(savedTo: destination)

                case .done:
                    if !isUnmodified {
                        let output = try await renderOutput(title: "Exporting")
                        CaptureCoordinator.shared.afterCapture(output)
                    }
                    window?.close()
                }
            } catch is CancellationError {
                // The user cancelled; nothing to report.
            } catch {
                CaptureCoordinator.shared.report(error)
            }
        }
    }

    /// The recording itself when nothing changed, otherwise a fresh export.
    private func renderOutput(title: String) async throws -> CaptureItem {
        if isUnmodified { return item }
        exportTitle = format == .gif ? "Creating GIF" : title
        exportProgress = 0
        let progress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, let current = self.exportProgress else { return }
                self.exportProgress = max(current, value)
            }
        }
        let range = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                                end: CMTime(seconds: trimEnd, preferredTimescale: 600))
        let renderer = makeRenderer(size: outputSize, timeOffset: trimStart, speed: 1)
        switch format {
        case .mp4:
            let settings = VideoExportSettings(range: range, renderer: renderer, quality: quality, codec: codec, mute: mute)
            let url = try await VideoTranscoder.export(item.url, settings: settings, progress: progress)
            return CaptureItem(url: url, kind: .video)
        case .gif:
            let url = try await GIFExporter.export(item.url, range: range, renderer: renderer, fps: gifFPS, quality: quality,
                                                   progress: progress)
            return CaptureItem(url: url, kind: .gif)
        }
    }

    // MARK: Rendering

    /// The renderer for an output of `size`. Exports start at the trim start; the preview plays the whole recording.
    /// While a zoom's region is being picked, the preview shows the whole video.
    private func makeRenderer(size: CGSize, timeOffset: Double, speed: Double, preview: Bool = false) -> FrameRenderer {
        edit.renderer(for: source, renderSize: size, duration: duration, timeOffset: timeOffset, speed: speed,
                      zoomed: !(preview && pickingZoom != nil))
    }

    /// Where the video shows inside a view of `size` that fits the preview, y-down: for picking a zoom region.
    func videoFrame(in size: CGSize) -> CGRect {
        let preview = previewSize
        let scale = min(size.width / preview.width, size.height / preview.height)
        let shown = CGSize(width: preview.width * scale, height: preview.height * scale)
        let origin = CGPoint(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2)
        let layout = edit.layout(for: source)
        let k = shown.width / layout.canvasSize.width
        let content = layout.contentRect
        return CGRect(x: origin.x + content.minX * k, y: origin.y + content.minY * k, width: content.width * k, height: content.height * k)
    }

    // MARK: Zoom

    /// Whether the recording has clicks to zoom on.
    var hasClicks: Bool { events?.events.contains { $0.kind == .click } == true }

    /// Replaces the automatic zooms with fresh ones from the clicks, or removes them. Zooms added by hand stay.
    private func applyAutoZoom() {
        var zooms = edit.zooms.filter { !$0.isAuto }
        if autoZoom, let events, duration > 0 { zooms += AutoZoom.segments(for: events, duration: duration) }
        edit.zooms = zooms.sorted { $0.start < $1.start }
    }

    func deleteZoom(_ id: UUID) {
        edit.zooms.removeAll { $0.id == id }
        if selectedZoom == id { selectedZoom = nil }
        if pickingZoom == id { pickingZoom = nil }
    }

    /// Removes every zoom and turns Auto zoom off, so none come back.
    func removeAllZooms() {
        pickingZoom = nil
        selectedZoom = nil
        autoZoom = false
        edit.zooms.removeAll()
    }

    /// Moves a zoom to start at `start`, keeping its length, inside the video.
    func moveZoom(_ id: UUID, to start: Double) {
        guard let index = edit.zooms.firstIndex(where: { $0.id == id }) else { return }
        let length = edit.zooms[index].duration
        let clamped = min(max(start, 0), max(duration - length, 0))
        edit.zooms[index].start = clamped
        edit.zooms[index].end = clamped + length
    }

    /// Adds a 3 second zoom at the playhead and asks for its region on the preview.
    func addZoom() {
        guard duration > 0 else { return }
        pause()
        let length = min(3, duration)
        let start = min(max(currentTime, 0), duration - length)
        let zoom = ZoomSegment(start: start, end: start + length, center: CGPoint(x: 0.5, y: 0.5), zoom: edit.zoomStrength, isAuto: false)
        edit.zooms.append(zoom)
        edit.zooms.sort { $0.start < $1.start }
        selectedZoom = zoom.id
        pickingZoom = zoom.id
    }

    /// The region picked on the preview, in unit coordinates of the video: the zoom centers on it and goes in until it fills the view.
    func setZoomRegion(_ rect: CGRect) {
        guard let id = pickingZoom, let index = edit.zooms.firstIndex(where: { $0.id == id }) else { return }
        let side = max(rect.width, rect.height, 0.01)
        let range = AutoZoom.strengthRange
        edit.zooms[index].center = CGPoint(x: rect.midX, y: rect.midY)
        edit.zooms[index].zoom = min(max(1 / side, range.lowerBound), range.upperBound)
        pickingZoom = nil
    }

    func endPicking() {
        pickingZoom = nil
    }

    /// The pixel size of the preview: the full-size output, at most 1920 pixels wide.
    var previewSize: CGSize {
        let full = edit.outputSize(for: source, resolution: .original)
        let scale = min(1, 1920 / max(full.width, full.height, 1))
        return CGSize(width: max(2, (full.width * scale).rounded()), height: max(2, (full.height * scale).rounded()))
    }

    /// The preview draws through the same compositor as the export, so what it shows is what gets exported.
    private func updatePreview() {
        guard let playerItem = player.currentItem, videoTrackID != kCMPersistentTrackID_Invalid else { return }
        playerItem.videoComposition = EditedVideo.videoComposition(renderer: makeRenderer(size: previewSize, timeOffset: 0, speed: 1, preview: true),
                                                                   trackID: videoTrackID, duration: CMTime(seconds: duration, preferredTimescale: 600),
                                                                   fps: fps)
        // A paused player keeps showing the old frame until it seeks.
        if !isPlaying { seek(to: currentTime) }
    }
}
