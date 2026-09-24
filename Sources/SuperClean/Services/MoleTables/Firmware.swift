import Foundation

// MARK: - Firmware table
// Ported from tw93/Mole lib/clean/user.sh (GPL-3.0),
// `clean_cached_device_firmware`. Data only — no disk access.
// Cached .ipsw restore images are Apple-signed firmware downloads; a device
// restore re-downloads them on demand, which is why upstream deletes them.

public enum Firmware {

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
            group: .firmware,
            path: .homeRelative(path),
            kind: kind,
            explanation: explanation,
            source: source
        )
    }

    public static let all: [CleanTarget] = [
        target(
            "iPhone Software Updates",
            "Library/iTunes/iPhone Software Updates/*.ipsw",
            kind: .glob,
            explanation: "Cached iPhone .ipsw firmware files (top level only). Re-downloaded from Apple on the next restore.",
            source: "mole lib/clean/user.sh:2491"
        ),
        target(
            "iPad Software Updates",
            "Library/iTunes/iPad Software Updates/*.ipsw",
            kind: .glob,
            explanation: "Cached iPad .ipsw firmware files (top level only). Re-downloaded from Apple on the next restore.",
            source: "mole lib/clean/user.sh:2492"
        ),
        target(
            "iPod Software Updates",
            "Library/iTunes/iPod Software Updates/*.ipsw",
            kind: .glob,
            explanation: "Cached iPod .ipsw firmware files (top level only). Re-downloaded from Apple on the next restore.",
            source: "mole lib/clean/user.sh:2493"
        ),
        target(
            "Configurator cached firmware",
            "Library/Group Containers/*.group.com.apple.configurator/*.ipsw",
            kind: .glob,
            explanation: "Firmware nested under Apple Configurator's per-team-id group containers. Upstream's find is recursive under each container; the .ipsw files are re-downloadable restore images, and every non-ipsw file is untouched.",
            source: "mole lib/clean/user.sh:2499"
        ),
    ]
}
