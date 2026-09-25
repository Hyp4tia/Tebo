import Foundation

// MARK: - App Caches table
// Ported from tw93/Mole lib/clean/user.sh (GPL-3.0), `clean_app_caches` and
// `clean_support_app_data`: the merged macOS system caches, the explicit
// com.apple.* container rows, the per-container sandbox sweep, group-container
// candidates and the Handoff pasteboard cache. Data only — no disk access.

public enum AppCaches {

    // Builds a row for this table: home-relative, safe by default.
    private static func target(
        _ label: String,
        _ path: String,
        kind: MoleTargetKind,
        explanation: String,
        source: String
    ) -> CleanTarget {
        CleanTarget(
            label: label,
            group: .appCaches,
            path: .homeRelative(path),
            kind: kind,
            explanation: explanation,
            source: source
        )
    }

    public static let all: [CleanTarget] = [
        // -- macOS system caches (merged from clean_macos_system_caches) ----------
        target(
            "Saved application states",
            "Library/Saved Application State",
            kind: .directorySweep,
            explanation: "Window restore snapshots written by apps on quit. macOS rebuilds them on next launch.",
            source: "mole lib/clean/user.sh:959"
        ),
        target(
            "Photo analysis cache",
            "Library/Caches/com.apple.photoanalysisd",
            kind: .directory,
            explanation: "Scene/face analysis scratch data. Rebuilt by photoanalysisd when needed.",
            source: "mole lib/clean/user.sh:960"
        ),
        target(
            "Apple ID cache",
            "Library/Caches/com.apple.akd",
            kind: .directory,
            explanation: "Apple ID auth daemon cache. Recreated on next sign-in check.",
            source: "mole lib/clean/user.sh:961"
        ),
        target(
            "WebKit network cache",
            "Library/Caches/com.apple.WebKit.Networking",
            kind: .directorySweep,
            explanation: "Shared WebKit HTTP cache for in-app web views. Re-downloaded on demand.",
            source: "mole lib/clean/user.sh:962"
        ),
        target(
            "Diagnostic reports",
            "Library/DiagnosticReports",
            kind: .directorySweep,
            explanation: "User-level crash/panic reports already offered to Apple. Purely informational logs.",
            source: "mole lib/clean/user.sh:963"
        ),
        target(
            "QuickLook thumbnails",
            "Library/Caches/com.apple.QuickLook.thumbnailcache",
            kind: .directory,
            explanation: "Previews generated from file contents. Regenerated when you browse folders.",
            source: "mole lib/clean/user.sh:964"
        ),
        target(
            "QuickLook cache",
            "Library/Caches/Quick Look",
            kind: .directorySweep,
            explanation: "QuickLook preview scratch. Regenerated on next preview.",
            source: "mole lib/clean/user.sh:965"
        ),
        target(
            "Icon services cache",
            "Library/Caches/com.apple.iconservices*",
            kind: .glob,
            explanation: "Rendered icon cache. Rebuilt by iconservicesd in the background.",
            source: "mole lib/clean/user.sh:966"
        ),
        target(
            "Identity caches",
            "Library/IdentityCaches",
            kind: .directorySweep,
            explanation: "Account/identity metadata cache. Rebuilt on next service use.",
            source: "mole lib/clean/user.sh:970"
        ),
        target(
            "Siri suggestions cache",
            "Library/Suggestions",
            kind: .directorySweep,
            explanation: "Siri suggestion index scratch. Rebuilt over time by the suggestion daemons.",
            source: "mole lib/clean/user.sh:971"
        ),
        target(
            "Address Book photo cache",
            "Library/Application Support/AddressBook/Sources/*/Photos.cache",
            kind: .glob,
            explanation: "Downscaled contact photo copies. Regenerated from the originals in Contacts.",
            source: "mole lib/clean/user.sh:976"
        ),
        target(
            "CrashReporter reports",
            "Library/Application Support/CrashReporter",
            kind: .findRule(maxDepth: 5, minAgeMinutes: 30 * 24 * 60, filesOnly: true),
            explanation: "Crash-reporter scratch files older than 30 days. Already-uploaded diagnostic data.",
            source: "mole lib/clean/user.sh:881"
        ),
        target(
            "Messages sticker cache",
            "Library/Messages/StickerCache",
            kind: .directorySweep,
            explanation: "Sticker previews only: never chat history or attachments. Rebuilt on demand.",
            source: "mole lib/clean/user.sh:893"
        ),
        target(
            "Messages preview attachment cache",
            "Library/Messages/Caches/Previews/Attachments",
            kind: .directorySweep,
            explanation: "Attachment preview thumbnails. The attachments themselves live elsewhere and are untouched.",
            source: "mole lib/clean/user.sh:894"
        ),
        target(
            "Messages preview sticker cache",
            "Library/Messages/Caches/Previews/StickerCache",
            kind: .directorySweep,
            explanation: "Sticker preview thumbnails. Rebuilt when you open Messages.",
            source: "mole lib/clean/user.sh:895"
        ),

        // -- Explicit com.apple.* container / cache rows --------------------------
        target(
            "Wallpaper agent cache",
            "Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "Wallpaper daemon cache. Never touches the aerial videos themselves: only rebuildable cache data.",
            source: "mole lib/clean/user.sh:983"
        ),
        target(
            "Media analysis cache",
            "Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "Photos media-analysis scratch. Regenerated by mediaanalysisd.",
            source: "mole lib/clean/user.sh:984"
        ),
        target(
            "Media analysis temp files",
            "Library/Containers/com.apple.mediaanalysisd/Data/tmp",
            kind: .directorySweep,
            explanation: "Transient media-analysis working files. Safe once the daemon finishes a pass.",
            source: "mole lib/clean/user.sh:985"
        ),
        target(
            "App Store cache",
            "Library/Containers/com.apple.AppStore/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "Storefront artwork and metadata cache. Re-fetched when you browse the App Store.",
            source: "mole lib/clean/user.sh:986"
        ),
        target(
            "Apple Configurator temp files",
            "Library/Containers/com.apple.configurator.xpc.InternetService/Data/tmp",
            kind: .directorySweep,
            explanation: "Configurator network-service scratch. Recreated per session.",
            source: "mole lib/clean/user.sh:987"
        ),
        target(
            "Wallpaper aerials temp files",
            "Library/Containers/com.apple.wallpaper.extension.aerials/Data/tmp",
            kind: .directorySweep,
            explanation: "Aerial wallpaper download scratch. The downloaded videos are kept.",
            source: "mole lib/clean/user.sh:988"
        ),
        target(
            "Geod temp files",
            "Library/Containers/com.apple.geod/Data/tmp",
            kind: .directorySweep,
            explanation: "GeoServices daemon scratch. Rebuilt on next location lookup.",
            source: "mole lib/clean/user.sh:989"
        ),
        target(
            "Stocks cache",
            "Library/Containers/com.apple.stocks/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "Cached stock quotes and artwork. Re-fetched on next launch.",
            source: "mole lib/clean/user.sh:990"
        ),
        target(
            "macOS Help system cache",
            "Library/Caches/com.apple.helpd",
            kind: .directorySweep,
            explanation: "Help viewer index cache. Rebuilt by helpd.",
            source: "mole lib/clean/user.sh:996"
        ),
        target(
            "Maps geo tile cache",
            "Library/Caches/GeoServices",
            kind: .directorySweep,
            explanation: "Map tiles and geo metadata. Re-downloaded as you pan Maps.",
            source: "mole lib/clean/user.sh:997"
        ),
        target(
            "Memoji picker cache",
            "Library/Containers/com.apple.AvatarUI.AvatarPickerMemojiPicker/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "Memoji rendering cache. Regenerated from stored Memoji data.",
            source: "mole lib/clean/user.sh:998"
        ),
        target(
            "Music album art cache",
            "Library/Containers/com.apple.AMPArtworkAgent/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "Album artwork cache. Re-fetched from Apple's servers on demand.",
            source: "mole lib/clean/user.sh:999"
        ),
        target(
            "CoreDevice service cache",
            "Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "Device-management service cache. Rebuilt on next device sync.",
            source: "mole lib/clean/user.sh:1000"
        ),
        target(
            "Apple Intelligence extension cache",
            "Library/Containers/com.apple.NeptuneOneExtension/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "Apple Intelligence model scratch. Re-downloaded/regenerated on demand.",
            source: "mole lib/clean/user.sh:1001"
        ),
        target(
            "Apple Media Services temp files",
            "Library/Containers/com.apple.AppleMediaServicesUI.UtilityExtension/Data/tmp",
            kind: .directorySweep,
            explanation: "Media services UI scratch. Recreated per session.",
            source: "mole lib/clean/user.sh:1002"
        ),
        target(
            "Apple Media Services cache",
            "Library/Caches/com.apple.AppleMediaServices",
            kind: .directorySweep,
            explanation: "Storefront/media metadata cache. Re-fetched on demand.",
            source: "mole lib/clean/user.sh:1003"
        ),
        target(
            "Duet Expert cache",
            "Library/Caches/com.apple.duetexpertd",
            kind: .directorySweep,
            explanation: "CoreDuet knowledge-graph scratch. Regenerated continuously.",
            source: "mole lib/clean/user.sh:1004"
        ),
        target(
            "Parsecd cache",
            "Library/Caches/com.apple.parsecd",
            kind: .directorySweep,
            explanation: "Safari/Siri search daemon cache. Rebuilt by parsecd.",
            source: "mole lib/clean/user.sh:1005"
        ),
        target(
            "Apple Python cache",
            "Library/Caches/com.apple.python",
            kind: .directorySweep,
            explanation: "Bytecode cache for Apple's bundled Python. Regenerated on import.",
            source: "mole lib/clean/user.sh:1006"
        ),

        // -- Generic sweeps -------------------------------------------------------
        target(
            "Sandboxed app caches (per container)",
            "Library/Containers/*/Data/Library/Caches",
            kind: .glob,
            explanation: "For every app container, sweep the children of its Data/Library/Caches. Critical system components, protected bundle IDs and compiled-model caches are skipped per item.",
            source: "mole lib/clean/user.sh:1010"
        ),
        target(
            "Group Containers logs/caches",
            "Library/Group Containers/*",
            kind: .glob,
            explanation: "Per shared container: Logs and Library/Logs always; tmp, Library/tmp, Caches and Library/Caches only when the owning app is not protected. Apple-owned and Safari-extension containers are skipped entirely.",
            source: "mole lib/clean/user.sh:1221"
        ),

        // -- Handoff / Universal Clipboard ----------------------------------------
        target(
            "Handoff clipboard cache",
            "Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard",
            kind: .findRule(maxDepth: 1, minAgeMinutes: 60, filesOnly: false),
            explanation: "Ephemeral Handoff pasteboard transfer buffers. Anything touched in the last hour is kept so an in-flight clipboard sync is never cut off.",
            source: "mole lib/clean/user.sh:1070"
        ),
    ]
}
