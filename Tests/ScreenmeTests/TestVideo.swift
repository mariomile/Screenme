import AVFoundation
import CoreImage
import XCTest
@testable import Screenme

/// Generated H.264 videos for the export tests: a solid color with a white block moving across it, so every frame differs.
enum TestVideo {
    /// `make` on a background thread, for tests on the main actor: writing a video blocks, and AVFoundation logs a
    /// warning when that happens on the main thread.
    static func makeOffMain(width: Int, height: Int, seconds: Double, fps: Int = 30,
                            color: (r: UInt8, g: UInt8, b: UInt8) = (0, 160, 0)) async throws -> URL {
        try await Task.detached { try make(width: width, height: height, seconds: seconds, fps: fps, color: color) }.value
    }

    static func make(width: Int, height: Int, seconds: Double, fps: Int = 30,
                     color: (r: UInt8, g: UInt8, b: UInt8) = (0, 160, 0), tone: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screenme-test-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: H264.settings(width: width, height: height, fps: fps,
                                                                                       quality: .high, realTime: false))
        input.expectsMediaDataInRealTime = false
        var audioInput: AVAssetWriterInput?
        if tone {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
            ])
            audio.expectsMediaDataInRealTime = false
            writer.add(audio)
            audioInput = audio
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ScreenmeError.recordingFailed }
        writer.startSession(atSourceTime: .zero)

        // A handful of distinct frames, used in turn: the encoder still sees motion, the test does not pay for painting.
        let variants = 16
        var buffers: [CVPixelBuffer] = []
        for index in 0..<variants {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
            guard let buffer else { throw ScreenmeError.recordingFailed }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let blockX = (width - width / 8) * index / variants
            for y in 0..<height {
                let line = base + y * row
                for x in 0..<width {
                    let inBlock = x >= blockX && x < blockX + width / 8 && y >= height / 3 && y < height / 3 + height / 8
                    let p = line + x * 4
                    p[0] = inBlock ? 255 : color.b
                    p[1] = inBlock ? 255 : color.g
                    p[2] = inBlock ? 255 : color.r
                    p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            buffers.append(buffer)
        }

        // With a tone: a 440 Hz sine, 16-bit mono at 48 kHz, one chunk per video frame so the writer can interleave.
        var format: CMAudioFormatDescription?
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                                      mBitsPerChannel: 16, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let chunk = 48000 / fps
        func appendTone(frame: Int, to input: AVAssetWriterInput) {
            let first = frame * chunk
            var samples = (0..<chunk).map { Int16(8000 * sin(2 * .pi * 440 * Double(first + $0) / 48000)) }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: chunk * 2, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: chunk * 2, flags: 0, blockBufferOut: &block)
            samples.withUnsafeMutableBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: chunk * 2) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: chunk,
                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(first), timescale: 48000),
                                                                 packetDescriptions: nil, sampleBufferOut: &sample)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            input.append(sample!)
        }

        let frames = Int(seconds * Double(fps))
        for frame in 0..<frames {
            if let audioInput { appendTone(frame: frame, to: audioInput) }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            adaptor.append(buffers[frame % variants], withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        audioInput?.markAsFinished()
        let done = XCTestExpectation()
        writer.finishWriting { done.fulfill() }
        _ = XCTWaiter.wait(for: [done], timeout: 120)
        guard writer.status == .completed else { throw writer.error ?? ScreenmeError.recordingFailed }
        return url
    }

    /// The RGB of a pixel of the frame at `time`, from the top-left corner.
    static func pixel(of url: URL, at time: Double, x: Int, y: Int) async throws -> (r: Int, g: Int, b: Int) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    static func size(of url: URL) async throws -> CGSize {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
        return try await track?.load(.naturalSize) ?? .zero
    }
}
