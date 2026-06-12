import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var store = DashboardStore()

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                WindowConfigurator(pinned: store.config.desktopPinned)
                    .frame(width: 0, height: 0)
                HeaderView(store: store)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SystemStatusView(status: store.systemStatus)
                        ServiceGroupView(kind: .local, services: store.localServices, store: store)
                        ServiceGroupView(kind: .docker, services: store.dockerServices, store: store)
                    }
                    .padding(14)
                }
            }

            if let updateProgress = store.updateProgress {
                UpdateProgressOverlay(progress: updateProgress)
            }
        }
        .frame(minWidth: 420, idealWidth: 500, minHeight: 560, idealHeight: 680)
        .background(.regularMaterial)
        .background(TextInputFocusDismissView())
        .alert(item: $store.activeAlert) { alert in
            if let logServiceID = alert.logServiceID {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text(AppText.t("Open Log", zh: "打开日志"))) {
                        store.openLocalServiceLog(serviceID: logServiceID)
                    },
                    secondaryButton: .cancel(Text(AppText.t("OK", zh: "知道了")))
                )
            }

            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(AppText.t("OK", zh: "知道了")))
            )
        }
        .alert(item: $store.updatePrompt) { prompt in
            Alert(
                title: Text(AppText.t("New Version Available \(prompt.tagName)", zh: "发现新版本 \(prompt.tagName)")),
                message: Text(AppText.t("Current version is \(AppVersion.current). \(prompt.archiveName) is available. The dashboard will restart automatically after installation.", zh: "当前版本 \(AppVersion.current)，可安装 \(prompt.archiveName)。安装完成后 dashboard 会自动重启。")),
                primaryButton: .default(Text(AppText.t("Install Update", zh: "安装更新"))) {
                    store.installAvailableUpdate()
                },
                secondaryButton: .cancel(Text(AppText.t("Later", zh: "稍后")))
            )
        }
        .task {
            store.start()
        }
    }
}

private struct UpdateProgressOverlay: View {
    var progress: UpdateProgressState

    var body: some View {
        ZStack {
            Color.black.opacity(0.08)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text(progress.title)
                    .font(.headline)
                Text(progress.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let fraction = progress.fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                } else {
                    ProgressView()
                }
            }
            .padding(16)
            .frame(width: 300)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(radius: 12)
        }
    }
}

private struct TextInputFocusDismissView: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusDismissNSView {
        FocusDismissNSView()
    }

    func updateNSView(_ nsView: FocusDismissNSView, context: Context) {}

    static func dismantleNSView(_ nsView: FocusDismissNSView, coordinator: ()) {
        nsView.removeEventMonitor()
    }
}

private final class FocusDismissNSView: NSView {
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            removeEventMonitor()
        } else {
            installEventMonitorIfNeeded()
        }
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else {
            return
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else {
                return event
            }

            if !self.eventHitsTextInput(event) {
                self.window?.makeFirstResponder(nil)
            }
            return event
        }
    }

    func removeEventMonitor() {
        guard let eventMonitor else {
            return
        }

        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func eventHitsTextInput(_ event: NSEvent) -> Bool {
        guard let contentView = window?.contentView else {
            return false
        }

        let location = event.locationInWindow
        guard let hitView = contentView.hitTest(location) else {
            return false
        }

        return hitView.hasTextInputAncestor
    }
}

private extension NSView {
    var hasTextInputAncestor: Bool {
        var currentView: NSView? = self
        while let view = currentView {
            if view is NSTextField || view is NSTextView || view is NSSearchField || view is NSComboBox {
                return true
            }
            currentView = view.superview
        }
        return false
    }
}

private struct HeaderView: View {
    @ObservedObject var store: DashboardStore
    private let toolButtonSize: CGFloat = 24

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
                        .frame(width: toolButtonSize, height: toolButtonSize)
                }
                .buttonStyle(.borderless)
                .help(AppText.t("Refresh status", zh: "刷新状态"))

                Menu {
                    Button {
                        store.toggleLaunchAgent()
                    } label: {
                        Label(
                            store.launchAgentInstalled ? AppText.t("Remove Login Item", zh: "移除开机自启") : AppText.t("Install Login Item", zh: "安装开机自启"),
                            systemImage: "bolt.fill"
                        )
                    }

                    Button {
                        store.openConfigFile()
                    } label: {
                        Label(AppText.t("Open Config", zh: "打开配置"), systemImage: "doc.text")
                    }

                    Button {
                        store.revealLogs()
                    } label: {
                        Label(AppText.t("Open Logs Folder", zh: "打开日志目录"), systemImage: "terminal")
                    }

                    Button {
                        store.openAppLog()
                    } label: {
                        Label(AppText.t("Open App Log", zh: "打开 App 日志"), systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        store.checkForUpdates()
                    } label: {
                        Label(AppText.t("Check for Updates", zh: "检查更新"), systemImage: "arrow.down.circle")
                    }

                    Divider()

                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Label(AppText.t("Quit", zh: "退出"), systemImage: "power")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: toolButtonSize, height: toolButtonSize)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(AppText.t("More actions", zh: "更多操作"))
            }

            HStack(spacing: 8) {
                Toggle(AppText.t("Pin to desktop", zh: "贴桌面"), isOn: Binding(
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
        let updated = store.lastUpdated.map { Self.dateFormatter.string(from: $0) } ?? AppText.t("Not refreshed", zh: "尚未刷新")
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
                Text(AppText.t("System Status", zh: "本机状态"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                SystemMetricTile(
                    title: AppText.t("Storage", zh: "存储"),
                    value: bytePair(used: status.storageUsedBytes, total: status.storageTotalBytes),
                    detail: percentDetail(used: status.storageUsedBytes, total: status.storageTotalBytes),
                    symbolName: "internaldrive"
                )
                SystemMetricTile(
                    title: "CPU",
                    value: percentValue(status.cpuUsagePercent),
                    detail: AppText.t("Current usage", zh: "当前占用"),
                    symbolName: "cpu"
                )
                SystemMetricTile(
                    title: AppText.t("Memory", zh: "内存"),
                    value: bytePair(used: status.memoryUsedBytes, total: status.memoryTotalBytes),
                    detail: percentDetail(used: status.memoryUsedBytes, total: status.memoryTotalBytes),
                    symbolName: "memorychip"
                )
                SystemMetricTile(
                    title: AppText.t("Network", zh: "网络"),
                    value: networkDownloadValue(status.networkDownloadBytesPerSecond),
                    detail: networkDetail(
                        reachable: status.networkReachable,
                        uploadBytesPerSecond: status.networkUploadBytesPerSecond
                    ),
                    symbolName: "network"
                )
            }
        }
    }

    private func bytePair(used: UInt64?, total: UInt64?) -> String {
        guard let used, let total, total > 0 else {
            return AppText.t("Unavailable", zh: "不可用")
        }
        return "\(formatBytes(used)) / \(formatBytes(total))"
    }

    private func percentDetail(used: UInt64?, total: UInt64?) -> String {
        guard let used, let total, total > 0 else {
            return AppText.t("Used --", zh: "已用 --")
        }
        let percent = (Double(used) / Double(total)) * 100
        return AppText.t("Used \(formatPercent(percent))", zh: "已用 \(formatPercent(percent))")
    }

    private func percentValue(_ value: Double?) -> String {
        guard let value else {
            return AppText.t("Unavailable", zh: "不可用")
        }
        return formatPercent(value)
    }

    private func networkDownloadValue(_ bytesPerSecond: Double?) -> String {
        AppText.t("Down \(formatBytesPerSecond(bytesPerSecond))", zh: "下行 \(formatBytesPerSecond(bytesPerSecond))")
    }

    private func networkDetail(reachable: Bool?, uploadBytesPerSecond: Double?) -> String {
        AppText.t(
            "Up \(formatBytesPerSecond(uploadBytesPerSecond)) · \(networkReachabilityLabel(reachable))",
            zh: "上行 \(formatBytesPerSecond(uploadBytesPerSecond)) · \(networkReachabilityLabel(reachable))"
        )
    }

    private func networkReachabilityLabel(_ value: Bool?) -> String {
        guard let value else {
            return AppText.t("Probe unavailable", zh: "探测不可用")
        }
        return value ? AppText.t("Reachable", zh: "可连接") : AppText.t("Unreachable", zh: "不可连接")
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

    private func formatBytesPerSecond(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite else {
            return "--"
        }

        let clampedBytes = min(max(bytesPerSecond, 0), Double(UInt64.max))
        return "\(formatBytes(UInt64(clampedBytes)))/s"
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
    var kind: ServiceKind
    var services: [ServiceSnapshot]
    @ObservedObject var store: DashboardStore
    @State private var showingLocalServiceEditor = false
    private let columns = [
        GridItem(.adaptive(minimum: 220), spacing: 8, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kind.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("\(services.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                if kind == .local {
                    Button {
                        showingLocalServiceEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(AppText.t("Add local service", zh: "新增本机服务"))
                }
            }

            if services.isEmpty {
                EmptyGroupHint(title: kind.displayName)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
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
            Text(AppText.t("No \(title)", zh: "暂无\(title)"))
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
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .confirmationDialog(AppText.t("Delete local service?", zh: "删除本机服务？"), isPresented: $showingDeleteConfirmation) {
            Button(AppText.t("Delete", zh: "删除"), role: .destructive) {
                store.removeLocalService(serviceID: service.id)
            }
            Button(AppText.t("Cancel", zh: "取消"), role: .cancel) {}
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: service.state.symbolName)
                    .foregroundStyle(service.state.tint)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localServiceTitle)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(service.state.displayName)
                        .font(.caption)
                        .foregroundStyle(service.state.tint)
                }

                Spacer(minLength: 0)
            }

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
                    Text(service.state.displayName)
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
                .help(AppText.t("Stop", zh: "停止"))
            } else {
                Button {
                    store.startLocalService(serviceID: service.id)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help(AppText.t("Start", zh: "启动"))
            }

            Button {
                editingService = store.localServiceConfig(serviceID: service.id)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(AppText.t("Edit", zh: "编辑"))

            Button {
                showingDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help(AppText.t("Delete", zh: "删除"))

            Button {
                viewingLogService = store.localServiceConfig(serviceID: service.id)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(AppText.t("View logs", zh: "查看日志"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(snapshot.ownerKind.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            TextField(AppText.t("Note", zh: "备注"), text: Binding(
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
    private let bottomID = "log-bottom"
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppText.t("\(service.name) Logs", zh: "\(service.name) 日志"))
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
                .help(AppText.t("Refresh logs", zh: "刷新日志"))

                Button {
                    store.openLocalServiceLog(serviceID: service.id)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help(AppText.t("Open log file", zh: "打开日志文件"))

                Button(AppText.t("Close", zh: "关闭")) {
                    dismiss()
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(logText.isEmpty ? AppText.t("No logs yet", zh: "暂无日志") : logText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                }
                .onChange(of: logText) {
                    scrollToBottom(proxy)
                }
                .onAppear {
                    scrollToBottom(proxy)
                }
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
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
                Text(service == nil ? AppText.t("Add Local Service", zh: "新增本机容器服务") : AppText.t("Edit Local Service", zh: "编辑本机容器服务"))
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField(AppText.t("Name", zh: "名称"), text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField(AppText.t("Start command", zh: "启动命令"), text: $command)
                    .textFieldStyle(.roundedBorder)
                TextField(AppText.t("Working directory", zh: "工作目录"), text: $workingDirectory)
                    .textFieldStyle(.roundedBorder)
                TextField(AppText.t("Service note", zh: "服务备注"), text: $note)
                    .textFieldStyle(.roundedBorder)
                Toggle(AppText.t("Start with dashboard", zh: "随 dashboard 启动"), isOn: $autoStart)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(AppText.t("Monitored ports (optional)", zh: "监控端口（可选）"))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Button {
                        ports.append(LocalServicePortDraft())
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(AppText.t("Add monitored port", zh: "添加监控端口"))
                }

                ForEach($ports) { $port in
                    HStack(spacing: 8) {
                        TextField(AppText.t("Probe Host", zh: "检测 Host"), text: $port.host)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        TextField(AppText.t("Probe Port", zh: "检测 Port"), text: $port.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        TextField(AppText.t("Note", zh: "备注"), text: $port.note)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            removePortDraft(port.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(ports.count == 1)
                        .help(AppText.t("Remove monitored port", zh: "删除监控端口"))
                    }
                    .font(.caption)
                }
            }

            HStack {
                Spacer()
                Button(AppText.t("Cancel", zh: "取消")) {
                    dismiss()
                }
                Button(AppText.t("Save", zh: "保存")) {
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
