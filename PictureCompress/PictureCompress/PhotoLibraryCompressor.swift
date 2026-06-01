import CoreLocation
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

struct PhotoEstimate: Identifiable {
    let id: String
    let asset: PHAsset
    let originalBytes: Int
    let compressedBytes: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let creationDate: Date?

    var savedBytes: Int {
        max(0, originalBytes - compressedBytes)
    }

    var displayName: String {
        let dimensions = "\(pixelWidth)x\(pixelHeight)"
        guard let creationDate else {
            return dimensions
        }

        return "\(creationDate.formatted(date: .abbreviated, time: .shortened)) - \(dimensions)"
    }
}

struct RequestedPhotoData {
    let data: Data
    let uniformTypeIdentifier: String?
}

private struct PreparedReplacement {
    let asset: PHAsset
    let temporaryURL: URL
    let temporaryBytes: Int
    let albums: [PHAssetCollection]
}

@MainActor
final class PhotoLibraryCompressor: ObservableObject {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var estimates: [PhotoEstimate] = []
    @Published private(set) var progress = 0.0
    @Published private(set) var statusText = "Idle"
    @Published private(set) var messages: [String] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCompressing = false

    private let imageManager = PHImageManager.default()
    private let maxBatchTemporaryBytes = 200 * 1024 * 1024
    private let maxBatchItemCount = 100

    var canAccessPhotos: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var isBusy: Bool {
        isScanning || isCompressing
    }

    var authorizationSummary: String {
        switch authorizationStatus {
        case .authorized:
            return "Full Photos access"
        case .limited:
            return "Limited Photos access"
        case .denied, .restricted:
            return "Photos access is blocked"
        case .notDetermined:
            return "Photos access is needed"
        @unknown default:
            return "Unknown Photos permission"
        }
    }

    var totalOriginalBytes: Int {
        estimates.reduce(0) { $0 + $1.originalBytes }
    }

    var totalCompressedBytes: Int {
        estimates.reduce(0) { $0 + $1.compressedBytes }
    }

    var estimatedSavingsBytes: Int {
        max(0, totalOriginalBytes - totalCompressedBytes)
    }

    var estimatedSavingsPercent: String {
        guard totalOriginalBytes > 0 else { return "0%" }
        let percent = Double(estimatedSavingsBytes) / Double(totalOriginalBytes) * 100
        return percent.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    func refreshAuthorization() async {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async {
        authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func scan(maxPixelSize: Int, jpegQuality: Double) async {
        guard canAccessPhotos else {
            messages.insert("Grant Photos access first.", at: 0)
            return
        }

        isScanning = true
        progress = 0
        statusText = "Fetching photos..."
        messages.removeAll()
        estimates.removeAll()
        defer {
            isScanning = false
            progress = 1
            statusText = "Scan complete"
        }

        let assets = fetchImageAssets()
        guard assets.count > 0 else {
            messages.append("No image assets were available.")
            return
        }

        var newEstimates: [PhotoEstimate] = []
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            statusText = "Estimating \(index + 1) of \(assets.count)"
            progress = Double(index) / Double(assets.count)

            do {
                guard !shouldSkip(asset: asset) else { continue }

                let source = try await requestImageData(for: asset)
                guard !shouldSkip(uniformTypeIdentifier: source.uniformTypeIdentifier) else { continue }

                let compressedData = try await Task.detached(priority: .utility) {
                    try ImageCompressor.compressedJPEGData(
                        from: source.data,
                        maxPixelSize: maxPixelSize,
                        jpegQuality: jpegQuality
                    )
                }.value

                guard compressedData.count < source.data.count else { continue }

                newEstimates.append(
                    PhotoEstimate(
                        id: asset.localIdentifier,
                        asset: asset,
                        originalBytes: source.data.count,
                        compressedBytes: compressedData.count,
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight,
                        creationDate: asset.creationDate
                    )
                )
            } catch {
                messages.append("Skipped a photo: \(error.localizedDescription)")
            }

            if index % 10 == 0 {
                estimates = newEstimates.sorted { $0.savedBytes > $1.savedBytes }
            }
        }

        estimates = newEstimates.sorted { $0.savedBytes > $1.savedBytes }
        messages.insert("Estimated \(estimates.count) photos with positive savings.", at: 0)
    }

    func compressAndReplace(maxPixelSize: Int, jpegQuality: Double) async {
        guard canAccessPhotos else {
            messages.insert("Grant Photos access first.", at: 0)
            return
        }
        guard !estimates.isEmpty else {
            messages.insert("Run an estimate first.", at: 0)
            return
        }

        isCompressing = true
        progress = 0
        defer {
            isCompressing = false
            progress = 1
            statusText = "Compression complete"
        }

        let targets = estimates
        var prepared: [PreparedReplacement] = []
        var preparedBytes = 0
        var replaced = 0
        var failed = 0

        for (index, estimate) in targets.enumerated() {
            statusText = "Preparing \(index + 1) of \(targets.count)"
            progress = Double(index) / Double(max(1, targets.count))

            do {
                let replacement = try await prepareReplacement(
                    for: estimate.asset,
                    maxPixelSize: maxPixelSize,
                    jpegQuality: jpegQuality
                )
                prepared.append(replacement)
                preparedBytes += replacement.temporaryBytes

                if shouldCommitBatch(prepared, temporaryBytes: preparedBytes) {
                    replaced += await commitPreparedBatch(&prepared, failed: &failed)
                    preparedBytes = 0
                }
            } catch {
                failed += 1
                messages.append("Could not prepare a photo: \(error.localizedDescription)")
            }
        }

        if !prepared.isEmpty {
            replaced += await commitPreparedBatch(&prepared, failed: &failed)
        }

        guard replaced > 0 else {
            messages.insert("No photos were replaced. Failed: \(failed).", at: 0)
            return
        }

        messages.insert("Replaced \(replaced) photos in bounded batches. Failed: \(failed).", at: 0)
        await scan(maxPixelSize: maxPixelSize, jpegQuality: jpegQuality)
    }

    func formatted(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func fetchImageAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return PHAsset.fetchAssets(with: options)
    }

    private func prepareReplacement(for asset: PHAsset, maxPixelSize: Int, jpegQuality: Double) async throws -> PreparedReplacement {
        guard !shouldSkip(asset: asset) else {
            throw PhotoCompressionError.unsupportedAssetKind
        }

        let source = try await requestImageData(for: asset)
        guard !shouldSkip(uniformTypeIdentifier: source.uniformTypeIdentifier) else {
            throw PhotoCompressionError.unsupportedAssetKind
        }

        let compressedData = try await Task.detached(priority: .utility) {
            try ImageCompressor.compressedJPEGData(
                from: source.data,
                maxPixelSize: maxPixelSize,
                jpegQuality: jpegQuality
            )
        }.value

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")

        try compressedData.write(to: temporaryURL, options: [.atomic])
        return PreparedReplacement(
            asset: asset,
            temporaryURL: temporaryURL,
            temporaryBytes: compressedData.count,
            albums: userAlbums(containing: asset)
        )
    }

    private func shouldCommitBatch(_ replacements: [PreparedReplacement], temporaryBytes: Int) -> Bool {
        replacements.count >= maxBatchItemCount || temporaryBytes >= maxBatchTemporaryBytes
    }

    private func commitPreparedBatch(_ replacements: inout [PreparedReplacement], failed: inout Int) async -> Int {
        let batch = replacements
        replacements.removeAll(keepingCapacity: true)

        do {
            let batchSize = formatted(batch.reduce(0) { $0 + $1.temporaryBytes })
            statusText = "Waiting for Photos confirmation for \(batch.count) photos (\(batchSize))..."
            try await commitReplacements(batch)
            cleanupTemporaryFiles(for: batch)
            return batch.count
        } catch {
            failed += batch.count
            messages.append("Photos did not apply a batch of \(batch.count) photos: \(error.localizedDescription)")
            cleanupTemporaryFiles(for: batch)
            return 0
        }
    }

    private func cleanupTemporaryFiles(for replacements: [PreparedReplacement]) {
        for replacement in replacements {
            try? FileManager.default.removeItem(at: replacement.temporaryURL)
        }
    }

    private func commitReplacements(_ replacements: [PreparedReplacement]) async throws {
        try await performPhotoChanges {
            for replacement in replacements {
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.creationDate = replacement.asset.creationDate
                creationRequest.location = replacement.asset.location
                creationRequest.addResource(with: .photo, fileURL: replacement.temporaryURL, options: nil)

                if let placeholder = creationRequest.placeholderForCreatedAsset {
                    for album in replacement.albums {
                        PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                    }
                }
            }

            PHAssetChangeRequest.deleteAssets(replacements.map(\.asset) as NSArray)
        }
    }

    private func userAlbums(containing asset: PHAsset) -> [PHAssetCollection] {
        let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var albums: [PHAssetCollection] = []
        collections.enumerateObjects { collection, _, _ in
            if collection.assetCollectionType == .album {
                albums.append(collection)
            }
        }
        return albums
    }

    private func shouldSkip(asset: PHAsset) -> Bool {
        asset.mediaSubtypes.contains(.photoLive)
    }

    private func shouldSkip(uniformTypeIdentifier: String?) -> Bool {
        guard
            let uniformTypeIdentifier,
            let type = UTType(uniformTypeIdentifier)
        else {
            return false
        }

        return type.conforms(to: .rawImage) || type.conforms(to: .gif)
    }

    private func requestImageData(for asset: PHAsset) async throws -> RequestedPhotoData {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current

            var didResume = false
            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, uniformTypeIdentifier, _, info in
                guard !didResume else { return }
                if let error = info?[PHImageErrorKey] as? Error {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }

                if info?[PHImageCancelledKey] as? Bool == true {
                    didResume = true
                    continuation.resume(throwing: CancellationError())
                    return
                }

                guard let data else {
                    didResume = true
                    continuation.resume(throwing: PhotoCompressionError.missingImageData)
                    return
                }

                didResume = true
                continuation.resume(returning: RequestedPhotoData(data: data, uniformTypeIdentifier: uniformTypeIdentifier))
            }
        }
    }

    private func performPhotoChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoCompressionError.photoLibraryChangeFailed)
                }
            }
        }
    }
}

enum PhotoCompressionError: LocalizedError {
    case missingImageData
    case cannotCreateImageSource
    case cannotCreateThumbnail
    case cannotCreateDestination
    case cannotFinalizeImage
    case photoLibraryChangeFailed
    case unsupportedAssetKind

    var errorDescription: String? {
        switch self {
        case .missingImageData:
            return "Photos did not return image data."
        case .cannotCreateImageSource:
            return "The image data could not be decoded."
        case .cannotCreateThumbnail:
            return "A resized image could not be created."
        case .cannotCreateDestination:
            return "A compressed JPEG destination could not be created."
        case .cannotFinalizeImage:
            return "The compressed JPEG could not be finalized."
        case .photoLibraryChangeFailed:
            return "Photos did not apply the requested change."
        case .unsupportedAssetKind:
            return "This asset type is skipped to avoid losing Live Photo, RAW, or animated image data."
        }
    }
}
