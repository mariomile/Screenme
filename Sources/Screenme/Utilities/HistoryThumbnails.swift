import AppKit
import AVFoundation
import ImageIO

/// A decoded grid thumbnail. `duration` is set for videos.
final class HistoryThumbnail {
    let image: CGImage
    let duration: TimeInterval?
    init(image: CGImage, duration: TimeInterval?) {
        self.image = image
        self.duration = duration
    }
}

/// Generates grid thumbnails off the main thread and caches them. Images go through ImageIO,
/// which decodes straight to thumbnail size; videos use their first frame.
enum HistoryThumbnails {
    private static let cache: NSCache<NSString, HistoryThumbnail> = {
        let cache = NSCache<NSString, HistoryThumbnail>()
        cache.countLimit = 600
        return cache
    }()

    /// Longest side in pixels: enough for a retina grid cell.
    private static let maxPixelSize = 640

    static func cached(for item: CaptureItem) -> HistoryThumbnail? {
        cache.object(forKey: key(for: item.url))
    }

    static func invalidate(_ url: URL) {
        // The key embeds the modification date, so a changed file already misses; free the old entry anyway.
        cache.removeObject(forKey: key(for: url))
    }

    /// Runs on the cooperative pool, never the main actor.
    static func thumbnail(for item: CaptureItem) async -> HistoryThumbnail? {
        let key = key(for: item.url)
        if let hit = cache.object(forKey: key) { return hit }
        guard !Task.isCancelled else { return nil }

        let result: HistoryThumbnail?
        switch item.kind {
        case .image: result = imageThumbnail(item.url)
        case .video: result = await videoThumbnail(item.url)
        }
        if let result, !Task.isCancelled { cache.setObject(result, forKey: key) }
        return result
    }

    private static func key(for url: URL) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(modified)" as NSString
    }

    private static func imageThumbnail(_ url: URL) -> HistoryThumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return HistoryThumbnail(image: image, duration: nil)
    }

    private static func videoThumbnail(_ url: URL) async -> HistoryThumbnail? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        return HistoryThumbnail(image: image, duration: seconds.isFinite && seconds > 0 ? seconds : nil)
    }
}
