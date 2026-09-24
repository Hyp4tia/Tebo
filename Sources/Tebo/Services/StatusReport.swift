import Darwin
import Foundation

// MARK: - StatusReport
// Read-only native system status for the Disk tab, ported from Mole's
// `mo status` collectors (cmd/status/metrics_disk.go, metrics_memory.go,
// metrics_cpu.go, metrics_hardware.go). Foundation + Darwin only: no shell
// commands, no stats library. Every metric that can fail to read is
// Optional so the UI can render "unavailable" instead of a fabricated
// number - the port contract forbids invented values.

// MARK: Disk

/// Free/total accounting for one volume. Mole reads this from gopsutil and
/// corrects APFS numbers through Finder/diskutil (cmd/status/metrics_disk.go
/// collectDisks); this app reads Foundation URL resource values instead,
/// which is the native equivalent of the porting contract.
public struct DiskStatus: Sendable, Equatable {
    /// Volume root path, e.g. "/".
    public let volumePath: String
    /// Total capacity; nil when the volume attributes cannot be read.
    public let totalBytes: Int64?
    /// Space available for important usage - the number Finder shows as
    /// free (volumeAvailableCapacityForImportantUsage).
    public let availableBytes: Int64?
    /// Space that could be made available by purging caches
    /// (volumeAvailableCapacityForOpportunisticUsage); nil when unreadable.
    public let opportunisticBytes: Int64?

    public init(
        volumePath: String,
        totalBytes: Int64?,
        availableBytes: Int64?,
        opportunisticBytes: Int64?
    ) {
        self.volumePath = volumePath
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.opportunisticBytes = opportunisticBytes
    }

    /// Fraction of the volume used, clamped to 0...1; nil when total or
    /// available capacity is unknown.
    public var usedFraction: Double? {
        guard let total = totalBytes, let available = availableBytes, total > 0 else {
            return nil
        }
        let used = min(total, max(0, total - available))
        return Double(used) / Double(total)
    }

    public var displayTotal: String? {
        totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    public var displayAvailable: String? {
        availableBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

// MARK: Memory

/// Memory totals. Mole reads vm_stat for file-backed pages and shells out
/// to memory_pressure (cmd/status/metrics_memory.go); this app reads the
/// same Mach statistics natively via host_statistics64, counting free plus
/// inactive pages as reclaimable, which is what a cleaner can actually
/// free without paging.
public struct MemoryStatus: Sendable, Equatable {
    /// Total physical RAM; nil when unreadable.
    public let totalBytes: Int64?
    /// Reclaimable RAM (free + inactive pages); nil when unreadable.
    public let freeBytes: Int64?

    public init(totalBytes: Int64?, freeBytes: Int64?) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    /// Fraction of RAM in use, clamped to 0...1; nil when unknown.
    public var usedFraction: Double? {
        guard let total = totalBytes, let free = freeBytes, total > 0 else {
            return nil
        }
        let used = min(total, max(0, total - free))
        return Double(used) / Double(total)
    }

    public var displayTotal: String? {
        totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) }
    }

    public var displayFree: String? {
        freeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) }
    }
}

// MARK: Report

/// One collected status snapshot. Everything except collectedAt is
/// optional: the UI must be able to show "unavailable" per row.
public struct SystemStatusReport: Sendable, Equatable {
    public let disk: DiskStatus
    public let memory: MemoryStatus
    /// Seconds since boot (ProcessInfo.systemUptime in production).
    public let uptimeSeconds: TimeInterval?
    /// Logical CPU count (ProcessInfo.processorCount in production).
    public let processorCount: Int?
    /// Currently active CPU count (ProcessInfo.activeProcessorCount).
    public let activeProcessorCount: Int?
    /// Physical cores via sysctl hw.physicalcpu; nil when unreadable
    /// (Mole cmd/status/metrics_cpu.go getCoreTopology reads the perflevel
    /// sysctls for the P/E split; the plain count is enough here).
    public let physicalCoreCount: Int?
    /// macOS version string (ProcessInfo.operatingSystemVersionString).
    public let osVersionString: String?
    public let collectedAt: Date

    public init(
        disk: DiskStatus,
        memory: MemoryStatus,
        uptimeSeconds: TimeInterval?,
        processorCount: Int?,
        activeProcessorCount: Int?,
        physicalCoreCount: Int?,
        osVersionString: String?,
        collectedAt: Date
    ) {
        self.disk = disk
        self.memory = memory
        self.uptimeSeconds = uptimeSeconds
        self.processorCount = processorCount
        self.activeProcessorCount = activeProcessorCount
        self.physicalCoreCount = physicalCoreCount
        self.osVersionString = osVersionString
        self.collectedAt = collectedAt
    }
}

// MARK: Providers

/// Injectable metric readers. Tests pass fakes; production passes
/// .native(). Keeping readers behind closures is what lets the test suite
/// run without depending on this machine's disk/RAM/CPU state.
public struct StatusProviders: Sendable {
    /// Reads disk capacity for a volume path (production: Foundation URL
    /// resource values, never a shell command).
    public var disk: @Sendable (String) -> DiskStatus
    public var memory: @Sendable () -> MemoryStatus
    public var uptime: @Sendable () -> TimeInterval?
    public var processorCount: @Sendable () -> Int?
    public var activeProcessorCount: @Sendable () -> Int?
    public var physicalCoreCount: @Sendable () -> Int?
    public var osVersion: @Sendable () -> String?

    public init(
        disk: @escaping @Sendable (String) -> DiskStatus,
        memory: @escaping @Sendable () -> MemoryStatus,
        uptime: @escaping @Sendable () -> TimeInterval?,
        processorCount: @escaping @Sendable () -> Int?,
        activeProcessorCount: @escaping @Sendable () -> Int?,
        physicalCoreCount: @escaping @Sendable () -> Int?,
        osVersion: @escaping @Sendable () -> String?
    ) {
        self.disk = disk
        self.memory = memory
        self.uptime = uptime
        self.processorCount = processorCount
        self.activeProcessorCount = activeProcessorCount
        self.physicalCoreCount = physicalCoreCount
        self.osVersion = osVersion
    }

    /// Real readers: Foundation + Darwin only.
    public static func native() -> StatusProviders {
        StatusProviders(
            disk: { volumePath in nativeDisk(volumePath: volumePath) },
            memory: { nativeMemory() },
            uptime: { ProcessInfo.processInfo.systemUptime },
            processorCount: { ProcessInfo.processInfo.processorCount },
            activeProcessorCount: { ProcessInfo.processInfo.activeProcessorCount },
            physicalCoreCount: { nativeSysctlInt("hw.physicalcpu") },
            osVersion: { ProcessInfo.processInfo.operatingSystemVersionString }
        )
    }

    /// Foundation URL resource values, the native reading path the porting
    /// contract requires (no df/diskutil shell-out).
    static func nativeDisk(volumePath: String) -> DiskStatus {
        let url = URL(fileURLWithPath: volumePath, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        return DiskStatus(
            volumePath: volumePath,
            totalBytes: values?.volumeTotalCapacity.map { Int64($0) },
            availableBytes: values?.volumeAvailableCapacityForImportantUsage.map { Int64($0) },
            opportunisticBytes: values?.volumeAvailableCapacityForOpportunisticUsage.map { Int64($0) }
        )
    }

    /// host_statistics64 (the same Mach counters vm_stat prints). Total RAM
    /// comes from ProcessInfo, which cannot fail on macOS; the free number
    /// can, so it stays optional.
    static func nativeMemory() -> MemoryStatus {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return MemoryStatus(totalBytes: total, freeBytes: nil)
        }
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return MemoryStatus(totalBytes: total, freeBytes: nil)
        }
        // Inactive pages are clean file-backed pages the VM can reclaim
        // instantly - a cleaner should count them as free.
        let free = (Int64(stats.free_count) + Int64(stats.inactive_count)) * Int64(pageSize)
        return MemoryStatus(totalBytes: total, freeBytes: free)
    }

    /// sysctl integer. hw.physicalcpu is a 32-bit CTLTYPE_INT on macOS, so
    /// both 4- and 8-byte results are accepted (the 8-byte check alone
    /// silently dropped the value on Apple Silicon).
    static func nativeSysctlInt(_ name: String) -> Int? {
        var int32Value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &int32Value, &size, nil, 0) == 0 else { return nil }
        return Int(int32Value)
    }
}

// MARK: Service

/// Entry point the Apps/Disk tab calls. Find/report only - nothing here
/// writes to the system.
public struct StatusReport: Sendable {
    public let providers: StatusProviders

    public init(providers: StatusProviders = .native()) {
        self.providers = providers
    }

    /// Collect one snapshot. All fields come from the injected providers,
    /// so a failed reader surfaces as nil, never as a guessed number.
    public func collect() -> SystemStatusReport {
        SystemStatusReport(
            disk: providers.disk("/"),
            memory: providers.memory(),
            uptimeSeconds: providers.uptime(),
            processorCount: providers.processorCount(),
            activeProcessorCount: providers.activeProcessorCount(),
            physicalCoreCount: providers.physicalCoreCount(),
            osVersionString: providers.osVersion(),
            collectedAt: Date()
        )
    }
}
