import Darwin
import Foundation
import ImageIO

struct MediaFileSnapshot: Sendable, Equatable {
    let identity: FileIdentity
    let size: Int64
    let modified: Date
    let isDirectory: Bool
    static func read(_ path: String) -> Self? {
        guard let identity = FileIdentity.read(path: path), let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType, [.typeRegular, .typeDirectory].contains(type),
              let size = (attributes[.size] as? NSNumber)?.int64Value, let modified = attributes[.modificationDate] as? Date else { return nil }
        return .init(identity: identity, size: size, modified: modified, isDirectory: type == .typeDirectory)
    }
}

struct MediaExportOptions: Sendable {
    var codec = "h264"
    var quality = 23
    var maxWidth = 1920
    var maxHeight = 1080
    var limitSize = false
    var requireSmaller = false
    var ignoredExifTags: Set<String> = []
}

enum MediaExportResult: Sendable { case preview, exported(URL) }
enum MediaExportError: LocalizedError {
    case refused(String)
    var errorDescription: String? { if case .refused(let reason) = self { reason } else { nil } }
}

/// Exports into a fresh, exclusive filename. Never rewrites or removes a source.
struct MediaExportService: Sendable {
    let ffmpegPath: String?
    func export(item: CzkawkaItem, expected: MediaFileSnapshot, to folder: URL, options: MediaExportOptions,
                preview: Bool, whitelist: Set<String>, references: [String] = []) async throws -> MediaExportResult {
        guard !expected.isDirectory, PathValidator.validate(path: item.path, whitelist: whitelist) == nil,
              MediaFileSnapshot.read(item.path) == expected else { throw MediaExportError.refused("Source changed or is protected. Scan again.") }
        if preview { return .preview }
        var referenceSettings = MediaScanSettings(); referenceSettings.references = references
        guard folder.isFileURL, !referenceSettings.isReference(folder.path), PathValidator.validate(path: folder.path, whitelist: whitelist) == nil,
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw MediaExportError.refused("Choose an existing output folder that is not protected.")
        }
        let fm = FileManager.default
        let stageFolder = folder.appendingPathComponent(".tebo-export-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stageFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stageFolder) }
        let suffix = item.tool == .exifMetadata ? URL(fileURLWithPath: item.path).pathExtension : options.codec == "vp9" ? "webm" : "mp4"
        let staged = stageFolder.appendingPathComponent("output." + suffix)
        if item.tool == .exifMetadata {
            try await Task.detached(priority: .utility) { try stripMetadata(source: URL(fileURLWithPath: item.path), to: staged, preserving: options.ignoredExifTags) }.value
        } else {
            guard item.tool == .videoTranscode || item.tool == .videoCrop, let ffmpegPath else {
                throw MediaExportError.refused("Video export requires ffmpeg.")
            }
            let codecs = ["h264": "libx264", "h265": "libx265", "av1": "libaom-av1", "vp9": "libvpx-vp9"]
            guard let encoder = codecs[options.codec] else { throw MediaExportError.refused("Unsupported output codec.") }
            var filters: [String] = []
            if item.tool == .videoCrop {
                guard case .videoOptimization(let width, let height, _, let bounds)? = item.detail,
                      let bounds, bounds.isValid(width: width, height: height) else {
                    throw MediaExportError.refused("No valid crop plan. Scan again.")
                }
                filters.append("crop=\(bounds.width):\(bounds.height):\(bounds.left):\(bounds.top)")
            }
            if options.limitSize {
                let w = max(2, min(options.maxWidth, 16384)), h = max(2, min(options.maxHeight, 16384))
                filters.append("scale=w='min(iw,\(w))':h='min(ih,\(h))':force_original_aspect_ratio=decrease:force_divisible_by=2")
            }
            var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-protocol_whitelist", "file,pipe", "-i", item.path, "-map", "0:v:0", "-map", "0:a?",
                        "-map_metadata", "0", "-c:v", encoder, "-crf", String(max(0, min(options.quality, 51))),
                        "-c:a", options.codec == "vp9" ? "libopus" : "aac", "-pix_fmt", "yuv420p"]
            if ["av1", "vp9"].contains(options.codec) { args += ["-b:v", "0"] }
            if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
            if options.codec != "vp9" { args += ["-movflags", "+faststart"] }
            args += [staged.path]
            let result = await BoundedProcessRunner.run(executablePath: ffmpegPath, arguments: args, timeout: nil)
            try Task.checkCancellation()
            guard result.terminationStatus == 0 else { throw MediaExportError.refused("Video export failed: " + result.stderr.suffix(1500)) }
        }
        try Task.checkCancellation()
        guard MediaFileSnapshot.read(item.path) == expected else { throw MediaExportError.refused("Source changed during export. No copy published.") }
        let bytes = ((try fm.attributesOfItem(atPath: staged.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else { throw MediaExportError.refused("Export produced no usable file.") }
        guard item.tool == .exifMetadata || !options.requireSmaller || bytes < expected.size else { throw MediaExportError.refused("The new copy is not smaller. Original kept.") }
        let source = URL(fileURLWithPath: item.path)
        let output = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-tebo-" + UUID().uuidString.prefix(8) + "." + suffix)
        try Task.checkCancellation()
        guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, output.path, UInt32(RENAME_EXCL)) == 0 else {
            throw MediaExportError.refused("Could not save the copy without overwriting an existing file.")
        }
        return .exported(output)
    }

    private func stripMetadata(source: URL, to output: URL, preserving: Set<String>) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(imageSource),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, CGImageSourceGetCount(imageSource), nil) else {
            throw MediaExportError.refused("This image format cannot be exported with ImageIO.")
        }
        let metadata = CGImageMetadataCreateMutable()
        if !preserving.isEmpty, let original = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil) {
            CGImageMetadataEnumerateTagsUsingBlock(original, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
                if let name = CGImageMetadataTagCopyName(tag), preserving.contains(name as String) {
                    CGImageMetadataSetTagWithPath(metadata, nil, path, tag)
                }
                return true
            }
        }
        let copyOptions: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false]
        if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
           let orientation = properties[kCGImagePropertyOrientation] {
            CGImageMetadataSetValueWithPath(metadata, nil, "tiff:Orientation" as CFString, orientation as CFTypeRef)
        }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, imageSource, copyOptions as CFDictionary, &error) else {
            throw MediaExportError.refused(error?.takeRetainedValue().localizedDescription ?? "Image metadata export failed.")
        }
    }
}
