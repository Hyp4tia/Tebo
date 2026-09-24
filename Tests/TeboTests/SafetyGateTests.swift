import Foundation
import Testing
@testable import Tebo

// MARK: - SafetyGate tests
// Most important tests: a bug here = deleted user data.
// Run: swift test

@Suite("SafetyGate")
struct SafetyGateTests {

    @Test("Blocks system paths")
    func blocksSystem() {
        #expect(SafetyGate.isAllowed(path: "/System/Library/x", whitelist: []) == false)
        #expect(SafetyGate.isAllowed(path: "/Library/Updates/staged", whitelist: []) == false)
    }

    @Test("Respects whitelist")
    func respectsWhitelist() {
        let wl: Set<String> = ["com.myapp"]
        #expect(SafetyGate.isAllowed(path: "/Users/me/Library/Caches/com.myapp", whitelist: wl) == false)
        #expect(SafetyGate.isAllowed(path: "/Users/me/Library/Caches/other", whitelist: wl) == true)
    }

    @Test("Rejects root and empty")
    func rejectsRoot() {
        #expect(SafetyGate.isAllowed(path: "/", whitelist: []) == false)
        #expect(SafetyGate.isAllowed(path: "", whitelist: []) == false)
    }

    @Test("Expands ~ in whitelist entries")
    func expandsTilde() {
        // The Settings placeholder suggests ~/... paths — those must work.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let target = (home as NSString).appendingPathComponent("Library/Caches/com.myapp")
        #expect(SafetyGate.isAllowed(path: target, whitelist: ["~/Library/Caches/com.myapp"]) == false)
        #expect(SafetyGate.isAllowed(path: target, whitelist: ["~/Library/Caches/other"]) == true)
    }
}

// MARK: - SafetyGate: Mole deny list
// One expectation per path so a regression names the exact entry.

@Suite("SafetyGate Mole deny list")
struct SafetyGateDenyListTests {

    /// The full critical list from Mole's `_mole_is_critical_deletion_path`
    /// plus the app's extras. Subtree entries use a representative child.
    @Test("Denies every critical path from Mole")
    func deniesMoleCriticalList() {
        let denied: [String] = [
            "/", "/bin", "/bin/ls", "/dev", "/dev/null", "/sbin", "/sbin/mount",
            "/usr", "/usr/share", "/System", "/System/Library/Caches/x",
            "/Library", "/Library/Caches/x", "/Library/Apple", "/Library/Apple/x",
            "/Library/Application Support", "/Library/Extensions", "/Library/Extensions/x",
            "/Library/Keychains", "/Library/Keychains/x",
            "/Applications", "/Applications/Finder.app", "/Applications/Finder.app/x",
            "/Applications/Safari.app", "/Applications/Safari.app/Contents/x",
            "/Volumes", "/opt", "/opt/homebrew",
            "/Users", "/Users/Shared", "/Users/Guest", "/Users/Guest/x",
            "/private", "/private/tmp", "/etc", "/etc/hosts",
            "/private/etc", "/private/etc/x",
            "/var", "/var/db", "/var/db/x", "/var/audit", "/var/audit/x", "/var/root",
            "/private/var", "/private/var/tmp", "/private/var/folders",
            "/private/var/db", "/private/var/db/powerlog/x",
            "/private/var/audit", "/private/var/audit/x", "/private/var/root",
            "/Library/Updates", "/Library/Updates/staged",
            "/macOS Install Data", "/macOS Install Data/x"
        ]
        for path in denied {
            #expect(SafetyGate.isAllowed(path: path, whitelist: []) == false, "expected denied: \(path)")
        }
    }

    @Test("A whole home dir is denied, its children are not")
    func usersBoundary() {
        #expect(SafetyGate.isAllowed(path: "/Users", whitelist: []) == false)
        // Exactly one component under /Users = an entire home dir. Never.
        #expect(SafetyGate.isAllowed(path: "/Users/alice", whitelist: []) == false)
        #expect(SafetyGate.isAllowed(path: "/Users/alice/Library/Caches/x", whitelist: []) == true)
        #expect(SafetyGate.isAllowed(path: "/Users/Shared", whitelist: []) == false)
        // Mole keeps /Users/Shared/Downloads cleanable (an installer search root).
        #expect(SafetyGate.isAllowed(path: "/Users/Shared/Downloads", whitelist: []) == true)
    }

    @Test("Homebrew cells under /usr/local and /opt/homebrew stay cleanable")
    func homebrewCarveOuts() {
        // Roots are denied...
        #expect(SafetyGate.isAllowed(path: "/usr/local", whitelist: []) == false)
        #expect(SafetyGate.isAllowed(path: "/opt/homebrew", whitelist: []) == false)
        // ...individual cells are not (Mole: "/usr/local/* | /opt/homebrew/*").
        #expect(SafetyGate.isAllowed(path: "/usr/local/bin/tool", whitelist: []) == true)
        #expect(SafetyGate.isAllowed(path: "/opt/homebrew/Cellar/foo", whitelist: []) == true)
        // Everything else under /usr stays denied.
        #expect(SafetyGate.isAllowed(path: "/usr/bin/tool", whitelist: []) == false)
    }

    @Test("Deny rules match on component boundaries, not substrings")
    func componentBoundaries() {
        // "Library" inside a user path is not the system /Library.
        #expect(SafetyGate.isAllowed(path: "/Users/alice/Library/Caches/x", whitelist: []) == true)
        // "/Applications" as a prefix of a longer, unrelated path: allowed.
        #expect(SafetyGate.isAllowed(path: "/Users/alice/Applications/MyApp.app", whitelist: []) == true)
        // "/Users" inside a longer path is fine too.
        #expect(SafetyGate.isAllowed(path: "/Users/alice/Dev/Users-Guide", whitelist: []) == true)
    }

    @Test("Path traversal is a component, not a substring")
    func traversalIsComponent() {
        #expect(SafetyGate.isAllowed(path: "/Users/x/../etc", whitelist: []) == false)
        #expect(SafetyGate.isAllowed(path: "/Users/x/../y", whitelist: []) == false)
        #expect(SafetyGate.isAllowed(path: "/..", whitelist: []) == false)
        // ".." inside a name is legitimate (Firefox's "name..files").
        #expect(SafetyGate.isAllowed(path: "/Users/x/name..files", whitelist: []) == true)
    }

    @Test("Rejects control characters and newlines")
    func controlCharacters() {
        #expect(SafetyGate.isAllowed(path: "/Users/x/evil\nname", whitelist: []) == false)
        #expect(SafetyGate.isAllowed(path: "/Users/x/evil\tname", whitelist: []) == false)
        #expect(SafetyGate.isAllowed(path: "/Users/x/ok-name", whitelist: []) == true)
    }

    @Test("Rejects relative paths")
    func relativePaths() {
        #expect(SafetyGate.isAllowed(path: "relative/path", whitelist: []) == false)
        #expect(SafetyGate.isAllowed(path: "~/Library/Caches/x", whitelist: []) == false)
    }

    @Test("Blocks Apple system fragments")
    func appleFragments() {
        #expect(SafetyGate.isAllowed(path: "/Users/me/Library/Caches/com.apple.safari", whitelist: []) == false)
        #expect(SafetyGate.isAllowed(path: "/Users/me/Library/Preferences/ByHost/com.x.plist", whitelist: []) == false)
    }

    @Test("Blank whitelist entries are ignored")
    func blankWhitelistEntries() {
        #expect(SafetyGate.isAllowed(path: "/Users/me/Library/Caches/x", whitelist: ["", "   "]) == true)
    }

    @Test("Normalizes // and /./ before matching the deny list")
    func normalizesCosmetics() {
        // Cosmetic padding cannot slip a path past the deny list.
        #expect(SafetyGate.isAllowed(path: "/System/./Library//x", whitelist: []) == false)
        #expect(SafetyGate.isAllowed(path: "/Library//Caches", whitelist: []) == false)
    }
}

// MARK: - SafetyGate: allow-list regression guard
// Paths the app legitimately cleans. Over-blocking breaks the product,
// under-blocking breaks users. Both directions are pinned here.

@Suite("SafetyGate allow-list regression")
struct SafetyGateAllowListTests {

    /// Real user paths that MUST stay cleanable. The app cleans inside the
    /// home directory (e.g. ~/Library/Caches/Chrome) while the deny list
    /// protects the system /Library — this suite proves the boundary.
    @Test("Real user paths stay cleanable")
    func userPathsAllowed() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let allowed: [String] = [
            (home as NSString).appendingPathComponent("Library/Caches/Chrome"),
            (home as NSString).appendingPathComponent("Library/Caches/x"),
            (home as NSString).appendingPathComponent("Library/Logs/x"),
            (home as NSString).appendingPathComponent("Library/Developer/Xcode/DerivedData"),
            (home as NSString).appendingPathComponent("Library/Caches/Homebrew"),
            (home as NSString).appendingPathComponent(".npm"),
            (home as NSString).appendingPathComponent("Downloads/installer.dmg"),
            (home as NSString).appendingPathComponent("Desktop/file"),
            (home as NSString).appendingPathComponent("Documents/Projects/p/node_modules"),
            (home as NSString).appendingPathComponent("Library/Application Support/MyApp"),
            (home as NSString).appendingPathComponent("Library/Preferences/com.someapp.plist")
        ]
        for path in allowed {
            #expect(SafetyGate.isAllowed(path: path, whitelist: []) == true, "expected allowed: \(path)")
        }
    }
}

// MARK: - PathValidator tests
// The disk-touching half of the pipeline: symlink resolution + inode guards.

@Suite("PathValidator")
struct PathValidatorTests {

    private func makeDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-val-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeFile(
        in dir: URL,
        name: String = "file.txt",
        bytes: Data = Data("x".utf8)
    ) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try bytes.write(to: file)
        return file
    }

    @Test("A harmless file in a temp dir validates")
    func harmlessPath() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeFile(in: dir)
        #expect(PathValidator.validate(path: file.path, whitelist: []) == nil)
    }

    @Test("A symlink whose target is /System is refused")
    func leafSymlinkToSystem() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("system-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/System")
        #expect(PathValidator.validate(path: link.path, whitelist: []) == .symlinkToProtectedPath)
    }

    @Test("A symlinked ancestor resolving into /System is refused")
    func ancestorSymlinkToSystem() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let redirect = dir.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(atPath: redirect.path, withDestinationPath: "/System")
        let path = redirect.appendingPathComponent("Library/Caches/x").path
        #expect(PathValidator.validate(path: path, whitelist: []) == .symlinkToProtectedPath)
    }

    @Test("A symlink to a harmless target stays allowed")
    func harmlessSymlink() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real")
        let file = try makeFile(in: real)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        #expect(PathValidator.validate(path: file.path, whitelist: []) == nil)
        #expect(
            PathValidator.validate(
                path: link.appendingPathComponent(file.lastPathComponent).path,
                whitelist: []
            ) == nil
        )
    }

    @Test("String-rule reasons map onto PathValidator")
    func reasonMapping() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeFile(in: dir)
        #expect(PathValidator.validate(path: "", whitelist: []) == .emptyPath)
        #expect(PathValidator.validate(path: "relative/x", whitelist: []) == .relativePath)
        #expect(PathValidator.validate(path: "/Users/x/../y", whitelist: []) == .pathTraversal)
        #expect(PathValidator.validate(path: "/tmp/bad\nname", whitelist: []) == .controlCharacters)
        #expect(PathValidator.validate(path: "/System/x", whitelist: []) == .criticalSystemPath)
        #expect(
            PathValidator.validate(path: file.path, whitelist: [file.lastPathComponent])
                == .whitelisted
        )
    }
}
