// ServerRuntimeInfo.swift — cross-platform (macOS + Linux) replacements for
// the Node-only diagnostics `routes/settings.js`'s `GET /info` reports via
// `process.uptime()`, `process.version`, `process.platform`,
// `process.memoryUsage()`, and `os.{loadavg,arch,totalmem,freemem,cpus}()`.
//
// There is no Swift equivalent of Node/V8's heap (`heapTotal`/`heapUsed`) or
// `external` (off-heap Buffer allocations), so those fields are approximated
// from the process's resident set size — good enough for the Settings
// page's diagnostic display, which is the only consumer.
//
// Kept in PodiumCore (not PodiumServer/Routes) per the project's established
// split: routers only do HTTP mapping, system/computation logic lives here —
// same rationale as `Pricing/CostCalculator.swift`.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ServerRuntimeInfo {
    /// Captured the first time this type is touched. Since `ServerContext`
    /// (and therefore every router) is constructed once at process startup,
    /// this is an accurate-enough proxy for "process start time" without
    /// needing a platform-specific `/proc/self/stat` / `proc_pidinfo` read.
    public static let processStartDate = Date()

    /// `process.uptime()` — seconds since `processStartDate`.
    public static var uptimeSeconds: Double {
        Date().timeIntervalSince(processStartDate)
    }

    /// `process.version` has no Swift equivalent; reports the Swift
    /// language version this binary was compiled against instead (same
    /// intent: "what runtime is this hosted under").
    public static var runtimeVersion: String {
        #if swift(>=6.0)
        return "swift-6.0"
        #elseif swift(>=5.10)
        return "swift-5.10"
        #elseif swift(>=5.9)
        return "swift-5.9"
        #else
        return "swift-unknown"
        #endif
    }

    /// `process.platform` (`"darwin"` / `"linux"` / `"win32"`).
    public static var platform: String {
        #if os(macOS)
        return "darwin"
        #elseif os(Linux)
        return "linux"
        #elseif os(Windows)
        return "win32"
        #else
        return "unknown"
        #endif
    }

    /// `os.arch()` (`"arm64"` / `"x64"` / …).
    public static var arch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x64"
        #elseif arch(i386)
        return "ia32"
        #else
        return "unknown"
        #endif
    }

    /// `os.cpus().length`.
    public static var cpuCount: Int {
        ProcessInfo.processInfo.processorCount
    }

    /// `os.totalmem()` — total physical RAM in bytes.
    public static var totalMemoryBytes: Double {
        Double(ProcessInfo.processInfo.physicalMemory)
    }

    /// `os.loadavg()` — 1/5/15-minute load averages via the POSIX
    /// `getloadavg()` call (available on both Darwin and glibc). `[0, 0, 0]`
    /// if unsupported/unavailable.
    public static var loadAverages: [Double] {
        var loads = [Double](repeating: 0, count: 3)
        let filled = loads.withUnsafeMutableBufferPointer { buffer -> Int32 in
            getloadavg(buffer.baseAddress, 3)
        }
        return filled == 3 ? loads : [0, 0, 0]
    }

    /// `os.freemem()` — free physical RAM in bytes.
    public static var freeMemoryBytes: Double {
        #if os(macOS)
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(stats.free_count) * Double(pageSize)
        #elseif os(Linux)
        guard let text = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) else { return 0 }
        for line in text.split(separator: "\n") where line.hasPrefix("MemAvailable:") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, let kb = Double(parts[1]) { return kb * 1024 }
        }
        return 0
        #else
        return 0
        #endif
    }

    /// `process.memoryUsage().rss` — this process's resident set size in
    /// bytes.
    public static var residentMemoryBytes: Double {
        #if os(macOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) : 0
        #elseif os(Linux)
        guard let text = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return 0 }
        for line in text.split(separator: "\n") where line.hasPrefix("VmRSS:") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, let kb = Double(parts[1]) { return kb * 1024 }
        }
        return 0
        #else
        return 0
        #endif
    }
}
