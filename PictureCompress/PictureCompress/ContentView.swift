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
    @State private var isShowingReplaceConfirmation = false

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

            }
            .navigationTitle("Photo Squeeze")
            .task {
                await library.refreshAuthorization()
            }
            .alert(replaceConfirmationTitle, isPresented: $isShowingReplaceConfirmation) {
                Button(replaceConfirmationButtonTitle, role: .destructive) {
                    Task {
                        await library.compressAndReplace(maxPixelSize: maxSidePixels, quality: quality, format: exportFormat)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Photo Squeeze will create compressed replacements, then remove the originals after Photos asks for permission.")
            }
        }
    }

    private var replaceConfirmationTitle: String {
        guard library.estimatedSavingsBytes > 0 else {
            return "Replace originals with compressed versions?"
        }

        return "Replace originals with compressed versions and save \(library.formatted(library.estimatedSavingsBytes))?"
    }

    private var replaceConfirmationButtonTitle: String {
        guard library.estimatedSavingsBytes > 0 else {
            return "Replace Originals"
        }

        return "Save \(library.formatted(library.estimatedSavingsBytes))"
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

            HStack(spacing: 12) {
                Button {
                    Task {
                        await library.scan(maxPixelSize: maxSidePixels, quality: quality, format: exportFormat)
                    }
                } label: {
                    Label("ESTIMATE", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(!library.canAccessPhotos || library.isBusy)

                Button(role: .destructive) {
                    isShowingReplaceConfirmation = true
                } label: {
                    Label("COMPRESS", systemImage: "arrow.triangle.2.circlepath.camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(.red)
                .disabled(!library.canAccessPhotos || library.isBusy)
            }
            .controlSize(.large)
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
