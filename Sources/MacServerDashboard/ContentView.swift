import SwiftUI

struct ContentView: View {
    @StateObject private var store = DashboardStore()

    var body: some View {
        VStack(spacing: 0) {
            WindowConfigurator(pinned: store.config.desktopPinned)
                .frame(width: 0, height: 0)
            HeaderView(store: store)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ServiceGroupView(title: ServiceKind.local.rawValue, services: store.localServices, store: store)
                    ServiceGroupView(title: ServiceKind.docker.rawValue, services: store.dockerServices, store: store)
                    SystemStatusView(status: store.systemStatus)
                }
                .padding(14)
            }
        }
        .frame(minWidth: 420, idealWidth: 500, minHeight: 560, idealHeight: 680)
        .background(.regularMaterial)
        .alert(item: $store.activeAlert) { alert in
            if let logServiceID = alert.logServiceID {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("打开日志")) {
                        store.openLocalServiceLog(serviceID: logServiceID)
                    },
                    secondaryButton: .cancel(Text("知道了"))
                )
            }

            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .alert(item: $store.updatePrompt) { prompt in
            Alert(
                title: Text("发现新版本 \(prompt.tagName)"),
                message: Text("当前版本 \(AppVersion.current)，可安装 \(prompt.archiveName)。安装完成后 dashboard 会自动重启。"),
                primaryButton: .default(Text("安装更新")) {
                    store.installAvailableUpdate()
                },
                secondaryButton: .cancel(Text("稍后"))
            )
        }
        .task {
            store.start()
        }
    }
}

private struct HeaderView: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac Server Dashboard")
                        .font(.headline)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新状态")

                Menu {
                    Button {
                        store.toggleLaunchAgent()
                    } label: {
                        Label(store.launchAgentInstalled ? "移除开机自启" : "安装开机自启", systemImage: "bolt.fill")
                    }

                    Button {
                        store.openConfigFile()
                    } label: {
                        Label("打开配置", systemImage: "doc.text")
                    }

                    Button {
                        store.revealLogs()
                    } label: {
                        Label("打开日志目录", systemImage: "terminal")
                    }

                    Button {
                        store.checkForUpdates()
                    } label: {
                        Label("检查更新", systemImage: "arrow.down.circle")
                    }

                    Divider()

                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Label("退出", systemImage: "power")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("更多操作")
            }

            HStack(spacing: 8) {
                Toggle("贴桌面", isOn: Binding(
                    get: { store.config.desktopPinned },
                    set: { store.setDesktopPinned($0) }
                ))
                .toggleStyle(.switch)
            }
            .font(.caption)
        }
        .padding(14)
    }

    private var statusLine: String {
        let updated = store.lastUpdated.map { Self.dateFormatter.string(from: $0) } ?? "尚未刷新"
        return "\(store.message) · v\(AppVersion.current) · \(updated)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct SystemStatusView: View {
    var status: SystemStatusSnapshot

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本机状态")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                SystemMetricTile(
                    title: "存储",
                    value: bytePair(used: status.storageUsedBytes, total: status.storageTotalBytes),
                    detail: percentDetail(used: status.storageUsedBytes, total: status.storageTotalBytes),
                    symbolName: "internaldrive"
                )
                SystemMetricTile(
                    title: "CPU",
                    value: percentValue(status.cpuUsagePercent),
                    detail: "当前占用",
                    symbolName: "cpu"
                )
                SystemMetricTile(
                    title: "内存",
                    value: bytePair(used: status.memoryUsedBytes, total: status.memoryTotalBytes),
                    detail: percentDetail(used: status.memoryUsedBytes, total: status.memoryTotalBytes),
                    symbolName: "memorychip"
                )
                SystemMetricTile(
                    title: "温度",
                    value: temperatureValue(status.temperatureCelsius),
                    detail: status.temperatureCelsius == nil ? "传感器不可读" : "CPU 温度",
                    symbolName: "thermometer.medium"
                )
            }
        }
    }

    private func bytePair(used: UInt64?, total: UInt64?) -> String {
        guard let used, let total, total > 0 else {
            return "不可用"
        }
        return "\(formatBytes(used)) / \(formatBytes(total))"
    }

    private func percentDetail(used: UInt64?, total: UInt64?) -> String {
        guard let used, let total, total > 0 else {
            return "已用 --"
        }
        let percent = (Double(used) / Double(total)) * 100
        return "已用 \(formatPercent(percent))"
    }

    private func percentValue(_ value: Double?) -> String {
        guard let value else {
            return "不可用"
        }
        return formatPercent(value)
    }

    private func temperatureValue(_ value: Double?) -> String {
        guard let value else {
            return "不可用"
        }
        return String(format: "%.1f°C", value)
    }

    private func formatPercent(_ value: Double) -> String {
        if value >= 10 {
            return String(format: "%.0f%%", value)
        }
        return String(format: "%.1f%%", value)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 || value >= 100 {
            return String(format: "%.0f %@", value, units[unitIndex])
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

private struct SystemMetricTile: View {
    var title: String
    var value: String
    var detail: String
    var symbolName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(minHeight: 66)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ServiceGroupView: View {
    var title: String
    var services: [ServiceSnapshot]
    @ObservedObject var store: DashboardStore
    @State private var showingLocalServiceEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("\(services.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                if title == ServiceKind.local.rawValue {
                    Button {
                        showingLocalServiceEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("新增本机服务")
                }
            }

            if services.isEmpty {
                EmptyGroupHint(title: title)
            } else {
                VStack(spacing: 8) {
                    ForEach(services) { service in
                        ServiceRow(service: service, store: store)
                    }
                }
            }
        }
        .sheet(isPresented: $showingLocalServiceEditor) {
            LocalServiceEditorView(store: store)
        }
    }
}

private struct EmptyGroupHint: View {
    var title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
            Text("暂无\(title)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

private struct ServiceRow: View {
    var service: ServiceSnapshot
    @ObservedObject var store: DashboardStore
    @State private var showingDeleteConfirmation = false
    @State private var editingService: LocalServiceConfig?
    @State private var viewingLogService: LocalServiceConfig?

    var body: some View {
        Group {
            if service.kind == .local {
                localServiceBody
            } else {
                defaultServiceBody
            }
        }
        .padding(10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .confirmationDialog("删除本机服务？", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                store.removeLocalService(serviceID: service.id)
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $editingService) { service in
            LocalServiceEditorView(store: store, service: service)
        }
        .sheet(item: $viewingLogService) { service in
            LocalServiceLogView(store: store, service: service)
        }
    }

    private var defaultServiceBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(name: service.name)

            if !service.detail.isEmpty || !service.note.isEmpty {
                Text(service.detail.isEmpty ? service.note : service.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 26)
            }

            if !service.ports.isEmpty {
                VStack(spacing: 6) {
                    ForEach(service.ports) { port in
                        PortRow(snapshot: port, store: store)
                    }
                }
            }
        }
    }

    private var localServiceBody: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: service.state.symbolName)
                .foregroundStyle(service.state.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(localServiceTitle)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(service.state.rawValue)
                    .font(.caption)
                    .foregroundStyle(service.state.tint)
            }

            Spacer()

            localServiceActions
        }
    }

    private func header(name: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: service.state.symbolName)
                .foregroundStyle(service.state.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    Text(service.state.rawValue)
                        .font(.caption)
                        .foregroundStyle(service.state.tint)
                }
            }
        }
    }

    private var localServiceActions: some View {
        HStack(spacing: 12) {
            if store.isLocalServiceRunning(serviceID: service.id) {
                Button {
                    store.stopLocalService(serviceID: service.id)
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("停止")
            } else {
                Button {
                    store.startLocalService(serviceID: service.id)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("启动")
            }

            Button {
                editingService = store.localServiceConfig(serviceID: service.id)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑")

            Button {
                showingDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("删除")

            Button {
                viewingLogService = store.localServiceConfig(serviceID: service.id)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("查看日志")
        }
    }

    private var localServiceTitle: String {
        guard !service.ports.isEmpty else {
            return service.name
        }

        let ports = service.ports
            .map { String($0.port) }
            .joined(separator: ",")
        return "\(service.name):\(ports)"
    }
}

private struct PortRow: View {
    var snapshot: PortSnapshot
    @ObservedObject var store: DashboardStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot.state.symbolName)
                .foregroundStyle(snapshot.state.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(snapshot.displayEndpoint)
                        .font(.caption)
                        .monospaced()
                    if let internalPort = snapshot.internalPort {
                        Text("→ \(internalPort)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(snapshot.ownerKind.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            TextField("备注", text: Binding(
                get: { snapshot.note },
                set: { store.setPortNote(snapshot, note: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.caption)
        }
    }
}

private struct LocalServiceLogView: View {
    @ObservedObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss
    var service: LocalServiceConfig
    @State private var logText = ""
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(service.name) 日志")
                        .font(.headline)
                    Text(service.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    refreshLog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新日志")

                Button {
                    store.openLocalServiceLog(serviceID: service.id)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("打开日志文件")

                Button("关闭") {
                    dismiss()
                }
            }

            ScrollView {
                Text(logText.isEmpty ? "暂无日志" : logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(16)
        .frame(width: 720, height: 520)
        .onAppear(perform: refreshLog)
        .onReceive(refreshTimer) { _ in
            refreshLog()
        }
    }

    private func refreshLog() {
        logText = store.localServiceLogText(serviceID: service.id)
    }
}

private struct LocalServiceEditorView: View {
    @ObservedObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss
    private let service: LocalServiceConfig?
    @State private var name = ""
    @State private var command = ""
    @State private var workingDirectory = ""
    @State private var note = ""
    @State private var autoStart = false
    @State private var ports = [LocalServicePortDraft()]

    init(store: DashboardStore, service: LocalServiceConfig? = nil) {
        self.store = store
        self.service = service
        _name = State(initialValue: service?.name ?? "")
        _command = State(initialValue: service?.command ?? "")
        _workingDirectory = State(initialValue: service?.workingDirectory ?? "")
        _note = State(initialValue: service?.note ?? "")
        _autoStart = State(initialValue: service?.autoStart ?? false)
        _ports = State(initialValue: Self.portDrafts(from: service))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(service == nil ? "新增本机容器服务" : "编辑本机容器服务")
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("启动命令", text: $command)
                    .textFieldStyle(.roundedBorder)
                TextField("工作目录", text: $workingDirectory)
                    .textFieldStyle(.roundedBorder)
                TextField("服务备注", text: $note)
                    .textFieldStyle(.roundedBorder)
                Toggle("随 dashboard 启动", isOn: $autoStart)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("监控端口（可选）")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Button {
                        ports.append(LocalServicePortDraft())
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("添加监控端口")
                }

                ForEach($ports) { $port in
                    HStack(spacing: 8) {
                        TextField("检测 Host", text: $port.host)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        TextField("检测 Port", text: $port.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        TextField("备注", text: $port.note)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            removePortDraft(port.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(ports.count == 1)
                        .help("删除监控端口")
                    }
                    .font(.caption)
                }
            }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 500)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            parsedPorts != nil
    }

    private var parsedPorts: [PortConfig]? {
        var result: [PortConfig] = []

        for draft in ports {
            let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let portText = draft.port.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)

            if host.isEmpty && portText.isEmpty && note.isEmpty {
                continue
            }

            guard let port = Int(portText), port > 0, port <= 65535 else {
                return nil
            }

            result.append(
                PortConfig(
                    host: host.isEmpty ? "127.0.0.1" : host,
                    port: port,
                    note: note
                )
            )
        }

        return result
    }

    private func save() {
        guard let parsedPorts else {
            return
        }

        let didSave: Bool
        if let service {
            didSave = store.updateLocalService(
                serviceID: service.id,
                name: name,
                command: command,
                workingDirectory: workingDirectory,
                autoStart: autoStart,
                note: note,
                ports: parsedPorts
            )
        } else {
            didSave = store.addLocalService(
                name: name,
                command: command,
                workingDirectory: workingDirectory,
                autoStart: autoStart,
                note: note,
                ports: parsedPorts
            )
        }

        if didSave {
            dismiss()
        }
    }

    private func removePortDraft(_ id: UUID) {
        guard ports.count > 1 else {
            return
        }
        ports.removeAll { $0.id == id }
    }

    private static func portDrafts(from service: LocalServiceConfig?) -> [LocalServicePortDraft] {
        guard let service, !service.ports.isEmpty else {
            return [LocalServicePortDraft()]
        }

        return service.ports.map { LocalServicePortDraft(port: $0) }
    }
}

private struct LocalServicePortDraft: Identifiable {
    var id = UUID()
    var host = "127.0.0.1"
    var port = ""
    var note = ""

    init() {}

    init(port: PortConfig) {
        host = port.host
        self.port = String(port.port)
        note = port.note
    }
}
