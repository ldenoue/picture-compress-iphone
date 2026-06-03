import Photos
import SwiftUI

private struct MaxSideOption: Identifiable, Hashable {
    let pixels: Int
    let title: String
    let detail: String

    var id: Int { pixels }
}

struct ContentView: View {
    private let maxSideOptions = [
        MaxSideOption(pixels: 1280, title: "1280 px", detail: "Small"),
        MaxSideOption(pixels: 2048, title: "2048 px", detail: "Balanced"),
        MaxSideOption(pixels: 2560, title: "2560 px", detail: "Detailed"),
        MaxSideOption(pixels: 3840, title: "3840 px", detail: "4K")
    ]

    @StateObject private var library = PhotoLibraryCompressor()
    @State private var maxSidePixels = 2048
    @State private var quality = 0.78
    @State private var exportFormat: ExportFormat = .heic

    var body: some View {
        NavigationStack {
            List {
                Section {
                    permissionRow
                }

                Section {
                    savingsGauge
                }

                Section("Compression Settings") {
                    Picker("Format", selection: $exportFormat) {
                        ForEach(ExportFormat.allCases) { format in
                            Text("\(format.displayName) - \(format.detail)")
                                .tag(format)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Max side", selection: $maxSidePixels) {
                        ForEach(maxSideOptions) { option in
                            Text("\(option.title) - \(option.detail)")
                                .tag(option.pixels)
                        }
                    }
                    .pickerStyle(.menu)

                    VStack(alignment: .leading) {
                        HStack {
                            Text("\(exportFormat.displayName) quality")
                            Spacer()
                            Text("\(Int(quality * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $quality, in: 0.35...0.95)
                    }
                }

                Section {
                    Button {
                        Task {
                            await library.scan(maxPixelSize: maxSidePixels, quality: quality, format: exportFormat)
                        }
                    } label: {
                        Label("Estimate Savings", systemImage: "magnifyingglass")
                    }
                    .disabled(!library.canAccessPhotos || library.isBusy)

                    Button(role: .destructive) {
                        Task {
                            await library.compressAndReplace(maxPixelSize: maxSidePixels, quality: quality, format: exportFormat)
                        }
                    } label: {
                        Label("Compress and Replace Originals", systemImage: "arrow.triangle.2.circlepath.camera")
                    }
                    .disabled(!library.canAccessPhotos || library.isBusy)
                } footer: {
                    Text("You can estimate first, or compress directly in one pass. iOS does not allow apps to rewrite a Photos original in place, so this prepares bounded batches of compressed replacements, then asks Photos to save each batch and delete its originals.")
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

    private var savingsGauge: some View {
        VStack(spacing: 12) {
            Gauge(value: library.estimatedSavingsRatio, in: 0...1) {
                Text("Savings")
            } currentValueLabel: {
                Text(library.estimatedSavingsPercent)
                    .font(.headline)
            } minimumValueLabel: {
                Text("0")
            } maximumValueLabel: {
                Text("100%")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(.blue)
            .frame(maxWidth: .infinity)

            VStack(spacing: 3) {
                Text(library.formatted(library.estimatedSavingsBytes))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .contentTransition(.numericText())
                Text(library.savingsGaugeCaption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 6)
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
