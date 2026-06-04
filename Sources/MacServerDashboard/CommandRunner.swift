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
        let nvmDirectory = environment["NVM_DIR"] ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/.nvm"
        return """
        export NVM_DIR=\(shellEscaped(nvmDirectory))
        if [ -s "$NVM_DIR/nvm.sh" ]; then . "$NVM_DIR/nvm.sh" --no-use; fi
        export PATH=\(shellEscaped(path)):$PATH
        \(command)
        """
    }

    private static func mergedEnvironment(workingDirectory: String? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["BUN_INSTALL"] = environment["BUN_INSTALL"] ?? "\(home)/.bun"
        environment["NVM_DIR"] = environment["NVM_DIR"] ?? "\(home)/.nvm"

        var preferredPaths = pythonVirtualEnvPaths(workingDirectory: workingDirectory)
        if let nvmNodeBinPath = nvmNodeBinPath(workingDirectory: workingDirectory, home: home) {
            preferredPaths.append(nvmNodeBinPath)
            environment["NVM_BIN"] = nvmNodeBinPath
        }
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

    private static func nvmNodeBinPath(workingDirectory: String?, home: String) -> String? {
        let versionsRoot = URL(fileURLWithPath: home)
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let installedVersions = installedNVMNodeVersions(in: versionsRoot)
        guard !installedVersions.isEmpty else {
            return nil
        }

        let requestedVersion = nvmVersionRequest(workingDirectory: workingDirectory, home: home)
        let selectedVersion = requestedVersion.flatMap {
            resolveNVMVersion($0, installedVersions: installedVersions, home: home)
        } ?? installedVersions.first

        guard let selectedVersion else {
            return nil
        }

        let binPath = versionsRoot
            .appendingPathComponent(selectedVersion, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .path
        return FileManager.default.fileExists(atPath: binPath) ? binPath : nil
    }

    private static func installedNVMNodeVersions(in versionsRoot: URL) -> [String] {
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: versionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return versions
            .filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("v") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
    }

    private static func nvmVersionRequest(workingDirectory: String?, home: String) -> String? {
        if let workingDirectory, !workingDirectory.isEmpty {
            let nvmrcURL = URL(fileURLWithPath: expandingTilde(workingDirectory))
                .appendingPathComponent(".nvmrc")
            if let nvmrcVersion = readNVMVersionFile(nvmrcURL) {
                return nvmrcVersion
            }
        }

        let defaultAliasURL = URL(fileURLWithPath: home)
            .appendingPathComponent(".nvm/alias/default")
        return readNVMVersionFile(defaultAliasURL)
    }

    private static func resolveNVMVersion(
        _ request: String,
        installedVersions: [String],
        home: String,
        visitedAliases: Set<String> = []
    ) -> String? {
        let normalized = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != "system" else {
            return nil
        }

        if normalized == "node" || normalized == "stable" || normalized == "unstable" || normalized == "lts/*" {
            return installedVersions.first
        }

        let explicitVersion = normalized.hasPrefix("v") ? normalized : "v\(normalized)"
        if installedVersions.contains(explicitVersion) {
            return explicitVersion
        }

        let versionPrefix = explicitVersion.dropFirst()
        if let matchingVersion = installedVersions.first(where: {
            $0.dropFirst() == versionPrefix || $0.dropFirst().hasPrefix("\(versionPrefix).")
        }) {
            return matchingVersion
        }

        guard !visitedAliases.contains(normalized),
              let aliasValue = readNVMAlias(normalized, home: home) else {
            return nil
        }

        return resolveNVMVersion(
            aliasValue,
            installedVersions: installedVersions,
            home: home,
            visitedAliases: visitedAliases.union([normalized])
        )
    }

    private static func readNVMAlias(_ alias: String, home: String) -> String? {
        let aliasComponents = alias
            .split(separator: "/")
            .map(String.init)
        guard !aliasComponents.isEmpty,
              !aliasComponents.contains(where: { $0 == "." || $0 == ".." }) else {
            return nil
        }

        var aliasURL = URL(fileURLWithPath: home)
            .appendingPathComponent(".nvm/alias", isDirectory: true)
        for component in aliasComponents {
            aliasURL.appendPathComponent(component)
        }
        return readNVMVersionFile(aliasURL)
    }

    private static func readNVMVersionFile(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        return text
            .split(separator: "\n")
            .compactMap { line -> String? in
                let uncommented = line
                    .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                    .first
                    .map(String.init) ?? ""
                let trimmed = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .first
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
