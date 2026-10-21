import AVFoundation
import VideoToolbox

/// The one encoder configuration: H.264 for recordings, H.264 or HEVC for exports from the video editor.
enum H264 {
    /// Writer settings for a `width` x `height` video at `fps`.
    /// `realTime` is live capture: frame reordering is off, so every frame leaves the encoder as soon as it arrives.
    /// HEVC gets the same look from about two thirds of the bits.
    static func settings(width: Int, height: Int, fps: Int, quality: VideoQuality, realTime: Bool, codec: VideoCodec = .h264) -> [String: Any] {
        let rate = Double(width * height * fps) * quality.bitsPerPixel * (codec == .hevc ? 0.65 : 1)
        return [
            AVVideoCodecKey: codec.type,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(min(max(rate, 1_000_000), 80_000_000)),
                AVVideoProfileLevelKey: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: !realTime,
            ] as [String: Any],
        ]
    }
}
