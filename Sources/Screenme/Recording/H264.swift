import AVFoundation

/// The one H.264 configuration, for recordings and for exports from the video editor.
enum H264 {
    /// Writer settings for a `width` x `height` video at `fps`.
    /// `realTime` is live capture: frame reordering is off, so every frame leaves the encoder as soon as it arrives.
    static func settings(width: Int, height: Int, fps: Int, quality: VideoQuality, realTime: Bool) -> [String: Any] {
        let rate = Double(width * height * fps) * quality.bitsPerPixel
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
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
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: !realTime,
            ] as [String: Any],
        ]
    }
}
