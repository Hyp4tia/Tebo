import Foundation

// MARK: - Developer Tools table
// Ported from tw93/Mole lib/clean/app_caches.sh (GPL-3.0)
// `clean_xcode_derived_data`, `clean_xcode_tools`, and lib/clean/dev.sh
// `clean_xcode_documentation_cache`, `clean_xcode_xctest_devices`,
// `clean_xcode_system_coresimulator_caches`, `clean_xcode_device_support`,
// `clean_dev_mobile`, `clean_dev_npm`, `clean_dev_python`, `clean_dev_rust`,
// `clean_dev_ruby`, `clean_dev_mise`, `clean_homebrew` and `clean_dev_docker`.
// Data only: no disk access, no subprocess spawns.
//
// Guard parity (pinned Mole revision, see docs/MOLE-RULE-DISPOSITIONS.json):
//   * xcodeToolingGuard  = app_protection.sh `xcode_build_tooling_process_state`
//   * simulatorGuard     = dev.sh `_coresimulator_activity_state` (process probe
//                          bracketed around a booted-device probe)
//   * xctestDevicesGuard = dev.sh `_xctest_devices_activity_state`
//   * deviceSupportGuard = dev.sh `_xcode_xctest_devices_process_running`
//                          (no booted-device bracket: `_xcode_delete_guard_allows`)

private let xcodeToolingGuard = MoleProcessGuard(
    family: "Xcode",
    exactProcessNames: ["Xcode", "xcodebuild", "xctest", "XCTRunner", "XCBBuildService", "swift-frontend"]
)
private let simulatorGuard = MoleProcessGuard(
    family: "Simulator",
    exactProcessNames: ["Xcode", "Simulator", "xcodebuild", "xctest", "XCTRunner", "simctl"],
    probesBootedSimulator: true
)
private let xctestDevicesGuard = MoleProcessGuard(
    family: "Xcode",
    exactProcessNames: ["Xcode", "xcodebuild", "xctest", "XCTRunner", "XCBBuildService", "swift-frontend",
                        "Simulator", "simctl"],
    pathSubstrings: ["xctest", "com.apple.dt.xctest"],
    probesBootedSimulator: true
)
private let deviceSupportGuard = MoleProcessGuard(
    family: "Xcode",
    exactProcessNames: ["Xcode", "xcodebuild", "xctest", "XCTRunner", "XCBBuildService", "swift-frontend",
                        "Simulator", "simctl"],
    pathSubstrings: ["xctest", "com.apple.dt.xctest"]
)
private let rustGuard = MoleProcessGuard.exact("cargo")

public enum DeveloperTools {

    // Builds a row for this table: home-relative, safe by default.
    // Promoted rows carry their whole contract explicitly: eligibility, tier,
    // guard and evidence policy. Nothing here may inherit a default silently.
    private static func target(
        _ label: String,
        _ path: String,
        kind: MoleTargetKind,
        explanation: String,
        risk: MoleRisk = .safe,
        eligibility: MoleEligibility = .unsupported,
        processGuard: MoleProcessGuard? = nil,
        pruneRule: MolePruneRule? = nil,
        scanBudget: MoleScanBudget = .standard,
        evidencePolicy: MoleEvidencePolicy = .strict,
        source: String
    ) -> CleanTarget {
        CleanTarget(
            label: label,
            group: .developerTools,
            path: .homeRelative(path),
            kind: kind,
            risk: risk,
            eligibility: eligibility,
            explanation: explanation,
            processGuard: processGuard,
            pruneRule: pruneRule,
            scanBudget: scanBudget,
            evidencePolicy: evidencePolicy,
            source: source
        )
    }

    // Root-owned rows: needsAdmin + report-only (the app pipeline never elevates).
    private static func adminTarget(
        _ label: String,
        _ path: String,
        kind: MoleTargetKind,
        explanation: String,
        processGuard: MoleProcessGuard? = nil,
        pruneRule: MolePruneRule? = nil,
        source: String
    ) -> CleanTarget {
        CleanTarget(
            label: label,
            group: .developerTools,
            path: .absolute(path),
            kind: kind,
            risk: .safe,
            needsAdmin: true,
            explanation: explanation,
            processGuard: processGuard,
            pruneRule: pruneRule,
            reportOnly: true,
            source: source
        )
    }

    private static let deviceSupportPrune = MolePruneRule.keepNewest(keepCount: 2)

    public static let all: [CleanTarget] = [
        // -- Xcode build caches (app_caches.sh clean_xcode_tools) --------------------
        target(
            "Xcode DerivedData",
            "Library/Developer/Xcode/DerivedData",
            kind: .directorySweep,
            explanation: "Per-project build directories. Xcode rebuilds them on demand; dependency checkouts inside SourcePackages are build inputs and re-fetched on the next resolve.",
            eligibility: .rebuildableCache,
            processGuard: xcodeToolingGuard,
            scanBudget: .bulk,
            evidencePolicy: .xcodeBuildCache,
            source: "mole lib/clean/app_caches.sh:101"
        ),
        target(
            "Xcode build products",
            "Library/Developer/Xcode/Products",
            kind: .directorySweep,
            explanation: "Old Xcode build output. Regenerated on the next build; embedded provisioning payloads are build inputs, not credentials.",
            eligibility: .rebuildableCache,
            processGuard: xcodeToolingGuard,
            scanBudget: .bulk,
            evidencePolicy: .xcodeBuildCache,
            source: "mole lib/clean/app_caches.sh:349"
        ),
        target(
            "Xcode cache",
            "Library/Caches/com.apple.dt.Xcode",
            kind: .directorySweep,
            explanation: "Xcode's own cache directory. Read-only in Tebo: the path contains a com.apple. component, which the safety gate never allows. Mole removes it with a running Xcode closed.",
            processGuard: xcodeToolingGuard,
            source: "mole lib/clean/app_caches.sh:321"
        ),

        // -- Simulator caches (app_caches.sh clean_xcode_tools) ----------------------
        target(
            "Simulator caches",
            "Library/Developer/CoreSimulator/Caches",
            kind: .directorySweep,
            explanation: "CoreSimulator cache dirs. Regenerated when simulators boot; kept while a simulator is booted.",
            eligibility: .rebuildableCache,
            processGuard: simulatorGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/app_caches.sh:282"
        ),
        target(
            "Simulator temp files",
            "Library/Developer/CoreSimulator/Devices/*/data/tmp/*",
            kind: .glob,
            explanation: "Per-simulator temp data. Safe once the simulator is not booted.",
            eligibility: .rebuildableCache,
            processGuard: simulatorGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/app_caches.sh:287"
        ),
        target(
            "CoreSimulator logs",
            "Library/Logs/CoreSimulator",
            kind: .directorySweep,
            explanation: "Simulator diagnostic logs. Purely informational.",
            eligibility: .rebuildableCache,
            processGuard: simulatorGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/app_caches.sh:292"
        ),

        // -- dev.sh clean_dev_mobile --------------------------------------------------
        target(
            "Xcode XCTestDevices",
            "Library/Developer/XCTestDevices",
            kind: .directorySweep,
            explanation: "Per-test-run clone UUID dirs; Xcode recreates clones inside the kept root. Kept while Xcode tooling, a simulator or an XCTest process is active.",
            eligibility: .rebuildableCache,
            processGuard: xctestDevicesGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:1776"
        ),
        target(
            "Simulator runtime cache",
            "Library/Developer/CoreSimulator/Profiles/Runtimes/*/Contents/Resources/RuntimeRoot/System/Library/Caches/*",
            kind: .glob,
            explanation: "System cache dirs inside installed simulator runtimes. Rebuilt on next boot.",
            eligibility: .rebuildableCache,
            processGuard: simulatorGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2830"
        ),
        target(
            "iOS DeviceSupport old versions",
            "Library/Developer/Xcode/iOS DeviceSupport",
            kind: .directorySweep,
            explanation: "Debug-symbol versions (1-3 GB each). Keeps the 2 most recent; older versions regenerate when a device with that iOS version reconnects.",
            eligibility: .rebuildableCache,
            processGuard: deviceSupportGuard,
            pruneRule: deviceSupportPrune,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2823"
        ),
        target(
            "watchOS DeviceSupport old versions",
            "Library/Developer/Xcode/watchOS DeviceSupport",
            kind: .directorySweep,
            explanation: "Same keep-2 rule for watchOS debug symbols; regenerated on device connect.",
            eligibility: .rebuildableCache,
            processGuard: deviceSupportGuard,
            pruneRule: deviceSupportPrune,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2824"
        ),
        target(
            "tvOS DeviceSupport old versions",
            "Library/Developer/Xcode/tvOS DeviceSupport",
            kind: .directorySweep,
            explanation: "Same keep-2 rule for tvOS debug symbols; regenerated on device connect.",
            eligibility: .rebuildableCache,
            processGuard: deviceSupportGuard,
            pruneRule: deviceSupportPrune,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2825"
        ),
        target(
            "visionOS DeviceSupport old versions",
            "Library/Developer/Xcode/visionOS DeviceSupport",
            kind: .directorySweep,
            explanation: "Same keep-2 rule for visionOS debug symbols; regenerated on device connect.",
            eligibility: .rebuildableCache,
            processGuard: deviceSupportGuard,
            pruneRule: deviceSupportPrune,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2890"
        ),
        target(
            "iOS DeviceSupport symbol caches",
            "Library/Developer/Xcode/iOS DeviceSupport/*/Symbols/System/Library/Caches/*",
            kind: .glob,
            explanation: "Inner cache dirs of kept DeviceSupport versions. Rebuilt from the symbols.",
            eligibility: .rebuildableCache,
            processGuard: deviceSupportGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2027"
        ),
        target(
            "watchOS DeviceSupport symbol caches",
            "Library/Developer/Xcode/watchOS DeviceSupport/*/Symbols/System/Library/Caches/*",
            kind: .glob,
            explanation: "Inner cache dirs of kept watchOS DeviceSupport versions.",
            eligibility: .rebuildableCache,
            processGuard: deviceSupportGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2027"
        ),
        target(
            "tvOS DeviceSupport symbol caches",
            "Library/Developer/Xcode/tvOS DeviceSupport/*/Symbols/System/Library/Caches/*",
            kind: .glob,
            explanation: "Inner cache dirs of kept tvOS DeviceSupport versions.",
            eligibility: .rebuildableCache,
            processGuard: deviceSupportGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2027"
        ),
        target(
            "visionOS DeviceSupport symbol caches",
            "Library/Developer/Xcode/visionOS DeviceSupport/*/Symbols/System/Library/Caches/*",
            kind: .glob,
            explanation: "Inner cache dirs of kept visionOS DeviceSupport versions.",
            eligibility: .rebuildableCache,
            processGuard: deviceSupportGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2890"
        ),
        target(
            "iOS DeviceSupport logs",
            "Library/Developer/Xcode/iOS DeviceSupport/*.log",
            kind: .glob,
            explanation: "Top-level DeviceSupport log files. Purely diagnostic.",
            eligibility: .rebuildableCache,
            processGuard: deviceSupportGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2028"
        ),
        target(
            "watchOS DeviceSupport logs",
            "Library/Developer/Xcode/watchOS DeviceSupport/*.log",
            kind: .glob,
            explanation: "Top-level watchOS DeviceSupport log files.",
            eligibility: .rebuildableCache,
            processGuard: deviceSupportGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2028"
        ),
        target(
            "tvOS DeviceSupport logs",
            "Library/Developer/Xcode/tvOS DeviceSupport/*.log",
            kind: .glob,
            explanation: "Top-level tvOS DeviceSupport log files.",
            eligibility: .rebuildableCache,
            processGuard: deviceSupportGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2028"
        ),
        target(
            "visionOS DeviceSupport logs",
            "Library/Developer/Xcode/visionOS DeviceSupport/*.log",
            kind: .glob,
            explanation: "Top-level visionOS DeviceSupport log files.",
            eligibility: .rebuildableCache,
            processGuard: deviceSupportGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2890"
        ),
        target(
            "Xcode Interface Builder cache",
            "Library/Developer/Xcode/UserData/IB Support",
            kind: .directorySweep,
            explanation: "Storyboard/IB rendering scratch. Regenerated when you open a storyboard.",
            eligibility: .rebuildableCache,
            processGuard: deviceSupportGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2840"
        ),
        adminTarget(
            "Xcode documentation cache (old indexes)",
            "/Library/Developer/Xcode/DocumentationCache/DeveloperDocumentation*.index",
            kind: .glob,
            explanation: "Stale DeveloperDocumentation index builds. Keeps the newest index; Mole removes the older ones with sudo. Tebo only reports this row.",
            processGuard: xcodeToolingGuard,
            pruneRule: .keepNewest(keepCount: 1),
            source: "mole lib/clean/dev.sh:1348"
        ),
        adminTarget(
            "Xcode Simulator system cache",
            "/Library/Developer/CoreSimulator/Caches",
            kind: .directorySweep,
            explanation: "Root-owned CoreSimulator cache entries. Rebuilt when simulators run; Mole needs sudo, Tebo only reports it.",
            processGuard: simulatorGuard,
            source: "mole lib/clean/dev.sh:1831"
        ),

        // -- Mobile build caches (dev.sh clean_dev_mobile) ----------------------------
        target(
            "Android Studio cache",
            "Library/Caches/Google/AndroidStudio*/*",
            kind: .glob,
            explanation: "Android Studio IDE caches. Rebuilt on next launch.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2832"
        ),
        target(
            "Android build cache",
            ".android/build-cache",
            kind: .directorySweep,
            explanation: "Gradle build-output cache. Regenerated on the next build.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2835"
        ),
        target(
            "Android SDK cache",
            ".android/cache",
            kind: .directorySweep,
            explanation: "Android SDK metadata cache. Re-fetched by the SDK manager.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2836"
        ),
        target(
            "Swift package manager cache",
            ".cache/swift-package-manager",
            kind: .directorySweep,
            explanation: "SwiftPM download/derived-data cache. Re-fetched on next resolve.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2842"
        ),
        target(
            "Swift package manager library cache",
            "Library/Caches/org.swift.swiftpm",
            kind: .directorySweep,
            explanation: "SwiftPM's macOS cache root. Rebuilt on next resolve.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2843"
        ),
        target(
            "Expo Go cache",
            ".expo/expo-go",
            kind: .directorySweep,
            explanation: "Expo Go simulator app cache. Re-downloaded on demand.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2845"
        ),
        target(
            "Expo Android APK cache",
            ".expo/android-apk-cache",
            kind: .directorySweep,
            explanation: "Built APK cache. Regenerated on the next export.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2846"
        ),
        target(
            "Expo iOS simulator app cache",
            ".expo/ios-simulator-app-cache",
            kind: .directorySweep,
            explanation: "Simulator app builds cache. Regenerated on next run.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2847"
        ),
        target(
            "Expo native modules cache",
            ".expo/native-modules-cache",
            kind: .directorySweep,
            explanation: "Prebuild native-module cache. Regenerated on prebuild.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2848"
        ),
        target(
            "Expo schema cache",
            ".expo/schema-cache",
            kind: .directorySweep,
            explanation: "Cached config schemas. Re-fetched on demand.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2849"
        ),
        target(
            "Expo template cache",
            ".expo/template-cache",
            kind: .directorySweep,
            explanation: "Project template cache. Re-downloaded on demand.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2850"
        ),
        target(
            "Expo versions cache",
            ".expo/versions-cache",
            kind: .directorySweep,
            explanation: "SDK versions metadata. Re-fetched on demand.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:2851"
        ),

        // -- JS package managers (dev.sh clean_dev_npm) -------------------------------
        target(
            "npm cache directory",
            ".npm/_cacache",
            kind: .directorySweep,
            explanation: "npm content-addressable cache. Re-downloaded on next install.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:454"
        ),
        target(
            "npm npx cache",
            ".npm/_npx",
            kind: .directorySweep,
            explanation: "npx package cache. Re-downloaded on next npx run.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:454"
        ),
        target(
            "npm logs",
            ".npm/_logs",
            kind: .directorySweep,
            explanation: "npm diagnostic logs. Purely informational.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:454"
        ),
        target(
            "npm prebuilds",
            ".npm/_prebuilds",
            kind: .directorySweep,
            explanation: "Prebuilt binary downloads. Re-fetched on demand.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:454"
        ),
        target(
            "tnpm cache directory",
            ".tnpm/_cacache",
            kind: .directorySweep,
            explanation: "Alibaba tnpm content cache. Re-downloaded on next install.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:542"
        ),
        target(
            "tnpm logs",
            ".tnpm/_logs",
            kind: .directorySweep,
            explanation: "tnpm diagnostic logs. Purely informational.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:543"
        ),
        target(
            "Yarn cache",
            ".yarn/cache",
            kind: .directorySweep,
            explanation: "Yarn package cache. Re-downloaded on next install.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:544"
        ),
        target(
            "Yarn v1 cache",
            "Library/Caches/Yarn",
            kind: .directorySweep,
            explanation: "Yarn v1 cache root. Re-downloaded on next install.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:545"
        ),
        target(
            "bun cache",
            ".bun/install/cache",
            kind: .directorySweep,
            explanation: "bun package cache. Re-downloaded on next install.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:476"
        ),
        target(
            "Corepack cache",
            ".cache/node/corepack",
            kind: .directorySweep,
            explanation: "Corepack-managed package-manager downloads. Re-fetched on demand.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:75"
        ),

        // -- Python ecosystem (dev.sh clean_dev_python) -------------------------------
        target(
            "pip cache",
            "Library/Caches/pip",
            kind: .directorySweep,
            explanation: "pip download cache. Re-downloaded on next install.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:774"
        ),
        target(
            "uv cache",
            ".cache/uv",
            kind: .directorySweep,
            explanation: "uv package cache. Re-downloaded on next install; uv's internal hard/soft link farm stays inside the cache root.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:81"
        ),
        target(
            "pyenv cache",
            ".pyenv/cache",
            kind: .directorySweep,
            explanation: "pyenv Python-build downloads. Re-fetched on next build.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:779"
        ),
        target(
            "Poetry cache",
            ".cache/poetry",
            kind: .directorySweep,
            explanation: "Poetry repository cache. Re-downloaded on next install.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:780"
        ),
        target(
            "Poetry artifacts cache",
            "Library/Caches/pypoetry/artifacts",
            kind: .directorySweep,
            explanation: "Poetry built-wheel cache. The virtualenvs sibling (live interpreters) is never touched.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:788"
        ),
        target(
            "Poetry package cache",
            "Library/Caches/pypoetry/cache",
            kind: .directorySweep,
            explanation: "Poetry repository downloads. Re-fetched on demand.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:789"
        ),
        target(
            "Ruff cache",
            ".cache/ruff",
            kind: .directorySweep,
            explanation: "Ruff lint cache. Regenerated on next lint run.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:791"
        ),
        target(
            "MyPy cache",
            ".cache/mypy",
            kind: .directorySweep,
            explanation: "MyPy incremental type-check cache. Regenerated on next run.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:792"
        ),
        target(
            "Pytest cache",
            ".pytest_cache",
            kind: .directorySweep,
            explanation: "Pytest last-failed/stepwise state. Regenerated on next run.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:793"
        ),
        target(
            "Jupyter runtime cache",
            ".jupyter/runtime",
            kind: .directorySweep,
            explanation: "Jupyter kernel connection files. Recreated per session.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:795"
        ),

        // -- Rust (dev.sh clean_dev_rust) ---------------------------------------------
        target(
            "Rust cargo cache",
            ".cargo/registry/cache",
            kind: .directorySweep,
            explanation: "Cargo crate downloads. Re-downloaded on next build; registry/src (extracted sources) is deliberately kept so offline builds still work.",
            eligibility: .rebuildableCache,
            processGuard: rustGuard,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:1204"
        ),
        target(
            "Rustup downloads cache",
            ".rustup/downloads",
            kind: .directorySweep,
            explanation: "Rustup installer downloads. Re-fetched on demand.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:1215"
        ),

        // -- Ruby ecosystem (dev.sh clean_dev_ruby) -----------------------------------
        target(
            "rbenv download cache",
            ".rbenv/cache",
            kind: .directorySweep,
            explanation: "rbenv Ruby-build downloads. Re-fetched on next build.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:1218"
        ),
        target(
            "gem spec cache",
            ".gem/specs",
            kind: .directorySweep,
            explanation: "RubyGems spec index. Re-fetched on next gem command.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:1219"
        ),
        target(
            "gem package cache",
            ".gem/ruby/*/cache/*.gem",
            kind: .glob,
            explanation: "Downloaded .gem packages. Re-downloaded on next install.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:1220"
        ),
        target(
            "Ruby Bundler cache",
            ".bundle/cache",
            kind: .directorySweep,
            explanation: "Bundler package cache. Re-downloaded on next install.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:1221"
        ),

        // -- mise (dev.sh clean_dev_mise) ---------------------------------------------
        target(
            "mise cache",
            "Library/Caches/mise",
            kind: .directorySweep,
            explanation: "mise tool-download cache (default path). Re-fetched on demand.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:1071"
        ),

        // -- Tool caches beyond the original port (dev.sh clean_homebrew / clean_dev_docker) --
        target(
            "Homebrew downloads cache",
            "Library/Caches/Homebrew/downloads",
            kind: .directorySweep,
            explanation: "Homebrew download cache. Re-fetched on demand; the lock directory is deliberately not swept, because removing a lock a running brew fetch holds breaks that fetch.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:5714"
        ),
        target(
            "Docker BuildX cache",
            ".docker/buildx/cache",
            kind: .directorySweep,
            explanation: "BuildX build cache. Regenerated on the next build.",
            eligibility: .rebuildableCache,
            scanBudget: .bulk,
            evidencePolicy: .developerCache,
            source: "mole lib/clean/dev.sh:1351"
        ),

        // -- pnpm store (owner-pruned; left for manual review upstream) ---------------
        CleanTarget(
            label: "pnpm store (manual review)",
            group: .developerTools,
            path: .homeRelative("Library/pnpm/store"),
            kind: .directorySweep,
            risk: .review,
            explanation: "pnpm's global content-addressable store. Mole only prunes it through the pnpm binary (`store prune`, never a raw delete); with no usable pnpm installed it is left for manual review, so Tebo reports it instead of deleting.",
            reportOnly: true,
            source: "mole lib/clean/dev.sh:362"
        ),
    ]
}
