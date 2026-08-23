import Foundation
import LaicaiNativeDomain

enum AppSettingsStorage {
    private static let key = "laicai.appSettings.v1"

    static func load() throws -> AppSettings? {
        guard let data = LaicaiStoragePaths.defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    static func save(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        LaicaiStoragePaths.defaults.set(data, forKey: key)
    }
}

private func normalizedPersistedSettings(_ settings: AppSettings) -> AppSettings {
    var normalized = settings
    if WorkspaceSandbox.isOverlyBroadWorkspace(normalized.workspacePath)
        || WorkspaceSandbox.isDisposableSmokeWorkspace(normalized.workspacePath)
    {
        let fallback = normalized.recentWorkspaces.first { path in
            !WorkspaceSandbox.isOverlyBroadWorkspace(path)
                && !WorkspaceSandbox.isDisposableSmokeWorkspace(path)
                && FileManager.default.fileExists(atPath: path)
        }
        normalized.workspacePath = fallback ?? ""
    }
    normalized.recentWorkspaces = normalized.recentWorkspaces.filter { path in
        !WorkspaceSandbox.isOverlyBroadWorkspace(path)
            && !WorkspaceSandbox.isDisposableSmokeWorkspace(path)
            && FileManager.default.fileExists(atPath: path)
    }
    return normalized
}

func migrateFromPythonConnectorCatalog(workspacePath: String) -> ConnectorCatalog? {
    let path = (workspacePath as NSString).appendingPathComponent("desktop-connectors.json")
    guard FileManager.default.fileExists(atPath: path),
        let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let activeID = UUID(uuidString: json["active_id"] as? String ?? "")
    let items = json["items"] as? [[String: Any]] ?? []
    let connectors: [ConnectorProfile] = items.compactMap { item in
        guard let id = UUID(uuidString: item["id"] as? String ?? ""),
            let name = item["name"] as? String,
            let endpoint = item["endpoint"] as? String
        else { return nil }
        return ConnectorProfile(
            id: id, name: name,
            kind: item["kind"] as? String ?? "openai-compatible",
            endpoint: endpoint,
            modelName: item["model"] as? String ?? "",
            note: item["api_key"] as? String ?? "",
            toolCallingPolicy: (item["tool_calling_policy"] as? String).flatMap(ConnectorToolCallingPolicy.init(rawValue:)),
            toolCallingCapability: (item["tool_calling_capability"] as? String).flatMap(ConnectorToolCallingCapability.init(rawValue:)),
            health: .attention, lastCheckedAt: .now
        )
    }
    guard !connectors.isEmpty else { return nil }
    return ConnectorCatalog(connectors: connectors, activeConnectorID: activeID)
}

extension AppState {
    public static var preview: AppState { SampleData.appState }

    public static func bootstrap(environment: AppEnvironment) -> AppState {
        var state = AppState.empty
        var issues: [String] = []
        restoreSettings(into: &state, issues: &issues)
        restoreThreads(into: &state, environment: environment, issues: &issues)
        restoreConnectors(into: &state, environment: environment, issues: &issues)
        startWorkspaceServices(for: state.settings.workspacePath)

        if normalizeThreads(in: &state) {
            do {
                try environment.agentRepository.saveAgents(state.threads)
            } catch {
                issues.append("保存规范化会话失败：\(error.localizedDescription)")
            }
        }

        // Restore data without selecting a thread behind the user's back.
        startMCPServers()
        loadPluginsIfNeeded(workspaceRoot: state.settings.workspacePath)
        if !issues.isEmpty {
            state.notice = AppNotice(
                message: issues.joined(separator: "\n"),
                style: .error
            )
        }
        return state
    }

    private static func restoreSettings(into state: inout AppState, issues: inout [String]) {
        do {
            if let settings = try AppSettingsStorage.load() {
                state.settings = normalizedPersistedSettings(settings)
                let last = URL(fileURLWithPath: state.settings.workspacePath).lastPathComponent
                if !last.isEmpty { state.workspaceName = last }
            }
        } catch {
            issues.append("读取应用设置失败：\(error.localizedDescription)")
        }
        if state.workspaceName == "来采原生版" { state.workspaceName = "来财原生版" }
    }

    private static func restoreThreads(
        into state: inout AppState,
        environment: AppEnvironment,
        issues: inout [String]
    ) {
        do {
            if let savedThreads = try environment.agentRepository.loadAgents(), !savedThreads.isEmpty {
                state.threads = savedThreads.filter { !$0.isEmptyPlaceholder }
                return
            }
        } catch {
            issues.append("读取会话快照失败：\(error.localizedDescription)")
        }
        do {
            if let savedThreads = try environment.threadRepository.loadThreads(), !savedThreads.isEmpty {
                state.threads = savedThreads.filter { !$0.isEmptyPlaceholder }
                return
            }
        } catch {
            issues.append("读取历史会话失败：\(error.localizedDescription)")
        }

        var legacySessions: [ChatSession] = []
        var legacyTasks: [AgentTask] = []
        do {
            legacySessions = try environment.sessionRepository.loadSessions() ?? []
        } catch {
            issues.append("读取旧版对话失败：\(error.localizedDescription)")
        }
        do {
            legacyTasks = try environment.taskRepository.loadTasks() ?? []
        } catch {
            issues.append("读取旧版任务失败：\(error.localizedDescription)")
        }
        let legacyThreads = (legacySessions.map(Thread.init(session:)) + legacyTasks.map(Thread.init(task:)))
            .filter { !$0.isEmptyPlaceholder }
        if !legacyThreads.isEmpty {
            state.threads = legacyThreads
            return
        }
        if let jsonSessions = LegacyJSONMigration.loadSessions(), !jsonSessions.isEmpty {
            state.threads = jsonSessions.map(Thread.init(session:)).filter { !$0.isEmptyPlaceholder }
            if !state.threads.isEmpty {
                do {
                    try environment.agentRepository.saveAgents(state.threads)
                } catch {
                    issues.append("迁移旧版对话失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private static func restoreConnectors(
        into state: inout AppState,
        environment: AppEnvironment,
        issues: inout [String]
    ) {
        let catalog: ConnectorCatalog?
        do {
            catalog = try environment.connectorRepository.loadConnectorCatalog()
        } catch {
            catalog = nil
            issues.append("读取连接器失败：\(error.localizedDescription)")
        }
        if let catalog, !catalog.connectors.isEmpty {
            state.connectors = catalog.connectors.map(normalizedBootstrapConnector)
            state.activeConnectorID = catalog.activeConnectorID ?? catalog.connectors.first?.id
            state.settings.defaultConnectorName =
                state.activeConnector?.name ?? catalog.connectors.first?.name ?? state.settings.defaultConnectorName
            if state.connectors != catalog.connectors {
                saveRestoredConnectors(state: state, environment: environment, issues: &issues)
            }
        } else if let migrated = migrateFromPythonConnectorCatalog(workspacePath: state.settings.workspacePath) {
            state.connectors = migrated.connectors.map(normalizedBootstrapConnector)
            state.activeConnectorID = migrated.activeConnectorID ?? migrated.connectors.first?.id
            state.settings.defaultConnectorName =
                state.activeConnector?.name ?? migrated.connectors.first?.name ?? state.settings.defaultConnectorName
            if state.connectors != migrated.connectors {
                saveRestoredConnectors(state: state, environment: environment, issues: &issues)
            }
        } else if let migrated = LegacyJSONMigration.loadConnectorCatalog(), !migrated.connectors.isEmpty {
            state.connectors = migrated.connectors.map(normalizedBootstrapConnector)
            state.activeConnectorID = migrated.activeConnectorID ?? migrated.connectors.first?.id
            state.settings.defaultConnectorName =
                state.activeConnector?.name ?? migrated.connectors.first?.name ?? state.settings.defaultConnectorName
            saveRestoredConnectors(state: state, environment: environment, issues: &issues)
        }
    }

    private static func saveRestoredConnectors(
        state: AppState,
        environment: AppEnvironment,
        issues: inout [String]
    ) {
        do {
            try environment.connectorRepository.saveConnectors(
                state.connectors,
                activeConnectorID: state.activeConnectorID
            )
        } catch {
            issues.append("保存迁移后的连接器失败：\(error.localizedDescription)")
        }
    }

    private static func startWorkspaceServices(for workspacePath: String) {
        Task { @MainActor in
            WorkspaceSandbox.shared.workspaceRoot = workspacePath
        }
    }

    private static func normalizeThreads(in state: inout AppState) -> Bool {
        var normalizedThreads = false
        for index in state.threads.indices {
            if state.threads[index].isChatOnly {
                if Thread.isPlaceholderTitle(state.threads[index].title) {
                    let firstMsg = state.threads[index].steps.first(where: { $0.kind == .userInput })?.text ?? ""
                    let title = String(
                        firstMsg.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
                    if !title.isEmpty { state.threads[index].title = title }
                }
                state.threads[index].preview = normalizedSessionPreview(state.threads[index].preview)
            }

            let beforeAgentState = state.threads[index].executionState
            let beforeAgentGoal = state.threads[index].goal
            let beforePlan = state.threads[index].currentPlan
            let beforeArtifacts = state.threads[index].artifacts
            AppStore.syncAgentSnapshot(&state.threads[index])
            if state.threads[index].executionState != beforeAgentState
                || state.threads[index].goal != beforeAgentGoal
                || state.threads[index].currentPlan != beforePlan
                || state.threads[index].artifacts != beforeArtifacts
            {
                normalizedThreads = true
            }

            if state.threads[index].isChatOnly,
                state.threads[index].projectID != nil,
                !threadNeedsProjectScope(state.threads[index])
            {
                state.threads[index].projectID = nil
                normalizedThreads = true
            }
        }
        return normalizedThreads
    }

    private static func startMCPServers() {
        Task { @MainActor in
            let manager = MCPManager.shared
            await manager.startAll()
            manager.registerTools(in: ToolRegistry.shared)
        }
    }

    private static func loadPluginsIfNeeded(workspaceRoot: String) {
        if !workspaceRoot.isEmpty {
            Task { @MainActor in
                PluginRegistry.shared.loadPlugins(workspaceRoot: workspaceRoot)
            }
        }
    }
}

private func normalizedBootstrapConnector(_ connector: ConnectorProfile) -> ConnectorProfile {
    var normalized = connector
    normalized.name = connector.name.trimmingCharacters(in: .whitespacesAndNewlines)
    normalized.kind = connector.kind.trimmingCharacters(in: .whitespacesAndNewlines)
    normalized.endpoint = connector.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    normalized.modelName = connector.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    normalized.note = connector.note.trimmingCharacters(in: .whitespacesAndNewlines)
    normalized.kind = LiveChatRuntime.normalizedConnectorKind(normalized.kind, endpoint: normalized.endpoint)
    return normalized
}

private func threadNeedsProjectScope(_ thread: Thread) -> Bool {
    if thread.isExecution { return true }
    return thread.workflowName != nil
        || thread.steps.contains { step in
            step.kind == .toolCall || step.kind == .toolResult || step.kind == .reviewRequest || step.kind == .reviewResult
        }
}
