import AppKit
import SwiftUI

struct MediaScanControls: View {
    @Binding var settings: MediaScanSettings
    let tool: CzkawkaTool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            folders("Included folders", paths: $settings.included)
            Toggle("Include subfolders", isOn: $settings.recursive).font(.caption)
            DisclosureGroup("Excluded and reference folders") {
                VStack(alignment: .leading, spacing: 12) {
                    folders("Excluded folders", paths: $settings.excluded)
                    folders("Reference folders", paths: $settings.references)
                    Text("Reference folders are scanned for comparison and always kept.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }
            DisclosureGroup("Scan filters") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Allowed extensions, comma-separated", text: $settings.extensions)
                    TextField("Excluded extensions, comma-separated", text: $settings.excludedExtensions)
                    TextField("Excluded patterns, comma-separated", text: $settings.excludedPatterns)
                    if [.duplicates, .similarImages, .similarVideos, .similarMusic].contains(tool) {
                        HStack {
                            TextField("Minimum bytes", value: $settings.minimumBytes, format: .number)
                            TextField("Maximum bytes", value: $settings.maximumBytes, format: .number)
                        }
                        Text("Blank size limits use the engine defaults.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Stepper("CPU threads: \(settings.threads == 0 ? "Auto" : String(settings.threads))", value: $settings.threads, in: 0...128)
                    Button("Reset filters and comparisons") {
                        var defaults = MediaScanSettings()
                        defaults.included = settings.included; defaults.excluded = settings.excluded; defaults.references = settings.references
                        settings = defaults
                    }.controlSize(.small)
                }.textFieldStyle(.roundedBorder).padding(.top, 10)
            }
            if [.duplicates, .similarImages, .similarMusic, .similarVideos, .bigFiles, .exifMetadata, .videoTranscode, .videoCrop].contains(tool) {
                DisclosureGroup("\(tool.isExportTool ? "Detection" : "Comparison") options") {
                    options.padding(.top, 10)
                }
            }
        }.font(.callout).teboCard(padding: 12)
    }
    private func folders(_ title: String, paths: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                if !paths.wrappedValue.isEmpty { Button("Clear") { paths.wrappedValue = [] }.controlSize(.small) }
                Button("Choose…") { choose(paths) }.controlSize(.small).accessibilityLabel("Choose " + title.lowercased())
            }
            Text(paths.wrappedValue.isEmpty ? "None" : paths.wrappedValue.map(TeboPath.abbreviate).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
        }
    }
    private func choose(_ paths: Binding<[String]>) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Use these folders"
        if panel.runModal() == .OK { paths.wrappedValue = panel.urls.map(\.path) }
    }
    @ViewBuilder private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch tool {
            case .duplicates:
                Picker("Compare", selection: $settings.duplicateMethod) {
                    Text("Content hash").tag(CzkawkaDupSearchMethod.hash); Text("Size").tag(CzkawkaDupSearchMethod.size)
                    Text("Name").tag(CzkawkaDupSearchMethod.name); Text("Size and name").tag(CzkawkaDupSearchMethod.sizeName)
                }
                choice("Hash", value: $settings.duplicateHash, choices: ["BLAKE3", "CRC32", "XXH3"])
                if settings.duplicateMethod != .hash { Text("Names and sizes can match even when content differs. Review these groups manually.").font(.caption).foregroundStyle(.secondary) }
            case .similarImages:
                Stepper("Maximum difference: \(settings.imageDifference)", value: $settings.imageDifference, in: 0...40)
                Picker("Hash size", selection: $settings.imageHashSize) { ForEach([8,16,32,64], id: \.self) { Text(String($0)).tag($0) } }
                choice("Hash algorithm", value: $settings.imageHash, choices: ["Mean", "Gradient", "Blockhash", "VertGradient", "DoubleGradient", "Median"])
                choice("Resize filter", value: $settings.imageFilter, choices: ["Nearest", "Lanczos3", "Triangle", "Gaussian", "CatmullRom"])
                choice("Rotation and reflection", value: $settings.geometricInvariance, choices: ["off", "mirror-flip", "mirror-flip-rotate90"])
                sameSizeToggles
                Text("0 means identical image hashes. Higher differences allow looser matches.").font(.caption).foregroundStyle(.secondary)
            case .similarMusic:
                Toggle("Compare audio fingerprints", isOn: $settings.musicContent)
                if settings.musicContent {
                    TextField("Minimum segment, seconds", value: $settings.musicSegment, format: .number)
                    TextField("Maximum fingerprint difference", value: $settings.musicDifference, format: .number)
                } else {
                    TextField("Tags: track_title,track_artist,year,bitrate,genre,length", text: $settings.musicTags)
                    Toggle("Approximate tag comparison", isOn: $settings.approximateTags)
                }
            case .similarVideos:
                videoOptions
            case .bigFiles:
                Stepper("Files to list: \(settings.bigFileCount)", value: $settings.bigFileCount, in: 1...10000)
                Toggle("Find smallest files instead", isOn: $settings.smallestFiles)
            case .exifMetadata:
                TextField("Keep tag names, comma-separated", text: $settings.ignoredExifTags)
                Text("Specified tags and essential image orientation are preserved in exported copies.").font(.caption).foregroundStyle(.secondary)
            case .videoTranscode:
                TextField("Excluded source codecs, comma-separated", text: $settings.excludedVideoCodecs)
            case .videoCrop:
                choice("Detect", value: $settings.cropMechanism, choices: ["blackbars", "staticcontent"])
                Stepper("Black threshold: \(settings.blackPixelThreshold)", value: $settings.blackPixelThreshold, in: 0...128)
                Stepper("Bar coverage: \(settings.blackBarPercentage)%", value: $settings.blackBarPercentage, in: 50...100)
                Stepper("Samples: \(settings.cropSamples)", value: $settings.cropSamples, in: 5...1000)
                Stepper("Minimum crop: \(settings.minimumCropSize) px", value: $settings.minimumCropSize, in: 1...1000)
            default: EmptyView()
            }
        }.textFieldStyle(.roundedBorder)
    }
    private var sameSizeToggles: some View {
        VStack(alignment: .leading) {
            Toggle("Ignore matching byte sizes", isOn: $settings.ignoreSameSize)
            Toggle("Ignore matching resolutions", isOn: $settings.ignoreSameResolution)
        }
    }
    private var videoOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Compare by audio fingerprint", isOn: $settings.videoAudio)
            if settings.videoAudio {
                TextField("Required audio match, %", value: $settings.videoAudioSimilarity, format: .number)
                TextField("Maximum audio difference", value: $settings.videoAudioDifference, format: .number)
                TextField("Minimum length ratio", value: $settings.videoAudioLengthRatio, format: .number)
                TextField("Minimum duration, seconds", value: $settings.videoAudioMinimumDuration, format: .number)
            } else {
                Stepper("Maximum difference: \(settings.videoDifference)", value: $settings.videoDifference, in: 0...20)
                Stepper("Skip first \(settings.videoSkip) seconds", value: $settings.videoSkip, in: 0...300)
                Stepper("Sample \(settings.videoDuration) seconds", value: $settings.videoDuration, in: 1...300)
                Stepper("Temporal windows: \(settings.videoWindows)", value: $settings.videoWindows, in: 1...20)
                TextField("Duration tolerance, %", value: $settings.videoDurationTolerance, format: .number)
                TextField("Required matching windows, 0–1", value: $settings.videoMatchingWindows, format: .number)
                Toggle("Detect letterbox borders", isOn: $settings.videoCropDetection)
            }
            sameSizeToggles
        }
    }
    private func choice(_ title: String, value: Binding<String>, choices: [String]) -> some View {
        Picker(title, selection: value) { ForEach(choices, id: \.self) { Text($0).tag($0) } }
    }
}

@MainActor enum MediaSettingsStore {
    private static let key = "media.scan.settings"
    static func load() -> MediaScanSettings {
        guard let data = UserDefaults.standard.data(forKey: key), let settings = try? JSONDecoder().decode(MediaScanSettings.self, from: data) else { return .init() }
        return settings
    }
    static func save(_ settings: MediaScanSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: key) }
    }
    static func exportTool() -> CzkawkaTool {
        guard let name = UserDefaults.standard.string(forKey: "media.export.tool"),
              let tool = CzkawkaTool(rawValue: name), tool.isExportTool else { return .exifMetadata }
        return tool
    }
    static func saveExportTool(_ tool: CzkawkaTool) { UserDefaults.standard.set(tool.rawValue, forKey: "media.export.tool") }
}
