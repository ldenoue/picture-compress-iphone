import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case heic
    case jpeg

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heic:
            return "HEIC"
        case .jpeg:
            return "JPEG"
        }
    }

    var detail: String {
        switch self {
        case .heic:
            return "Smaller"
        case .jpeg:
            return "Compatible"
        }
    }

    var fileExtension: String {
        switch self {
        case .heic:
            return "heic"
        case .jpeg:
            return "jpg"
        }
    }

    var typeIdentifier: CFString {
        switch self {
        case .heic:
            return UTType.heic.identifier as CFString
        case .jpeg:
            return UTType.jpeg.identifier as CFString
        }
    }
}

enum ImageCompressor {
    static func compressedData(from sourceData: Data, maxPixelSize: Int, quality: Double, format: ExportFormat) throws -> Data {
        try autoreleasepool {
            let image = try resizedImage(from: sourceData, maxPixelSize: maxPixelSize)

            let outputData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                outputData,
                format.typeIdentifier,
                1,
                nil
            ) else {
                throw PhotoCompressionError.cannotCreateDestination
            }

            try addImage(image, from: sourceData, to: destination, quality: quality)
            return outputData as Data
        }
    }

    static func writeCompressedImage(from sourceData: Data, to url: URL, maxPixelSize: Int, quality: Double, format: ExportFormat) throws -> Int {
        try autoreleasepool {
            let image = try resizedImage(from: sourceData, maxPixelSize: maxPixelSize)
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                format.typeIdentifier,
                1,
                nil
            ) else {
                throw PhotoCompressionError.cannotCreateDestination
            }

            try addImage(image, from: sourceData, to: destination, quality: quality)
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

    private static func addImage(_ image: CGImage, from sourceData: Data, to destination: CGImageDestination, quality: Double) throws {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw PhotoCompressionError.cannotCreateImageSource
        }

        var metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        metadata[kCGImagePropertyOrientation] = 1

        var destinationProperties = metadata
        destinationProperties[kCGImageDestinationLossyCompressionQuality] = quality

        CGImageDestinationAddImage(destination, image, destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoCompressionError.cannotFinalizeImage
        }
    }
}
