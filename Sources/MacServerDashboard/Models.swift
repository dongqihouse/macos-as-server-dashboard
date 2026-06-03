import Foundation
import SwiftUI

struct DashboardAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var logServiceID: String?
}

enum ServiceKind: String, CaseIterable, Identifiable, Sendable {
    case local = "本机容器服务"
    case docker = "Docker 容器"

    var id: String { rawValue }
}

enum HealthState: String, Sendable {
    case online = "可连接"
    case available = "可运行"
    case offline = "不可连接"
    case running = "运行中"
    case configured = "已配置"
    case unknown = "未知"

    var tint: Color {
        switch self {
        case .online, .available, .running:
            return .green
        case .offline:
            return .red
        case .configured:
            return .blue
        case .unknown:
            return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .online, .available, .running:
            return "checkmark.circle.fill"
        case .offline:
            return "xmark.circle.fill"
        case .configured:
            return "gearshape.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }
}

struct DashboardConfig: Codable, Sendable {
    var refreshIntervalSeconds: Double
    var desktopPinned: Bool
    var startConfiguredLocalServicesOnLaunch: Bool
    var localServices: [LocalServiceConfig]
    var portNotes: [String: String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case refreshIntervalSeconds
        case desktopPinned
        case startConfiguredLocalServicesOnLaunch
        case localServices
        case portNotes
    }

    init(
        refreshIntervalSeconds: Double = 5,
        desktopPinned: Bool = true,
        startConfiguredLocalServicesOnLaunch: Bool = false,
        localServices: [LocalServiceConfig] = [],
        portNotes: [String: String] = [:]
    ) {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.desktopPinned = desktopPinned
        self.startConfiguredLocalServicesOnLaunch = startConfiguredLocalServicesOnLaunch
        self.localServices = localServices
        self.portNotes = portNotes
    }

    init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: RawConfigKey.self)
        let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknownKey = rawContainer.allKeys.first(where: { !allowedKeys.contains($0.stringValue) }) {
            throw DecodingError.dataCorruptedError(
                forKey: unknownKey,
                in: rawContainer,
                debugDescription: "Unknown dashboard config key: \(unknownKey.stringValue)"
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshIntervalSeconds = try container.decode(Double.self, forKey: .refreshIntervalSeconds)
        desktopPinned = try container.decode(Bool.self, forKey: .desktopPinned)
        startConfiguredLocalServicesOnLaunch = try container.decode(Bool.self, forKey: .startConfiguredLocalServicesOnLaunch)
        localServices = try container.decode([LocalServiceConfig].self, forKey: .localServices)
        portNotes = try container.decode([String: String].self, forKey: .portNotes)
    }

}

private struct RawConfigKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct LocalServiceConfig: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var command: String
    var workingDirectory: String?
    var autoStart: Bool
    var note: String
    var ports: [PortConfig]

    init(
        id: String,
        name: String,
        command: String,
        workingDirectory: String? = nil,
        autoStart: Bool = false,
        note: String = "",
        ports: [PortConfig] = []
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.autoStart = autoStart
        self.note = note
        self.ports = ports
    }

    static func makeID(from name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = name.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

struct PortConfig: Codable, Identifiable, Hashable, Sendable {
    var host: String
    var port: Int
    var note: String
    var protocolName: String

    var id: String {
        "\(host):\(port)/\(protocolName)"
    }

    init(
        host: String = "127.0.0.1",
        port: Int,
        note: String = "",
        protocolName: String = "tcp"
    ) {
        self.host = host
        self.port = port
        self.note = note
        self.protocolName = protocolName.lowercased()
    }
}

struct ServiceSnapshot: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var kind: ServiceKind
    var state: HealthState
    var detail: String
    var note: String
    var ports: [PortSnapshot]
}

struct PortSnapshot: Identifiable, Hashable, Sendable {
    var id: String
    var host: String
    var port: Int
    var protocolName: String
    var ownerID: String
    var ownerName: String
    var ownerKind: ServiceKind
    var state: HealthState
    var note: String
    var internalPort: Int?

    var displayEndpoint: String {
        "\(host):\(port)"
    }
}

struct SystemStatusSnapshot: Hashable, Sendable {
    var storageUsedBytes: UInt64?
    var storageTotalBytes: UInt64?
    var memoryUsedBytes: UInt64?
    var memoryTotalBytes: UInt64?
    var cpuUsagePercent: Double?
    var temperatureCelsius: Double?

    static let placeholder = SystemStatusSnapshot(
        storageUsedBytes: nil,
        storageTotalBytes: nil,
        memoryUsedBytes: nil,
        memoryTotalBytes: nil,
        cpuUsagePercent: nil,
        temperatureCelsius: nil
    )
}

struct DockerContainer: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var image: String
    var status: String
    var state: String
    var ports: [DockerPort]
}

struct DockerPort: Hashable, Sendable {
    var host: String
    var hostPort: Int
    var containerPort: Int
    var protocolName: String
}

struct ListeningPort: Identifiable, Hashable, Sendable {
    var id: String
    var processName: String
    var pid: String
    var host: String
    var port: Int
}
