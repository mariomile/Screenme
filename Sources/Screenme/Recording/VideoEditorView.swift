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
        let window = WindowPresenter.shared.show(id, title: item.url.lastPathComponent, size: CGSize(width: 940, height: 680),
                                                 style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]) {
            VideoEditorView(model: model)
        }
        window.minSize = CGSize(width: 780, height: 560)
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
            labeled("Size") {
                Picker("Size", selection: $model.resolution) {
                    ForEach(ExportResolution.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
                .help("Size\nSmaller sizes make lighter files, good for chats and email.")
            }
            labeled("Quality") {
                Picker("Quality", selection: $model.quality) {
                    ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                .help("Quality\nHigher looks sharper; lower makes a lighter file.")
            }
            if model.format == .gif {
                labeled("Frame rate") {
                    Picker("Frame rate", selection: $model.gifFPS) {
                        ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    .help("Frame rate\nMore frames move more smoothly; fewer make a lighter GIF.")
                }
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
                Text(model.format == .gif ? "\(model.gifFPS) fps, loops" : "H.264")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            // From the recording as it was made: the trim and Mute would cut the narration.
            Button(CaptureAction.bugReport.title(for: model.item.kind), systemImage: CaptureAction.bugReport.symbol(for: model.item.kind)) {
                model.pause()
                Task { await CaptureAction.bugReport.perform(model.item) }
            }
            .help(CaptureAction.bugReport.tooltip(for: model.item.kind) + " Uses the whole recording, without trim or export settings.")
            Spacer()
            Button(CaptureAction.copy.title(for: model.item.kind)) { model.perform(.copy) }
                .help("Copy\nExports with these settings and puts the file on the clipboard.")
            Button(CaptureAction.save.title(for: model.item.kind)) { model.perform(.save) }
                .help("Save\nExports with these settings into your save folder (Settings > General).")
            Button(CaptureAction.saveAs.title(for: model.item.kind)) { model.perform(.saveAs) }
                .help("Save As\nExports with these settings where you choose.")
            Button("Done") { model.perform(.done) }
                .help("Done (Return)\nExports your trim and settings as a new capture in Quick Access and History, then closes.")
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
