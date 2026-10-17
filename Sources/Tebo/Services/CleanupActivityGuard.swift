import Darwin
import Foundation

/// Open handles are checked again at the removal boundary, including SQLite sidecars.
public enum CleanupActivityGuard {
    public enum Status: Sendable, Equatable { case idle, inUse, unknown }
    public typealias Probe = @Sendable (String, [String], TimeInterval?) async -> BoundedProcessRunner.Result

    static func status(for path: String, timeout: TimeInterval = 3,
                       probe: Probe = { executable, arguments, timeout in
        await BoundedProcessRunner.run(executablePath: executable, arguments: arguments, timeout: timeout)
    }) async -> Status {
        var info = stat()
        guard !Task.isCancelled, path.hasPrefix("/"),
              lstat(path, &info) == 0, !FileTreeMeasurement.isDataless(flags: info.st_flags),
              let binding = PathBinding.read(path: path),
              let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .volumeIsLocalKey
              ]), values.isSymbolicLink == false, values.volumeIsLocal == true,
              values.isDirectory == true || values.isRegularFile == true else { return .unknown }

        var arguments = ["-nP", "-F0pfn"]
        if values.isDirectory == true {
            arguments += ["+D", path]
        } else {
            // SQLite databases such as Chromium's History have no extension.
            let family = [path] + ["-wal", "-shm", "-journal"].map { path + $0 }
                .filter { FileManager.default.fileExists(atPath: $0) }
            arguments += ["--"] + family
        }
        let result = await probe("/usr/sbin/lsof", arguments, timeout)
        guard !Task.isCancelled, PathBinding.read(path: path) == binding,
              !result.outputTruncated, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unknown
        }
        // Directory searches can report matching descriptors with status 1 as well as 0.
        if result.terminationStatus == 0 || result.terminationStatus == 1, !result.stdout.isEmpty { return .inUse }
        // lsof uses status 1 with no output for a successful search that found no handles.
        if result.terminationStatus == 1, result.stdout.isEmpty { return .idle }
        return .unknown
    }

    static func reason(for path: String, timeout: TimeInterval = 3, probe: Probe? = nil) async -> String? {
        let resolvedProbe = probe ?? { executable, arguments, timeout in
            await BoundedProcessRunner.run(executablePath: executable, arguments: arguments, timeout: timeout)
        }
        switch await status(for: path, timeout: timeout, probe: resolvedProbe) {
        case .idle: return nil
        case .inUse: return "An app or process is using this item. Close it and rescan."
        case .unknown: return "Open-file activity could not be verified; item kept."
        }
    }
}
