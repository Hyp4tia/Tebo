import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - ThumbnailStore
// Real previews for real files: QuickLook thumbnails for visual media, Finder icons for
// everything else (which is also what gives real app icons in the Apps tab). Nothing is
// synthesized or faked: a file that is gone renders as absent, not as a placeholder riddle.

@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private let cache = NSCache<NSString, NSImage>()
    /// One generation per (path, size) at a time: a list that recycles rows cannot stampede
    /// QuickLook with the same request.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        cache.countLimit = 600
    }

    /// Cached image, if this exact request was already fulfilled.
    func cached(_ path: String, side: CGFloat) -> NSImage? {
        cache.object(forKey: Self.key(path, side) as NSString)
    }

    /// Thumbnail or icon for a path. Returns nil when the file no longer exists.
    func image(for path: String, side: CGFloat) async -> NSImage? {
        let key = Self.key(path, side)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }

        let task = Task<NSImage?, Never> { await Self.render(path: path, side: side) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    private static func key(_ path: String, _ side: CGFloat) -> String {
        "\(Int(side.rounded()))|\(path)"
    }

    private static func render(path: String, side: CGFloat) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        if previewableExtensions.contains(url.pathExtension.lowercased()) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: side, height: side),
                scale: 2,
                representationTypes: .thumbnail
            )
            if let representation = try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request) {
                return representation.nsImage
            }
        }
        // Finder icons cover app bundles, folders and documents, and are cached by AppKit.
        return NSWorkspace.shared.icon(forFile: path)
    }

    private static let previewableExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "avif",
        "svg", "pdf", "raw", "cr2", "nef", "arw", "dng",
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv",
    ]
}

// MARK: - FileThumb

/// Square preview for one path: thumbnail when the format has one, icon when it does not,
/// a quiet ghost when the file is gone.
struct FileThumb: View {
    let path: String
    var side: CGFloat = 40
    /// Bumped by the caller when a scan should re-read the file (e.g. after a scan).
    var refreshToken: Int = 0

    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side > 60 ? 10 : 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: side > 60 ? 10 : 6, style: .continuous))
            } else if missing {
                // The row is still listed (the engine found it at scan time); it is just gone now.
                Image(systemName: "questionmark.folder")
                    .font(.system(size: side * 0.4, weight: .light))
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: FileThumb.symbol(for: path))
                    .font(.system(size: side * 0.38, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .overlay(
            RoundedRectangle(cornerRadius: side > 60 ? 10 : 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .task(id: "\(path)|\(refreshToken)") {
            missing = false
            let loaded = await ThumbnailStore.shared.image(for: path, side: side)
            guard !Task.isCancelled else { return }
            image = loaded
            missing = loaded == nil
        }
    }

    /// Symbol for formats with no thumbnail: still says what kind of file this is. Images and
    /// video normally get a QuickLook preview; these are the fallbacks when one cannot be made.
    static func symbol(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "app": return "app"
        case "": return "folder"
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg",
             "raw", "cr2", "nef", "arw", "dng": return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv": return "film"
        case "mp3", "m4a", "aac", "flac", "wav", "aiff", "ogg": return "music.note"
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "pkg", "iso": return "shippingbox"
        case "swift", "rs", "go", "sh", "zsh", "py", "js", "ts", "json", "yml", "yaml", "toml",
             "md", "txt", "log", "xml", "plist", "csv": return "doc.text"
        case "ttf", "otf", "woff", "woff2": return "textformat"
        default: return "doc"
        }
    }
}
