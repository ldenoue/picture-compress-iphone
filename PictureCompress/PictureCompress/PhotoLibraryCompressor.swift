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

private enum EstimateOutcome {
    case savings(PhotoEstimate)
    case noSavings
    case failed(String)
}

private enum ReplacementOutcome {
    case prepared(PreparedReplacement)
    case skipped
    case failed(String)
}

private enum PhotoCompressionWorker {
    static func estimate(asset: PHAsset, maxPixelSize: Int, quality: Double, format: ExportFormat) async -> EstimateOutcome {
        guard !shouldSkip(asset: asset) else {
            return .noSavings
        }

        do {
            let source = try await requestImageData(for: asset)
            guard !shouldSkip(uniformTypeIdentifier: source.uniformTypeIdentifier) else {
                return .noSavings
            }

            let compressedData = try ImageCompressor.compressedData(
                from: source.data,
                maxPixelSize: maxPixelSize,
                quality: quality,
                format: format
            )

            guard compressedData.count < source.data.count else {
                return .noSavings
            }

            return .savings(
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
            return .failed(error.localizedDescription)
        }
    }

    static func prepareReplacement(
        for asset: PHAsset,
        temporaryDirectory: URL,
        maxPixelSize: Int,
        quality: Double,
        format: ExportFormat
    ) async -> ReplacementOutcome {
        guard !shouldSkip(asset: asset) else {
            return .skipped
        }

        do {
            let source = try await requestImageData(for: asset)
            guard !shouldSkip(uniformTypeIdentifier: source.uniformTypeIdentifier) else {
                return .skipped
            }

            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )

            let temporaryURL = temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(format.fileExtension)

            let compressedBytes: Int
            do {
                compressedBytes = try ImageCompressor.writeCompressedImage(
                    from: source.data,
                    to: temporaryURL,
                    maxPixelSize: maxPixelSize,
                    quality: quality,
                    format: format
                )
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }

            guard compressedBytes < source.data.count else {
                try? FileManager.default.removeItem(at: temporaryURL)
                return .skipped
            }

            return .prepared(
                PreparedReplacement(
                    asset: asset,
                    temporaryURL: temporaryURL,
                    temporaryBytes: compressedBytes,
                    albums: userAlbums(containing: asset)
                )
            )
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func userAlbums(containing asset: PHAsset) -> [PHAssetCollection] {
        let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var albums: [PHAssetCollection] = []
        collections.enumerateObjects { collection, _, _ in
            if collection.assetCollectionType == .album {
                albums.append(collection)
            }
        }
        return albums
    }

    private static func shouldSkip(asset: PHAsset) -> Bool {
        asset.mediaSubtypes.contains(.photoLive)
    }

    private static func shouldSkip(uniformTypeIdentifier: String?) -> Bool {
        guard
            let uniformTypeIdentifier,
            let type = UTType(uniformTypeIdentifier)
        else {
            return false
        }

        return type.conforms(to: .rawImage) || type.conforms(to: .gif)
    }

    private static func requestImageData(for asset: PHAsset) async throws -> RequestedPhotoData {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current

            var didResume = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uniformTypeIdentifier, _, info in
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
    @Published private(set) var photosChecked = 0
    @Published private(set) var photosWithNoSavings = 0
    @Published private(set) var stopRequested = false
    @Published private(set) var throughputText = ""

    private let temporaryReplacementFolderName = "PhotoSqueezeReplacements"
    private let fallbackBatchTemporaryBytes = 200 * 1024 * 1024
    private let maxBatchTemporaryBytes = 4 * 1024 * 1024 * 1024
    private let minimumBatchTemporaryBytes = 50 * 1024 * 1024
    private let lowStorageBatchTemporaryBytes = 10 * 1024 * 1024
    private let freeSpaceReserveBytes = 1 * 1024 * 1024 * 1024
    private let maxBatchItemCount = 1000

    var canAccessPhotos: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var isBusy: Bool {
        isScanning || isCompressing
    }

    private var temporaryReplacementDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(temporaryReplacementFolderName, isDirectory: true)
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

    var estimatedSavingsRatio: Double {
        guard totalOriginalBytes > 0 else { return 0 }
        return min(1, max(0, Double(estimatedSavingsBytes) / Double(totalOriginalBytes)))
    }

    var savingsGaugeCaption: String {
        if isScanning {
            return "potential storage found so far"
        }

        if photosChecked > 0 && estimates.isEmpty {
            return "no smaller replacements found for these settings"
        }

        guard !estimates.isEmpty else {
            return "run an estimate to fill the savings meter"
        }

        return "potential storage savings"
    }

    func refreshAuthorization() async {
        cleanupAllTemporaryReplacementFiles()
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async {
        authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func clearEstimateResults() {
        guard !isBusy else { return }
        estimates.removeAll()
        photosChecked = 0
        photosWithNoSavings = 0
        progress = 0
        statusText = "Idle"
        throughputText = ""
    }

    func stopCurrentWork() {
        guard isBusy else { return }
        stopRequested = true
        statusText = "Stopping..."
    }

    func cleanupTemporaryStorageIfIdle() {
        guard !isBusy else { return }
        cleanupAllTemporaryReplacementFiles()
    }

    func scan(maxPixelSize: Int, quality: Double, format: ExportFormat, parallelism: Int) async {
        guard canAccessPhotos else {
            messages.insert("Grant Photos access first.", at: 0)
            return
        }

        isScanning = true
        stopRequested = false
        progress = 0
        statusText = "Fetching photos..."
        throughputText = ""
        messages.removeAll()
        estimates.removeAll()
        photosChecked = 0
        photosWithNoSavings = 0
        defer {
            let wasStopped = stopRequested
            stopRequested = false
            isScanning = false
            progress = 1
            statusText = wasStopped ? "Estimate stopped" : "Scan complete"
        }

        let assets = fetchImageAssetArray()
        guard assets.count > 0 else {
            messages.append("No image assets were available.")
            return
        }

        var newEstimates: [PhotoEstimate] = []
        var processed = 0
        let startedAt = Date()
        for chunk in assets.chunked(into: normalizedParallelism(parallelism)) {
            if stopRequested {
                statusText = "Estimate stopped"
                break
            }

            let outcomes = await estimate(chunk, maxPixelSize: maxPixelSize, quality: quality, format: format)
            for outcome in outcomes {
                photosChecked += 1
                processed += 1

                switch outcome {
                case .savings(let estimate):
                    newEstimates.append(estimate)
                case .noSavings:
                    photosWithNoSavings += 1
                case .failed(let message):
                    photosWithNoSavings += 1
                    messages.append("Skipped a photo: \(message)")
                }
            }

            statusText = "Estimating \(min(processed, assets.count)) of \(assets.count)"
            progress = Double(processed) / Double(assets.count)
            throughputText = throughputSummary(processed: processed, startedAt: startedAt)
            estimates = newEstimates.sorted { $0.savedBytes > $1.savedBytes }
        }

        estimates = newEstimates.sorted { $0.savedBytes > $1.savedBytes }
        if stopRequested {
            messages.insert("Estimate stopped after checking \(photosChecked) photos.", at: 0)
        } else {
            messages.insert("Checked \(photosChecked) photos. \(estimates.count) had positive savings.", at: 0)
        }
    }

    func compressAndReplace(maxPixelSize: Int, quality: Double, format: ExportFormat, parallelism: Int) async {
        guard canAccessPhotos else {
            messages.insert("Grant Photos access first.", at: 0)
            return
        }
        isCompressing = true
        stopRequested = false
        cleanupAllTemporaryReplacementFiles()
        progress = 0
        throughputText = ""

        var prepared: [PreparedReplacement] = []
        defer {
            cleanupAllTemporaryReplacementFiles()
            stopRequested = false
            isCompressing = false
            progress = 1
            if statusText != "Compression stopped" {
                statusText = "Compression complete"
            }
        }

        let targets = compressionTargets()
        var preparedBytes = 0
        var replaced = 0
        var failed = 0
        var skipped = 0
        var batchTemporaryByteLimit = dynamicBatchTemporaryByteLimit()

        guard !targets.isEmpty else {
            messages.insert("No image assets were available.", at: 0)
            return
        }

        let targetDescription = estimates.isEmpty ? "photo" : "estimated photo"
        var processed = 0
        let startedAt = Date()
        for chunk in targets.chunked(into: normalizedParallelism(parallelism)) {
            if stopRequested {
                statusText = "Compression stopped"
                break
            }

            let outcomes = await prepareReplacements(
                chunk,
                maxPixelSize: maxPixelSize,
                quality: quality,
                format: format
            )

            for outcome in outcomes {
                processed += 1

                switch outcome {
                case .prepared(let replacement):
                    prepared.append(replacement)
                    preparedBytes += replacement.temporaryBytes
                case .skipped:
                    skipped += 1
                case .failed(let message):
                    failed += 1
                    messages.append("Could not prepare a photo: \(message)")
                }

                statusText = "Preparing \(min(processed, targets.count)) of \(targets.count) \(targetDescription)s"
                progress = Double(processed) / Double(max(1, targets.count))
                throughputText = throughputSummary(processed: processed, startedAt: startedAt)

                guard !stopRequested else {
                    statusText = "Compression stopped"
                    break
                }

                guard !prepared.isEmpty else { continue }
                if shouldCommitBatch(prepared, temporaryBytes: preparedBytes, byteLimit: batchTemporaryByteLimit) {
                    guard !stopRequested else {
                        statusText = "Compression stopped"
                        break
                    }
                    replaced += await commitPreparedBatch(&prepared, failed: &failed)
                    preparedBytes = 0
                    batchTemporaryByteLimit = dynamicBatchTemporaryByteLimit()
                }
            }

            if stopRequested {
                statusText = "Compression stopped"
                break
            }
        }

        if !stopRequested && !prepared.isEmpty {
            replaced += await commitPreparedBatch(&prepared, failed: &failed)
        }

        if stopRequested {
            messages.insert("Compression stopped. Replaced \(replaced) photos before stopping.", at: 0)
            return
        }

        guard replaced > 0 else {
            messages.insert("No photos were replaced. Skipped: \(skipped). Failed: \(failed).", at: 0)
            return
        }

        estimates.removeAll()
        photosChecked = 0
        photosWithNoSavings = 0
        messages.insert("Replaced \(replaced) photos in bounded batches. Skipped: \(skipped). Failed: \(failed).", at: 0)
        messages.insert("Run Estimate Savings again if you want refreshed numbers.", at: 1)
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

    private func fetchImageAssetArray() -> [PHAsset] {
        let assets = fetchImageAssets()
        var assetArray: [PHAsset] = []
        assetArray.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            assetArray.append(asset)
        }
        return assetArray
    }

    private func compressionTargets() -> [PHAsset] {
        guard estimates.isEmpty else {
            return estimates.map(\.asset)
        }

        return fetchImageAssetArray()
    }

    private func normalizedParallelism(_ parallelism: Int) -> Int {
        min(8, max(1, parallelism))
    }

    private func estimate(_ assets: [PHAsset], maxPixelSize: Int, quality: Double, format: ExportFormat) async -> [EstimateOutcome] {
        await withTaskGroup(of: EstimateOutcome.self) { group in
            for asset in assets {
                group.addTask {
                    await PhotoCompressionWorker.estimate(
                        asset: asset,
                        maxPixelSize: maxPixelSize,
                        quality: quality,
                        format: format
                    )
                }
            }

            var outcomes: [EstimateOutcome] = []
            outcomes.reserveCapacity(assets.count)
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    private func prepareReplacements(_ assets: [PHAsset], maxPixelSize: Int, quality: Double, format: ExportFormat) async -> [ReplacementOutcome] {
        let temporaryDirectory = temporaryReplacementDirectory
        return await withTaskGroup(of: ReplacementOutcome.self) { group in
            for asset in assets {
                group.addTask {
                    await PhotoCompressionWorker.prepareReplacement(
                        for: asset,
                        temporaryDirectory: temporaryDirectory,
                        maxPixelSize: maxPixelSize,
                        quality: quality,
                        format: format
                    )
                }
            }

            var outcomes: [ReplacementOutcome] = []
            outcomes.reserveCapacity(assets.count)
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    private func shouldCommitBatch(_ replacements: [PreparedReplacement], temporaryBytes: Int, byteLimit: Int) -> Bool {
        replacements.count >= maxBatchItemCount || temporaryBytes >= byteLimit
    }

    private func dynamicBatchTemporaryByteLimit() -> Int {
        let availableBytes = availableTemporaryVolumeBytes()
        guard availableBytes > 0 else {
            return fallbackBatchTemporaryBytes
        }

        let usableBytes = max(0, availableBytes - freeSpaceReserveBytes)
        guard usableBytes > 0 else {
            return max(lowStorageBatchTemporaryBytes, min(minimumBatchTemporaryBytes, availableBytes / 4))
        }

        let cautiousLimit = usableBytes / 2
        return min(maxBatchTemporaryBytes, max(minimumBatchTemporaryBytes, cautiousLimit))
    }

    private func availableTemporaryVolumeBytes() -> Int {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]

        guard let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: keys) else {
            return 0
        }

        if let importantCapacity = values.volumeAvailableCapacityForImportantUsage {
            return max(0, Int(min(importantCapacity, Int64(Int.max))))
        }

        return max(0, values.volumeAvailableCapacity ?? 0)
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

    private func cleanupAllTemporaryReplacementFiles() {
        try? FileManager.default.removeItem(at: temporaryReplacementDirectory)
    }

    private func commitReplacements(_ replacements: [PreparedReplacement]) async throws {
        try await performPhotoChanges {
            for replacement in replacements {
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.creationDate = replacement.asset.creationDate
                creationRequest.location = replacement.asset.location

                let resourceOptions = PHAssetResourceCreationOptions()
                resourceOptions.originalFilename = replacement.temporaryURL.lastPathComponent
                resourceOptions.shouldMoveFile = true
                creationRequest.addResource(with: .photo, fileURL: replacement.temporaryURL, options: resourceOptions)

                if let placeholder = creationRequest.placeholderForCreatedAsset {
                    for album in replacement.albums {
                        PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                    }
                }
            }

            PHAssetChangeRequest.deleteAssets(replacements.map(\.asset) as NSArray)
        }
    }

    private func shouldUpdateProgress(index: Int, total: Int) -> Bool {
        index == 0 || index == total - 1 || index % 5 == 0
    }

    private func throughputSummary(processed: Int, startedAt: Date) -> String {
        let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
        let rate = Double(processed) / elapsed
        let elapsedText = elapsed.formatted(.number.precision(.fractionLength(elapsed < 10 ? 1 : 0)))
        let rateText = rate.formatted(.number.precision(.fractionLength(rate < 10 ? 1 : 0)))
        return "\(elapsedText)s elapsed - \(rateText) photos/sec"
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
    case noStorageSavings

    var errorDescription: String? {
        switch self {
        case .missingImageData:
            return "Photos did not return image data."
        case .cannotCreateImageSource:
            return "The image data could not be decoded."
        case .cannotCreateThumbnail:
            return "A resized image could not be created."
        case .cannotCreateDestination:
            return "A compressed image destination could not be created."
        case .cannotFinalizeImage:
            return "The compressed image could not be finalized."
        case .photoLibraryChangeFailed:
            return "Photos did not apply the requested change."
        case .unsupportedAssetKind:
            return "This asset type is skipped to avoid losing Live Photo, RAW, or animated image data."
        case .noStorageSavings:
            return "The compressed photo would not save storage."
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { startIndex in
            Array(self[startIndex..<Swift.min(startIndex + size, count)])
        }
    }
}
