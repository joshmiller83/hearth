import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Scales photos down before they go to Claude (about 1,568 px on the long side
/// is all the model uses) and makes the small thumbnails the recent list shows.
/// ImageIO, so it runs on the phone and in macOS tests alike.
public enum ImageShrinker {
    public static func jpeg(_ data: Data, maxPixels: Int = 1568, quality: Double = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // respect the camera's orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    public static func thumbnail(_ data: Data) -> Data? {
        jpeg(data, maxPixels: 160, quality: 0.7)
    }
}
