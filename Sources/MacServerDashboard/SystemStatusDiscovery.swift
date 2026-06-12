import Foundation
import Darwin

enum SystemStatusDiscovery {
    static func snapshot() async -> SystemStatusSnapshot {
        async let cpuUsage = cpuUsagePercent()
        async let memory = memoryUsage()
        async let networkReachability = networkReachable()
        async let networkTraffic = NetworkTrafficSampler.shared.currentRate()
        let storage = storageUsage()

        let memoryUsage = await memory
        let traffic = await networkTraffic
        return SystemStatusSnapshot(
            storageUsedBytes: storage?.used,
            storageTotalBytes: storage?.total,
            memoryUsedBytes: memoryUsage?.used,
            memoryTotalBytes: memoryUsage?.total,
            cpuUsagePercent: await cpuUsage,
            networkReachable: await networkReachability,
            networkDownloadBytesPerSecond: traffic?.downloadBytesPerSecond,
            networkUploadBytesPerSecond: traffic?.uploadBytesPerSecond
        )
    }

    private static func storageUsage() -> (used: UInt64, total: UInt64)? {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
            guard let total = attributes[.systemSize] as? NSNumber,
                  let free = attributes[.systemFreeSize] as? NSNumber else {
                AppLogger.error("Storage discovery failed: missing file system size attributes")
                return nil
            }

            let totalBytes = total.uint64Value
            let freeBytes = min(free.uint64Value, totalBytes)
            return (used: totalBytes - freeBytes, total: totalBytes)
        } catch {
            AppLogger.error("Storage discovery failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func memoryUsage() async -> (used: UInt64, total: UInt64)? {
        let total = ProcessInfo.processInfo.physicalMemory
        let result = await CommandRunner.run("vm_stat", timeout: 2)
        guard result.exitCode == 0 else {
            AppLogger.error("Memory discovery failed exit=\(result.exitCode): \(result.output)")
            return nil
        }

        let pageSize = parsePageSize(from: result.output) ?? 4096
        let pages = parseVMStatPages(from: result.output)
        let freePages = (pages["Pages free"] ?? 0) + (pages["Pages speculative"] ?? 0)
        let freeBytes = min(UInt64(freePages) * UInt64(pageSize), total)
        return (used: total - freeBytes, total: total)
    }

    private static func cpuUsagePercent() async -> Double? {
        guard let first = cpuTicks() else {
            AppLogger.error("CPU discovery failed: first host_statistics call failed")
            return nil
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        guard let second = cpuTicks() else {
            AppLogger.error("CPU discovery failed: second host_statistics call failed")
            return nil
        }

        let total = second.total - first.total
        guard total > 0 else {
            return nil
        }

        let idle = second.idle - first.idle
        return clampPercent((1 - Double(idle) / Double(total)) * 100)
    }

    private static func parsePageSize(from output: String) -> Int? {
        guard let range = output.range(of: "page size of ") else {
            return nil
        }

        let suffix = output[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func parseVMStatPages(from output: String) -> [String: Int] {
        output
            .split(separator: "\n")
            .reduce(into: [String: Int]()) { result, line in
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else {
                    return
                }

                let valueText = parts[1].filter { $0.isNumber }
                guard let value = Int(valueText) else {
                    return
                }
                result[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] = value
            }
    }

    private static func networkReachable() async -> Bool? {
        let endpoints = [
            (host: "1.1.1.1", port: 53),
            (host: "8.8.8.8", port: 53),
            (host: "223.5.5.5", port: 53)
        ]

        for endpoint in endpoints {
            let command = "nc -G 1 -z \(CommandRunner.shellEscaped(endpoint.host)) \(endpoint.port)"
            let result = await CommandRunner.run(command, timeout: 2)
            if result.exitCode == 0 {
                AppLogger.info("Network connectivity reachable endpoint=\(endpoint.host):\(endpoint.port)")
                return true
            }
        }

        AppLogger.info("Network connectivity unavailable")
        return false
    }

    private static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private struct CPUTicks {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64

        var total: UInt64 {
            user + system + idle + nice
        }
    }
}

private actor NetworkTrafficSampler {
    static let shared = NetworkTrafficSampler()

    private var previousCounters: NetworkTrafficCounters?

    func currentRate() -> NetworkTrafficRate? {
        guard let currentCounters = Self.trafficCounters() else {
            return nil
        }

        defer {
            previousCounters = currentCounters
        }

        guard let previousCounters else {
            return NetworkTrafficRate(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil)
        }

        let elapsedSeconds = currentCounters.timestamp.timeIntervalSince(previousCounters.timestamp)
        guard elapsedSeconds > 0 else {
            return NetworkTrafficRate(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil)
        }

        let downloadDelta = Self.byteDelta(currentCounters.downloadBytes, previousCounters.downloadBytes)
        let uploadDelta = Self.byteDelta(currentCounters.uploadBytes, previousCounters.uploadBytes)
        return NetworkTrafficRate(
            downloadBytesPerSecond: Double(downloadDelta) / elapsedSeconds,
            uploadBytesPerSecond: Double(uploadDelta) / elapsedSeconds
        )
    }

    private nonisolated static func trafficCounters() -> NetworkTrafficCounters? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            AppLogger.error("Network traffic discovery failed: getifaddrs unavailable")
            return nil
        }
        defer {
            freeifaddrs(firstInterface)
        }

        var downloadBytes: UInt64 = 0
        var uploadBytes: UInt64 = 0
        var foundInterface = false
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let interface = cursor {
            cursor = interface.pointee.ifa_next

            guard let address = interface.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_LINK,
                  isUsableInterface(flags: interface.pointee.ifa_flags),
                  let data = interface.pointee.ifa_data else {
                continue
            }

            let networkData = data.assumingMemoryBound(to: if_data.self).pointee
            downloadBytes += UInt64(networkData.ifi_ibytes)
            uploadBytes += UInt64(networkData.ifi_obytes)
            foundInterface = true
        }

        guard foundInterface else {
            AppLogger.info("Network traffic discovery unavailable: no active interface counters")
            return nil
        }

        return NetworkTrafficCounters(
            downloadBytes: downloadBytes,
            uploadBytes: uploadBytes,
            timestamp: Date()
        )
    }

    private nonisolated static func isUsableInterface(flags: UInt32) -> Bool {
        (flags & UInt32(IFF_UP)) != 0 &&
            (flags & UInt32(IFF_RUNNING)) != 0 &&
            (flags & UInt32(IFF_LOOPBACK)) == 0
    }

    private nonisolated static func byteDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        guard current >= previous else {
            return 0
        }
        return current - previous
    }
}

private struct NetworkTrafficCounters: Sendable {
    var downloadBytes: UInt64
    var uploadBytes: UInt64
    var timestamp: Date
}

private struct NetworkTrafficRate: Sendable {
    var downloadBytesPerSecond: Double?
    var uploadBytesPerSecond: Double?
}
