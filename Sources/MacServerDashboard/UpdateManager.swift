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

struct UpdateInstallProgress: Sendable {
    var detail: String
    var fraction: Double?
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
                $0.name.hasSuffix(".dmg")
        }) else {
            throw UpdateError.assetNotFound(AppText.t("No DMG installer found for \(arch).", zh: "没有找到适用于 \(arch) 的 DMG 安装包。"))
        }

        guard let checksum = release.assets.first(where: { $0.name.hasSuffix("-checksums.txt") }) else {
            throw UpdateError.assetNotFound(AppText.t("No checksum file found.", zh: "没有找到 checksum 文件。"))
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

    static func install(
        _ update: AvailableUpdate,
        progress: @escaping @Sendable (UpdateInstallProgress) -> Void
    ) async throws -> URL {
        progress(UpdateInstallProgress(detail: AppText.t("Preparing update installation", zh: "准备安装更新"), fraction: 0.02))
        guard let executableURL = currentExecutableURL() else {
            throw UpdateError.installFailed(AppText.t("Could not determine current executable path.", zh: "无法确定当前可执行文件路径。"))
        }

        guard let currentAppURL = currentAppBundleURL() else {
            throw UpdateError.installFailed(AppText.t("In-app updates require launching from MacServerDashboard.app.", zh: "应用内更新需要从 MacServerDashboard.app 启动。"))
        }

        guard FileManager.default.isWritableFile(atPath: currentAppURL.deletingLastPathComponent().path) else {
            throw UpdateError.installFailed(AppText.t("Current installation directory is not writable: \(currentAppURL.deletingLastPathComponent().path)", zh: "当前安装目录不可写：\(currentAppURL.deletingLastPathComponent().path)"))
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacServerDashboardUpdate-\(UUID().uuidString)", isDirectory: true)
        let mountDirectory = workDirectory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workDirectory)
        }

        let installerURL = workDirectory.appendingPathComponent(update.archiveName)
        let checksumURL = workDirectory.appendingPathComponent(update.checksumName)
        progress(UpdateInstallProgress(detail: AppText.t("Downloading DMG", zh: "正在下载 DMG"), fraction: 0.05))
        try await download(update.archiveURL, to: installerURL) { downloadFraction in
            let fraction = 0.05 + (downloadFraction ?? 0) * 0.55
            progress(UpdateInstallProgress(detail: AppText.t("Downloading DMG", zh: "正在下载 DMG"), fraction: downloadFraction == nil ? nil : fraction))
        }

        progress(UpdateInstallProgress(detail: AppText.t("Downloading checksum", zh: "正在下载 checksum"), fraction: 0.62))
        try await download(update.checksumURL, to: checksumURL) { downloadFraction in
            let fraction = 0.62 + (downloadFraction ?? 0) * 0.08
            progress(UpdateInstallProgress(detail: AppText.t("Downloading checksum", zh: "正在下载 checksum"), fraction: downloadFraction == nil ? nil : fraction))
        }

        progress(UpdateInstallProgress(detail: AppText.t("Verifying SHA256", zh: "正在校验 SHA256"), fraction: 0.72))
        let checksumText = try String(contentsOf: checksumURL, encoding: .utf8)
        guard let expectedChecksum = checksum(in: checksumText, for: update.archiveName) else {
            throw UpdateError.checksumFailed(AppText.t("The checksum file does not contain \(update.archiveName).", zh: "checksum 文件里没有 \(update.archiveName)。"))
        }

        let actualChecksum = try sha256(of: installerURL)
        guard expectedChecksum.lowercased() == actualChecksum.lowercased() else {
            throw UpdateError.checksumFailed(AppText.t("SHA256 mismatch. Expected \(expectedChecksum), got \(actualChecksum).", zh: "SHA256 不匹配。期望 \(expectedChecksum)，实际 \(actualChecksum)。"))
        }

        progress(UpdateInstallProgress(detail: AppText.t("Mounting DMG", zh: "正在挂载 DMG"), fraction: 0.78))
        try await attachDiskImage(installerURL, to: mountDirectory)
        do {
            progress(UpdateInstallProgress(detail: AppText.t("Finding new app bundle", zh: "正在查找新版本应用"), fraction: 0.84))
            let newAppURL = try findPackagedApp(in: mountDirectory)
            progress(UpdateInstallProgress(detail: AppText.t("Replacing app", zh: "正在替换应用"), fraction: 0.9))
            let installedAppURL = try replaceAppBundle(at: currentAppURL, with: newAppURL)
            await detachDiskImage(at: mountDirectory)
            progress(UpdateInstallProgress(detail: AppText.t("Installation complete", zh: "安装完成"), fraction: 0.96))
            return installedAppURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent(executableURL.lastPathComponent)
        } catch {
            await detachDiskImage(at: mountDirectory)
            throw error
        }
    }

    static func relaunch(from executableURL: URL) throws {
        guard let appURL = appBundleURL(containing: executableURL) else {
            throw UpdateError.relaunchFailed(AppText.t("The updated application is not a .app bundle: \(executableURL.path)", zh: "更新后的应用不是 .app：\(executableURL.path)"))
        }
        try openAppBundle(appURL)
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
        do {
            return try await latestAPIRelease()
        } catch {
            AppLogger.error("GitHub Releases API update check failed, falling back to releases/latest: \(error.localizedDescription)")
            return try await latestWebRelease()
        }
    }

    private static func latestAPIRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("MacServerDashboard/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = githubErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw UpdateError.networkFailed(AppText.t("GitHub Releases API request failed (HTTP \(statusCode)): \(detail)", zh: "GitHub Releases API 请求失败（HTTP \(statusCode)）：\(detail)"))
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private static func latestWebRelease() async throws -> GitHubRelease {
        let latestURL = URL(string: "https://github.com/\(repository)/releases/latest")!
        var request = URLRequest(url: latestURL)
        request.setValue("MacServerDashboard/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateError.networkFailed(AppText.t("GitHub releases page request failed (HTTP \(statusCode)).", zh: "GitHub releases 页面请求失败（HTTP \(statusCode)）。"))
        }

        guard let finalURL = httpResponse.url,
              let tagName = releaseTagName(from: finalURL) else {
            throw UpdateError.networkFailed(AppText.t("Could not determine latest release tag from GitHub releases page.", zh: "无法从 GitHub releases 页面确定最新版本 tag。"))
        }

        let arch = currentArchitecture()
        let archiveName = "MacServerDashboard-\(tagName)-macos-\(arch).dmg"
        let checksumName = "MacServerDashboard-\(tagName)-checksums.txt"
        return GitHubRelease(
            tagName: tagName,
            htmlURL: releasePageURL(tagName: tagName),
            draft: false,
            prerelease: false,
            assets: [
                GitHubReleaseAsset(name: archiveName, browserDownloadURL: releaseAssetURL(tagName: tagName, fileName: archiveName)),
                GitHubReleaseAsset(name: checksumName, browserDownloadURL: releaseAssetURL(tagName: tagName, fileName: checksumName))
            ]
        )
    }

    private static func releaseTagName(from url: URL) -> String? {
        let components = url.pathComponents
        guard let tagIndex = components.firstIndex(of: "tag") else {
            return nil
        }

        let nextIndex = components.index(after: tagIndex)
        guard nextIndex < components.endIndex else {
            return nil
        }

        let tagName = components[nextIndex]
        return tagName.isEmpty ? nil : tagName
    }

    private static func releasePageURL(tagName: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/\(tagName)")!
    }

    private static func releaseAssetURL(tagName: String, fileName: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/\(tagName)/\(fileName)")!
    }

    private static func githubErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let message = dictionary["message"] as? String,
              !message.isEmpty else {
            return nil
        }

        return message
    }

    private static func download(
        _ remoteURL: URL,
        to localURL: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        var request = URLRequest(url: remoteURL)
        request.setValue("MacServerDashboard/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw UpdateError.networkFailed(AppText.t("Download failed: \(remoteURL.absoluteString)", zh: "下载失败：\(remoteURL.absoluteString)"))
        }

        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: localURL)
        let expectedBytes = httpResponse.expectedContentLength
        var receivedBytes: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        do {
            for try await byte in bytes {
                buffer.append(byte)
                receivedBytes += 1

                if buffer.count >= 64 * 1024 {
                    handle.write(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }

                if expectedBytes > 0, receivedBytes % 16_384 == 0 {
                    progress(min(Double(receivedBytes) / Double(expectedBytes), 1))
                }
            }

            if !buffer.isEmpty {
                handle.write(buffer)
            }
            progress(expectedBytes > 0 ? 1 : nil)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
    }

    private static func attachDiskImage(_ diskImageURL: URL, to mountURL: URL) async throws {
        let command = [
            "hdiutil attach",
            CommandRunner.shellEscaped(diskImageURL.path),
            "-mountpoint",
            CommandRunner.shellEscaped(mountURL.path),
            "-nobrowse",
            "-readonly"
        ].joined(separator: " ")
        let result = await CommandRunner.run(command, timeout: 30)
        guard result.exitCode == 0 else {
            throw UpdateError.installFailed(result.output.isEmpty ? AppText.t("Mounting DMG failed.", zh: "挂载 DMG 失败。") : result.output)
        }
    }

    private static func detachDiskImage(at mountURL: URL) async {
        let command = "hdiutil detach \(CommandRunner.shellEscaped(mountURL.path))"
        _ = await CommandRunner.run(command, timeout: 10)
    }

    private static func findPackagedApp(in directory: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw UpdateError.installFailed(AppText.t("Could not read mounted directory.", zh: "无法读取解压目录。"))
        }

        for case let url as URL in enumerator where url.lastPathComponent == "MacServerDashboard.app" {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            return url
        }

        throw UpdateError.installFailed(AppText.t("MacServerDashboard.app was not found in the DMG.", zh: "DMG 中没有找到 MacServerDashboard.app。"))
    }

    private static func replaceAppBundle(at targetAppURL: URL, with newAppURL: URL) throws -> URL {
        let backupURL = targetAppURL.deletingLastPathComponent()
            .appendingPathComponent("\(targetAppURL.lastPathComponent).previous")
        let replacementURL = targetAppURL.deletingLastPathComponent()
            .appendingPathComponent("\(targetAppURL.lastPathComponent).new")

        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.removeItem(at: replacementURL)
        try FileManager.default.copyItem(at: newAppURL, to: replacementURL)
        chmodPackagedExecutable(in: replacementURL)

        try FileManager.default.moveItem(at: targetAppURL, to: backupURL)
        do {
            try FileManager.default.moveItem(at: replacementURL, to: targetAppURL)
        } catch {
            try? FileManager.default.moveItem(at: backupURL, to: targetAppURL)
            throw error
        }

        return targetAppURL
    }

    private static func currentAppBundleURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            return nil
        }
        return bundleURL
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

    private static func appBundleURL(containing executableURL: URL) -> URL? {
        var url = executableURL.deletingLastPathComponent()
        while url.path != "/" {
            if url.pathExtension == "app" {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func openAppBundle(_ appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", appURL.path]

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw UpdateError.relaunchFailed(AppText.t("open exited with code \(process.terminationStatus)", zh: "open 返回退出码 \(process.terminationStatus)"))
            }
        } catch {
            throw UpdateError.relaunchFailed(error.localizedDescription)
        }
    }

    private static func chmodPackagedExecutable(in appURL: URL) {
        let executableURL = appURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("MacServerDashboard")
        _ = chmod(executableURL.path, 0o755)
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
