import Foundation

enum AppLogger {
    static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacServerDashboard", isDirectory: true)
    }

    static var appLogURL: URL {
        logsDirectory.appendingPathComponent("app.log")
    }

    private static let queue = DispatchQueue(label: "dev.codex.mac-server-dashboard.app-log")

    static func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    static func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    static func ensureLogFileExists() {
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: appLogURL.path) {
                    FileManager.default.createFile(atPath: appLogURL.path, contents: nil)
                }
            } catch {
                // Logging should never interrupt the dashboard itself.
            }
        }
    }

    private static func write(level: String, message: String) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: appLogURL.path) {
                    FileManager.default.createFile(atPath: appLogURL.path, contents: nil)
                }

                let timestamp = ISO8601DateFormatter().string(from: Date())
                let line = "[\(timestamp)] [\(level)] \(message)\n"
                let handle = try FileHandle(forWritingTo: appLogURL)
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                try handle.close()
            } catch {
                // Keep logging best-effort.
            }
        }
    }
}
