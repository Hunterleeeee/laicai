import Foundation
import LaicaiNativeDomain

enum AppSettingsStorage {
    private static let key = "laicai.appSettings.v1"

    static func load() -> AppSettings? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private func normalizedPersistedSettings(_ settings: AppSettings) -> AppSettings {
    var normalized = settings
    if WorkspaceSandbox.isOverlyBroadWorkspace(normalized.workspacePath)
        || WorkspaceSandbox.isDisposableSmokeWorkspace(normalized.workspacePath) {
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
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let activeID = UUID(uuidString: json["active_id"] as? String ?? "")
    let items = json["items"] as? [[String: Any]] ?? []
    let connectors: [ConnectorProfile] = items.compactMap { item in
        guard let id = UUID(uuidString: item["id"] as? String ?? ""),
              let name = item["name"] as? String,
              let endpoint = item["endpoint"] as? String else { return nil }
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

public extension AppState {
    static var preview: AppState { SampleData.appState }

    static func bootstrap(environment: AppEnvironment) -> AppState {
        var state = SampleData.appState
        if let settings = AppSettingsStorage.load() {
            state.settings = normalizedPersistedSettings(settings)
            let last = URL(fileURLWithPath: state.settings.workspacePath).lastPathComponent
            if !last.isEmpty { state.workspaceName = last }
        }

        if let savedThreads = try? environment.agentRepository.loadAgents(), !savedThreads.isEmpty {
            state.threads = savedThreads.filter { !$0.isEmptyPlaceholder }
        } else if let savedThreads = try? environment.threadRepository.loadThreads(), !savedThreads.isEmpty {
            state.threads = savedThreads.filter { !$0.isEmptyPlaceholder }
        } else {
            let legacySessions = (try? environment.sessionRepository.loadSessions()) ?? []
            let legacyTasks = (try? environment.taskRepository.loadTasks()) ?? []
            let legacyThreads = (legacySessions.map(Thread.init(session:)) + legacyTasks.map(Thread.init(task:)))
                .filter { !$0.isEmptyPlaceholder }
            if !legacyThreads.isEmpty {
                state.threads = legacyThreads
            }
        }

        if let catalog = try? environment.connectorRepository.loadConnectorCatalog(), !catalog.connectors.isEmpty {
            state.connectors = catalog.connectors.map(normalizedBootstrapConnector)
            state.activeConnectorID = catalog.activeConnectorID ?? catalog.connectors.first?.id
            state.settings.defaultConnectorName = state.activeConnector?.name ?? catalog.connectors.first?.name ?? state.settings.defaultConnectorName
            if state.connectors != catalog.connectors {
                try? environment.connectorRepository.saveConnectors(state.connectors, activeConnectorID: state.activeConnectorID)
            }
        } else if let migrated = migrateFromPythonConnectorCatalog(workspacePath: state.settings.workspacePath) {
            state.connectors = migrated.connectors.map(normalizedBootstrapConnector)
            state.activeConnectorID = migrated.activeConnectorID ?? migrated.connectors.first?.id
            state.settings.defaultConnectorName = state.activeConnector?.name ?? migrated.connectors.first?.name ?? state.settings.defaultConnectorName
            if state.connectors != migrated.connectors {
                try? environment.connectorRepository.saveConnectors(state.connectors, activeConnectorID: state.activeConnectorID)
            }
        }

        if state.workspaceName == "来采原生版" { state.workspaceName = "来财原生版" }
        let workspacePath = state.settings.workspacePath
        Task { @MainActor in
            WorkspaceSandbox.shared.workspaceRoot = workspacePath
        }

        var normalizedThreads = false
        for index in state.threads.indices {
            if state.threads[index].isAskAgent {
                if Thread.isPlaceholderTitle(state.threads[index].title) {
                    let firstMsg = state.threads[index].steps.first(where: { $0.kind == .userInput })?.text ?? ""
                    let title = String(firstMsg.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
                    if !title.isEmpty { state.threads[index].title = title }
                }
                state.threads[index].preview = normalizedSessionPreview(state.threads[index].preview)
            } else if state.threads[index].status == .running {
                state.threads[index].status = .cancelled
                state.threads[index].agentState = .paused
                if !state.threads[index].steps.contains(where: { $0.kind == .error && $0.text.contains("上次运行被中断") }) {
                    state.threads[index].steps.append(TaskStep(
                        kind: .error,
                        text: "上次运行被中断，已自动标记为已暂停。",
                        isFailure: false,
                        recoverable: true,
                        retryAction: "继续执行"
                    ))
                }
                normalizedThreads = true
            }

            let beforeAgentState = state.threads[index].agentState
            let beforeAgentGoal = state.threads[index].agentGoal
            let beforePlan = state.threads[index].currentPlan
            let beforeArtifacts = state.threads[index].artifacts
            AppStore.syncAgentSnapshot(&state.threads[index])
            if state.threads[index].agentState != beforeAgentState
                || state.threads[index].agentGoal != beforeAgentGoal
                || state.threads[index].currentPlan != beforePlan
                || state.threads[index].artifacts != beforeArtifacts {
                normalizedThreads = true
            }

            if state.threads[index].isAskAgent,
               state.threads[index].projectID != nil,
               !threadNeedsProjectScope(state.threads[index]) {
                state.threads[index].projectID = nil
                normalizedThreads = true
            }
        }

        if normalizedThreads {
            try? environment.agentRepository.saveAgents(state.threads)
        }

        state.selectThread(id: state.threads.sorted { $0.updatedAt > $1.updatedAt }.first?.id)

        // Start MCP servers and register their tools
        Task { @MainActor in
            let manager = MCPManager.shared
            await manager.startAll()
            manager.registerTools(in: ToolRegistry.shared)
        }

        // Load plugins from .laicai/plugins/
        let wsRoot = state.settings.workspacePath
        if !wsRoot.isEmpty {
            Task { @MainActor in
                PluginRegistry.shared.loadPlugins(workspaceRoot: wsRoot)
            }
        }

        return state
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
    if thread.isExecutionAgent { return true }
    return thread.workflowName != nil
        || thread.steps.contains { step in
            step.kind == .toolCall || step.kind == .toolResult || step.kind == .reviewRequest || step.kind == .reviewResult
        }
}
