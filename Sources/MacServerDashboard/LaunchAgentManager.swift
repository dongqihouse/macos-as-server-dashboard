import Foundation

enum LaunchAgentManager {
    static let label = "dev.codex.mac-server-dashboard"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func install() async throws {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let launchAgentsDirectory = plistURL.deletingLastPathComponent()
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacServerDashboard", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/MacServerDashboard/app.log")
                .path,
            "StandardErrorPath": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/MacServerDashboard/app.err.log")
                .path
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        _ = await CommandRunner.run("launchctl bootstrap gui/$(id -u) \(CommandRunner.shellEscaped(plistURL.path))", timeout: 5)
        _ = await CommandRunner.run("launchctl kickstart -k gui/$(id -u)/\(label)", timeout: 5)
    }

    static func uninstall() async throws {
        _ = await CommandRunner.run("launchctl bootout gui/$(id -u)/\(label)", timeout: 5)
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}
