import Foundation

enum LocalPortDiscovery {
    static func discover() async -> [ListeningPort] {
        let result = await CommandRunner.run("lsof -nP -iTCP -sTCP:LISTEN", timeout: 3)
        guard result.exitCode == 0 else {
            return []
        }

        return result.output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ line: String) -> ListeningPort? {
        let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard columns.count >= 9 else {
            return nil
        }

        let processName = columns[0]
        let pid = columns[1]
        guard let tcpIndex = columns.firstIndex(of: "TCP"),
              columns.indices.contains(tcpIndex + 1) else {
            return nil
        }

        let endpoint = columns[tcpIndex + 1]
        guard let colon = endpoint.lastIndex(of: ":"),
              let port = Int(endpoint[endpoint.index(after: colon)...]) else {
            return nil
        }

        let rawHost = String(endpoint[..<colon])
        let host = normalizeHost(rawHost)
        return ListeningPort(
            id: "\(processName)-\(pid)-\(host)-\(port)",
            processName: processName,
            pid: pid,
            host: host,
            port: port
        )
    }

    private static func normalizeHost(_ host: String) -> String {
        if host == "*" || host == "0.0.0.0" || host == "::" {
            return "127.0.0.1"
        }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}
