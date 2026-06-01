import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageCompressor {
    static func compressedJPEGData(from sourceData: Data, maxPixelSize: Int, jpegQuality: Double) throws -> Data {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw PhotoCompressionError.cannotCreateImageSource
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw PhotoCompressionError.cannotCreateThumbnail
        }

        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoCompressionError.cannotCreateDestination
        }

        var metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        metadata[kCGImagePropertyOrientation] = 1

        var destinationProperties = metadata
        destinationProperties[kCGImageDestinationLossyCompressionQuality] = jpegQuality

        CGImageDestinationAddImage(destination, image, destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoCompressionError.cannotFinalizeImage
        }

        return outputData as Data
    }
}
