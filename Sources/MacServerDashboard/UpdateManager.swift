import CryptoKit
import Darwin
import Foundation

struct AvailableUpdate: Hashable, Sendable {
    var tagName: String
    var version: String
    var releaseURL: URL
    var archiveName: String
    var archiveURL: URL
    var checksumName: String
    var checksumURL: URL
}

enum UpdateManager {
    static let repository = "dongqihouse/macos-as-server-dashboard"

    static func checkForUpdate(currentVersion: String = AppVersion.current) async throws -> AvailableUpdate? {
        let release = try await latestRelease()
        guard !release.draft, !release.prerelease else {
            return nil
        }

        let latestVersion = normalizedVersion(release.tagName)
        guard compareVersions(latestVersion, currentVersion) == .orderedDescending else {
            return nil
        }

        let arch = currentArchitecture()
        guard let archive = release.assets.first(where: {
            $0.name.hasPrefix("MacServerDashboard-") &&
                $0.name.contains("-macos-\(arch)") &&
                $0.name.hasSuffix(".tar.gz")
        }) else {
            throw UpdateError.assetNotFound("没有找到适用于 \(arch) 的安装包。")
        }

        guard let checksum = release.assets.first(where: { $0.name.hasSuffix("-checksums.txt") }) else {
            throw UpdateError.assetNotFound("没有找到 checksum 文件。")
        }

        return AvailableUpdate(
            tagName: release.tagName,
            version: latestVersion,
            releaseURL: release.htmlURL,
            archiveName: archive.name,
            archiveURL: archive.browserDownloadURL,
            checksumName: checksum.name,
            checksumURL: checksum.browserDownloadURL
        )
    }

    static func install(_ update: AvailableUpdate) async throws -> URL {
        guard let executableURL = currentExecutableURL() else {
            throw UpdateError.installFailed("无法确定当前可执行文件路径。")
        }

        guard FileManager.default.isWritableFile(atPath: executableURL.deletingLastPathComponent().path) else {
            throw UpdateError.installFailed("当前安装目录不可写：\(executableURL.deletingLastPathComponent().path)")
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacServerDashboardUpdate-\(UUID().uuidString)", isDirectory: true)
        let extractDirectory = workDirectory.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workDirectory)
        }

        let archiveURL = workDirectory.appendingPathComponent(update.archiveName)
        let checksumURL = workDirectory.appendingPathComponent(update.checksumName)
        try await download(update.archiveURL, to: archiveURL)
        try await download(update.checksumURL, to: checksumURL)

        let checksumText = try String(contentsOf: checksumURL, encoding: .utf8)
        guard let expectedChecksum = checksum(in: checksumText, for: update.archiveName) else {
            throw UpdateError.checksumFailed("checksum 文件里没有 \(update.archiveName)。")
        }

        let actualChecksum = try sha256(of: archiveURL)
        guard expectedChecksum.lowercased() == actualChecksum.lowercased() else {
            throw UpdateError.checksumFailed("SHA256 不匹配。期望 \(expectedChecksum)，实际 \(actualChecksum)。")
        }

        try await extractTarGzip(archiveURL, to: extractDirectory)
        let newExecutableURL = try findPackagedExecutable(in: extractDirectory)
        try replaceExecutable(at: executableURL, with: newExecutableURL)
        return executableURL
    }

    static func relaunch(from executableURL: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw UpdateError.relaunchFailed("更新后的可执行文件不可运行：\(executableURL.path)")
        }

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()

        do {
            try process.run()
        } catch {
            throw UpdateError.relaunchFailed(error.localizedDescription)
        }
    }

    static func compareVersions(_ left: String, _ right: String) -> ComparisonResult {
        let leftParts = versionParts(left)
        let rightParts = versionParts(right)
        let count = max(leftParts.count, rightParts.count)

        for index in 0..<count {
            let leftValue = index < leftParts.count ? leftParts[index] : 0
            let rightValue = index < rightParts.count ? rightParts[index] : 0
            if leftValue < rightValue {
                return .orderedAscending
            }
            if leftValue > rightValue {
                return .orderedDescending
            }
        }

        return .orderedSame
    }

    private static func latestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("MacServerDashboard/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw UpdateError.networkFailed("GitHub Releases API 请求失败。")
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private static func download(_ remoteURL: URL, to localURL: URL) async throws {
        var request = URLRequest(url: remoteURL)
        request.setValue("MacServerDashboard/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw UpdateError.networkFailed("下载失败：\(remoteURL.absoluteString)")
        }

        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: localURL)
    }

    private static func extractTarGzip(_ archiveURL: URL, to destinationURL: URL) async throws {
        let command = "tar -xzf \(CommandRunner.shellEscaped(archiveURL.path)) -C \(CommandRunner.shellEscaped(destinationURL.path))"
        let result = await CommandRunner.run(command, timeout: 30)
        guard result.exitCode == 0 else {
            throw UpdateError.installFailed(result.output.isEmpty ? "解压安装包失败。" : result.output)
        }
    }

    private static func findPackagedExecutable(in directory: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw UpdateError.installFailed("无法读取解压目录。")
        }

        for case let url as URL in enumerator where url.lastPathComponent == "MacServerDashboard" {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        throw UpdateError.installFailed("安装包中没有找到 MacServerDashboard 可执行文件。")
    }

    private static func replaceExecutable(at targetURL: URL, with newExecutableURL: URL) throws {
        let backupURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent("\(targetURL.lastPathComponent).previous")
        let replacementURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent("\(targetURL.lastPathComponent).new")

        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.removeItem(at: replacementURL)
        try FileManager.default.copyItem(at: newExecutableURL, to: replacementURL)
        chmod(replacementURL.path, 0o755)

        try FileManager.default.moveItem(at: targetURL, to: backupURL)
        do {
            try FileManager.default.moveItem(at: replacementURL, to: targetURL)
        } catch {
            try? FileManager.default.moveItem(at: backupURL, to: targetURL)
            throw error
        }
    }

    private static func currentExecutableURL() -> URL? {
        if let executableURL = Bundle.main.executableURL {
            return executableURL
        }

        guard let argument = CommandLine.arguments.first, !argument.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: argument)
    }

    private static func checksum(in text: String, for fileName: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, parts[1] == fileName else {
                continue
            }
            return parts[0]
        }
        return nil
    }

    private static func sha256(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedVersion(_ tagName: String) -> String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    private static func versionParts(_ version: String) -> [Int] {
        normalizedVersion(version)
            .split(separator: "-", maxSplits: 1)
            .first?
            .split(separator: ".")
            .map { Int($0) ?? 0 } ?? []
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

private struct GitHubRelease: Decodable {
    var tagName: String
    var htmlURL: URL
    var draft: Bool
    var prerelease: Bool
    var assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    var name: String
    var browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private enum UpdateError: LocalizedError {
    case assetNotFound(String)
    case checksumFailed(String)
    case installFailed(String)
    case networkFailed(String)
    case relaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .assetNotFound(message),
             let .checksumFailed(message),
             let .installFailed(message),
             let .networkFailed(message),
             let .relaunchFailed(message):
            return message
        }
    }
}
