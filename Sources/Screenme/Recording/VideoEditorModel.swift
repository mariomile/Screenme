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

    init(item: CaptureItem) {
        self.item = item
        asset = AVURLAsset(url: item.url)
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

    var outputSize: CGSize { resolution.outputSize(for: videoSize) }
    var clipDuration: Double { trimEnd - trimStart }

    /// True when the output would be a byte-for-byte copy of the recording.
    private var isUnmodified: Bool {
        format == .mp4 && trimStart <= 0.001 && trimEnd >= duration - 0.001 && resolution == .original
            && (!mute || !hasAudio) && quality == .high && codec == .h264
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
    private func makeRenderer(size: CGSize, timeOffset: Double, speed: Double) -> FrameRenderer {
        FrameRenderer(renderSize: size, timeOffset: timeOffset, speed: speed)
    }

    /// The preview draws through the same compositor as the export, at a size a window shows: at most 1920 pixels wide.
    private func updatePreview() {
        guard let playerItem = player.currentItem, videoTrackID != kCMPersistentTrackID_Invalid else { return }
        let full = outputSize
        let scale = min(1, 1920 / max(full.width, full.height, 1))
        let size = CGSize(width: max(2, (full.width * scale).rounded()), height: max(2, (full.height * scale).rounded()))
        playerItem.videoComposition = EditedVideo.videoComposition(renderer: makeRenderer(size: size, timeOffset: 0, speed: 1),
                                                                   trackID: videoTrackID, duration: CMTime(seconds: duration, preferredTimescale: 600),
                                                                   fps: fps)
    }
}
