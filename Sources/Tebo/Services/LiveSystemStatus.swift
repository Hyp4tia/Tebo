import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

struct ProcessStatus: Sendable, Identifiable {
    let id: Int32
    let name: String
    let memoryBytes: UInt64
    let cpuPercent: Double?
}

struct LiveSystemSnapshot: Sendable {
    let system: SystemStatusReport
    let cpuPercent: Double?
    let corePercent: [Double]
    let load: [Double]
    let downloadBytesPerSecond: Double?
    let uploadBytesPerSecond: Double?
    let networkInterface: String?
    let diskReadBytesPerSecond: Double?
    let diskWriteBytesPerSecond: Double?
    let batteryPercent: Int?
    let batteryCharging: Bool?
    let processes: [ProcessStatus]
}

actor LiveSystemStatus {
    private struct Counters: Sendable {
        let at: Date
        let cores: [[UInt64]]
        let network: (received: UInt64, sent: UInt64, name: String)?
        let disk: (read: UInt64, written: UInt64)?
        let processes: [Int32: ProcessCounter]
    }
    private struct ProcessCounter: Sendable {
        let name: String
        let memory: UInt64
        let cpuTime: UInt64
        let started: UInt64
    }
    private var previous: Counters?

    func collect() -> LiveSystemSnapshot {
        let now = Counters(at: .now, cores: Self.cpuCounters(), network: Self.networkCounters(),
                           disk: Self.diskCounters(), processes: Self.processCounters())
        let interval = previous.map { now.at.timeIntervalSince($0.at) }
        var cores: [Double] = []
        if let previous, previous.cores.count == now.cores.count {
            for (current, earlier) in zip(now.cores, previous.cores) {
                let delta = zip(current, earlier).map { $0 >= $1 ? $0 - $1 : 0 }
                let total = delta.reduce(0, +)
                cores.append(total == 0 ? 0 : Double(total - delta[2]) / Double(total) * 100)
            }
        }
        let networkSame = previous?.network?.name == now.network?.name
        let processes = now.processes.map { pid, counter in
            let old = previous?.processes[pid]
            let cpu = old?.started == counter.started
                ? Self.rate(counter.cpuTime, old?.cpuTime, interval).map { $0 / 1_000_000_000 * 100 } : nil
            return ProcessStatus(id: pid, name: counter.name, memoryBytes: counter.memory, cpuPercent: cpu)
        }.sorted { left, right in
            if let a = left.cpuPercent, let b = right.cpuPercent, a != b { return a > b }
            return left.memoryBytes > right.memoryBytes
        }
        let battery = Self.battery()
        var averages = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&averages, 3)
        let result = LiveSystemSnapshot(system: StatusReport().collect(),
            cpuPercent: cores.isEmpty ? nil : cores.reduce(0, +) / Double(cores.count), corePercent: cores,
            load: loadCount > 0 ? Array(averages.prefix(Int(loadCount))) : [],
            downloadBytesPerSecond: networkSame ? Self.rate(now.network?.received, previous?.network?.received, interval) : nil,
            uploadBytesPerSecond: networkSame ? Self.rate(now.network?.sent, previous?.network?.sent, interval) : nil,
            networkInterface: now.network?.name,
            diskReadBytesPerSecond: Self.rate(now.disk?.read, previous?.disk?.read, interval),
            diskWriteBytesPerSecond: Self.rate(now.disk?.written, previous?.disk?.written, interval),
            batteryPercent: battery?.0, batteryCharging: battery?.1, processes: Array(processes.prefix(8)))
        previous = now
        return result
    }

    static func rate(_ current: UInt64?, _ previous: UInt64?, _ seconds: TimeInterval?) -> Double? {
        guard let current, let previous, let seconds, seconds > 0, current >= previous else { return nil }
        return Double(current - previous) / seconds
    }

    private static func cpuCounters() -> [[UInt64]] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                              vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        return (0..<Int(count)).map { core in
            (0..<Int(CPU_STATE_MAX)).map { UInt64(UInt32(bitPattern: info[core * Int(CPU_STATE_MAX) + $0])) }
        }
    }

    private static func networkCounters() -> (UInt64, UInt64, String)? {
        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primary = global?["PrimaryInterface"] as? String
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let start = address else { return nil }
        defer { freeifaddrs(start) }
        var next: UnsafeMutablePointer<ifaddrs>? = start
        var fallback: (UInt64, UInt64, String)?
        while let item = next {
            defer { next = item.pointee.ifa_next }
            guard item.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = item.pointee.ifa_data else { continue }
            let name = String(cString: item.pointee.ifa_name)
            let statistics = data.assumingMemoryBound(to: if_data.self).pointee
            let value = (UInt64(statistics.ifi_ibytes), UInt64(statistics.ifi_obytes), name)
            if name == primary { return value }
            if fallback == nil, name.hasPrefix("en") { fallback = value }
        }
        return primary == nil ? fallback : nil
    }

    private static func diskCounters() -> (UInt64, UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        var found = false
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let statistics = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                let r = statistics["Bytes (Read)"] as? NSNumber,
                let w = statistics["Bytes (Write)"] as? NSNumber else { continue }
            found = true; read += r.uint64Value; written += w.uint64Value
        }
        return found ? (read, written) : nil
    }

    private static func battery() -> (Int, Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return (min(100, max(0, current * 100 / maximum)), description[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }

    private static func processCounters() -> [Int32: ProcessCounter] {
        let capacity = max(1024, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var result: [Int32: ProcessCounter] = [:]
        let deadline = Date.now.addingTimeInterval(0.8)
        for pid in pids.prefix(max(0, min(capacity, Int(count)))) where pid > 0 {
            if Date.now > deadline || Task.isCancelled { break }
            var info = proc_taskinfo(), bsd = proc_bsdinfo()
            let read = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(MemoryLayout<proc_taskinfo>.size))
            }
            guard read == MemoryLayout<proc_taskinfo>.size else { continue }
            let bsdRead = withUnsafeMutablePointer(to: &bsd) {
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
            }
            guard bsdRead == MemoryLayout<proc_bsdinfo>.size else { continue }
            var name = [CChar](repeating: 0, count: 256)
            let named = name.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
            guard named > 0 else { continue }
            let displayName = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result[pid] = ProcessCounter(name: displayName, memory: info.pti_resident_size,
                cpuTime: info.pti_total_user + info.pti_total_system,
                started: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec)
        }
        return result
    }
}
