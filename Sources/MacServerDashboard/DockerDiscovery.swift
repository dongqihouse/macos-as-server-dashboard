import Foundation

enum DockerDiscovery {
    static func discover() async -> [DockerContainer] {
        let result = await CommandRunner.run("docker ps --format '{{json .}}'", timeout: 3)
        guard result.exitCode == 0 else {
            return []
        }

        return result.output
            .split(separator: "\n")
            .compactMap { parseContainerLine(String($0)) }
    }

    private static func parseContainerLine(_ line: String) -> DockerContainer? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        let id = dictionary["ID"] as? String ?? UUID().uuidString
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
}
