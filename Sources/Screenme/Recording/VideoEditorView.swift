import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Opens a recording in the editor: player, trim timeline and export options.
@MainActor
enum VideoEditor {
    static func open(_ item: CaptureItem) {
        let id = "videoEditor-\(item.id.uuidString)"
        if WindowPresenter.shared.focus(id) { return }
        let model = VideoEditorModel(item: item)
        let window = WindowPresenter.shared.show(id, title: item.url.lastPathComponent, size: CGSize(width: 960, height: 780),
                                                 style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]) {
            VideoEditorView(model: model)
        }
        window.minSize = CGSize(width: 820, height: 660)
        model.attach(to: window)
    }
}

struct VideoEditorView: View {
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
                VideoInspector(model: model)
                Divider()
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
        .frame(minWidth: 820, minHeight: 660)
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
                if model.pickingZoom != nil {
                    ZoomRegionPicker(model: model)
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
            .help("Play / Pause (Space)\nPlays the part between the trim handles.")

            Text("\(Duration.format(model.currentTime, tenths: true))  /  \(Duration.format(model.duration, tenths: true))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Text("Selected \(Duration.format(model.clipDuration, tenths: true))")
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
                .help("Format\nMP4 keeps full quality and sound. GIF loops silently and plays anywhere, even in chats.")
            }
            if model.format == .mp4 {
                labeled("Codec") {
                    Picker("Codec", selection: $model.codec) {
                        ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                    .help("Codec\nH.264 plays everywhere. HEVC makes a file about a third smaller at the same look, for Apple devices and recent browsers.")
                }
                labeled("Size") {
                    Picker("Size", selection: $model.resolution) {
                        ForEach(ExportResolution.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .help("Size\nSmaller sizes make lighter files, good for chats and email.")
                }
            } else {
                labeled("Max width") {
                    Picker("Max width", selection: $model.gifMaxWidth) {
                        Text("Original").tag(0)
                        ForEach([1280, 1024, 800, 640, 480], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .help("Max width\nThe widest the GIF gets. Narrower GIFs are much lighter.")
                }
                labeled("Frame rate") {
                    Picker("Frame rate", selection: $model.gifFPS) {
                        ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    .help("Frame rate\nMore frames move more smoothly; fewer make a lighter GIF.")
                }
            }
            labeled("Quality") {
                Picker("Quality", selection: $model.quality) {
                    ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                .help(model.format == .gif
                      ? "Quality\nHigh uses 256 colors with dithering; Medium and Low use fewer colors for a lighter GIF."
                      : "Quality\nHigher looks sharper; lower makes a lighter file.")
            }
            if model.hasAudio && model.format == .mp4 {
                labeled("Audio") {
                    Toggle(isOn: Binding(get: { !model.mute }, set: { model.mute = !$0 })) {
                        Label(model.mute ? "Muted" : "Sound", systemImage: model.mute ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .toggleStyle(.button)
                    .help("Audio\nKeeps or removes the sound in the exported video.")
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))")
                Text(model.format == .gif ? "\(model.gifFPS) fps, loops" : model.codec.title)
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            // From the recording as it was made: the trim and Mute would cut the narration.
            Button(CaptureAction.reportForAI.title(for: model.item.kind), systemImage: CaptureAction.reportForAI.symbol(for: model.item.kind)) {
                model.pause()
                Task { await CaptureAction.reportForAI.perform(model.item) }
            }
            .help(CaptureAction.reportForAI.tooltip(for: model.item.kind) + " Uses the whole recording, without trim or export settings.")
            Spacer()
            Button(CaptureAction.copy.title(for: model.item.kind)) { model.perform(.copy) }
                .help("Copy\nExports with these settings and puts the file on the clipboard.")
            Button(CaptureAction.save.title(for: model.item.kind)) { model.perform(.save) }
                .help("Save\nExports with these settings into your save folder (Settings > General).")
            Button(CaptureAction.saveAs.title(for: model.item.kind)) { model.perform(.saveAs) }
                .help("Save As\nExports with these settings where you choose.")
            Button("Done") { model.perform(.done) }
                .help("Done (Return)\nExports your edit as a new capture in History (copied too when Copy file to clipboard is on in Settings > Recording), then closes.")
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

    /// Space plays and pauses; the arrow keys step one frame; Delete removes the selected zoom.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { model.step(frames: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.step(frames: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { if let id = model.selectedZoom { model.deleteZoom(id) } }.keyboardShortcut(.delete, modifiers: [])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}

/// Over the preview while a new zoom waits for its region: drag a rectangle on the video. Esc keeps the middle.
private struct ZoomRegionPicker: View {
    @ObservedObject var model: VideoEditorModel
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let frame = model.videoFrame(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25)
                if let rect = dragged(in: frame) {
                    Rectangle()
                        .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(Color.white.opacity(0.08))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
                VStack(spacing: 8) {
                    Text("Drag a rectangle where the zoom should go")
                        .font(.system(size: 12, weight: .semibold))
                    Button("Keep the Middle") { model.endPicking() }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                        .help("Keep the Middle (Esc)\nThe zoom stays on the middle of the video.")
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                if start == nil { start = value.startLocation }
                current = value.location
            }.onEnded { _ in
                defer { start = nil; current = nil }
                guard let rect = dragged(in: frame), frame.width > 0, frame.height > 0 else { return }
                model.setZoomRegion(CGRect(x: (rect.minX - frame.minX) / frame.width, y: (rect.minY - frame.minY) / frame.height,
                                           width: rect.width / frame.width, height: rect.height / frame.height))
            })
        }
    }

    /// The dragged rectangle, kept on the video.
    private func dragged(in frame: CGRect) -> CGRect? {
        guard let start, let current else { return nil }
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        let clipped = rect.intersection(frame)
        return clipped.isNull || clipped.width < 2 || clipped.height < 2 ? nil : clipped
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
