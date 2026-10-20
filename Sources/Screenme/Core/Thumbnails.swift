import AppKit
import AVFoundation
import ImageIO

/// A decoded preview of a capture. `duration` is set for videos.
final class Thumbnail {
    let image: CGImage
    let duration: TimeInterval?
    init(image: CGImage, duration: TimeInterval?) {
        self.image = image
        self.duration = duration
    }
}

/// Previews for Quick Access, History and pins, made off the main thread. Images go through ImageIO,
/// which decodes straight to the asked size; videos use a frame near the start.
enum Thumbnails {
    /// Keyed by path, modification date and size: an edited file misses and gets a fresh preview.
    private static let cache: NSCache<NSString, Thumbnail> = {
        let cache = NSCache<NSString, Thumbnail>()
        cache.countLimit = 600
        return cache
    }()

    static func cached(for item: CaptureItem, maxPixelSize: Int) -> Thumbnail? {
        cache.object(forKey: key(for: item.url, maxPixelSize: maxPixelSize))
    }

    /// A preview with its longest side at most `maxPixelSize` pixels, or full size when nil (not cached).
    /// Runs on the cooperative pool, never the main actor.
    static func make(for item: CaptureItem, maxPixelSize: Int?) async -> Thumbnail? {
        let key = maxPixelSize.map { key(for: item.url, maxPixelSize: $0) }
        if let key, let hit = cache.object(forKey: key) { return hit }
        guard !Task.isCancelled else { return nil }

        let result: Thumbnail?
        switch item.kind {
        case .image, .gif: result = decodeImage(at: item.url, maxPixelSize: maxPixelSize).map { Thumbnail(image: $0, duration: nil) }
        case .video: result = await videoFrame(item.url, maxPixelSize: maxPixelSize)
        }
        if let key, let result, !Task.isCancelled { cache.setObject(result, forKey: key) }
        return result
    }

    /// Height over width of an image capture, read from the file header. 0.65 for videos and when unknown.
    static func aspectRatio(of item: CaptureItem) -> CGFloat {
        guard item.kind != .video,
              let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0 else { return 0.65 }
        return height / width
    }

    /// The first picture in an image file, its longest side at most `maxPixelSize` (nil keeps the original size).
    static func decodeImage(at url: URL, maxPixelSize: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        guard let maxPixelSize else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func key(for url: URL, maxPixelSize: Int) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(modified)|\(maxPixelSize)" as NSString
    }

    /// A frame 0.3 s in (past the first, often blank, frame) when the video is longer than a second.
    private static func videoFrame(_ url: URL, maxPixelSize: Int?) async -> Thumbnail? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maxPixelSize { generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize) }
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: seconds > 1 ? 0.3 : 0, preferredTimescale: 600)
        guard let (image, _) = try? await generator.image(at: time) else { return nil }
        return Thumbnail(image: image, duration: seconds.isFinite && seconds > 0 ? seconds : nil)
    }
}
