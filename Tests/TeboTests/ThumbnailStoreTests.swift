import AppKit
import Foundation
import Testing

@testable import Tebo

// MARK: - Thumbnails
// The previews are the point of the Duplicates layouts, so the pipeline is proven on a real file
// instead of assumed.

@Suite("Thumbnails")
@MainActor
struct ThumbnailStoreTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-thumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePNG(at url: URL) throws {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        image.unlockFocus()
        let rep = try #require(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    @Test("a real image yields a preview")
    func realImageYieldsPreview() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sample.png")
        try writePNG(at: url)

        let thumbnail = await ThumbnailStore.shared.image(for: url.path, side: 128)

        #expect(thumbnail != nil, "QuickLook must be able to preview a plain PNG")
        #expect(ThumbnailStore.shared.cached(url.path, side: 128) != nil, "the preview is cached after use")
    }

    @Test("a document falls back to its Finder icon")
    func documentFallsBackToIcon() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)

        // Text is not previewable here, so this is the icon path, and it must still be an image.
        let icon = await ThumbnailStore.shared.image(for: url.path, side: 32)
        #expect(icon != nil)
    }

    @Test("a file that no longer exists yields nothing rather than a placeholder")
    func missingFileYieldsNil() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let thumbnail = await ThumbnailStore.shared.image(
            for: dir.appendingPathComponent("gone.png").path,
            side: 64
        )

        #expect(thumbnail == nil, "a deleted file must render as absent, not as a riddle")
    }

    @Test(
        "file kinds map to the symbol a person would guess",
        arguments: [
            ("/tmp/clip.mp4", "film"), ("/tmp/shot.png", "photo"),
            ("/tmp/song.flac", "music.note"), ("/tmp/archive.zip", "shippingbox"),
            ("/tmp/notes.md", "doc.text"), ("/tmp/Some.app", "app"),
            ("/tmp/folder", "folder"),
        ]
    )
    func symbolMapping(path: String, expected: String) {
        #expect(FileThumb.symbol(for: path) == expected)
    }
}
