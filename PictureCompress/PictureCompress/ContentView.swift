import Photos
import SwiftUI

struct ContentView: View {
    @StateObject private var library = PhotoLibraryCompressor()
    @State private var maxDimension = 1280.0
    @State private var jpegQuality = 0.78

    var body: some View {
        NavigationStack {
            List {
                Section {
                    permissionRow
                }

                Section("Compression Settings") {
                    Stepper(value: $maxDimension, in: 640...4096, step: 160) {
                        HStack {
                            Text("Max side")
                            Spacer()
                            Text("\(Int(maxDimension)) px")
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("JPEG quality")
                            Spacer()
                            Text("\(Int(jpegQuality * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $jpegQuality, in: 0.35...0.95)
                    }
                }

                Section {
                    Button {
                        Task {
                            await library.scan(maxPixelSize: Int(maxDimension), jpegQuality: jpegQuality)
                        }
                    } label: {
                        Label("Estimate Savings", systemImage: "magnifyingglass")
                    }
                    .disabled(!library.canAccessPhotos || library.isBusy)

                    Button(role: .destructive) {
                        Task {
                            await library.compressAndReplace(maxPixelSize: Int(maxDimension), jpegQuality: jpegQuality)
                        }
                    } label: {
                        Label("Compress and Replace Originals", systemImage: "arrow.triangle.2.circlepath.camera")
                    }
                    .disabled(!library.canAccessPhotos || library.estimates.isEmpty || library.isBusy)
                } footer: {
                    Text("iOS does not allow apps to rewrite a Photos original in place. This prepares bounded batches of compressed replacements, then asks Photos to save each batch and delete its originals.")
                }

                if library.isBusy {
                    Section("Progress") {
                        ProgressView(value: library.progress)
                        Text(library.statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Estimate") {
                    metricRow("Photos scanned", value: "\(library.estimates.count)")
                    metricRow("Current size", value: library.formatted(library.totalOriginalBytes))
                    metricRow("Compressed size", value: library.formatted(library.totalCompressedBytes))
                    metricRow("Potential savings", value: library.formatted(library.estimatedSavingsBytes))
                    metricRow("Savings", value: library.estimatedSavingsPercent)
                }

                if !library.estimates.isEmpty {
                    Section("Largest Savings") {
                        ForEach(library.estimates.prefix(20)) { estimate in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(estimate.displayName)
                                    .font(.headline)
                                Text("\(library.formatted(estimate.originalBytes)) -> \(library.formatted(estimate.compressedBytes))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !library.messages.isEmpty {
                    Section("Log") {
                        ForEach(library.messages, id: \.self) { message in
                            Text(message)
                                .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("Photo Squeeze")
            .task {
                await library.refreshAuthorization()
            }
        }
    }

    private var permissionRow: some View {
        HStack {
            Label(library.authorizationSummary, systemImage: library.canAccessPhotos ? "checkmark.circle" : "photo.badge.exclamationmark")
            Spacer()
            if !library.canAccessPhotos {
                Button("Allow") {
                    Task {
                        await library.requestAuthorization()
                    }
                }
            }
        }
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
