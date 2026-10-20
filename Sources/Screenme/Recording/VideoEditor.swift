import AppKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/// Trimming uses AVKit's native trim bar; the result replaces the capture in place.
@MainActor
enum Trimmer {
    private static var windows: [NSWindow] = []

    static func open(_ url: URL, onTrimmed: @escaping (URL) -> Void) {
        let player = AVPlayer(url: url)
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Trim: \(url.lastPathComponent)"
        window.contentView = playerView
        window.isReleasedWhenClosed = false
        window.center()
        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // The trim bar needs the item to be ready before it can open.
        Task { @MainActor in
            _ = try? await player.currentItem?.asset.load(.duration)
            playerView.beginTrimming { result in MainActor.assumeIsolated {
                let item = player.currentItem
                player.pause()
                window.close()
                windows.removeAll { $0 === window }
                guard result == .okButton, let item else { return }
                let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
                let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
                Task {
                    if let trimmed = try? await export(url, range: CMTimeRange(start: start, end: end)) {
                        onTrimmed(trimmed)
                    }
                }
            } }
        }
    }

    private static func export(_ url: URL, range: CMTimeRange) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ScreenmeError.recordingFailed
        }
        session.timeRange = range
        let output = Storage.newURL(extension: "mp4")
        try await session.export(to: output, as: .mp4)
        return output
    }
}

/// Converts a recording to an animated GIF: 12 fps, at most 960 px wide.
enum GIFExporter {
    static func export(_ url: URL, fps: Double = 12, maxWidth: CGFloat = 960) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let count = max(1, Int(duration * fps))
        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }

        let output = Storage.newURL(extension: "gif")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps],
        ] as CFDictionary

        for await result in generator.images(for: times) {
            if let image = try? result.image {
                CGImageDestinationAddImage(destination, image, frameProperties)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output
    }
}

/// Opens a recording for editing. Stub: trim only; the full editor replaces this.
@MainActor
enum VideoEditor {
    static func open(_ item: CaptureItem) {
        Trimmer.open(item.url) { url in
            CaptureCoordinator.shared.afterCapture(CaptureItem(url: url, kind: .video))
        }
    }
}
