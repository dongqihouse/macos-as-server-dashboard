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
            let outputHandle = pipe.fileHandleForReading
            let outputBuffer = CommandOutputBuffer()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.environment = mergedEnvironment()
            process.standardOutput = pipe
            process.standardError = pipe
            outputHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    return
                }
                outputBuffer.append(data)
            }

            do {
                try process.run()
            } catch {
                outputHandle.readabilityHandler = nil
                continuation.resume(returning: CommandResult(exitCode: 127, output: error.localizedDescription))
                return
            }

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
                outputHandle.readabilityHandler = nil
                let data = outputBuffer.snapshot()
                let output = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus != 0 {
                    AppLogger.error("Command failed exit=\(process.terminationStatus): \(command)\n\(truncated(output))")
                }
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
        let environment = mergedEnvironment(workingDirectory: workingDirectory)
        AppLogger.info("Starting service command log=\(logName) cwd=\(workingDirectory ?? "") command=\(command)")
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", serviceCommand(command, environment: environment)]
        process.environment = environment
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
        AppLogger.info("Started service command log=\(logName) pid=\(process.processIdentifier)")
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

    private static func serviceCommand(_ command: String, environment: [String: String]) -> String {
        let path = environment["PATH"] ?? defaultPath
        return "export PATH=\(shellEscaped(path)):$PATH\n\(command)"
    }

    private static func mergedEnvironment(workingDirectory: String? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["BUN_INSTALL"] = environment["BUN_INSTALL"] ?? "\(home)/.bun"

        var preferredPaths = pythonVirtualEnvPaths(workingDirectory: workingDirectory)
        preferredPaths.append(contentsOf: [
            "\(home)/.pyenv/shims",
            "\(home)/.asdf/shims",
            "\(home)/.rye/shims",
            "\(home)/.pixi/bin",
            "\(home)/.poetry/bin",
            "\(home)/.bun/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ])
        preferredPaths.append(contentsOf: pythonUserInstallPaths(home: home))

        let currentPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        environment["PATH"] = deduplicatedPath(preferredPaths + currentPaths).joined(separator: ":")
        return environment
    }

    private static func pythonVirtualEnvPaths(workingDirectory: String?) -> [String] {
        guard let workingDirectory, !workingDirectory.isEmpty else {
            return []
        }

        let expandedWorkingDirectory = expandingTilde(workingDirectory)
        return [
            "\(expandedWorkingDirectory)/.venv/bin",
            "\(expandedWorkingDirectory)/venv/bin"
        ]
    }

    private static func pythonUserInstallPaths(home: String) -> [String] {
        let pythonRoot = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Python", isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: pythonRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return versions
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appendingPathComponent("bin", isDirectory: true).path }
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

    private static func truncated(_ value: String, maxCharacters: Int = 2_000) -> String {
        if value.count <= maxCharacters {
            return value
        }
        return String(value.prefix(maxCharacters)) + "\n...<truncated>"
    }
}

private final class CommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ nextData: Data) {
        lock.lock()
        data.append(nextData)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let currentData = data
        lock.unlock()
        return currentData
    }
}
