import AppKit
import Darwin
import Foundation

@MainActor
final class DashboardStore: ObservableObject {
    @Published private(set) var config = DashboardConfig()
    @Published private(set) var localServices: [ServiceSnapshot] = []
    @Published private(set) var dockerServices: [ServiceSnapshot] = []
    @Published private(set) var systemStatus = SystemStatusSnapshot.placeholder
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var message = AppText.t("Initializing", zh: "正在初始化")
    @Published private(set) var launchAgentInstalled = LaunchAgentManager.isInstalled
    @Published private(set) var localServiceRuntimeMessages: [String: String] = [:]
    @Published var activeAlert: DashboardAlert?
    @Published var updatePrompt: UpdatePrompt?
    @Published var updateProgress: UpdateProgressState?

    private var refreshTimer: Timer?
    private var refreshTimerInterval: TimeInterval?
    private var configFileWatcher: DispatchSourceFileSystemObject?
    private var configFileDescriptor: CInt = -1
    private var pendingConfigReload: DispatchWorkItem?
    private var isRefreshing = false
    private var pendingRefresh = false
    private var configVersion = 0
    private var startedProcesses: [String: Process] = [:]
    private var localServiceLaunchIDs: [String: UUID] = [:]
    private var localServiceLaunchReclaimAttempts: [UUID: Bool] = [:]
    private var stoppingServiceIDs = Set<String>()
    private var lastAlertSignature: String?
    private var configLoadFailureReason: String?
    private var availableUpdate: AvailableUpdate?
    private var isCheckingForUpdates = false
    private var isInstallingUpdate = false

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacServerDashboard", isDirectory: true)
    }

    static var configURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    func start() {
        AppLogger.ensureLogFileExists()
        AppLogger.info("Dashboard starting version=\(AppVersion.current) pid=\(ProcessInfo.processInfo.processIdentifier)")
        ensureConfigExists()
        loadConfig()
        launchAgentInstalled = LaunchAgentManager.isInstalled
        startConfigFileWatcher()

        startConfiguredLocalServices()
        configureRefreshTimer()

        Task {
            await refresh()
        }
    }

    func refresh() async {
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }

        let refreshConfigVersion = configVersion
        isRefreshing = true
        message = AppText.t("Refreshing", zh: "正在刷新")
        AppLogger.info("Refresh started configVersion=\(refreshConfigVersion)")
        loadConfig()
        let currentConfig = config

        async let dockerContainersTask = DockerDiscovery.discover()
        async let systemStatusTask = SystemStatusDiscovery.snapshot()

        let localSnapshots = await buildLocalServiceSnapshots(from: currentConfig)
        let dockerContainers = await dockerContainersTask
        let dockerSnapshots = await buildDockerSnapshots(containers: dockerContainers, config: currentConfig)
        let status = await systemStatusTask

        guard refreshConfigVersion == configVersion else {
            pendingRefresh = true
            isRefreshing = false
            AppLogger.info("Refresh deferred due to config change refreshVersion=\(refreshConfigVersion) currentVersion=\(configVersion)")
            runPendingRefreshIfNeeded()
            return
        }

        localServices = localSnapshots
        dockerServices = dockerSnapshots
        systemStatus = status
        lastUpdated = Date()
        message = AppText.t("Refreshed", zh: "已刷新")
        AppLogger.info(
            "Refresh completed local=\(localSnapshots.count) docker=\(dockerSnapshots.count) " +
                "storage=\(status.storageUsedBytes != nil) cpu=\(status.cpuUsagePercent != nil) memory=\(status.memoryUsedBytes != nil) network=\(status.networkReachable.map { String($0) } ?? "unknown")"
        )
        isRefreshing = false
        runPendingRefreshIfNeeded()
    }

    func openConfigFile() {
        ensureConfigExists()
        NSWorkspace.shared.open(Self.configURL)
    }

    func checkForUpdates() {
        guard !isCheckingForUpdates, !isInstallingUpdate else {
            return
        }

        isCheckingForUpdates = true
        updateProgress = nil
        message = AppText.t("Checking for updates", zh: "正在检查更新")
        AppLogger.info("Checking for updates")
        Task {
            do {
                let update = try await UpdateManager.checkForUpdate()
                isCheckingForUpdates = false

                guard let update else {
                    message = AppText.t("Already up to date", zh: "已是最新版本")
                    AppLogger.info("No update available current=\(AppVersion.current)")
                    showError(
                        title: AppText.t("Already Up to Date", zh: "已是最新版本"),
                        message: AppText.t("Current version \(AppVersion.current) is already the latest version.", zh: "当前版本 \(AppVersion.current) 已是最新版本。")
                    )
                    return
                }

                availableUpdate = update
                message = AppText.t("New version found \(update.tagName)", zh: "发现新版本 \(update.tagName)")
                AppLogger.info("Update available tag=\(update.tagName) asset=\(update.archiveName)")
                updatePrompt = UpdatePrompt(
                    tagName: update.tagName,
                    version: update.version,
                    archiveName: update.archiveName
                )
            } catch {
                isCheckingForUpdates = false
                message = AppText.t("Check for updates failed", zh: "检查更新失败")
                AppLogger.error("Check update failed: \(error.localizedDescription)")
                showError(title: AppText.t("Check for Updates Failed", zh: "检查更新失败"), message: error.localizedDescription)
            }
        }
    }

    func installAvailableUpdate() {
        guard !isInstallingUpdate, let update = availableUpdate else {
            return
        }

        isInstallingUpdate = true
        message = AppText.t("Installing \(update.tagName)", zh: "正在安装 \(update.tagName)")
        updateProgress = UpdateProgressState(
            title: AppText.t("Installing \(update.tagName)", zh: "正在安装 \(update.tagName)"),
            detail: AppText.t("Preparing to download update", zh: "准备下载更新"),
            fraction: 0.02
        )
        AppLogger.info("Installing update tag=\(update.tagName) asset=\(update.archiveName)")
        Task {
            do {
                let installedURL = try await UpdateManager.install(update) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateProgress = UpdateProgressState(
                            title: AppText.t("Installing \(update.tagName)", zh: "正在安装 \(update.tagName)"),
                            detail: progress.detail,
                            fraction: progress.fraction
                        )
                        self?.message = progress.detail
                    }
                }
                isInstallingUpdate = false
                availableUpdate = nil
                message = AppText.t("Installed \(update.tagName), restarting", zh: "已安装 \(update.tagName)，正在重启")
                updateProgress = UpdateProgressState(
                    title: AppText.t("Installing \(update.tagName)", zh: "正在安装 \(update.tagName)"),
                    detail: AppText.t("Restarting dashboard", zh: "正在重启 dashboard"),
                    fraction: 0.98
                )
                AppLogger.info("Update installed tag=\(update.tagName) executable=\(installedURL.path)")
                do {
                    try UpdateManager.relaunch(from: installedURL)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    NSApplication.shared.terminate(nil)
                } catch {
                    message = AppText.t("Installed \(update.tagName)", zh: "已安装 \(update.tagName)")
                    updateProgress = nil
                    AppLogger.error("Relaunch failed after update tag=\(update.tagName): \(error.localizedDescription)")
                    showError(
                        title: AppText.t("Update Installed", zh: "更新已安装"),
                        message: AppText.t("Installed \(update.tagName), but automatic restart failed: \(error.localizedDescription)\n\nPlease reopen manually: \(installedURL.path)", zh: "已安装 \(update.tagName)，但自动重启失败：\(error.localizedDescription)\n\n请手动重新打开：\(installedURL.path)")
                    )
                }
            } catch {
                isInstallingUpdate = false
                updateProgress = nil
                message = AppText.t("Install update failed", zh: "安装更新失败")
                AppLogger.error("Install update failed tag=\(update.tagName): \(error.localizedDescription)")
                showError(title: AppText.t("Install Update Failed", zh: "安装更新失败"), message: error.localizedDescription)
            }
        }
    }

    func revealLogs() {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacServerDashboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logsDirectory)
    }

    func openAppLog() {
        AppLogger.ensureLogFileExists()
        NSWorkspace.shared.open(AppLogger.appLogURL)
    }

    func openLocalServiceLog(serviceID: String) {
        guard let url = try? CommandRunner.logFileURL(logName: serviceID) else {
            message = AppText.t("Open log failed", zh: "打开日志失败")
            showError(
                title: AppText.t("Open Log Failed", zh: "打开日志失败"),
                message: AppText.t("Could not create or open the log file for this service.", zh: "无法创建或打开该服务的日志文件。")
            )
            return
        }
        NSWorkspace.shared.open(url)
    }

    func localServiceLogText(serviceID: String) -> String {
        CommandRunner.logText(logName: serviceID)
    }

    func setPortNote(_ snapshot: PortSnapshot, note: String) {
        var nextConfig = config
        let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines)

        switch snapshot.ownerKind {
        case .local:
            if let serviceIndex = nextConfig.localServices.firstIndex(where: { $0.id == snapshot.ownerID }),
               let portIndex = nextConfig.localServices[serviceIndex].ports.firstIndex(where: { portKey($0) == portKey(host: snapshot.host, port: snapshot.port, protocolName: snapshot.protocolName) }) {
                nextConfig.localServices[serviceIndex].ports[portIndex].note = normalized
            }
        case .docker:
            storeDiscoveredPortNote(in: &nextConfig, host: snapshot.host, port: snapshot.port, protocolName: snapshot.protocolName, note: normalized)
        }

        saveConfig(nextConfig)
        applyNoteLocally(snapshotID: snapshot.id, note: normalized)
    }

    func setLocalServiceAutoStart(serviceID: String, enabled: Bool) {
        var nextConfig = config
        guard let index = nextConfig.localServices.firstIndex(where: { $0.id == serviceID }) else {
            return
        }
        nextConfig.localServices[index].autoStart = enabled
        if saveConfig(nextConfig) {
            applyLocalServicesImmediately(from: nextConfig)
        }
    }

    func localServiceConfig(serviceID: String) -> LocalServiceConfig? {
        config.localServices.first { $0.id == serviceID }
    }

    func addLocalService(
        name: String,
        command: String,
        workingDirectory: String,
        autoStart: Bool,
        note: String,
        ports: [PortConfig]
    ) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWorkingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty, !trimmedCommand.isEmpty else {
            message = AppText.t("Name and command are required", zh: "名称和命令不能为空")
            showError(
                title: AppText.t("Invalid Local Service Config", zh: "本机服务配置无效"),
                message: AppText.t("Name and start command are required.", zh: "名称和启动命令不能为空。")
            )
            return false
        }

        var nextConfig = config
        let id = makeUniqueLocalServiceID(name: trimmedName, existingIDs: Set(nextConfig.localServices.map(\.id)))
        let service = LocalServiceConfig(
            id: id,
            name: trimmedName,
            command: trimmedCommand,
            workingDirectory: trimmedWorkingDirectory.isEmpty ? nil : trimmedWorkingDirectory,
            autoStart: autoStart,
            note: trimmedNote,
            ports: ports
        )

        nextConfig.localServices.append(service)
        guard saveConfig(nextConfig) else {
            return false
        }
        applyLocalServicesImmediately(from: nextConfig)
        message = AppText.t("Added \(trimmedName)", zh: "已添加 \(trimmedName)")
        Task { await refresh() }
        return true
    }

    func updateLocalService(
        serviceID: String,
        name: String,
        command: String,
        workingDirectory: String,
        autoStart: Bool,
        note: String,
        ports: [PortConfig]
    ) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWorkingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty, !trimmedCommand.isEmpty else {
            message = AppText.t("Name and command are required", zh: "名称和命令不能为空")
            showError(
                title: AppText.t("Invalid Local Service Config", zh: "本机服务配置无效"),
                message: AppText.t("Name and start command are required.", zh: "名称和启动命令不能为空。")
            )
            return false
        }

        var nextConfig = config
        guard let index = nextConfig.localServices.firstIndex(where: { $0.id == serviceID }) else {
            message = AppText.t("Service to edit was not found", zh: "没有找到要编辑的服务")
            showError(
                title: AppText.t("Edit Failed", zh: "编辑失败"),
                message: AppText.t("Could not find the local service to edit.", zh: "没有找到要编辑的本机服务。")
            )
            return false
        }

        nextConfig.localServices[index] = LocalServiceConfig(
            id: serviceID,
            name: trimmedName,
            command: trimmedCommand,
            workingDirectory: trimmedWorkingDirectory.isEmpty ? nil : trimmedWorkingDirectory,
            autoStart: autoStart,
            note: trimmedNote,
            ports: ports
        )

        guard saveConfig(nextConfig) else {
            return false
        }
        applyLocalServicesImmediately(from: nextConfig)
        message = AppText.t("Updated \(trimmedName)", zh: "已更新 \(trimmedName)")
        Task { await refresh() }
        return true
    }

    func removeLocalService(serviceID: String) {
        var nextConfig = config
        guard let index = nextConfig.localServices.firstIndex(where: { $0.id == serviceID }) else {
            message = AppText.t("Service to delete was not found", zh: "没有找到要删除的服务")
            showError(
                title: AppText.t("Delete Failed", zh: "删除失败"),
                message: AppText.t("Could not find the local service to delete.", zh: "没有找到要删除的本机服务。")
            )
            return
        }

        _ = stopLocalServiceProcess(serviceID: serviceID)
        let name = nextConfig.localServices[index].name
        nextConfig.localServices.remove(at: index)
        guard saveConfig(nextConfig) else {
            return
        }
        applyLocalServicesImmediately(from: nextConfig)
        message = AppText.t("Deleted \(name)", zh: "已删除 \(name)")
        Task { await refresh() }
    }

    func startLocalService(serviceID: String) {
        guard let service = config.localServices.first(where: { $0.id == serviceID }) else {
            return
        }
        startLocalService(service)
        Task { await refresh() }
    }

    func stopLocalService(serviceID: String) {
        if stopLocalServiceProcess(serviceID: serviceID) {
            message = AppText.t("Service stopped", zh: "已停止服务")
            Task { await refresh() }
        }
    }

    func isLocalServiceRunning(serviceID: String) -> Bool {
        startedProcesses[serviceID]?.isRunning ?? false
    }

    func localServiceRuntimeMessage(serviceID: String) -> String? {
        localServiceRuntimeMessages[serviceID]
    }

    func setStartConfiguredServices(_ enabled: Bool) {
        var nextConfig = config
        nextConfig.startConfiguredLocalServicesOnLaunch = enabled
        saveConfig(nextConfig)
    }

    func setDesktopPinned(_ pinned: Bool) {
        var nextConfig = config
        nextConfig.desktopPinned = pinned
        saveConfig(nextConfig)
        WindowConfigurator.applyToAllWindows(pinned: pinned)
    }

    func startConfiguredLocalServices() {
        for service in config.localServices where service.autoStart && !service.command.isEmpty {
            startLocalService(service, reclaimAttempted: false)
        }
    }

    func toggleLaunchAgent() {
        Task {
            do {
                if LaunchAgentManager.isInstalled {
                    try await LaunchAgentManager.uninstall()
                    message = AppText.t("Login item removed", zh: "已移除开机自启")
                } else {
                    try await LaunchAgentManager.install()
                    message = AppText.t("Login item installed", zh: "已安装开机自启")
                }
                launchAgentInstalled = LaunchAgentManager.isInstalled
            } catch {
                message = AppText.t("Login item change failed: \(error.localizedDescription)", zh: "开机自启变更失败：\(error.localizedDescription)")
                showError(title: AppText.t("Login Item Change Failed", zh: "开机自启变更失败"), message: error.localizedDescription)
            }
        }
    }

    private func buildLocalServiceSnapshots(from config: DashboardConfig) async -> [ServiceSnapshot] {
        return await withTaskGroup(of: ServiceSnapshot.self, returning: [ServiceSnapshot].self) { group in
            for service in config.localServices {
                let service = service
                group.addTask {
                    let ports = await Self.checkPorts(
                        service.ports,
                        ownerID: service.id,
                        ownerName: service.name,
                        ownerKind: .local,
                        internalPort: nil
                    )
	                    let processState: HealthState = await MainActor.run {
	                        if let process = self.startedProcesses[service.id], process.isRunning {
	                            return .running
	                        }
	                        return Self.localServiceState(from: ports)
	                    }

                    return ServiceSnapshot(
                        id: service.id,
                        name: service.name,
                        kind: .local,
                        state: processState,
                        detail: service.command,
                        note: service.note,
                        ports: ports
                    )
                }
            }

            var snapshots: [ServiceSnapshot] = []
            for await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func buildDockerSnapshots(containers: [DockerContainer], config: DashboardConfig) async -> [ServiceSnapshot] {
        return await withTaskGroup(of: ServiceSnapshot.self, returning: [ServiceSnapshot].self) { group in
            for container in containers {
                let container = container
                group.addTask {
                    let portConfigs = container.ports.map {
                        PortConfig(host: $0.host, port: $0.hostPort, note: noteFor(host: $0.host, port: $0.hostPort, protocolName: $0.protocolName, config: config), protocolName: $0.protocolName)
                    }
                    let checked = await Self.checkPorts(
                        portConfigs,
                        ownerID: container.id,
                        ownerName: container.name,
                        ownerKind: .docker,
                        internalPort: nil
                    )
                    let dockerPorts = checked.map { snapshot in
                        var next = snapshot
                        if let dockerPort = container.ports.first(where: { $0.host == snapshot.host && $0.hostPort == snapshot.port }) {
                            next.internalPort = dockerPort.containerPort
                        }
                        return next
                    }

                    return ServiceSnapshot(
                        id: container.id,
                        name: container.name,
                        kind: .docker,
                        state: dockerPorts.isEmpty ? .running : Self.aggregateState(dockerPorts),
                        detail: container.image.isEmpty ? container.status : "\(container.image) · \(container.status)",
                        note: "",
                        ports: dockerPorts
                    )
                }
            }

            var snapshots: [ServiceSnapshot] = []
            for await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    nonisolated private static func checkPorts(
        _ ports: [PortConfig],
        ownerID: String,
        ownerName: String,
        ownerKind: ServiceKind,
        internalPort: Int?
    ) async -> [PortSnapshot] {
        return await withTaskGroup(of: PortSnapshot.self, returning: [PortSnapshot].self) { group in
            for port in ports where port.protocolName == "tcp" {
                let port = port
                group.addTask {
                    let state = await checkTCP(host: port.host, port: port.port)
                    return PortSnapshot(
                        id: "\(ownerKind.rawValue)-\(ownerID)-\(port.host)-\(port.port)-\(port.protocolName)",
                        host: port.host,
                        port: port.port,
                        protocolName: port.protocolName,
                        ownerID: ownerID,
                        ownerName: ownerName,
                        ownerKind: ownerKind,
                        state: state,
                        note: port.note,
                        internalPort: internalPort
                    )
                }
            }

            var snapshots: [PortSnapshot] = []
            for await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots.sorted { $0.port < $1.port }
        }
    }

    nonisolated private static func checkTCP(host: String, port: Int) async -> HealthState {
        let command = "nc -G 1 -z \(CommandRunner.shellEscaped(host)) \(port)"
        let result = await CommandRunner.run(command, timeout: 2)
        return result.exitCode == 0 ? .online : .offline
    }

	    nonisolated private static func aggregateState(_ ports: [PortSnapshot]) -> HealthState {
	        guard !ports.isEmpty else {
	            return .unknown
	        }
        if ports.contains(where: { $0.state == .online }) {
            return .online
        }
        if ports.allSatisfy({ $0.state == .offline }) {
            return .offline
	        }
	        return .unknown
	    }

	    nonisolated private static func localServiceState(from ports: [PortSnapshot]) -> HealthState {
	        guard !ports.isEmpty else {
	            return .configured
	        }

	        let aggregateState = aggregateState(ports)
	        return aggregateState == .online ? .available : aggregateState
	    }

    private func ensureConfigExists() {
        if FileManager.default.fileExists(atPath: Self.configURL.path) {
            return
        }

        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(DashboardConfig())
            try data.write(to: Self.configURL, options: .atomic)
        } catch {
            message = AppText.t("Create config failed: \(error.localizedDescription)", zh: "创建配置失败：\(error.localizedDescription)")
            showError(title: AppText.t("Create Config Failed", zh: "创建配置失败"), message: error.localizedDescription)
        }
    }

    private func configureRefreshTimer() {
        let interval = max(config.refreshIntervalSeconds, 2)
        guard refreshTimerInterval != interval else {
            return
        }

        refreshTimer?.invalidate()
        refreshTimerInterval = interval
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    private func startConfigFileWatcher() {
        stopConfigFileWatcher()

        configFileDescriptor = open(Self.configURL.path, O_EVTONLY)
        guard configFileDescriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: configFileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self else {
                return
            }

            let events = source?.data ?? []
            self.scheduleConfigFileReload(reopenWatcher: events.contains(.rename) || events.contains(.delete))
        }
        source.setCancelHandler { [descriptor = configFileDescriptor] in
            if descriptor >= 0 {
                close(descriptor)
            }
        }
        source.resume()
        configFileWatcher = source
    }

    private func stopConfigFileWatcher() {
        pendingConfigReload?.cancel()
        pendingConfigReload = nil

        configFileWatcher?.cancel()
        configFileWatcher = nil
        configFileDescriptor = -1
    }

    private func scheduleConfigFileReload(reopenWatcher: Bool) {
        pendingConfigReload?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                if reopenWatcher {
                    self?.startConfigFileWatcher()
                }
                await self?.refresh()
            }
        }
        pendingConfigReload = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func loadConfig() {
        do {
            if !FileManager.default.fileExists(atPath: Self.configURL.path) {
                config = DashboardConfig()
                configLoadFailureReason = nil
                return
            }

            let data = try Data(contentsOf: Self.configURL)
            config = try JSONDecoder().decode(DashboardConfig.self, from: data)
            configLoadFailureReason = nil
            configureRefreshTimer()
        } catch {
            let reason = configReadFailureMessage(error)
            configLoadFailureReason = reason
            message = AppText.t("Read config failed: \(reason)", zh: "读取配置失败：\(reason)")
            showError(
                title: AppText.t("Read Config Failed", zh: "读取配置失败"),
                message: AppText.t(
                    "\(reason)\n\nConfig file: \(Self.configURL.path)\n\nTo avoid overwriting the original config, dashboard has blocked automatic saving. Please fix the config file and restart.",
                    zh: "\(reason)\n\n配置文件：\(Self.configURL.path)\n\n为了避免覆盖原配置，dashboard 已阻止自动保存。请修正配置文件后重新启动。"
                )
            )
        }
    }

    private func configReadFailureMessage(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }

        switch decodingError {
        case let .dataCorrupted(context):
            return AppText.t("\(context.debugDescription) (path: \(codingPathDescription(context.codingPath)))", zh: "\(context.debugDescription)（位置：\(codingPathDescription(context.codingPath))）")
        case let .keyNotFound(key, context):
            return AppText.t("Missing field \(key.stringValue) (path: \(codingPathDescription(context.codingPath)))", zh: "缺少字段 \(key.stringValue)（位置：\(codingPathDescription(context.codingPath))）")
        case let .typeMismatch(type, context):
            return AppText.t("Field type mismatch, expected \(type) (path: \(codingPathDescription(context.codingPath)))", zh: "字段类型不匹配，期望 \(type)（位置：\(codingPathDescription(context.codingPath))）")
        case let .valueNotFound(type, context):
            return AppText.t("Missing value, expected \(type) (path: \(codingPathDescription(context.codingPath)))", zh: "字段值缺失，期望 \(type)（位置：\(codingPathDescription(context.codingPath))）")
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    private func codingPathDescription(_ path: [CodingKey]) -> String {
        let value = path.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? AppText.t("root", zh: "根节点") : value
    }

    private func runPendingRefreshIfNeeded() {
        guard pendingRefresh else {
            return
        }

        pendingRefresh = false
        Task { await refresh() }
    }

    @discardableResult
    private func saveConfig(_ nextConfig: DashboardConfig) -> Bool {
        if let configLoadFailureReason {
            message = AppText.t("Save blocked: config is unreadable", zh: "保存被阻止：配置不可读")
            showError(
                title: AppText.t("Save Blocked", zh: "保存被阻止"),
                message: AppText.t(
                    "The current config file is unreadable. To avoid overwriting it, this save has been cancelled.\n\nReason: \(configLoadFailureReason)\n\nConfig file: \(Self.configURL.path)",
                    zh: "当前配置文件不可读，为避免覆盖原配置，本次保存已取消。\n\n原因：\(configLoadFailureReason)\n\n配置文件：\(Self.configURL.path)"
                )
            )
            return false
        }

        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(nextConfig)
            try data.write(to: Self.configURL, options: .atomic)
            config = nextConfig
            configVersion += 1
            message = AppText.t("Config saved", zh: "配置已保存")
            return true
        } catch {
            message = AppText.t("Save config failed: \(error.localizedDescription)", zh: "保存配置失败：\(error.localizedDescription)")
            showError(title: AppText.t("Save Config Failed", zh: "保存配置失败"), message: error.localizedDescription)
            return false
        }
    }

    private func applyNoteLocally(snapshotID: String, note: String) {
        localServices = updateNote(in: localServices, snapshotID: snapshotID, note: note)
        dockerServices = updateNote(in: dockerServices, snapshotID: snapshotID, note: note)
    }

    private func updateNote(in services: [ServiceSnapshot], snapshotID: String, note: String) -> [ServiceSnapshot] {
        services.map { service in
            var nextService = service
            nextService.ports = service.ports.map { port in
                var nextPort = port
                if port.id == snapshotID {
                    nextPort.note = note
                }
                return nextPort
            }
            return nextService
        }
    }

    private func applyLocalServicesImmediately(from config: DashboardConfig) {
        localServices = config.localServices
            .map { immediateLocalServiceSnapshot(from: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func immediateLocalServiceSnapshot(from service: LocalServiceConfig) -> ServiceSnapshot {
        let existingService = localServices.first { $0.id == service.id }
        let ports = service.ports.map { portConfig in
            if let existingPort = existingService?.ports.first(where: { portKey($0) == portKey(portConfig) }) {
                var nextPort = existingPort
                nextPort.note = portConfig.note
                return nextPort
            }

            return PortSnapshot(
                id: "\(ServiceKind.local.rawValue)-\(service.id)-\(portConfig.host)-\(portConfig.port)-\(portConfig.protocolName)",
                host: portConfig.host,
                port: portConfig.port,
                protocolName: portConfig.protocolName,
                ownerID: service.id,
                ownerName: service.name,
                ownerKind: .local,
                state: .unknown,
                note: portConfig.note,
                internalPort: nil
            )
        }

	        let state: HealthState
	        if let process = startedProcesses[service.id], process.isRunning {
	            state = .running
	        } else if ports.isEmpty {
	            state = .configured
	        } else {
	            state = Self.localServiceState(from: ports)
	        }

        return ServiceSnapshot(
            id: service.id,
            name: service.name,
            kind: .local,
            state: state,
            detail: service.command,
            note: service.note,
            ports: ports
        )
    }

    private func startLocalService(_ service: LocalServiceConfig, reclaimAttempted: Bool = false) {
        if let process = startedProcesses[service.id], process.isRunning {
            message = AppText.t("\(service.name) is already running", zh: "\(service.name) 已在运行")
            return
        }

        guard !service.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = AppText.t("\(service.name) has no start command", zh: "\(service.name) 没有启动命令")
            showError(
                title: AppText.t("Start Failed", zh: "启动失败"),
                message: AppText.t("\(service.name) has no start command.", zh: "\(service.name) 没有启动命令。")
            )
            return
        }

        localServiceRuntimeMessages[service.id] = AppText.t("Starting", zh: "正在启动")
        message = AppText.t("Starting \(service.name)", zh: "正在启动 \(service.name)")
        let launchID = UUID()
        localServiceLaunchIDs[service.id] = launchID
        localServiceLaunchReclaimAttempts[launchID] = reclaimAttempted

        do {
            let process = try CommandRunner.startLongRunning(
                service.command,
                workingDirectory: service.workingDirectory,
                logName: service.id,
                terminationHandler: { [weak self] finishedProcess in
                    Task { @MainActor [weak self] in
                        await self?.handleLocalServiceTermination(
                            finishedProcess,
                            serviceID: service.id,
                            serviceName: service.name,
                            launchID: launchID
                        )
                    }
                }
            )
            guard localServiceLaunchIDs[service.id] == launchID else {
                return
            }

            if process.isRunning {
                startedProcesses[service.id] = process
            } else {
                Task {
                    await handleLocalServiceTermination(
                        process,
                        serviceID: service.id,
                        serviceName: service.name,
                        launchID: launchID
                    )
                }
                return
            }

            message = AppText.t("Started \(service.name)", zh: "已启动 \(service.name)")
            localServiceRuntimeMessages[service.id] = AppText.t("Started, waiting for port checks", zh: "已启动，正在等待端口检测")
            applyLocalServicesImmediately(from: config)
		        } catch {
		            localServiceLaunchIDs.removeValue(forKey: service.id)
		            localServiceLaunchReclaimAttempts.removeValue(forKey: launchID)
		            message = AppText.t("Starting \(service.name) failed: \(error.localizedDescription)", zh: "启动 \(service.name) 失败：\(error.localizedDescription)")
            localServiceRuntimeMessages[service.id] = AppText.t("Start failed: \(error.localizedDescription)", zh: "启动失败：\(error.localizedDescription)")
            showError(
                title: AppText.t("Starting \(service.name) Failed", zh: "启动 \(service.name) 失败"),
                message: error.localizedDescription,
                logServiceID: service.id
            )
        }
    }

    private func stopLocalServiceProcess(serviceID: String) -> Bool {
        guard let process = startedProcesses[serviceID] else {
            return false
        }

        if process.isRunning {
            stoppingServiceIDs.insert(serviceID)
            process.terminate()
        } else {
            localServiceLaunchIDs.removeValue(forKey: serviceID)
        }

        startedProcesses.removeValue(forKey: serviceID)
        localServiceRuntimeMessages[serviceID] = AppText.t("Stopped", zh: "已停止")
        applyLocalServicesImmediately(from: config)
        return true
    }

	    private func handleLocalServiceTermination(
	        _ finishedProcess: Process,
	        serviceID: String,
	        serviceName: String,
	        launchID: UUID
	    ) async {
	        guard localServiceLaunchIDs[serviceID] == launchID else {
	            return
	        }

	        localServiceLaunchIDs.removeValue(forKey: serviceID)
	        let reclaimAttempted = localServiceLaunchReclaimAttempts.removeValue(forKey: launchID) ?? false
	        let wasStopping = stoppingServiceIDs.remove(serviceID) != nil

        if startedProcesses[serviceID] === finishedProcess {
            startedProcesses.removeValue(forKey: serviceID)
        }

        if wasStopping {
            localServiceRuntimeMessages[serviceID] = AppText.t("Stopped", zh: "已停止")
            message = AppText.t("Stopped \(serviceName)", zh: "已停止 \(serviceName)")
        } else {
            let exitCode = finishedProcess.terminationStatus
		            let logBlock = CommandRunner.lastLogBlock(logName: serviceID)
		            let logTail = CommandRunner.lastLogLines(logName: serviceID, maxLines: 8)
		            let reason = logTail.isEmpty ? AppText.t("Exit code \(exitCode)", zh: "退出码 \(exitCode)") : logTail
		            if isPortAlreadyInUse(logBlock), !reclaimAttempted {
		                await reclaimOccupiedPortsAndRestart(serviceID: serviceID, serviceName: serviceName)
		                return
		            }
		            localServiceRuntimeMessages[serviceID] = AppText.t("Exited: \(reason)", zh: "已退出：\(reason)")
            message = AppText.t("\(serviceName) exited", zh: "\(serviceName) 已退出")
            showError(
                title: AppText.t("\(serviceName) Exited", zh: "\(serviceName) 已退出"),
                message: reason,
                logServiceID: serviceID
            )
        }

	        applyLocalServicesImmediately(from: config)
	        await refresh()
	    }

	    private func reclaimOccupiedPortsAndRestart(serviceID: String, serviceName: String) async {
	        guard let service = config.localServices.first(where: { $0.id == serviceID }), !service.ports.isEmpty else {
	            localServiceRuntimeMessages[serviceID] = AppText.t("Port is occupied, but no monitored port is configured for recovery", zh: "端口占用，但没有配置可处理的监控端口")
	            message = AppText.t("\(serviceName) restart failed", zh: "\(serviceName) 重启失败")
	            showError(
                    title: AppText.t("\(serviceName) Restart Failed", zh: "\(serviceName) 重启失败"),
                    message: AppText.t("Port occupation was detected, but this service has no monitored port configured.", zh: "检测到端口占用，但该服务没有配置监控端口。"),
                    logServiceID: serviceID
                )
	            return
	        }

	        let occupants = await listeningPorts(for: service)
	        guard !occupants.isEmpty else {
	            localServiceRuntimeMessages[serviceID] = AppText.t("Port is occupied, but no listener process was found", zh: "端口占用，但没有找到监听进程")
	            message = AppText.t("\(serviceName) restart failed", zh: "\(serviceName) 重启失败")
	            showError(
                    title: AppText.t("\(serviceName) Restart Failed", zh: "\(serviceName) 重启失败"),
                    message: AppText.t("Port occupation was detected, but no process listening on that port was found.", zh: "检测到端口占用，但没有找到监听该端口的进程。"),
                    logServiceID: serviceID
                )
	            return
	        }

	        let summary = occupants
	            .map { "\($0.processName)(pid \($0.pid)):\($0.port)" }
	            .joined(separator: ", ")
	        localServiceRuntimeMessages[serviceID] = AppText.t("Port is occupied, stopping: \(summary)", zh: "端口被占用，正在停止：\(summary)")
	        message = AppText.t("Restarting \(serviceName)", zh: "正在重启 \(serviceName)")

	        await terminate(occupants, signal: "TERM")
	        var remaining = await waitForPortsToRelease(service: service, timeout: 2.0)
	        if !remaining.isEmpty {
	            localServiceRuntimeMessages[serviceID] = AppText.t("Port is still occupied, force stopping listener process", zh: "端口仍被占用，强制停止占用进程")
	            await terminate(remaining, signal: "KILL")
	            remaining = await waitForPortsToRelease(service: service, timeout: 2.0)
	        }

	        guard remaining.isEmpty else {
	            let remainingSummary = remaining
	                .map { "\($0.processName)(pid \($0.pid)):\($0.port)" }
	                .joined(separator: ", ")
	            localServiceRuntimeMessages[serviceID] = AppText.t("Port release failed: \(remainingSummary)", zh: "端口释放失败：\(remainingSummary)")
	            message = AppText.t("\(serviceName) restart failed", zh: "\(serviceName) 重启失败")
	            showError(
                    title: AppText.t("\(serviceName) Restart Failed", zh: "\(serviceName) 重启失败"),
                    message: AppText.t("Could not stop the process occupying the port: \(remainingSummary)", zh: "无法停止占用端口的进程：\(remainingSummary)"),
                    logServiceID: serviceID
                )
	            return
	        }

	        localServiceRuntimeMessages[serviceID] = AppText.t("Port released, restarting", zh: "端口已释放，正在重新启动")
	        startLocalService(service, reclaimAttempted: true)
	    }

	    private func listeningPorts(for service: LocalServiceConfig) async -> [ListeningPort] {
	        let listeningPorts = await LocalPortDiscovery.discover()
	        let configuredPorts = Set(service.ports.map(\.port))
	        let currentPID = String(ProcessInfo.processInfo.processIdentifier)
	        return listeningPorts
	            .filter { configuredPorts.contains($0.port) && $0.pid != currentPID }
	            .reduce(into: [String: ListeningPort]()) { result, port in
	                result["\(port.pid)-\(port.port)"] = port
	            }
	            .values
	            .sorted { $0.port == $1.port ? $0.pid < $1.pid : $0.port < $1.port }
	    }

	    private func terminate(_ listeningPorts: [ListeningPort], signal: String) async {
	        let pids = Set(listeningPorts.map(\.pid))
	        for pid in pids {
	            _ = await CommandRunner.sendSignal(signal, pid: pid)
	        }
	    }

	    private func waitForPortsToRelease(service: LocalServiceConfig, timeout: TimeInterval) async -> [ListeningPort] {
	        let deadline = Date().addingTimeInterval(timeout)
	        var remaining = await listeningPorts(for: service)

	        while !remaining.isEmpty && Date() < deadline {
	            try? await Task.sleep(nanoseconds: 200_000_000)
	            remaining = await listeningPorts(for: service)
	        }

	        return remaining
	    }

    private func isPortAlreadyInUse(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("eaddrinuse") ||
            lowered.contains("address already in use") ||
            lowered.contains("port") && lowered.contains("in use")
    }

    private func showError(title: String, message: String, logServiceID: String? = nil) {
        let signature = "\(title)\n\(message)\n\(logServiceID ?? "")"
        if signature == lastAlertSignature {
            return
        }

        lastAlertSignature = signature
        activeAlert = DashboardAlert(title: title, message: message, logServiceID: logServiceID)
    }

}

private func portKey(_ config: PortConfig) -> String {
    portKey(host: config.host, port: config.port, protocolName: config.protocolName)
}

private func portKey(_ snapshot: PortSnapshot) -> String {
    portKey(host: snapshot.host, port: snapshot.port, protocolName: snapshot.protocolName)
}

private func portKey(host: String, port: Int, protocolName: String) -> String {
    "\(host):\(port)/\(protocolName.lowercased())"
}

private func noteFor(host: String, port: Int, protocolName: String, config: DashboardConfig) -> String {
    let key = portKey(host: host, port: port, protocolName: protocolName)
    return config.portNotes[key] ?? ""
}

private func storeDiscoveredPortNote(in config: inout DashboardConfig, host: String, port: Int, protocolName: String, note: String) {
    let key = portKey(host: host, port: port, protocolName: protocolName)
    if note.isEmpty {
        config.portNotes.removeValue(forKey: key)
    } else {
        config.portNotes[key] = note
    }
}

private func makeUniqueLocalServiceID(name: String, existingIDs: Set<String>) -> String {
    let rawBase = LocalServiceConfig.makeID(from: name)
    let base = rawBase.isEmpty ? "local-service" : rawBase
    if !existingIDs.contains(base) {
        return base
    }

    var suffix = 2
    while existingIDs.contains("\(base)-\(suffix)") {
        suffix += 1
    }
    return "\(base)-\(suffix)"
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
