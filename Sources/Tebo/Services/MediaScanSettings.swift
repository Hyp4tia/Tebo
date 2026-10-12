import Foundation

/// Typed, read-only options verified against the bundled Czkawka 12.0.2 CLI.
public struct MediaScanSettings: Codable, Hashable, Sendable {
    var included = [NSHomeDirectory()]
    var excluded: [String] = []
    var references: [String] = []
    var recursive = true
    var extensions = ""
    var excludedExtensions = ""
    var excludedPatterns = "*/.git/*"
    var minimumBytes: Int64? = nil
    var maximumBytes: Int64? = nil
    var threads = 0
    var duplicateMethod: CzkawkaDupSearchMethod = .hash
    var duplicateHash = "BLAKE3"
    var imageDifference = 5
    var imageHashSize = 16
    var imageHash = "Gradient"
    var imageFilter = "Nearest"
    var geometricInvariance = "off"
    var ignoreSameSize = false
    var ignoreSameResolution = false
    var musicContent = false
    var musicTags = "track_title,track_artist"
    var approximateTags = false
    var musicSegment = 10.0
    var musicDifference = 2.0
    var videoAudio = false
    var videoDifference = 10
    var videoSkip = 15
    var videoDuration = 10
    var videoWindows = 5
    var videoDurationTolerance = 20.0
    var videoMatchingWindows = 0.6
    var videoAudioSimilarity = 80.0
    var videoAudioDifference = 3.0
    var videoAudioLengthRatio = 0.1
    var videoAudioMinimumDuration = 10.0
    var videoCropDetection = true
    var bigFileCount = 50
    var smallestFiles = false
    var ignoredExifTags = ""
    var excludedVideoCodecs = "h265,av1,vp9"
    var cropMechanism = "blackbars"
    var blackPixelThreshold = 32
    var blackBarPercentage = 90
    var cropSamples = 20
    var minimumCropSize = 10

    var scanDirectories: [URL] { Array(Set(included + references)).sorted().map { URL(fileURLWithPath: $0) } }
    var scope: [String] {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return [String(data: (try? encoder.encode(self)) ?? Data(), encoding: .utf8) ?? ""]
    }

    func isReference(_ path: String) -> Bool {
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return references.contains {
            let root = URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
            return candidate == root || candidate.hasPrefix(root == "/" ? root : root + "/")
        }
    }

    func commonArguments(for tool: CzkawkaTool) throws -> [String] {
        guard !included.isEmpty, (included + excluded + references).allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
              minimumBytes.map({ $0 >= 1 }) ?? true, maximumBytes.map({ $0 >= max(1, minimumBytes ?? 1) }) ?? true else {
            throw MediaSettingsError.invalid("Choose absolute folder paths and a size range of at least one byte. Use Empty Files to find zero-byte files.")
        }
        var args = ["-T", String(max(0, min(threads, 128)))]
        for path in excluded { args += ["-e", path] }
        func tokens(_ value: String) throws -> [String] {
            let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard parts.allSatisfy({ !$0.hasPrefix("-") && !$0.contains("\0") }) else {
                throw MediaSettingsError.invalid("Filter values cannot start with a dash.")
            }
            return parts
        }
        for (flag, value) in [("-x", extensions), ("-P", excludedExtensions), ("-E", excludedPatterns)] {
            let values = try tokens(value)
            if !values.isEmpty { args += [flag] + values }
        }
        if !recursive { args += ["-R"] }
        if [.duplicates, .similarImages, .similarMusic, .similarVideos].contains(tool) {
            if let minimumBytes { args += ["-m", String(minimumBytes)] }
            if let maximumBytes { args += ["-i", String(maximumBytes)] }
        }
        return args
    }

    func toolArguments(for tool: CzkawkaTool) throws -> [String] {
        func choice(_ value: String, _ allowed: [String]) throws -> String {
            guard allowed.contains(value) else { throw MediaSettingsError.invalid("Unsupported scan option: " + value) }
            return value
        }
        switch tool {
        case .duplicates:
            return ["-s", duplicateMethod.clapValue, "-t", try choice(duplicateHash, ["BLAKE3", "CRC32", "XXH3"])]
        case .similarImages:
            var args = ["-s", String(max(0, min(imageDifference, 40))), "-c", String([8,16,32,64].contains(imageHashSize) ? imageHashSize : 16),
                        "-g", try choice(imageHash, ["Mean", "Gradient", "Blockhash", "VertGradient", "DoubleGradient", "Median"]),
                        "-z", try choice(imageFilter, ["Lanczos3", "Nearest", "Triangle", "Gaussian", "CatmullRom"]),
                        "--geometric-invariance", try choice(geometricInvariance, ["off", "mirror-flip", "mirror-flip-rotate90"])]
            if ignoreSameSize { args += ["-J"] }; if ignoreSameResolution { args += ["-Z"] }
            return args
        case .similarMusic:
            var args = ["-s", musicContent ? "CONTENT" : "TAGS"]
            if musicContent { args += ["-l", String(max(0.1, min(musicSegment, 300))), "-Y", String(max(0, min(musicDifference, 10)))] }
            else {
                let tags = musicTags.split(separator: ",").map(String.init)
                guard !tags.isEmpty, tags.allSatisfy({ ["track_title", "track_artist", "year", "bitrate", "genre", "length"].contains($0) }) else {
                    throw MediaSettingsError.invalid("Select at least one supported music tag.")
                }
                args += ["-z", tags.joined(separator: ",")]
                if approximateTags { args += ["-a"] }
            }
            return args
        case .similarVideos:
            var args = ["-t", String(max(0, min(videoDifference, 20))), "-U", String(max(0, min(videoSkip, 300))),
                        "-A", String(max(1, min(videoDuration, 300))), "-B", videoCropDetection ? "true" : "false",
                        "--window-count", String(max(1, min(videoWindows, 20))), "--duration-tolerance-pct", String(max(0, min(videoDurationTolerance, 100))),
                        "--min-matching-windows", String(max(0, min(videoMatchingWindows, 1)))]
            if videoAudio { args += ["--check-audio-content", "--audio-similarity-percent", String(max(0, min(videoAudioSimilarity, 100))),
                                    "--audio-maximum-difference", String(max(0, min(videoAudioDifference, 10))),
                                    "--audio-length-ratio", String(max(0, min(videoAudioLengthRatio, 1))),
                                    "--audio-min-duration-seconds", String(max(1, min(videoAudioMinimumDuration, 300)))] }
            if ignoreSameSize { args += ["-J"] }; if ignoreSameResolution { args += ["-Z"] }
            return args
        case .bigFiles: return ["-n", String(max(1, min(bigFileCount, 10000)))] + (smallestFiles ? ["-J"] : [])
        case .badNames: return tool.extraClapFlags
        case .exifMetadata:
            guard !ignoredExifTags.hasPrefix("-") else { throw MediaSettingsError.invalid("Invalid ignored tags.") }
            return ignoredExifTags.isEmpty ? [] : ["-i", ignoredExifTags]
        case .videoTranscode:
            guard !excludedVideoCodecs.hasPrefix("-") else { throw MediaSettingsError.invalid("Invalid codec filter.") }
            return ["transcode", "-c", excludedVideoCodecs]
        case .videoCrop:
            return ["crop", "-m", try choice(cropMechanism, ["blackbars", "staticcontent"]),
                    "-k", String(max(0, min(blackPixelThreshold, 128))), "-b", String(max(50, min(blackBarPercentage, 100))),
                    "-s", String(max(5, min(cropSamples, 1000))), "-z", String(max(1, min(minimumCropSize, 1000)))]
        default: return []
        }
    }
}

enum MediaSettingsError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}
