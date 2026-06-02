import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageCompressor {
    static func compressedJPEGData(from sourceData: Data, maxPixelSize: Int, jpegQuality: Double) throws -> Data {
        try autoreleasepool {
            let image = try resizedImage(from: sourceData, maxPixelSize: maxPixelSize)

            let outputData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                outputData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                throw PhotoCompressionError.cannotCreateDestination
            }

            try addJPEGImage(image, from: sourceData, to: destination, jpegQuality: jpegQuality)
            return outputData as Data
        }
    }

    static func writeCompressedJPEG(from sourceData: Data, to url: URL, maxPixelSize: Int, jpegQuality: Double) throws -> Int {
        try autoreleasepool {
            let image = try resizedImage(from: sourceData, maxPixelSize: maxPixelSize)
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                throw PhotoCompressionError.cannotCreateDestination
            }

            try addJPEGImage(image, from: sourceData, to: destination, jpegQuality: jpegQuality)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int ?? 0
        }
    }

    private static func resizedImage(from sourceData: Data, maxPixelSize: Int) throws -> CGImage {
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

        return image
    }

    private static func addJPEGImage(_ image: CGImage, from sourceData: Data, to destination: CGImageDestination, jpegQuality: Double) throws {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw PhotoCompressionError.cannotCreateImageSource
        }

        var metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        metadata[kCGImagePropertyOrientation] = 1

        var destinationProperties = metadata
        destinationProperties[kCGImageDestinationLossyCompressionQuality] = jpegQuality

        CGImageDestinationAddImage(destination, image, destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoCompressionError.cannotFinalizeImage
        }
    }
}
