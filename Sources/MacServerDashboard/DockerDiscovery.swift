import Darwin
import Foundation

enum DockerDiscovery {
    static func discover() async -> [DockerContainer] {
        if let containers = await discoverWithDockerCLI() {
            return containers
        }

        if let containers = await discoverWithDockerSocket() {
            return containers
        }

        AppLogger.error("Docker discovery failed: no working docker CLI or Docker socket found")
        return []
    }

    private static func discoverWithDockerCLI() async -> [DockerContainer]? {
        var failures: [String] = []

        for command in dockerCLICommands() {
            let result = await CommandRunner.run("\(command) ps --format '{{json .}}'", timeout: 8, logsFailures: false)
            guard result.exitCode == 0 else {
                failures.append("\(command): exit=\(result.exitCode) \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                continue
            }

            let containers = parseCLIContainers(result.output)
            AppLogger.info("Docker discovery completed source=cli command=\(command) count=\(containers.count)")
            return containers
        }

        if !failures.isEmpty {
            AppLogger.error("Docker CLI discovery failed: \(failures.joined(separator: " | "))")
        }
        return nil
    }

    private static func parseCLIContainers(_ output: String) -> [DockerContainer] {
        let containers = output
            .split(separator: "\n")
            .compactMap { parseContainerLine(String($0)) }
        return containers
    }

    private static func parseContainerLine(_ line: String) -> DockerContainer? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        let id = normalizedContainerID(dictionary["ID"] as? String ?? UUID().uuidString)
        let name = dictionary["Names"] as? String ?? "Docker Container"
        let portsText = dictionary["Ports"] as? String ?? ""

        return DockerContainer(
            id: id,
            name: name,
            image: dictionary["Image"] as? String ?? "",
            status: dictionary["Status"] as? String ?? "",
            state: dictionary["State"] as? String ?? "",
            ports: parsePorts(portsText)
        )
    }

    private static func discoverWithDockerSocket() async -> [DockerContainer]? {
        await Task.detached(priority: .utility) {
            for socketPath in dockerSocketPaths() {
                guard FileManager.default.fileExists(atPath: socketPath) else {
                    continue
                }

                do {
                    let data = try readDockerSocket(path: socketPath, requestPath: "/containers/json?all=0")
                    let containers = try parseSocketContainers(data)
                    AppLogger.info("Docker discovery completed source=socket path=\(socketPath) count=\(containers.count)")
                    return containers
                } catch {
                    AppLogger.error("Docker socket discovery failed path=\(socketPath): \(error.localizedDescription)")
                }
            }

            return nil
        }.value
    }

    private static func parseSocketContainers(_ data: Data) throws -> [DockerContainer] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let array = object as? [[String: Any]] else {
            return []
        }

        return array.compactMap(parseSocketContainer)
    }

    private static func parseSocketContainer(_ dictionary: [String: Any]) -> DockerContainer? {
        let rawID = dictionary["Id"] as? String ?? dictionary["ID"] as? String ?? UUID().uuidString
        let name = socketContainerName(from: dictionary["Names"]) ?? "Docker Container"

        return DockerContainer(
            id: normalizedContainerID(rawID),
            name: name,
            image: dictionary["Image"] as? String ?? "",
            status: dictionary["Status"] as? String ?? "",
            state: dictionary["State"] as? String ?? "",
            ports: parseSocketPorts(dictionary["Ports"] as? [[String: Any]] ?? [])
        )
    }

    private static func parseSocketPorts(_ values: [[String: Any]]) -> [DockerPort] {
        var seen = Set<String>()
        var ports: [DockerPort] = []

        for value in values {
            guard let publicPort = value["PublicPort"] as? Int,
                  let privatePort = value["PrivatePort"] as? Int else {
                continue
            }

            let host = normalizeDockerHost(value["IP"] as? String ?? "127.0.0.1")
            let protocolName = (value["Type"] as? String ?? "tcp").lowercased()
            let dedupeKey = "\(host):\(publicPort)/\(protocolName)"
            guard !seen.contains(dedupeKey) else {
                continue
            }

            seen.insert(dedupeKey)
            ports.append(
                DockerPort(
                    host: host,
                    hostPort: publicPort,
                    containerPort: privatePort,
                    protocolName: protocolName
                )
            )
        }

        return ports
    }

    private static func socketContainerName(from rawNames: Any?) -> String? {
        guard let names = rawNames as? [String], let firstName = names.first else {
            return nil
        }

        let trimmedName = firstName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmedName.isEmpty ? nil : trimmedName
    }

    private static func parsePorts(_ text: String) -> [DockerPort] {
        let segments = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var seen = Set<String>()
        var ports: [DockerPort] = []

        for segment in segments {
            guard let arrowRange = segment.range(of: "->") else {
                continue
            }

            let left = String(segment[..<arrowRange.lowerBound])
            let right = String(segment[arrowRange.upperBound...])
            guard let hostColon = left.lastIndex(of: ":"),
                  let hostPort = Int(left[left.index(after: hostColon)...]) else {
                continue
            }

            let rawHost = String(left[..<hostColon])
            let host = normalizeDockerHost(rawHost)
            let rightParts = right.split(separator: "/")
            guard let containerPortText = rightParts.first,
                  let containerPort = Int(containerPortText),
                  let protocolPart = rightParts.dropFirst().first else {
                continue
            }

            let protocolName = String(protocolPart).lowercased()
            let dedupeKey = "\(host):\(hostPort)/\(protocolName)"
            guard !seen.contains(dedupeKey) else {
                continue
            }

            seen.insert(dedupeKey)
            ports.append(
                DockerPort(
                    host: host,
                    hostPort: hostPort,
                    containerPort: containerPort,
                    protocolName: protocolName
                )
            )
        }

        return ports
    }

    private static func normalizeDockerHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if trimmed == "0.0.0.0" || trimmed == "::" || trimmed.isEmpty {
            return "127.0.0.1"
        }
        return trimmed
    }

    private static func normalizedContainerID(_ id: String) -> String {
        if id.count > 12 {
            return String(id.prefix(12))
        }
        return id
    }

    private static func dockerCLICommands() -> [String] {
        var commands = ["docker"]
        for path in dockerCLIPaths() where FileManager.default.isExecutableFile(atPath: path) {
            commands.append(CommandRunner.shellEscaped(path))
        }
        return deduplicated(commands)
    }

    private static func dockerCLIPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.docker/bin/docker",
            "\(home)/.rd/bin/docker",
            "\(home)/.orbstack/bin/docker",
            "\(home)/.local/bin/docker",
            "\(home)/Applications/Docker.app/Contents/Resources/bin/docker",
            "\(home)/Applications/Docker.app/Contents/Resources/bin/com.docker.cli",
            "\(home)/Applications/OrbStack.app/Contents/MacOS/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/com.docker.cli",
            "/Applications/OrbStack.app/Contents/MacOS/docker",
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "/usr/bin/docker"
        ]
    }

    private static func dockerSocketPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []

        if let dockerHostPath = dockerHostSocketPath() {
            paths.append(dockerHostPath)
        }

        paths.append(contentsOf: [
            "\(home)/.docker/run/docker.sock",
            "\(home)/.colima/default/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/.rd/docker.sock",
            "\(home)/.lima/docker/sock/docker.sock",
            "\(home)/.lima/default/sock/docker.sock",
            "\(home)/Library/Containers/com.docker.docker/Data/docker.sock",
            "\(home)/Library/Containers/com.docker.docker/Data/vms/0/docker.sock",
            "\(home)/Library/Group Containers/group.com.docker/docker.sock",
            "/var/run/docker.sock"
        ])

        return deduplicated(paths)
    }

    private static func dockerHostSocketPath() -> String? {
        guard let dockerHost = ProcessInfo.processInfo.environment["DOCKER_HOST"],
              dockerHost.hasPrefix("unix://") else {
            return nil
        }

        return String(dockerHost.dropFirst("unix://".count))
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func readDockerSocket(path: String, requestPath: String) throws -> Data {
        let socketFileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(socketFileDescriptor) }

        try connectSocket(socketFileDescriptor, path: path)

        let request = "GET \(requestPath) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
        try writeAll(Array(request.utf8), to: socketFileDescriptor)
        let response = try readAll(from: socketFileDescriptor, timeoutMilliseconds: 4_000)
        return try httpBody(from: response)
    }

    private static func connectSocket(_ socketFileDescriptor: CInt, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        guard let pathData = path.data(using: .utf8),
              pathData.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw DockerDiscoveryError.socketPathTooLong(path)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathData)
            buffer[pathData.count] = 0
        }

        let pathOffset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
        let addressLength = socklen_t(pathOffset + pathData.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFileDescriptor, $0, addressLength)
            }
        }

        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func writeAll(_ bytes: [UInt8], to socketFileDescriptor: CInt) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { rawBuffer in
                send(
                    socketFileDescriptor,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
            }

            guard written > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            offset += written
        }
    }

    private static func readAll(from socketFileDescriptor: CInt, timeoutMilliseconds: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)

        while true {
            var pollFileDescriptor = pollfd(fd: socketFileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&pollFileDescriptor, 1, timeoutMilliseconds)
            guard pollResult > 0 else {
                if pollResult == 0 {
                    throw DockerDiscoveryError.socketReadTimeout
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            let bufferCount = buffer.count
            let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
                recv(socketFileDescriptor, rawBuffer.baseAddress, bufferCount, 0)
            }

            if readCount == 0 {
                return data
            }

            guard readCount > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            buffer.withUnsafeBufferPointer { rawBuffer in
                data.append(rawBuffer.baseAddress!, count: readCount)
            }
        }
    }

    private static func httpBody(from response: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = response.range(of: separator) else {
            throw DockerDiscoveryError.invalidHTTPResponse
        }

        let headerData = response[..<headerEnd.lowerBound]
        let header = String(decoding: headerData, as: UTF8.self)
        guard header.contains(" 200 ") else {
            throw DockerDiscoveryError.httpFailure(header.components(separatedBy: "\r\n").first ?? "unknown")
        }

        let body = response[headerEnd.upperBound...]
        if header.lowercased().contains("transfer-encoding: chunked") {
            return try decodeChunkedHTTPBody(Data(body))
        }
        return body
    }

    private static func decodeChunkedHTTPBody(_ data: Data) throws -> Data {
        var decoded = Data()
        var cursor = data.startIndex

        while cursor < data.endIndex {
            guard let lineEnd = data.range(of: Data("\r\n".utf8), in: cursor..<data.endIndex) else {
                throw DockerDiscoveryError.invalidHTTPResponse
            }

            let sizeLine = String(decoding: data[cursor..<lineEnd.lowerBound], as: UTF8.self)
            let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeLine
            guard let chunkSize = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
                throw DockerDiscoveryError.invalidHTTPResponse
            }

            cursor = lineEnd.upperBound
            if chunkSize == 0 {
                return decoded
            }

            let chunkEnd = cursor + chunkSize
            guard chunkEnd <= data.endIndex else {
                throw DockerDiscoveryError.invalidHTTPResponse
            }

            decoded.append(data[cursor..<chunkEnd])
            cursor = chunkEnd

            guard cursor + 2 <= data.endIndex,
                  data[cursor..<(cursor + 2)] == Data("\r\n".utf8) else {
                throw DockerDiscoveryError.invalidHTTPResponse
            }
            cursor += 2
        }

        return decoded
    }
}

private enum DockerDiscoveryError: LocalizedError {
    case httpFailure(String)
    case invalidHTTPResponse
    case socketPathTooLong(String)
    case socketReadTimeout

    var errorDescription: String? {
        switch self {
        case let .httpFailure(status):
            return "Docker API request failed: \(status)"
        case .invalidHTTPResponse:
            return "Docker API returned an invalid HTTP response"
        case let .socketPathTooLong(path):
            return "Docker socket path is too long: \(path)"
        case .socketReadTimeout:
            return "Docker socket read timed out"
        }
    }
}
