import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens a recording in the editor: player, trim timeline and export options.
@MainActor
enum VideoEditor {
    static func open(_ item: CaptureItem) {
        let id = "videoEditor-\(item.id.uuidString)"
        let size = CGSize(width: 940, height: 680)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        if WindowPresenter.shared.isOpen(id) {
            WindowPresenter.shared.show(id, title: item.url.lastPathComponent, size: size, style: style) { EmptyView() }
            return
        }
        let model = VideoEditorModel(item: item)
        let window = WindowPresenter.shared.show(id, title: item.url.lastPathComponent, size: size, style: style) {
            VideoEditorView(model: model)
        }
        window.minSize = CGSize(width: 780, height: 560)
        model.attach(to: window)
    }
}

// MARK: - Options

enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4 = "MP4"
    case gif = "GIF"

    var id: String { rawValue }
}

enum ExportQuality: String, CaseIterable, Identifiable {
    case high, medium, low

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var gifColors: Int {
        switch self {
        case .high: 255
        case .medium: 128
        case .low: 64
        }
    }
    var gifDither: Bool { self == .high }
}

// MARK: - Model

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
            // GIFs at full size are huge: start from 720p when the source is large.
            if format == .gif, oldValue != .gif, resolution == .original, videoSize.width > 1280 { resolution = .p720 }
        }
    }
    @Published var resolution = ExportResolution.original
    @Published var quality = ExportQuality.high
    @Published var gifFPS = 15
    @Published var mute = false {
        didSet { player.isMuted = mute }
    }
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
            hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
            duration = length
            trimStart = 0
            trimEnd = length
            applyEnd()
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
        scrubHandle(to: trimStart)
    }

    func setTrimEnd(_ time: Double) {
        trimEnd = max(min(time, duration), trimStart + minimumClip)
        applyEnd()
        scrubHandle(to: max(trimEnd - 0.05, trimStart))
    }

    private func scrubHandle(to time: Double) {
        if isPlaying { pause() }
        isScrubbing = true
        seek(to: time)
    }

    // MARK: Export

    var outputSize: CGSize { resolution.outputSize(for: videoSize) }
    var clipDuration: Double { trimEnd - trimStart }

    /// True when the output would be a byte-for-byte copy of the recording.
    private var isUnmodified: Bool {
        format == .mp4 && trimStart <= 0.001 && trimEnd >= duration - 0.001 && resolution == .original
            && (!mute || !hasAudio) && quality == .high
    }

    private enum Action {
        case copy, save, saveAs, done
    }

    func copy() { perform(.copy) }
    func save() { perform(.save) }
    func saveAs() { perform(.saveAs) }
    func done() { perform(.done) }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func perform(_ action: Action) {
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
                    EditorClipboard.copy(output)
                    Toast.show("Copied", symbol: "doc.on.doc.fill")

                case .save:
                    let output = try await renderOutput(title: "Saving")
                    let saved = try Storage.save(output.url)
                    if output.url != item.url { CaptureCoordinator.shared.afterCapture(output) }
                    Toast.show("Saved to \(saved.deletingLastPathComponent().lastPathComponent)", symbol: "square.and.arrow.down.fill")

                case .saveAs:
                    guard let destination = chooseDestination() else { return }
                    let output = try await renderOutput(title: "Saving")
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.copyItem(at: output.url, to: destination)
                    NSWorkspace.shared.activateFileViewerSelecting([destination])

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
        switch format {
        case .mp4:
            let url = try await VideoTranscoder.export(item.url, settings: VideoExportSettings(range: range, size: outputSize,
                                                                                               quality: quality.rawValue, mute: mute),
                                                       progress: progress)
            return CaptureItem(url: url, kind: .video)
        case .gif:
            let url = try await GIFExporter.export(item.url, range: range, fps: Double(gifFPS), outputSize: outputSize,
                                                   colors: quality.gifColors, dither: quality.gifDither, progress: progress)
            return CaptureItem(url: url, kind: .image)
        }
    }

    private func chooseDestination() -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = Storage.saveDirectory
        panel.allowedContentTypes = [format == .gif ? .gif : .mpeg4Movie]
        panel.nameFieldStringValue = item.url.deletingPathExtension().lastPathComponent + (format == .gif ? ".gif" : ".mp4")
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum EditorClipboard {
    /// Puts the file on the pasteboard. GIFs also carry their data so chat apps animate them.
    static func copy(_ item: CaptureItem) {
        let board = NSPasteboard.general
        board.clearContents()
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.url.absoluteString, forType: .fileURL)
        if item.url.pathExtension.lowercased() == "gif", let data = try? Data(contentsOf: item.url) {
            pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        }
        board.writeObjects([pasteboardItem])
    }
}

// MARK: - View

private struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                player
                    .padding(.horizontal, 20)
                    .padding(.top, 36)
                transport
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                TrimTimeline(model: model)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                Divider().padding(.top, 14)
                options
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                Divider()
                actions
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .disabled(model.exportProgress != nil)

            if let progress = model.exportProgress {
                exportOverlay(progress)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.exportProgress == nil)
        .background(keyboardShortcuts)
        .frame(minWidth: 780, minHeight: 560)
    }

    private var player: some View {
        ZStack {
            Color.black
            if model.loadFailed {
                Text("This recording could not be opened.")
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                PlayerSurface(player: model.player)
                    .contentShape(Rectangle())
                    .onTapGesture { model.togglePlay() }
                if !model.isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.isPlaying)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Play / Pause (Space)")

            Text("\(Self.time(model.currentTime))  /  \(Self.time(model.duration))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Text("Selected \(Self.time(model.clipDuration))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var options: some View {
        HStack(alignment: .bottom, spacing: 16) {
            labeled("Format") {
                Picker("Format", selection: $model.format) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }
            labeled("Size") {
                Picker("Size", selection: $model.resolution) {
                    ForEach(ExportResolution.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
            }
            labeled("Quality") {
                Picker("Quality", selection: $model.quality) {
                    ForEach(ExportQuality.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            if model.format == .gif {
                labeled("Frame rate") {
                    Picker("Frame rate", selection: $model.gifFPS) {
                        ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
            }
            if model.hasAudio && model.format == .mp4 {
                labeled("Audio") {
                    Toggle(isOn: Binding(get: { !model.mute }, set: { model.mute = !$0 })) {
                        Label(model.mute ? "Muted" : "Sound", systemImage: model.mute ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .toggleStyle(.button)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))")
                Text(model.format == .gif ? "\(model.gifFPS) fps, loops" : "H.264")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Copy") { model.copy() }
            Button("Save") { model.save() }
            Button("Save As…") { model.saveAs() }
            Button("Done") { model.done() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private func exportOverlay(_ progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 12) {
                Text(model.exportTitle).font(.system(size: 13, weight: .semibold))
                ProgressView(value: progress).frame(width: 220)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.cancelExport() }
                    .controlSize(.small)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 20, y: 6)
        }
    }

    /// Space plays and pauses; the arrow keys step one frame.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { model.step(frames: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.step(frames: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    static func time(_ seconds: Double) -> String {
        let value = max(seconds, 0)
        let minutes = Int(value) / 60
        let secs = Int(value) % 60
        let tenths = Int((value - Double(Int(value))) * 10)
        return String(format: "%d:%02d.%d", minutes, secs, tenths)
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

// MARK: - Timeline

private struct TrimTimeline: View {
    @ObservedObject var model: VideoEditorModel
    private let handleWidth: CGFloat = 14
    private let height: CGFloat = 58

    var body: some View {
        GeometryReader { geometry in
            let inner = max(geometry.size.width - handleWidth * 2, 1)
            let duration = max(model.duration, 0.001)
            let x = { (time: Double) -> CGFloat in handleWidth + CGFloat(time / duration) * inner }
            let time = { (position: CGFloat) -> Double in Double((position - handleWidth) / inner) * duration }

            ZStack(alignment: .topLeading) {
                filmstrip(width: inner)
                    .offset(x: handleWidth)

                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(x(model.trimStart) - handleWidth, 0), height: height)
                    .offset(x: handleWidth)
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(handleWidth + inner - x(model.trimEnd), 0), height: height)
                    .offset(x: x(model.trimEnd))

                Rectangle()
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(x(model.trimEnd) - x(model.trimStart), 0), height: height)
                    .offset(x: x(model.trimStart))
                    .allowsHitTesting(false)

                handle(leading: true)
                    .offset(x: x(model.trimStart) - handleWidth)
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
                        model.setTrimStart(time(value.location.x + handleWidth / 2))
                    }.onEnded { _ in model.endScrub() })
                handle(leading: false)
                    .offset(x: x(model.trimEnd))
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
                        model.setTrimEnd(time(value.location.x - handleWidth / 2))
                    }.onEnded { _ in model.endScrub() })

                playhead
                    .offset(x: x(min(max(model.currentTime, model.trimStart), model.trimEnd)) - 1)
                    .allowsHitTesting(false)
            }
            .frame(height: height, alignment: .top)
            .padding(.top, 8)
            .coordinateSpace(name: "strip")
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
                model.scrub(to: time(value.location.x))
            }.onEnded { _ in model.endScrub() })
        }
        .frame(height: height + 8)
    }

    private func filmstrip(width: CGFloat) -> some View {
        let aspect = model.videoSize.height > 0 ? model.videoSize.width / model.videoSize.height : 1.6
        let count = max(Int((width / max(height * aspect, 20)).rounded(.up)), 1)
        let total = model.thumbnails.count
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let source = min(Int((Double(index) + 0.5) / Double(count) * Double(total)), total - 1)
                ZStack {
                    Color.primary.opacity(0.08)
                    if let image = model.thumbnails[source] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: width / CGFloat(count), height: height)
                .clipped()
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func handle(leading: Bool) -> some View {
        ZStack {
            UnevenRoundedRectangle(topLeadingRadius: leading ? 6 : 0, bottomLeadingRadius: leading ? 6 : 0,
                                   bottomTrailingRadius: leading ? 0 : 6, topTrailingRadius: leading ? 0 : 6)
                .fill(Color.yellow)
            Capsule().fill(.black.opacity(0.55)).frame(width: 2.5, height: 20)
        }
        .frame(width: handleWidth, height: height)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
    }

    private var playhead: some View {
        VStack(spacing: 0) {
            Circle().fill(.white).frame(width: 9, height: 9)
                .shadow(color: .black.opacity(0.4), radius: 1.5)
            Rectangle().fill(.white).frame(width: 2, height: height - 1)
                .shadow(color: .black.opacity(0.4), radius: 1.5)
        }
        .frame(width: 9)
        .offset(x: -3.5, y: -4)
    }
}
