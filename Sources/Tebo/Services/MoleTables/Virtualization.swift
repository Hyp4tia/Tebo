import Foundation

// MARK: - Virtualization table
// Ported from tw93/Mole lib/clean/user.sh (GPL-3.0),
// `clean_virtualization_tools`, `clean_utm_caches`, `clean_tart_caches`, and
// lib/clean/dev.sh `clean_dev_docker`. Data only — no disk access.
// Docker's daemon-managed "unused data" row (dev.sh:1281, `docker system df`)
// has no filesystem path in the source, so it is not ported here; OrbStack's
// container-data review row keeps the glob path Mole sizes it through.

private let utmGuard = MoleProcessGuard.exact("UTM")
private let tartGuard = MoleProcessGuard.exact("tart")

public enum Virtualization {

    // Builds a row for this table: home-relative, safe by default.
    private static func target(
        _ label: String,
        _ path: String,
        kind: MoleTargetKind,
        explanation: String,
        processGuard: MoleProcessGuard? = nil,
        source: String
    ) -> CleanTarget {
        CleanTarget(
            label: label,
            group: .virtualization,
            path: .homeRelative(path),
            kind: kind,
            explanation: explanation,
            processGuard: processGuard,
            source: source
        )
    }

    public static let all: [CleanTarget] = [
        target(
            "VMware Fusion cache",
            "Library/Caches/com.vmware.fusion",
            kind: .directorySweep,
            explanation: "VMware Fusion cache. Virtual machines themselves are untouched.",
            source: "mole lib/clean/user.sh:2108"
        ),
        target(
            "Parallels cache",
            "Library/Caches/com.parallels.*",
            kind: .glob,
            explanation: "Parallels Desktop caches. Virtual machines themselves are untouched.",
            source: "mole lib/clean/user.sh:2109"
        ),
        target(
            "UTM app cache",
            "Library/Caches/com.utmapp.UTM",
            kind: .directorySweep,
            explanation: "UTM app cache. VM images are untouched; skipped while UTM is running.",
            processGuard: utmGuard,
            source: "mole lib/clean/user.sh:2015"
        ),
        target(
            "UTM sandbox cache",
            "Library/Containers/com.utmapp.UTM/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "UTM sandboxed cache. VM images are untouched.",
            processGuard: utmGuard,
            source: "mole lib/clean/user.sh:2016"
        ),
        target(
            "UTM temporary files",
            "Library/Containers/com.utmapp.UTM/Data/tmp",
            kind: .directorySweep,
            explanation: "UTM sandbox temp scratch. Safe while UTM is not running.",
            processGuard: utmGuard,
            source: "mole lib/clean/user.sh:2017"
        ),
        target(
            "VirtualBox cache",
            "VirtualBox VMs/.cache",
            kind: .directorySweep,
            explanation: "VirtualBox cache dir. VM images (the sibling folders) are untouched.",
            source: "mole lib/clean/user.sh:2111"
        ),
        target(
            "Lima download cache",
            "Library/Caches/lima/download/by-url-sha256",
            kind: .directorySweep,
            explanation: "Lima VM image downloads keyed by URL hash. Re-downloaded on demand.",
            source: "mole lib/clean/user.sh:2112"
        ),
        target(
            "Vagrant temporary files",
            ".vagrant.d/tmp",
            kind: .directorySweep,
            explanation: "Vagrant temp files. Boxes and VMs live elsewhere and are untouched.",
            source: "mole lib/clean/user.sh:2113"
        ),
        target(
            "Tart cache",
            ".tart/cache",
            kind: .directorySweep,
            explanation: "Tart VM image cache. Upstream prunes entries older than 30 days via `tart prune --entries caches`; entries are re-fetched on demand. Skipped while tart runs.",
            processGuard: tartGuard,
            source: "mole lib/clean/user.sh:2021"
        ),
        target(
            "Docker BuildX cache",
            ".docker/buildx/cache",
            kind: .directorySweep,
            explanation: "Docker BuildX build cache. Images/containers are untouched; the daemon's own data is pruned via `docker system df` upstream, never by path.",
            source: "mole lib/clean/dev.sh:1300"
        ),
        CleanTarget(
            label: "OrbStack container data (review)",
            group: .virtualization,
            path: .homeRelative("Library/Group Containers/*dev.orbstack/data"),
            kind: .glob,
            risk: .review,
            explanation: "OrbStack VM/container data. Upstream only reports its size and points at `docker system df` for pruning: the data is daemon-managed, so Tebo reports it too and never deletes it.",
            reportOnly: true,
            source: "mole lib/clean/dev.sh:1270"
        ),
    ]
}
