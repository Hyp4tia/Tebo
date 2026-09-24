import AppKit
import Foundation

// MARK: - PermissionProbe
// macOS has no API to ask "do I have Full Disk Access", so we infer it by reading a path that TCC
// protects. access(2) reports success for those paths even when the read will be denied, so the
// probe actually opens the file — anything else would tell the user they are set up when they are not.

enum PermissionProbe {

    /// Paths that require Full Disk Access. First one that exists and reads wins.
    private static let protectedRelativePaths = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari/Bookmarks.plist",
        "Library/Mail"
    ]

    /// Reads (never copies, never parses) one protected path. Returns false when access is denied.
    static func hasFullDiskAccess(fileManager: FileManager = .default) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser
        for relative in protectedRelativePaths {
            let url = home.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if (try? fileManager.contentsOfDirectory(atPath: url.path)) != nil { return true }
            } else if let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.close()
                return true
            }
        }
        return false
    }

    /// Deep link straight into the Full Disk Access pane of System Settings.
    static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
