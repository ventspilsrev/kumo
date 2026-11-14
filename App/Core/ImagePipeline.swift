import CryptoKit
import Foundation
import ImageIO
import UIKit

/// Loads images for covers and pages.
///
/// Memory is the main risk on a 2 GB iPad, so:
///  - downloaded bytes go to disk, not to RAM
///  - images are decoded straight to the size they are shown at
///    (ImageIO thumbnail), never at full size first
///  - decoded images sit in a size-limited cache that is emptied on a
///    memory warning
final class ImagePipeline {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private let diskDir = AppPaths.caches.appendingPathComponent("images", isDirectory: true)

    private init() {
        memory.totalCostLimit = 48 * 1024 * 1024
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.memory.removeAllObjects()
        }
    }

    private func diskURL(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(hash)
    }

    /// - Parameter maxPixel: longest side of the decoded image, in pixels.
    /// Sources sometimes give "//host/cover.jpg" or "http://..." addresses.
    /// Both are turned into https; anything else is rejected.
    static func secureAddress(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.hasPrefix("https://") { return text }
        if lower.hasPrefix("http://") { return "https://" + text.dropFirst(7) }
        if text.hasPrefix("//") { return "https:" + text }
        return nil
    }

    func image(runtime: SourceRuntime, url rawURL: String, maxPixel: Int) async throws -> UIImage {
        guard let url = ImagePipeline.secureAddress(rawURL) else {
            throw SourceError(message: "Image address is missing or not a web address")
        }
        let cacheKey = "\(maxPixel)|\(url)" as NSString
        if let hit = memory.object(forKey: cacheKey) { return hit }

        let file = diskURL(runtime.sourceId + "|" + url)
        if !FileManager.default.fileExists(atPath: file.path) {
            let data = try await runtime.imageData(url: url)
            try data.write(to: file, options: .atomic)
        }
        try Task.checkCancellation()

        // Decoding is CPU work: keep it off the main thread.
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            ImagePipeline.downsample(file: file, maxPixel: maxPixel)
        }.value
        guard let image = decoded else {
            // A file that cannot be decoded is useless; delete it so a retry downloads again.
            try? FileManager.default.removeItem(at: file)
            throw SourceError(message: "The image could not be decoded (unsupported format or damaged file)")
        }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memory.setObject(image, forKey: cacheKey, cost: cost)
        return image
    }

    private static func downsample(file: URL, maxPixel: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cg)
    }

    func clearDisk() {
        try? FileManager.default.removeItem(at: diskDir)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        memory.removeAllObjects()
    }
}
