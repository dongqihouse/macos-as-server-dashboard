import Foundation
import Darwin

enum SystemStatusDiscovery {
    static func snapshot() async -> SystemStatusSnapshot {
        async let cpuUsage = cpuUsagePercent()
        async let memory = memoryUsage()
        async let temperature = temperatureCelsius()
        let storage = storageUsage()

        let memoryUsage = await memory
        return SystemStatusSnapshot(
            storageUsedBytes: storage?.used,
            storageTotalBytes: storage?.total,
            memoryUsedBytes: memoryUsage?.used,
            memoryTotalBytes: memoryUsage?.total,
            cpuUsagePercent: await cpuUsage,
            temperatureCelsius: await temperature
        )
    }

    private static func storageUsage() -> (used: UInt64, total: UInt64)? {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
            guard let total = attributes[.systemSize] as? NSNumber,
                  let free = attributes[.systemFreeSize] as? NSNumber else {
                return nil
            }

            let totalBytes = total.uint64Value
            let freeBytes = min(free.uint64Value, totalBytes)
            return (used: totalBytes - freeBytes, total: totalBytes)
        } catch {
            return nil
        }
    }

    private static func memoryUsage() async -> (used: UInt64, total: UInt64)? {
        let total = ProcessInfo.processInfo.physicalMemory
        let result = await CommandRunner.run("vm_stat", timeout: 2)
        guard result.exitCode == 0 else {
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
            return nil
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        guard let second = cpuTicks() else {
            return nil
        }

        let total = second.total - first.total
        guard total > 0 else {
            return nil
        }

        let idle = second.idle - first.idle
        return clampPercent((1 - Double(idle) / Double(total)) * 100)
    }

    private static func temperatureCelsius() async -> Double? {
        let commands = [
            "if command -v osx-cpu-temp >/dev/null 2>&1; then osx-cpu-temp; fi",
            "if command -v istats >/dev/null 2>&1; then istats cpu temp --no-graphs; fi"
        ]

        for command in commands {
            let result = await CommandRunner.run(command, timeout: 3)
            guard result.exitCode == 0,
                  let temperature = parseTemperature(from: result.output) else {
                continue
            }
            return temperature
        }

        return nil
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

    private static func parseTemperature(from output: String) -> Double? {
        let lowered = output.lowercased()
        guard lowered.contains("temp") || lowered.contains("cpu") || lowered.contains("c") else {
            return nil
        }

        return output
            .split(whereSeparator: { !$0.isNumber && $0 != "." })
            .compactMap { Double($0) }
            .first
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
