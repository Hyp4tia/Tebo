import Foundation

// MARK: - Cloud & Office table
// Ported from tw93/Mole lib/clean/user.sh (GPL-3.0), `clean_cloud_storage` and
// `clean_office_applications`. Data only — no disk access.
// Note: Mole has NO iCloud cache cleanup in its clean path; it treats
// ~/Library/CloudStorage and ~/Library/Mobile Documents as protected
// (lib/clean/purge_shared.sh:139-140), so no iCloud rows are invented here.

private let dropboxGuard = MoleProcessGuard.exact("Dropbox")
private let googleDriveGuard = MoleProcessGuard.exact("Google Drive")
private let oneDriveGuard = MoleProcessGuard.exact("OneDrive")

public enum CloudOffice {

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
            group: .cloudOffice,
            path: .homeRelative(path),
            kind: kind,
            explanation: explanation,
            processGuard: processGuard,
            source: source
        )
    }

    public static let all: [CleanTarget] = [
        // -- Cloud storage caches (clean_cloud_storage) -------------------------------
        target(
            "Dropbox cache (bundle id)",
            "Library/Caches/com.dropbox.*",
            kind: .glob,
            explanation: "Dropbox sync cache. Rebuilt on next sync; synced files themselves are untouched.",
            processGuard: dropboxGuard,
            source: "mole lib/clean/user.sh:682"
        ),
        target(
            "Dropbox cache (getdropbox)",
            "Library/Caches/com.getdropbox.dropbox",
            kind: .directorySweep,
            explanation: "Dropbox sync cache. Rebuilt on next sync.",
            processGuard: dropboxGuard,
            source: "mole lib/clean/user.sh:684"
        ),
        target(
            "Google Drive cache",
            "Library/Caches/com.google.GoogleDrive",
            kind: .directorySweep,
            explanation: "Google Drive for desktop cache. Rebuilt on next sync.",
            processGuard: googleDriveGuard,
            source: "mole lib/clean/user.sh:1950"
        ),
        target(
            "Baidu Netdisk cache",
            "Library/Caches/com.baidu.netdisk",
            kind: .directorySweep,
            explanation: "Baidu Netdisk client cache. Rebuilt on next sync.",
            source: "mole lib/clean/user.sh:1956"
        ),
        target(
            "Alibaba Cloud cache",
            "Library/Caches/com.alibaba.teambitiondisk",
            kind: .directorySweep,
            explanation: "Alibaba Teambition disk client cache. Rebuilt on next sync.",
            source: "mole lib/clean/user.sh:1957"
        ),
        target(
            "Box cache",
            "Library/Caches/com.box.desktop",
            kind: .directorySweep,
            explanation: "Box Drive client cache. Rebuilt on next sync.",
            source: "mole lib/clean/user.sh:1958"
        ),
        target(
            "OneDrive cache",
            "Library/Caches/com.microsoft.OneDrive",
            kind: .directorySweep,
            explanation: "OneDrive sync cache. Rebuilt on next sync.",
            processGuard: oneDriveGuard,
            source: "mole lib/clean/user.sh:1970"
        ),

        // -- Office apps (clean_office_applications) ----------------------------------
        target(
            "Microsoft Word cache",
            "Library/Caches/com.microsoft.Word",
            kind: .directorySweep,
            explanation: "Word cache. Documents live elsewhere and are untouched.",
            source: "mole lib/clean/user.sh:1985"
        ),
        target(
            "Microsoft Word container cache",
            "Library/Containers/com.microsoft.Word/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "Sandboxed Word cache. Rebuilt on next launch.",
            source: "mole lib/clean/user.sh:1989"
        ),
        target(
            "Microsoft Word temp files",
            "Library/Containers/com.microsoft.Word/Data/tmp",
            kind: .directorySweep,
            explanation: "Word sandbox temp scratch. Safe once Word is closed.",
            source: "mole lib/clean/user.sh:1990"
        ),
        target(
            "Microsoft Word container logs",
            "Library/Containers/com.microsoft.Word/Data/Library/Logs",
            kind: .directorySweep,
            explanation: "Word sandbox logs. Purely informational.",
            source: "mole lib/clean/user.sh:1991"
        ),
        target(
            "Microsoft Excel cache",
            "Library/Caches/com.microsoft.Excel",
            kind: .directorySweep,
            explanation: "Excel cache. Workbooks live elsewhere and are untouched.",
            source: "mole lib/clean/user.sh:1992"
        ),
        target(
            "Microsoft Excel container cache",
            "Library/Containers/com.microsoft.Excel/Data/Library/Caches",
            kind: .directorySweep,
            explanation: "Sandboxed Excel cache. Rebuilt on next launch.",
            source: "mole lib/clean/user.sh:1996"
        ),
        target(
            "Microsoft Excel temp files",
            "Library/Containers/com.microsoft.Excel/Data/tmp",
            kind: .directorySweep,
            explanation: "Excel sandbox temp scratch. Safe once Excel is closed.",
            source: "mole lib/clean/user.sh:1997"
        ),
        target(
            "Microsoft Excel container logs",
            "Library/Containers/com.microsoft.Excel/Data/Library/Logs",
            kind: .directorySweep,
            explanation: "Excel sandbox logs. Purely informational.",
            source: "mole lib/clean/user.sh:1998"
        ),
        target(
            "Microsoft PowerPoint cache",
            "Library/Caches/com.microsoft.Powerpoint",
            kind: .directorySweep,
            explanation: "PowerPoint cache. Presentations live elsewhere and are untouched.",
            source: "mole lib/clean/user.sh:1999"
        ),
        target(
            "Microsoft Outlook cache",
            "Library/Caches/com.microsoft.Outlook",
            kind: .directorySweep,
            explanation: "Outlook cache. Mail data lives elsewhere and is untouched.",
            source: "mole lib/clean/user.sh:2000"
        ),
        target(
            "Apple iWork cache",
            "Library/Caches/com.apple.iWork.*",
            kind: .glob,
            explanation: "Pages/Numbers/Keynote caches. Documents are untouched.",
            source: "mole lib/clean/user.sh:2001"
        ),
        target(
            "WPS Office cache",
            "Library/Caches/com.kingsoft.wpsoffice.mac",
            kind: .directorySweep,
            explanation: "WPS Office cache. Documents are untouched.",
            source: "mole lib/clean/user.sh:2002"
        ),
        target(
            "Thunderbird cache",
            "Library/Caches/org.mozilla.thunderbird",
            kind: .directorySweep,
            explanation: "Thunderbird mail client cache. Mail data is untouched.",
            source: "mole lib/clean/user.sh:2003"
        ),
        target(
            "Apple Mail cache",
            "Library/Caches/com.apple.mail",
            kind: .directorySweep,
            explanation: "Mail app cache. Messages live elsewhere and are untouched.",
            source: "mole lib/clean/user.sh:2004"
        ),
    ]
}
