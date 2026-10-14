import Foundation
import ImageIO
import Testing
@testable import Tebo

// Shares the serialized parent with bridge tests that inspect global engine processes/temp files.
extension CzkawkaBridgeTests {
@Suite("Krokiet media integration")
struct MediaIntegrationTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let engine = Self.repo.appendingPathComponent("Engines/czkawka_cli")
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tebo-media-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func fixture(_ name: String, in root: URL) throws -> URL {
        let result = root.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Self.repo.appendingPathComponent("Tests/Fixtures/media/" + name), to: result)
        return result
    }
    @Test("Captured EXIF and crop reports preserve actual tags and crop bounds")
    func capturedReports() throws {
        let exif = try CzkawkaJSON.items(in: Data(contentsOf: Self.repo.appendingPathComponent("Tests/Fixtures/czkawka/exif.json")), tool: .exifMetadata)
        #expect(exif.count == 1)
        if case .exifMetadata(let tags)? = exif.first?.detail { #expect(tags.contains("GPSLatitude")); #expect(tags.contains("Model")) }
        else { Issue.record("EXIF tags missing") }
        let cropped = try CzkawkaJSON.items(in: Data(contentsOf: Self.repo.appendingPathComponent("Tests/Fixtures/czkawka/video-crop.json")), tool: .videoCrop)
        #expect(cropped.count == 1)
        if case .videoOptimization(let width, let height, _, let crop)? = cropped.first?.detail {
            #expect(width == 200); #expect(height == 140); #expect(crop?.width == 160); #expect(crop?.height == 100)
        } else { Issue.record("Crop plan missing") }
    }
    @Test("Typed filters reject option injection and invalid ranges; scope encoding is stable")
    func settingsValidation() throws {
        var settings = MediaScanSettings()
        #expect(settings.scope == settings.scope)
        settings.excludedPatterns = "-D"
        #expect(throws: (any Error).self) { try settings.commonArguments(for: .duplicates) }
        settings.excludedPatterns = "*/.git/*"; settings.minimumBytes = 200; settings.maximumBytes = 100
        #expect(throws: (any Error).self) { try settings.commonArguments(for: .duplicates) }
        settings.minimumBytes = nil; settings.maximumBytes = nil; settings.included = []
        #expect(throws: (any Error).self) { try settings.commonArguments(for: .duplicates) }
        settings.included = ["/tmp/fixture"]; settings.videoAudio = true
        let flags = try settings.toolArguments(for: .similarVideos)
        #expect(flags.contains("--check-audio-content"))
        for tool in CzkawkaTool.allCases {
            let args = try settings.commonArguments(for: tool) + settings.toolArguments(for: tool)
            #expect(!args.contains("-D") && !args.contains("-F") && !args.contains("-y") && !args.contains("--overwrite-original"))
        }
    }
    @Test("Reference-folder originals remain read-only and all editable duplicate copies can be selected")
    func referencesKept() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let working = dir.appendingPathComponent("working"), backup = dir.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let data = Data(repeating: 42, count: 16384)
        try data.write(to: working.appendingPathComponent("copy.bin")); try data.write(to: backup.appendingPathComponent("original.bin"))
        var settings = MediaScanSettings(); settings.included = [working.path]; settings.references = [backup.path]
        let report = try await MediaScanService(engineURL: engine).scan(tool: .duplicates, settings: settings, whitelist: [])
        #expect(report.rows.count == 1); #expect(report.rows.first?.recommendedForSelection == true)
        #expect(report.kept.contains { $0.source.hasSuffix("original.bin") && $0.detail.contains("Reference") })
        #expect(!report.rows.contains { settings.isReference($0.path) })
        let workingRow = try #require(report.rows.first)
        #expect(MediaScanService.removalReason(path: workingRow.path, tool: .duplicates, settings: settings, expected: report.snapshots[workingRow.id], referenceGuard: report.referenceGuards[workingRow.id]) == nil)
        try Data("changed reference content".utf8).write(to: backup.appendingPathComponent("original.bin"))
        #expect(MediaScanService.removalReason(path: workingRow.path, tool: .duplicates, settings: settings, expected: report.snapshots[workingRow.id], referenceGuard: report.referenceGuards[workingRow.id]) != nil)
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: backup)
        #expect(settings.isReference(alias.appendingPathComponent("original.bin").path))
    }
    @Test("Name/size matches with different content get no default removal recommendation")
    func coarseDuplicates() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 65, count: 16384).write(to: dir.appendingPathComponent("one.bin"))
        try Data(repeating: 66, count: 16384).write(to: dir.appendingPathComponent("two.bin"))
        var settings = MediaScanSettings(); settings.included = [dir.path]; settings.duplicateMethod = .size
        let report = try await MediaScanService(engineURL: engine).scan(tool: .duplicates, settings: settings, whitelist: [])
        #expect(report.rows.count == 2); #expect(report.rows.allSatisfy { !$0.recommendedForSelection && $0.reason.contains("content may differ") })
        settings.duplicateMethod = .hash
        #expect(try await MediaScanService(engineURL: engine).scan(tool: .duplicates, settings: settings, whitelist: []).rows.isEmpty)
    }
    @Test("Real extension, size and folder filters change actual engine results")
    func actualFilters() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data(repeating: 1, count: 16384)
        try data.write(to: dir.appendingPathComponent("one.bin")); try data.write(to: dir.appendingPathComponent("two.bin"))
        var settings = MediaScanSettings(); settings.included = [dir.path]; settings.extensions = "bin"
        #expect(try await MediaScanService(engineURL: engine).scan(tool: .duplicates, settings: settings, whitelist: []).rows.count == 2)
        settings.minimumBytes = 32768
        #expect(try await MediaScanService(engineURL: engine).scan(tool: .duplicates, settings: settings, whitelist: []).rows.isEmpty)
        settings.minimumBytes = 1; settings.extensions = "jpg"
        #expect(try await MediaScanService(engineURL: engine).scan(tool: .duplicates, settings: settings, whitelist: []).rows.isEmpty)
    }
    @Test("Metadata export removes private tags, preserves pixels, and never changes the source")
    func metadataCopy() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture("metadata.jpg", in: dir), before = try Data(contentsOf: source)
        let output = dir.appendingPathComponent("exports"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let snapshot = try #require(MediaFileSnapshot.read(source.path))
        let item = CzkawkaItem(path: source.path, sizeBytes: snapshot.size, tool: .exifMetadata)
        let service = MediaExportService(ffmpegPath: nil)
        _ = try await service.export(item: item, expected: snapshot, to: output, options: .init(), preview: true, whitelist: [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        let result = try await service.export(item: item, expected: snapshot, to: output, options: .init(), preview: false, whitelist: [])
        guard case .exported(let url) = result else { Issue.record("Export was only previewed"); return }
        #expect(try Data(contentsOf: source) == before)
        let original = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let copied = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(copied, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil)
        let a = try #require(CGImageSourceCreateImageAtIndex(original, 0, nil)), b = try #require(CGImageSourceCreateImageAtIndex(copied, 0, nil))
        #expect(a.width == b.width && a.height == b.height)
        #expect((a.dataProvider?.data as Data?) == (b.dataProvider?.data as Data?))
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).count == 1)
        await #expect(throws: (any Error).self) {
            try await service.export(item: item, expected: snapshot, to: output, options: .init(), preview: false, whitelist: [output.path])
        }
        await #expect(throws: (any Error).self) {
            try await service.export(item: item, expected: snapshot, to: output, options: .init(), preview: false, whitelist: [], references: [output.path])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).count == 1)
    }
    @Test("Metadata copies retain requested tags and essential orientation")
    func retainedMetadata() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture("metadata.jpg", in: dir)
        let original = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let rotated = dir.appendingPathComponent("rotated.jpg")
        let imageType = try #require(CGImageSourceGetType(original))
        let destination = try #require(CGImageDestinationCreateWithURL(rotated as CFURL, imageType, 1, nil))
        CGImageDestinationAddImageFromSource(destination, original, 0, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let snapshot = try #require(MediaFileSnapshot.read(rotated.path))
        let item = CzkawkaItem(path: rotated.path, sizeBytes: snapshot.size, tool: .exifMetadata)
        var options = MediaExportOptions(); options.ignoredExifTags = ["Model"]
        let result = try await MediaExportService(ffmpegPath: nil).export(item: item, expected: snapshot, to: dir, options: options, preview: false, whitelist: [])
        guard case .exported(let output) = result else { Issue.record("Copy missing"); return }
        let image = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
        #expect((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String == "Tebo fixture camera")
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    }
    @Test("Video size limits do not enlarge smaller videos", .enabled(if: EngineLocator.findFFmpeg() != nil))
    func transcodeSizeLimit() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture("bordered.mp4", in: dir), snapshot = try #require(MediaFileSnapshot.read(source.path))
        let item = CzkawkaItem(path: source.path, sizeBytes: snapshot.size, tool: .videoTranscode)
        var options = MediaExportOptions(); options.limitSize = true
        let result = try await MediaExportService(ffmpegPath: EngineLocator.findFFmpeg()).export(item: item, expected: snapshot, to: dir, options: options, preview: false, whitelist: [])
        guard case .exported(let output) = result else { Issue.record("Video missing"); return }
        let ffprobe = URL(fileURLWithPath: try #require(EngineLocator.findFFmpeg())).deletingLastPathComponent().appendingPathComponent("ffprobe")
        let probe = await BoundedProcessRunner.run(executablePath: ffprobe.path, arguments: ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", output.path], timeout: 10)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(probe.stdout.utf8)) as? [String: Any])
        let streams = try #require(object["streams"] as? [[String: Any]])
        #expect(streams.first?["width"] as? Int == 200); #expect(streams.first?["height"] as? Int == 140)
    }
    @Test("Export refuses a changed source even in Preview")
    func changedSource() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture("metadata.jpg", in: dir), snapshot = try #require(MediaFileSnapshot.read(source.path))
        let item = CzkawkaItem(path: source.path, sizeBytes: snapshot.size, tool: .exifMetadata)
        try Data("different content".utf8).write(to: source)
        await #expect(throws: (any Error).self) {
            try await MediaExportService(ffmpegPath: nil).export(item: item, expected: snapshot, to: dir, options: .init(), preview: true, whitelist: [])
        }
    }
    @Test("Portable release helpers export all four codecs without external tool paths",
          .enabled(if: FileManager.default.isExecutableFile(atPath: Self.repo.appendingPathComponent(".build/video-helpers/bin/ffmpeg").path)))
    func portableCodecs() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture("bordered.mp4", in: dir), before = try Data(contentsOf: source)
        let snapshot = try #require(MediaFileSnapshot.read(source.path))
        let item = CzkawkaItem(path: source.path, sizeBytes: snapshot.size, tool: .videoTranscode)
        let helpers = Self.repo.appendingPathComponent(".build/video-helpers/bin")
        for (codec, expected) in [("h264", "h264"), ("h265", "hevc"), ("vp9", "vp9"), ("av1", "av1")] {
            var options = MediaExportOptions(); options.codec = codec
            let result = try await MediaExportService(ffmpegPath: helpers.appendingPathComponent("ffmpeg").path)
                .export(item: item, expected: snapshot, to: dir, options: options, preview: false, whitelist: [])
            guard case .exported(let output) = result else { Issue.record("Missing codec output: \(codec)"); continue }
            let probe = await BoundedProcessRunner.run(executablePath: helpers.appendingPathComponent("ffprobe").path,
                arguments: ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height", "-of", "json", output.path],
                timeout: 10, environment: ["PATH": "/usr/bin:/bin"])
            #expect(probe.terminationStatus == 0)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(probe.stdout.utf8)) as? [String: Any])
            let streams = try #require(object["streams"] as? [[String: Any]])
            #expect(streams.first?["codec_name"] as? String == expected)
            #expect(streams.first?["width"] as? Int == 200)
            #expect(streams.first?["height"] as? Int == 140)
            #expect(try Data(contentsOf: source) == before)
        }
    }
    @Test("Actual video crop exports the detected rectangle without modifying the original", .enabled(if: EngineLocator.findFFmpeg() != nil))
    func cropCopy() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture("bordered.mp4", in: dir), before = try Data(contentsOf: source)
        var settings = MediaScanSettings(); settings.included = [dir.path]; settings.minimumCropSize = 1
        let report = try await MediaScanService(engineURL: engine).scan(tool: .videoCrop, settings: settings, whitelist: [])
        let row = try #require(report.rows.first), detail = try #require(report.details[row.id])
        let item = CzkawkaItem(path: row.path, sizeBytes: row.sizeBytes, tool: .videoCrop, detail: detail)
        let snapshot = try #require(MediaFileSnapshot.read(source.path))
        let result = try await MediaExportService(ffmpegPath: EngineLocator.findFFmpeg()).export(item: item, expected: snapshot, to: dir, options: .init(), preview: false, whitelist: [])
        guard case .exported(let output) = result else { Issue.record("Video not exported"); return }
        #expect(try Data(contentsOf: source) == before)
        let ffprobe = URL(fileURLWithPath: try #require(EngineLocator.findFFmpeg())).deletingLastPathComponent().appendingPathComponent("ffprobe")
        let probe = await BoundedProcessRunner.run(executablePath: ffprobe.path, arguments: ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", output.path], timeout: 10)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(probe.stdout.utf8)) as? [String: Any])
        let streams = try #require(json["streams"] as? [[String: Any]])
        #expect(streams.first?["width"] as? Int == 160); #expect(streams.first?["height"] as? Int == 100)
    }
    @Test("Edited media and folders that gained files stay kept at the Trash boundary")
    func removalRecheck() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture("metadata.jpg", in: dir), snapshot = try #require(MediaFileSnapshot.read(source.path))
        let settings = MediaScanSettings()
        #expect(MediaScanService.removalReason(path: source.path, tool: .duplicates, settings: settings, expected: snapshot) == nil)
        try Data("changed after preview".utf8).write(to: source)
        #expect(MediaScanService.removalReason(path: source.path, tool: .duplicates, settings: settings, expected: snapshot) != nil)
        let empty = dir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let folderSnapshot = try #require(MediaFileSnapshot.read(empty.path))
        #expect(MediaScanService.removalReason(path: empty.path, tool: .emptyFolders, settings: settings, expected: folderSnapshot) == nil)
        try Data("keep".utf8).write(to: empty.appendingPathComponent("new-file.txt"))
        #expect(MediaScanService.removalReason(path: empty.path, tool: .emptyFolders, settings: settings, expected: folderSnapshot) != nil)
    }
    @Test("All upstream tool families are reachable from six Media cleanup pages") @MainActor
    func routing() {
        #expect(CleanupWorkspace.images.rawValue == "Media cleanup")
        #expect(CleanupWorkspace.images.pages.count == 6)
        let keys = Set(CleanupWorkspace.images.pages.flatMap(\.resultTabIDs))
        #expect(Set(CzkawkaTool.allCases.map(\.tabID)).isSubset(of: keys))
    }
}

}
