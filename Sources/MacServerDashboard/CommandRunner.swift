import Foundation

struct CommandResult: Sendable {
    var exitCode: Int32
    var output: String
}

enum CommandRunner {
    static let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func run(_ command: String, timeout: TimeInterval = 4) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.environment = mergedEnvironment()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                continuation.resume(returning: CommandResult(exitCode: 127, output: error.localizedDescription))
                return
            }

            let outputHandle = pipe.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }

                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.1)
                    if process.isRunning {
                        process.interrupt()
                    }
                }

                process.waitUntilExit()
                let data = outputHandle.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(exitCode: process.terminationStatus, output: output))
            }
        }
    }

    static func startLongRunning(
        _ command: String,
        workingDirectory: String?,
        logName: String,
        terminationHandler: (@Sendable (Process) -> Void)? = nil
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.environment = mergedEnvironment()
        process.terminationHandler = terminationHandler

        if let workingDirectory, !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: expandingTilde(workingDirectory))
        }

        let logURL = try logFileURL(logName: logName)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        let header = "\n--- \(Date()) ---\n$ \(command)\n"
        if let data = header.data(using: .utf8) {
            handle.write(data)
        }
        process.standardOutput = handle
        process.standardError = handle

        try process.run()
        return process
    }

    static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func expandingTilde(_ path: String) -> String {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        }
        return path
    }

    static func logFileURL(logName: String) throws -> URL {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacServerDashboard", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let safeName = logName.replacingOccurrences(of: "/", with: "-")
        let url = logsDirectory.appendingPathComponent("\(safeName).log")

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        return url
    }

    static func lastLogLines(logName: String, maxLines: Int = 4) -> String {
        guard let url = try? logFileURL(logName: logName),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }

        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxLines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func lastLogBlock(logName: String, fallbackMaxLines: Int = 80) -> String {
        guard let url = try? logFileURL(logName: logName),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }

        if let range = text.range(of: "\n--- ", options: .backwards) {
            return String(text[range.lowerBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(fallbackMaxLines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func logText(logName: String, maxBytes: Int = 120_000) -> String {
        guard let url = try? logFileURL(logName: logName),
              let data = try? Data(contentsOf: url) else {
            return ""
        }

        let viewData = data.count > maxBytes ? data.suffix(maxBytes) : data[...]
        return String(decoding: viewData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sendSignal(_ signal: String, pid: String) async -> CommandResult {
        guard let numericPID = Int(pid), numericPID > 1 else {
            return CommandResult(exitCode: 1, output: "Invalid pid: \(pid)")
        }

        return await run("kill -\(signal) \(numericPID)", timeout: 2)
    }

    private static func mergedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["BUN_INSTALL"] = environment["BUN_INSTALL"] ?? "\(home)/.bun"

        let preferredPaths = [
            "\(home)/.bun/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let currentPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        environment["PATH"] = deduplicatedPath(preferredPaths + currentPaths).joined(separator: ":")
        return environment
    }

    private static func deduplicatedPath(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for path in paths where !path.isEmpty && !seen.contains(path) {
            seen.insert(path)
            result.append(path)
        }

        return result
    }
}
