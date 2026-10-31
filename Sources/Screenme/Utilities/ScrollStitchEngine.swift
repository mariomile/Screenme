import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Receives ScreenCaptureKit frames on its own queue, feeds them to the stitcher and publishes what happened.
/// It reports facts (rows so far, the last frame's outcome); `ScrollSession` decides what they mean.
/// Access to the stitcher is serialized between the frame queue and the main actor.
final class ScrollStitchEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Update {
        var rows: Int
        var outcome: ScrollStitcher.Outcome
    }

    let queue = DispatchQueue(label: "dev.mariomiletta.Screenme.scrolling", qos: .userInitiated)
    /// Called on the frame queue, at most every 0.2 s, and at once for a lost or limit outcome.
    var onUpdate: (@Sendable (Update) -> Void)?

    private let lock = NSLock()
    private var stitcher: ScrollStitcher?
    private var closed = false
    private var lastPublish = Date.distantPast
    private var advances = 0
    private var backs = 0

    // MARK: SCStreamOutput, SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        process(pixels)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Screenme: scrolling capture stream stopped: \(error.localizedDescription)")
    }

    // MARK: Frames

    private func process(_ buffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        if stitcher == nil {
            stitcher = ScrollStitcher(width: width, height: height)
            if let space = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue() {
                stitcher?.colorSpace = space
            } else if let space = CGColorSpace(name: CGColorSpace.sRGB) {
                stitcher?.colorSpace = space
            }
        }
        guard let stitcher, stitcher.width == width, stitcher.height == height else { return }

        let outcome = stitcher.add(base.assumingMemoryBound(to: UInt8.self), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        if outcome == .advanced { advances += 1 }
        if outcome == .scrolledBack { backs += 1 }

        let now = Date()
        guard now.timeIntervalSince(lastPublish) > 0.2 || outcome == .lost || outcome == .limit else { return }
        lastPublish = now
        onUpdate?(Update(rows: stitcher.totalRows, outcome: outcome))
    }

    /// Frames that moved the page forward and backward since the last call.
    func motionCounts() -> (advances: Int, backs: Int) {
        lock.lock()
        defer { lock.unlock() }
        defer { advances = 0; backs = 0 }
        return (advances, backs)
    }

    func finish() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        return stitcher?.finish()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        stitcher = nil
    }
}
