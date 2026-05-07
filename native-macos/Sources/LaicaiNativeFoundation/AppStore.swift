import AppKit
import Combine
import Foundation
import LaicaiNativeDomain

@MainActor
public final class AppStore: ObservableObject {
    @Published public internal(set) var state: AppState
    @Published public var isShowingTaskModeInfo = false
    let environment: AppEnvironment
    var agentLoops: [UUID: AgentLoop] = [:]
    static let streamingOutputID = "__streaming_output__"
    var streamBuffers: [UUID: String] = [:]
    var streamLastFlushAt: [UUID: Date] = [:]
    var chatStreamBuffers: [UUID: String] = [:]
    var chatStreamLastFlushAt: [UUID: Date] = [:]
    var healthChecksInFlight: Set<UUID> = []
    let streamFlushCharacterThreshold = 200
    let streamFlushInterval: TimeInterval = 0.25
    let chatStreamFlushCharacterThreshold = 900
    let chatStreamFlushInterval: TimeInterval = 0.65
    private var shellStreamObserver: NSObjectProtocol?

    // H1: Debounced persistence — collapse rapid persist calls into one
    var persistDebounceTask: Task<Void, Never>?
    var lastPersistedAt: Date = .distantPast
    let persistDebounceInterval: TimeInterval = 1.0

    public init(state: AppState, environment: AppEnvironment = .preview) {
        var initialState = state
        Self.markStaleRunningTasks(in: &initialState)
        self.state = initialState
        self.environment = environment
        if initialState.threads != state.threads {
            persistThreads()
        }
        // Self-evolution: auto-promote winning prompt variants on startup
        PromptRegistry.shared.autoPromote()
        shellStreamObserver = NotificationCenter.default.addObserver(
            forName: .shellStreamUpdate,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let info = notification.userInfo
            Task { @MainActor [weak self] in
                guard let self = self, let info = info else { return }
                self.handleShellStreamNotification(info)
            }
        }
    }

    public static func preview() -> AppStore {
        AppStore(state: .preview, environment: .preview)
    }

    public static func live() -> AppStore {
        let environment = AppEnvironment.live
        return AppStore(state: .bootstrap(environment: environment), environment: environment)
    }

    // MARK: - Wiki

    public func buildWikiTopic(
        topic: String,
        vaultRoot: String,
        save: Bool,
        useWeb: Bool = false,
        onChunk: (@Sendable @MainActor (String) -> Void)? = nil
    ) async -> WikiBuildResult {
        await WikiEngine.buildTopic(
            topic: topic,
            vaultRoot: vaultRoot,
            save: save,
            useWeb: useWeb,
            topK: 8,
            connector: state.activeConnector,
            runtime: environment.runtimeClient,
            onChunk: onChunk
        )
    }

    // MARK: - Session Management

    public var filteredSessions: [ChatSession] {
        state.sessions
    }

    public func updateSearchText(_ value: String) { state.searchText = value }

    public func newSession() {
        let connectorName = state.activeConnector?.name ?? state.settings.defaultConnectorName
        let thread = Thread(
            title: "新会话",
            preview: "",
            modelName: connectorName,
            category: .engineering
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
        persistThreads()
    }

    public func selectSession(id: UUID?) {
        state.selectThread(id: id)
        state.modeLabel = "聊天"
    }

    public func updateExecutionMode(_ mode: ExecutionMode) {
        state.executionMode = mode
        state.modeLabel = mode.title
    }

    public func deleteSession(id: UUID) {
        state.threads.removeAll(where: { $0.id == id })
        if state.selectedSessionID == id {
            state.selectThread(id: nil)
            selectThread(state.threads.first.map { ThreadRecord(thread: $0, includeEvents: false) })
        }
        persistThreads()
    }

    public func pinSession(id: UUID) {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        state.threads[index].isPinned.toggle()
        persistThreads()
    }

    public func renameSession(id: UUID, title: String) {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { state.threads[index].title = trimmed }
        persistThreads()
    }

    /// Rate a thread's quality (1-5). Persists to both Thread model and TaskOutcomeRecorder.
    public func rateThread(id: UUID, rating: Int) {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        state.threads[index].userRating = rating
        persistThreads()
        TaskOutcomeRecorder.shared.rate(taskID: id.uuidString, rating: rating)
    }

    public func clearSessionTurns(id: UUID) {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        state.threads[index].steps = []
        state.threads[index].preview = ""
        persistThreads()
    }

    public func cloneSession(id: UUID) {
        guard let thread = state.threads.first(where: { $0.id == id }) else { return }
        let cloned = Thread(
            title: thread.title + " 副本",
            preview: thread.preview,
            steps: thread.steps,
            modelName: thread.modelName,
            category: thread.category
        )
        state.threads.insert(cloned, at: 0)
        state.selectThread(id: cloned.id)
        persistThreads()
        notify("已克隆会话", style: .success)
    }

    public func exportSession(id: UUID) -> String? {
        guard let thread = state.threads.first(where: { $0.id == id }) else { return nil }
        let session = ChatSession(thread: thread)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func exportTask(id: UUID) -> String? {
        guard let thread = state.threads.first(where: { $0.id == id }) else { return nil }
        let task = AgentTask(thread: thread)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(task) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func exportSelectedThreadMarkdown() -> String? {
        guard let thread = state.selectedThread else { return nil }
        var lines: [String] = ["# \(thread.title)", ""]
        lines.append("- 类型：\(thread.source == .task ? "任务" : "会话")")
        if thread.source == .task { lines.append("- 状态：\(thread.status.title)") }
        lines.append("- 更新时间：\(thread.updatedAt)")
        lines.append("")

        for step in thread.steps {
            lines.append("## \(step.kind.title)")
            if let toolName = step.toolName { lines.append("- 工具：\(toolName)") }
            if step.isFailure { lines.append("- 状态：失败") }
            lines.append("")
            lines.append(step.text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    public func exportSelectedThreadJSON() -> String? {
        guard let thread = state.selectedThread else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(thread) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func archiveThread(id: UUID) {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        state.threads[index].isArchived.toggle()
        // If the archived thread was selected, deselect it
        if state.threads[index].isArchived && state.selectedThread?.id == id {
            state.selectedThreadID = nil
        }
        persistThreads()
    }

    public func exportSelectedTaskEvidenceMarkdown() -> String? {
        guard let thread = state.selectedThread, thread.source == .task else { return nil }
        let steps = thread.steps
        let toolCalls = steps.filter { $0.kind == .toolCall }
        let readFiles = Self.uniqueMemoryValues(steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] })
        let searchQueries = Self.uniqueMemoryValues(toolCalls
            .filter { $0.toolName == "code.search" || $0.toolName == "web.search" }
            .compactMap { $0.toolParams?["query"] })
        let commands = Self.uniqueMemoryValues(toolCalls
            .filter { $0.toolName == "shell.exec" }
            .compactMap { $0.toolParams?["command"] })
        let writeReviews = Self.uniqueMemoryValues(steps
            .filter { $0.kind == .reviewRequest }
            .compactMap(\.diffFilePath))
        let failedTools = Dictionary(grouping: steps.filter { $0.kind == .toolResult && $0.isFailure }, by: { $0.toolName ?? "tool" })
            .map { "\($0.key) ×\($0.value.count)" }
            .sorted()
        let indexed = steps.contains { $0.kind == .toolResult && $0.toolName == "workspace.index" && !$0.isFailure }

        var lines: [String] = ["# 证据清单：\(thread.title)", ""]
        lines.append("- 状态：\(thread.status.title)")
        lines.append("- 步骤：\(steps.count)")
        lines.append("- 更新时间：\(thread.updatedAt)")
        if indexed { lines.append("- 项目索引：已建立") }
        if !readFiles.isEmpty { lines.append("- 已读文件：\(readFiles.prefix(12).joined(separator: "、"))") }
        if !searchQueries.isEmpty { lines.append("- 已搜索：\(searchQueries.prefix(8).joined(separator: "、"))") }
        if !commands.isEmpty { lines.append("- 已运行命令：\(commands.prefix(6).joined(separator: "、"))") }
        if !writeReviews.isEmpty { lines.append("- 审查文件：\(writeReviews.prefix(8).joined(separator: "、"))") }
        if !failedTools.isEmpty { lines.append("- 失败工具：\(failedTools.joined(separator: "、"))") }
        if let verification = thread.context.memory.verificationStatus {
            lines.append("- 验证状态：\(verification)")
        }
        if lines.count <= 4 {
            lines.append("- 说明：这条任务还没有形成足够工具证据。")
        }
        return lines.joined(separator: "\n")
    }

    public func importSession(json: String) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let session = try? decoder.decode(ChatSession.self, from: data) else { return false }
        let imported = Thread(session: session)
        state.threads.insert(imported, at: 0)
        state.selectThread(id: imported.id)
        persistThreads()
        notify("已导入会话", style: .success)
        return true
    }

    public func deleteTurn(sessionID: UUID, turnID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == sessionID }) else { return }
        state.threads[threadIndex].steps.removeAll(where: { $0.id == turnID })
        state.threads[threadIndex].preview = normalizedSessionPreview(state.threads[threadIndex].steps.last?.text ?? "")
        persistThreads()
    }

    // MARK: - Workbench & Navigation

    public func selectWorkbenchTab(_ tab: WorkbenchTab) { state.workbenchTab = tab }

    public func selectNextWorkbenchTab() {
        guard let index = WorkbenchTab.allCases.firstIndex(of: state.workbenchTab) else { return }
        state.workbenchTab = WorkbenchTab.allCases[(index + 1) % WorkbenchTab.allCases.count]
    }

    // MARK: - Connector Management

    public func selectConnector(id: UUID) {
        guard let connector = state.connectors.first(where: { $0.id == id }) else { return }
        state.activeConnectorID = connector.id
        state.settings.defaultConnectorName = connector.name
        if let threadIndex = state.threads.firstIndex(where: { $0.id == state.selectedThreadID }), state.threads[threadIndex].source == .session {
            state.threads[threadIndex].modelName = connector.name
        }
        persistSettings()
        persistConnectors()
        persistThreads()
        scheduleConnectorHealthRefreshIfNeeded(for: connector)
    }

    public func addConnector(_ connector: ConnectorProfile) {
        let normalized = normalizedConnector(connector)
        state.connectors.append(normalized)
        if state.activeConnectorID == nil {
            state.activeConnectorID = normalized.id
            state.settings.defaultConnectorName = normalized.name
        }
        persistSettings()
        persistConnectors()
        scheduleConnectorHealthRefreshIfNeeded(for: normalized, force: true)
    }

    public func updateConnector(_ connector: ConnectorProfile) {
        guard let index = state.connectors.firstIndex(where: { $0.id == connector.id }) else { return }
        let previous = state.connectors[index]
        let normalized = normalizedConnector(connector, previous: previous)
        let configurationChanged = Self.connectorConfigurationChanged(from: previous, to: normalized)
        state.connectors[index] = normalized
        if state.activeConnectorID == normalized.id {
            state.settings.defaultConnectorName = normalized.name
        }
        persistSettings()
        persistConnectors()
        if configurationChanged {
            scheduleConnectorHealthRefreshIfNeeded(for: normalized, force: true)
        }
    }

    public func deleteConnector(id: UUID) {
        state.connectors.removeAll(where: { $0.id == id })
        if state.activeConnectorID == id {
            state.activeConnectorID = state.connectors.first?.id
            state.settings.defaultConnectorName = state.activeConnector?.name ?? "无模型"
        }
        persistSettings()
        persistConnectors()
    }

    public func clearLearnedToolCallingCapability(id: UUID, showsToast: Bool = true) {
        guard let index = state.connectors.firstIndex(where: { $0.id == id }) else {
            if showsToast {
                notify("未找到该连接器", style: .info)
            }
            return
        }
        guard state.connectors[index].toolCallingCapability != nil else {
            if showsToast {
                notify("\(state.connectors[index].name) 当前没有已学习的工具兼容性记录", style: .info)
            }
            return
        }
        state.connectors[index].toolCallingCapability = nil
        state.connectors[index].toolCallingCapabilitySource = nil
        state.connectors[index].toolCallingCapabilityLearnedAt = nil
        refreshActiveAgentLoopIfNeeded(for: id)
        let connector = state.connectors[index]
        let capability = ConnectorCapabilityProfile.infer(for: connector, mode: state.settings.contextMode)
        let statusLine: String
        let toastMessage: String
        switch connector.toolCallingPolicy ?? .automatic {
        case .automatic:
            statusLine = "已清除已学习记录，后续将重新按 automatic 判断；可再次执行连接测试重新学习。"
            toastMessage = "已清除 \(connector.name) 的已学习工具兼容性，后续将重新自动判断。"
        case .enabled, .disabled:
            statusLine = "已清除已学习记录；当前仍按\(capability.toolCallingSource.title)生效。"
            toastMessage = "已清除 \(connector.name) 的已学习工具兼容性，当前仍按\(capability.toolCallingSource.title)生效。"
        }
        recordToolActivity(
            name: "connector.capability",
            summary: "已清除 \(connector.name) 的工具兼容性记录",
            statusLine: statusLine,
            isFailure: false
        )
        persistConnectors()
        if showsToast {
            notify(toastMessage, style: .success)
        }
    }

    public func checkConnectorHealth(id: UUID, showsToast: Bool = true, probeToolCalling: Bool = true) {
        guard let connector = state.connectors.first(where: { $0.id == id }) else { return }
        guard let index = state.connectors.firstIndex(where: { $0.id == id }) else { return }
        guard !healthChecksInFlight.contains(id) else { return }
        healthChecksInFlight.insert(id)
        if state.connectors[index].health != .ready {
            state.connectors[index].health = .attention
        }
        state.connectors[index].lastCheckedAt = .now

        Task {
            var shouldRecheck = false
            defer {
                self.healthChecksInFlight.remove(id)
                if shouldRecheck {
                    self.checkConnectorHealth(id: id, showsToast: false, probeToolCalling: probeToolCalling)
                }
            }
            do {
                let probe = try await environment.runtimeClient.probeConnector(
                    endpoint: connector.endpoint,
                    model: connector.modelName,
                    apiKey: connector.note,
                    kind: connector.kind,
                    probeToolCalling: probeToolCalling
                )
                guard let idx = self.state.connectors.firstIndex(where: { $0.id == id }) else { return }
                let current = self.state.connectors[idx]
                if Self.connectorConfigurationChanged(from: connector, to: current) {
                    shouldRecheck = self.canAutoCheckConnectorHealth(current)
                    return
                }
                self.state.connectors[idx].health = probe.health
                self.state.connectors[idx].lastCheckedAt = .now
                let capabilityChanged = self.rememberToolCallingCapability(
                    probe.toolCallingCapability,
                    connectorID: id,
                    activitySource: probeToolCalling ? .connectorProbe : nil
                )
                let capabilityProfile = ConnectorCapabilityProfile.infer(
                    for: self.state.connectors[idx],
                    mode: self.state.settings.contextMode
                )
                if showsToast {
                    switch probe.health {
                    case .ready:
                        if capabilityProfile.toolCallingConflict == .unsupported {
                            self.notify("\(connector.name) 已验证不兼容工具调用，但当前仍手动开启。", style: .warning)
                        } else if capabilityProfile.toolCallingConflict == .supported {
                            self.notify("\(connector.name) 已验证支持工具调用，但当前仍手动关闭。", style: .warning)
                        } else if probe.toolCallingCapability == .unsupported {
                            self.notify("\(connector.name) 已连接，但不兼容工具调用", style: .warning)
                        } else if probe.toolCallingCapability == .supported {
                            self.notify("\(connector.name) 就绪，已验证支持工具调用", style: .success)
                        } else {
                            self.notify("\(connector.name) 就绪", style: .success)
                        }
                    case .attention:
                        self.notify("\(connector.name) 配置需确认：服务可达，但模型或接口响应不匹配", style: .warning)
                    case .offline:
                        self.notify("\(connector.name) 离线", style: .error)
                    }
                }
                _ = capabilityChanged
            } catch {
                guard let idx = self.state.connectors.firstIndex(where: { $0.id == id }) else { return }
                let current = self.state.connectors[idx]
                if Self.connectorConfigurationChanged(from: connector, to: current) {
                    shouldRecheck = self.canAutoCheckConnectorHealth(current)
                    return
                }
                self.state.connectors[idx].health = .offline
                self.state.connectors[idx].lastCheckedAt = .now
                if showsToast { self.notify("\(connector.name) 连接失败：\(error.localizedDescription)", style: .error) }
            }
            self.persistConnectors()
        }
    }

    public func checkAllConnectorsHealth(showsToast: Bool = false, probeToolCalling: Bool = false) {
        for connector in state.connectors {
            checkConnectorHealth(id: connector.id, showsToast: showsToast, probeToolCalling: probeToolCalling)
        }
    }

    // MARK: - Live Activity Tracking

    /// Update the human-readable live activity description based on the latest step.
    func updateLiveActivity(from step: TaskStep) {
        switch step.kind {
        case .aiThinking:
            state.liveActivity = "正在思考…"
        case .toolCall:
            if let name = step.toolName {
                state.liveActivity = "正在\(Self.friendlyActivityName(name, params: step.toolParams))"
            } else {
                state.liveActivity = "正在调用工具…"
            }
        case .toolResult:
            if step.isFailure {
                state.liveActivity = "工具执行失败，正在处理…"
            }
            // Don't update for successful results — keep the previous activity
        case .textOutput:
            state.liveActivity = "正在生成回复…"
        case .reviewRequest:
            state.liveActivity = "等待审查确认"
        case .error:
            if step.recoverable {
                state.liveActivity = "遇到错误，尝试恢复…"
            } else {
                state.liveActivity = ""
            }
        case .userInput, .reviewResult:
            break
        }
    }

    static func friendlyActivityName(_ toolName: String, params: [String: String]?) -> String {
        switch toolName {
        case "workspace.index": return "索引项目结构…"
        case "code.search":
            if let q = params?["query"], !q.isEmpty { return "搜索「\(String(q.prefix(20)))」…" }
            return "搜索代码…"
        case "file.read":
            if let p = params?["path"] ?? params?["fullPath"] {
                let name = URL(fileURLWithPath: p).lastPathComponent
                return "读取 \(name)…"
            }
            return "读取文件…"
        case "file.write", "file.edit":
            if let p = params?["path"] ?? params?["fullPath"] {
                let name = URL(fileURLWithPath: p).lastPathComponent
                return "修改 \(name)…"
            }
            return "写入文件…"
        case "shell.exec":
            if let cmd = params?["command"] { return "执行 \(String(cmd.prefix(25)))…" }
            return "执行命令…"
        case "git": return "查看 Git 信息…"
        case "web.search":
            if let q = params?["query"] { return "搜索「\(String(q.prefix(20)))」…" }
            return "联网搜索…"
        case "web.fetch": return "读取网页…"
        case "wiki.build": return "构建知识页…"
        case "image.generate": return "生成图片…"
        case "verify.build": return "验证构建…"
        case "llm": return "LLM 分析…"
        default: return "调用 \(toolName)…"
        }
    }

    // MARK: - Message Sending

    private var generationTasks: [UUID: Task<Void, Never>] = [:]

    public func stopGenerating() {
        // Cancel only the selected thread's generation task
        if let threadID = state.selectedThreadID {
            generationTasks[threadID]?.cancel()
            generationTasks.removeValue(forKey: threadID)
            agentLoops.removeValue(forKey: threadID)
        }
        if generationTasks.isEmpty {
            state.isGenerating = false
            state.generationStartedAt = nil
            state.liveActivity = ""
        }
        if let threadID = state.selectedThreadID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == threadID }),
           state.threads[threadIndex].source == .task,
           state.threads[threadIndex].status == .running {
            flushStreamBuffer(for: threadID)
            state.threads[threadIndex].steps.append(TaskStep(kind: .error, text: "已中断", isFailure: false, recoverable: true, retryAction: "重试"))
            state.threads[threadIndex].status = .cancelled
            state.threads[threadIndex].updatedAt = .now
            BehaviorSignalTracker.record(signal: .cancel, thread: state.threads[threadIndex])
            persistThreads()
            streamBuffers.removeValue(forKey: threadID)
            streamLastFlushAt.removeValue(forKey: threadID)
        }
        // Clean up incomplete assistant step
        if let threadID = state.selectedThreadID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == threadID }),
           state.threads[threadIndex].source == .session {
            var steps = state.threads[threadIndex].steps
            if let lastStep = steps.last, lastStep.kind == .textOutput {
                if lastStep.text.isEmpty {
                    steps.removeLast()
                } else {
                    steps[steps.count - 1] = TaskStep(
                        id: lastStep.id, kind: .textOutput,
                        text: lastStep.text + "\n\n（已中断）",
                        isCollapsible: false, isCollapsed: false,
                        metrics: lastStep.metrics, createdAt: lastStep.createdAt
                    )
                }
                state.threads[threadIndex].steps = steps
                state.threads[threadIndex].preview = normalizedSessionPreview(steps.last?.text ?? "")
                state.threads[threadIndex].updatedAt = .now
            }
        }
        chatStreamBuffers.removeAll()
        chatStreamLastFlushAt.removeAll()
        persistThreads()
    }

    public func sendDraft() {
        let message = composedDraftMessage()
        // Allow concurrent tasks: only block if the selected thread is already running
        let selectedThreadRunning: Bool = {
            guard let tid = state.selectedThreadID else { return false }
            return generationTasks[tid] != nil
        }()
        guard !message.isEmpty, !selectedThreadRunning else { return }

        // Slash commands: /goal, /background, /schedule, /gateway
        if handleSlashCommand(message) { return }

        let agentInvocation = customAgentInvocation(from: message)
        let effectiveMessage = agentInvocation?.message ?? message

        reconcileSelectedRunningTaskIfIdle()
        if answerSelectedTaskStatusQuestion(effectiveMessage) {
            return
        }
        let decision = IntentRouter.plan(effectiveMessage)

        // Auto-match skill from registry
        let matchedSkill = SkillMatcher.match(input: effectiveMessage, intent: decision.intent)

        // Single path: always give full tools, LLM decides what to use.
        // Safety: file writes go through approval flow, dangerous commands need confirmation.
        sendTaskDraft(message: effectiveMessage, decision: decision, customAgent: agentInvocation?.agent, matchedSkill: matchedSkill)
    }

    private struct CustomAgentInvocation {
        let agent: CustomAgentDefinition
        let message: String
    }

    private func customAgentInvocation(from message: String) -> CustomAgentInvocation? {
        let prefix = "[Agent:"
        guard message.hasPrefix(prefix),
              let endIndex = message.firstIndex(of: "]") else {
            return nil
        }
        let nameStart = message.index(message.startIndex, offsetBy: prefix.count)
        let name = String(message[nameStart..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        AgentRegistry.shared.refresh(workspaceRoot: state.settings.workspacePath)
        guard let agent = AgentRegistry.shared.agents.first(where: { $0.name == name }) else {
            notify("未找到 Agent「\(name)」", style: .error)
            return nil
        }
        let contentStart = message.index(after: endIndex)
        let content = String(message[contentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return CustomAgentInvocation(agent: agent, message: content.isEmpty ? "请按你的 Agent 职责继续处理当前任务。" : content)
    }

    /// Send a task draft through the local task engine.
    private func sendTaskDraft(
        message: String,
        decision: PlannerDecision,
        customAgent: CustomAgentDefinition? = nil,
        matchedSkill: SkillMatchResult? = nil
    ) {
        let selectedConnector = customAgent?.preferredConnectorID.flatMap { id in
            state.connectors.first(where: { $0.id == id })
        } ?? state.activeConnector
        guard let connector = selectedConnector else {
            notify("请先选择一个连接器", style: .error)
            return
        }
        // Safety: block tool-using tasks when workspace is not set or is overly broad
        if decision.intent != .chat {
            let wp = state.settings.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if wp.isEmpty {
                notify("请先在设置中指定工作区目录，再执行任务。", style: .error)
                return
            }
            if WorkspaceSandbox.isOverlyBroadWorkspace(wp) {
                notify("工作区不能设为 home 目录或根目录，请指定一个具体的项目文件夹。", style: .error)
                return
            }
        }
        // Don't discard empty placeholder — we'll reuse it as the new task thread
        var context = AutoContextEngine.buildContext(
            workspaceRoot: state.settings.workspacePath,
            vaultRoot: state.settings.vaultPath,
            userInput: message,
            fileLimit: Self.relevantFileLimit(settings: state.settings, connector: connector),
            comfyUIServerURL: state.settings.comfyUIServerURL,
            comfyUIModelName: state.settings.comfyUIModelName
        )

        let intent = decision.intent
        let workflowName: String? = { if case .workflow(let name) = intent { return name } else { return nil } }()

        // If matching workflow, execute it directly
        if let wfName = workflowName, let workflow = WorkflowLibrary.find(named: wfName, workspaceRoot: state.settings.workspacePath) {
            executeWorkflow(taskTitle: message, workflow: workflow, context: context, message: message, decision: decision)
            return
        }

        // Check if multi-agent collaboration is warranted
        if customAgent == nil,
           MultiAgentOrchestrator.shouldUseMultiAgent(message: message, intent: intent),
           let plan = MultiAgentOrchestrator.createPlan(for: message, intent: intent, connectors: state.connectors, activeConnectorID: state.activeConnectorID) {
            executeMultiAgent(message: message, context: context, connector: connector, plan: plan, intent: intent, decision: decision)
            return
        }

        let isChatIntent = intent == .chat
        let userStep = TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false)
        // Chat intent: skip verbose planning step to keep UI clean
        let initialSteps: [TaskStep]
        if isChatIntent {
            initialSteps = [userStep]
        } else {
            var steps = [userStep]
            let planStep = TaskStep(
                kind: .aiThinking,
                text: Self.plannerStepText(for: decision),
                isCollapsible: true,
                isCollapsed: true
            )
            steps.append(planStep)
            if let match = matchedSkill {
                let skillStep = TaskStep(
                    kind: .aiThinking,
                    text: "🎯 \(match.reason)",
                    isCollapsible: true,
                    isCollapsed: true
                )
                steps.append(skillStep)
            }
            initialSteps = steps
        }
        let targetTaskID: UUID
        let loopPriorSteps: [TaskStep]
        if let selectedID = state.selectedThreadID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == selectedID }),
           state.threads[threadIndex].status != .running {
            let isEmptyPlaceholder = state.threads[threadIndex].steps.isEmpty
            if !isEmptyPlaceholder {
                // Continuing an existing thread with history
                if !state.threads[threadIndex].context.memory.isEmpty {
                    context.memory = state.threads[threadIndex].context.memory
                }
                Self.prepareThreadForContinuation(&state.threads[threadIndex], message: message)
                if UserFrustrationDetector.isFrustrated(message) {
                    BehaviorSignalTracker.record(signal: .frustration, thread: state.threads[threadIndex])
                }
            }
            // Update thread title if placeholder or generic
            let currentTitle = state.threads[threadIndex].title
            if isEmptyPlaceholder || currentTitle.isEmpty || currentTitle == "新会话" || currentTitle == "新对话" {
                state.threads[threadIndex].title = String(message.prefix(32))
            }
            state.threads[threadIndex].status = .running
            state.threads[threadIndex].connectorID = state.activeConnectorID
            state.threads[threadIndex].workflowName = workflowName
            state.threads[threadIndex].context = context
            for step in initialSteps {
                state.threads[threadIndex].steps.append(step)
            }
            loopPriorSteps = isEmptyPlaceholder ? initialSteps : state.threads[threadIndex].steps
            state.threads[threadIndex].updatedAt = .now
            targetTaskID = selectedID
        } else {
            let thread = Thread(
                title: String(message.prefix(32)),
                status: .running,
                steps: initialSteps,
                connectorID: state.activeConnectorID,
                workflowName: workflowName,
                context: context,
                source: isChatIntent ? .session : nil
            )
            state.threads.insert(thread, at: 0)
            targetTaskID = thread.id
            loopPriorSteps = thread.steps
        }
        state.selectThread(id: targetTaskID)
        state.modeLabel = decision.routeLabel
        persistThreads()

        let capturedImages = state.draftImages
        state.isGenerating = true
        state.generationStartedAt = Date()
        state.liveActivity = isChatIntent ? "思考中…" : "正在分析任务…"
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        var loopConfig = Self.agentLoopConfig(settings: state.settings, connector: connector, decision: decision)
        if let customAgent {
            loopConfig.customSystemPrompt = customAgent.systemPrompt
            let agentTools = Set(customAgent.tools.map { ToolNameCodec.canonicalName($0) })
            if !agentTools.isEmpty {
                loopConfig.allowedTools = agentTools
                if AgentLoop.expectsWikiOutput(message) {
                    loopConfig.allowedTools?.formUnion(["file.read", "file.extract", "wiki.build"])
                }
            }
        }
        // Inject matched skill hint into system prompt
        if customAgent == nil, let match = matchedSkill {
            let skill = match.skill
            var hint = "\n\n## 已激活技能：\(skill.name)\n\(skill.description)"
            if let systemHint = skill.systemHint, !systemHint.isEmpty {
                hint += "\n\n\(systemHint)"
            }
            if !skill.tools.isEmpty {
                hint += "\n推荐工具：\(skill.tools.joined(separator: "、"))"
            }
            hint += """

执行要求：
- 先按技能指南确认输入边界，再调用所需工具；不要只复述技能说明。
- 输出必须符合该技能的格式要求；保存类技能只有在 save_note/wiki_build/file_write 成功后才能说已保存。
- 如果技能请求与用户当前目标冲突，以用户当前目标为准，并说明取舍。
"""
            loopConfig.customSystemPrompt = (loopConfig.customSystemPrompt ?? "") + hint
            state.liveActivity = "已激活技能：\(skill.name)"
            // Switch to preferred model if needed
            if let preferred = ModelRouter.selectModel(for: skill, connectors: state.connectors, activeConnectorID: state.activeConnectorID),
               preferred.id != connector.id {
                loopConfig.modelName = preferred.modelName
            }
        }
        // Chat intent: cap iterations — LLM decides if tools needed, but don't run away
        if isChatIntent {
            loopConfig.maxIterations = min(loopConfig.maxIterations, 3)
        }
        let attemptedToolCalling = loopConfig.supportsToolCalling
        let loop = AgentLoop(
            config: loopConfig,
            runtime: environment.runtimeClient
        )
        agentLoops[targetTaskID] = loop

        generationTasks[targetTaskID] = Task { [weak self] in
            guard let self else { return }
            do {
                let completedTask = try await loop.run(
                    taskID: targetTaskID,
                    message: message,
                    intent: intent,
                    connector: connector,
                    allConnectors: state.connectors,
                    context: context,
                    priorSteps: loopPriorSteps,
                    summaryCache: state.threads.first(where: { $0.id == targetTaskID })?.summaryCache,
                    imageAttachments: capturedImages,
                    onStep: { [weak self] step in
                        guard let self else { return }
                        self.appendTaskStep(step, to: targetTaskID)
                    },
                    onStreamDelta: { [weak self] delta in
                        guard let self else { return }
                        self.appendStreamDelta(delta, to: targetTaskID)
                    }
                )

                guard !Task.isCancelled else { return }

                // Update task with completed state
                self.flushStreamBuffer(for: targetTaskID)
                self.mergeCompletedTask(completedTask, into: targetTaskID)
                self.recordConnectorOutcome(completedTask, connectorID: connector.id, attemptedToolCalling: attemptedToolCalling)
                MemoryEngine.shared.extractFromTask(completedTask)
                self.persistThreadsNow()

                // Record tool activities
                for step in completedTask.steps where step.kind == .toolCall {
                    self.recordToolActivity(name: step.toolName ?? "tool", summary: step.text, statusLine: "", isFailure: false)
                }

                // Post-mortem: scan completed session for known failure patterns
                if completedTask.context.metadata["selfImproveTask"] == nil,
                   let threadIndex = self.state.threads.firstIndex(where: { $0.id == targetTaskID }) {
                    let thread = self.state.threads[threadIndex]
                    let report = SessionPostMortem.shared.analyze(thread: thread)
                    if report.hasCritical {
                        AuditLog.shared.record(
                            tool: "postmortem",
                            input: "thread:\(thread.id)",
                            output: report.summary,
                            success: false
                        )
                        // Feed precise diagnosis to SelfImprovementEngine with session replay + source context
                        let precisePrompt = SelfImprovementEngine.shared.generatePreciseFixPrompt(
                            from: report,
                            steps: thread.steps
                        )
                        self.triggerPreciseSelfImprovement(prompt: precisePrompt, report: report)
                    }
                }

                // Self-improvement: check if metrics warrant auto-improving harness code
                if completedTask.context.metadata["selfImproveTask"] == nil {
                    self.checkAndTriggerSelfImprovement()
                } else {
                    // This WAS a self-improvement task — record result
                    let succeeded = completedTask.status == .completed
                    if succeeded {
                        SelfImprovementEngine.shared.onImprovementSuccess()
                    } else {
                        SelfImprovementEngine.shared.onImprovementFailure()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: targetTaskID)
                if let threadIndex = self.state.threads.firstIndex(where: { $0.id == targetTaskID }) {
                    self.state.threads[threadIndex].steps.append(
                        TaskStep(kind: .error, text: error.localizedDescription, isFailure: true, recoverable: true, retryAction: "重试")
                    )
                    self.state.threads[threadIndex].status = .failed
                    self.state.threads[threadIndex].updatedAt = Date()
                    self.persistThreadsNow()
                }
                self.recordToolActivity(name: "task.error", summary: "任务执行失败", statusLine: error.localizedDescription, isFailure: true)
            }

            // Append pending follow-up if exists
            if let followUp = self.state.pendingFollowUp, !followUp.isEmpty {
                if let threadIndex = self.state.threads.firstIndex(where: { $0.id == targetTaskID }) {
                    let step = TaskStep(kind: .userInput, text: followUp, isCollapsible: false, isCollapsed: false)
                    self.state.threads[threadIndex].steps.append(step)
                    self.state.threads[threadIndex].updatedAt = .now
                    self.persistThreadsNow()
                }
                self.state.pendingFollowUp = nil
            }

            self.generationTasks.removeValue(forKey: targetTaskID)
            self.agentLoops.removeValue(forKey: targetTaskID)
            self.streamBuffers.removeValue(forKey: targetTaskID)
            self.streamLastFlushAt.removeValue(forKey: targetTaskID)
            if self.generationTasks.isEmpty {
                self.state.isGenerating = false
                self.state.generationStartedAt = nil
                self.state.liveActivity = ""
            }
        }
    }

    /// Check outcome metrics and trigger a self-improvement task if needed.
    private func checkAndTriggerSelfImprovement() {
        guard let diagnosis = SelfImprovementEngine.shared.shouldTrigger() else { return }
        guard let connector = state.activeConnector else { return }
        guard !state.isGenerating else { return }

        let message = SelfImprovementEngine.shared.generateImprovementTask(diagnosis: diagnosis)

        // Build context pointing to the harness source directory
        var context = AutoContextEngine.buildContext(
            workspaceRoot: SelfImprovementEngine.shared.harnessRoot,
            userInput: message
        )
        context.metadata["selfImproveTask"] = "true"
        context.metadata["diagnosisCategory"] = diagnosis.category.rawValue

        let userStep = TaskStep(kind: .userInput, text: "🔧 自我改进：\(diagnosis.description)", isCollapsible: false, isCollapsed: false)
        let planStep = TaskStep(
            kind: .aiThinking,
            text: "检测到性能问题，启动自我改进流程。类别：\(diagnosis.category.rawValue)，严重程度：\(diagnosis.severity.rawValue)",
            isCollapsible: true,
            isCollapsed: false
        )
        let thread = Thread(
            title: "自我改进：\(diagnosis.category.rawValue)",
            status: .running,
            steps: [userStep, planStep],
            connectorID: state.activeConnectorID,
            context: context,
            source: .task
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
        persistThreads()

        state.isGenerating = true
        state.generationStartedAt = Date()
        var loopConfig = AgentLoop.Config(
            maxIterations: 20,
            maxTokensPerTurn: 16384,
            workspaceRoot: SelfImprovementEngine.shared.harnessRoot,
            supportsToolCalling: true,
            contextMode: .deep,
            modelName: connector.modelName
        )
        loopConfig.allowedTools = ["file.read", "file.edit", "code.search", "workspace.index", "shell.exec", "verify.build", "git"]

        let loop = AgentLoop(config: loopConfig, runtime: environment.runtimeClient)
        let targetID = thread.id
        agentLoops[targetID] = loop

        generationTasks[targetID] = Task { [weak self] in
            guard let self else { return }
            do {
                let completedTask: AgentTask = try await loop.run(
                    taskID: targetID,
                    message: message,
                    intent: UserIntent.task,
                    connector: connector,
                    context: context,
                    priorSteps: thread.steps,
                    onStep: { @MainActor [weak self] (step: TaskStep) in
                        guard let self else { return }
                        self.appendTaskStep(step, to: targetID)
                    },
                    onStreamDelta: { @Sendable @MainActor [weak self] (delta: String) in
                        guard let self else { return }
                        self.appendStreamDelta(delta, to: targetID)
                    }
                )
                guard !Task.isCancelled else { return }

                self.flushStreamBuffer(for: targetID)
                self.mergeCompletedTask(completedTask, into: targetID)
                self.persistThreadsNow()

                let succeeded = completedTask.status == .completed
                SelfImprovementEngine.shared.recordAttempt(
                    category: diagnosis.category.rawValue,
                    description: diagnosis.description,
                    filesChanged: completedTask.steps
                        .filter { $0.kind == .toolCall && ($0.toolName == "file.edit" || $0.toolName == "file.write") }
                        .compactMap { $0.toolParams?["path"] },
                    buildSuccess: succeeded,
                    commitHash: nil
                )
                if succeeded {
                    SelfImprovementEngine.shared.onImprovementSuccess()
                } else {
                    SelfImprovementEngine.shared.onImprovementFailure()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: targetID)
                if let threadIndex = self.state.threads.firstIndex(where: { $0.id == targetID }) {
                    self.state.threads[threadIndex].steps.append(
                        TaskStep(kind: .error, text: "自我改进失败：\(error.localizedDescription)", isFailure: true, recoverable: false)
                    )
                    self.state.threads[threadIndex].status = .failed
                    self.state.threads[threadIndex].updatedAt = Date()
                    self.persistThreadsNow()
                }
                SelfImprovementEngine.shared.onImprovementFailure()
            }

            self.generationTasks.removeValue(forKey: targetID)
            self.agentLoops.removeValue(forKey: targetID)
            self.streamBuffers.removeValue(forKey: targetID)
            self.streamLastFlushAt.removeValue(forKey: targetID)
            if self.generationTasks.isEmpty {
                self.state.isGenerating = false
                self.state.generationStartedAt = nil
                self.state.liveActivity = ""
            }
        }
    }

    // MARK: - Precise Self-Improvement (PostMortem-driven)

    /// Trigger a self-improvement task based on a precise PostMortem diagnosis.
    /// Unlike the stats-based approach, this provides exact source locations and fix descriptions.
    private func triggerPreciseSelfImprovement(prompt: String, report: SessionPostMortem.Report) {
        // Respect cooldown and guard conditions
        guard SelfImprovementEngine.shared.shouldTrigger() != nil || report.hasCritical else { return }
        guard let connector = state.activeConnector else { return }
        guard !state.isGenerating else { return }

        let message = """
        # 自我改进任务（会话后检触发）

        \(prompt)

        ## 执行步骤
        1. 先读取上述建议修复文件中指定行号附近的代码
        2. 理解当前实现和问题根因
        3. 用 file_edit 修改代码（最小化修改）
        4. 运行 `bash \(SelfImprovementEngine.shared.buildScript)` 验证编译
        5. 编译通过后提交：先运行 `git status --short`，只 `git add -- <本轮修改文件>`，再 `git commit -m "self-fix: \(report.findings.first?.pattern.rawValue ?? "postmortem")"`
        6. 重启应用

        ## 限制
        - 只修改 LaicaiNativeFoundation 目录下的 .swift 文件
        - 不要修改 Models.swift 的 struct 定义
        - 每次最多修改 3 个文件
        - 必须编译通过
        """

        var context = AutoContextEngine.buildContext(
            workspaceRoot: SelfImprovementEngine.shared.harnessRoot,
            userInput: message
        )
        context.metadata["selfImproveTask"] = "true"
        context.metadata["postmortemThreadID"] = report.threadID.uuidString

        let targetID = UUID()
        let thread = Thread(
            id: targetID,
            title: "🔧 自动修复：\(report.findings.first?.pattern.rawValue ?? "postmortem")",
            status: .running,
            connectorID: connector.id,
            context: context,
            modelName: connector.modelName,
            category: .engineering,
            source: .task
        )
        state.threads.insert(thread, at: 0)
        persistThreadsNow()

        var loopConfig = AgentLoop.Config(
            maxIterations: 20,
            maxTokensPerTurn: 16384,
            workspaceRoot: SelfImprovementEngine.shared.harnessRoot,
            supportsToolCalling: true,
            contextMode: .deep,
            modelName: connector.modelName
        )
        loopConfig.allowedTools = ["file.read", "file.edit", "code.search", "workspace.index", "shell.exec", "verify.build", "git"]

        let loop = AgentLoop(config: loopConfig, runtime: environment.runtimeClient)
        agentLoops[targetID] = loop

        state.isGenerating = true
        state.generationStartedAt = Date()
        let targetTaskID = targetID

        generationTasks[targetTaskID] = Task { [weak self] in
            guard let self else { return }
            do {
                let completedTask: AgentTask = try await loop.run(
                    taskID: targetID,
                    message: message,
                    intent: UserIntent.task,
                    connector: connector,
                    context: context,
                    priorSteps: [],
                    onStep: { @MainActor [weak self] (step: TaskStep) in
                        guard let self else { return }
                        self.appendTaskStep(step, to: targetTaskID)
                    },
                    onStreamDelta: { @Sendable @MainActor [weak self] (delta: String) in
                        guard let self else { return }
                        self.appendStreamDelta(delta, to: targetTaskID)
                    }
                )
                self.mergeCompletedTask(completedTask, into: targetTaskID)
                self.persistThreadsNow()

                let succeeded = completedTask.status == .completed
                SelfImprovementEngine.shared.recordAttempt(
                    category: report.findings.first?.pattern.rawValue ?? "postmortem",
                    description: report.summary,
                    filesChanged: completedTask.steps
                        .filter { $0.kind == .reviewRequest }
                        .compactMap(\.diffFilePath),
                    buildSuccess: succeeded,
                    commitHash: nil
                )
                if succeeded {
                    SelfImprovementEngine.shared.onImprovementSuccess()
                } else {
                    SelfImprovementEngine.shared.onImprovementFailure()
                }
            } catch {
                guard !Task.isCancelled else { return }
                if let ti = self.state.threads.firstIndex(where: { $0.id == targetTaskID }) {
                    self.state.threads[ti].steps.append(
                        TaskStep(kind: .error, text: "自动修复失败：\(error.localizedDescription)", isFailure: true, recoverable: false)
                    )
                    self.state.threads[ti].status = .failed
                    self.state.threads[ti].updatedAt = Date()
                    self.persistThreadsNow()
                }
                SelfImprovementEngine.shared.onImprovementFailure()
            }

            self.generationTasks.removeValue(forKey: targetTaskID)
            self.agentLoops.removeValue(forKey: targetTaskID)
            if self.generationTasks.isEmpty {
                self.state.isGenerating = false
                self.state.generationStartedAt = nil
                self.state.liveActivity = ""
            }
        }
    }

    // MARK: - Slash Commands

    /// Handle /goal, /background, /schedule, /gateway commands. Returns true if handled.
    private func handleSlashCommand(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)

        // /goal <title> — create a persistent goal
        if trimmed.hasPrefix("/goal ") {
            let body = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else {
                notify("用法：/goal <目标描述>", style: .error)
                return true
            }
            state.draftMessage = ""
            createGoal(title: body, message: body)
            return true
        }

        // /goal pause / resume / cancel / list
        if trimmed == "/goal list" {
            let goals = GoalEngine.shared.activeGoals
            let text = goals.isEmpty ? "暂无活跃目标" : goals.map { "- [\($0.status.displayText)] \($0.title)" }.joined(separator: "\n")
            notify(text, style: .info)
            state.draftMessage = ""
            return true
        }
        if trimmed.hasPrefix("/goal pause") {
            if let goal = GoalEngine.shared.activeGoals.first(where: { $0.status == .running }) {
                pauseGoal(id: goal.id)
            }
            state.draftMessage = ""
            return true
        }
        if trimmed.hasPrefix("/goal resume") {
            if let goal = GoalEngine.shared.activeGoals.first(where: { $0.status == .paused }) {
                resumeGoal(id: goal.id)
            }
            state.draftMessage = ""
            return true
        }

        // /background — send current task to background
        if trimmed == "/background" || trimmed == "/bg" {
            if let threadID = state.selectedThreadID {
                sendToBackground(threadID: threadID)
            } else {
                notify("没有选中的任务可以转到后台", style: .error)
            }
            state.draftMessage = ""
            return true
        }

        // /schedule <interval> <message> — quick schedule creation
        if trimmed.hasPrefix("/schedule ") {
            let body = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            let parts = body.components(separatedBy: " ")
            guard parts.count >= 2 else {
                notify("用法：/schedule <间隔分钟数> <任务消息>", style: .error)
                return true
            }
            if let minutes = Int(parts[0]) {
                let taskMessage = parts.dropFirst().joined(separator: " ")
                let task = ScheduledTask(
                    name: String(taskMessage.prefix(30)),
                    message: taskMessage,
                    schedule: .interval(seconds: minutes * 60)
                )
                SchedulerEngine.shared.addTask(task)
                notify("定时任务已创建：每 \(minutes) 分钟执行「\(taskMessage)」", style: .success)
            }
            state.draftMessage = ""
            return true
        }

        // /gateway start/stop
        if trimmed == "/gateway start" {
            startGateway()
            state.draftMessage = ""
            return true
        }
        if trimmed == "/gateway stop" {
            stopGateway()
            state.draftMessage = ""
            return true
        }

        // /pipe <skill1> | <skill2> | ... — run a skill pipeline
        if trimmed.hasPrefix("/pipe ") {
            let body = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if let pipeline = PipelineParser.parse(body) {
                state.draftMessage = ""
                Task { await SkillCompositionEngine.shared.execute(pipeline, workspaceRoot: state.settings.workspacePath) }
                notify("管道已启动：\(pipeline.name)", style: .success)
            } else {
                notify("用法：/pipe 技能1 | 技能2 | 技能3", style: .error)
            }
            return true
        }

        // /foreach <glob>: <message> — batch execution
        if trimmed.hasPrefix("/foreach ") {
            let body = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            if let pipeline = PipelineParser.parseBatch("/foreach " + body) {
                state.draftMessage = ""
                Task { await SkillCompositionEngine.shared.execute(pipeline, workspaceRoot: state.settings.workspacePath) }
                notify("批量任务已启动：\(pipeline.name)", style: .success)
            } else {
                notify("用法：/foreach file in *.swift: 审查代码", style: .error)
            }
            return true
        }

        // /export — export sessions for teleport
        if trimmed == "/export" {
            let url = SessionTeleport.suggestedExportURL(workspaceName: state.workspaceName)
            do {
                try SessionTeleport.shared.exportBundle(
                    threads: state.threads,
                    connectors: state.connectors,
                    settings: state.settings,
                    to: url
                )
                notify("已导出到 \(url.lastPathComponent)", style: .success)
            } catch {
                notify("导出失败：\(error.localizedDescription)", style: .error)
            }
            state.draftMessage = ""
            return true
        }

        // /regression — run model regression tests
        if trimmed == "/regression" {
            state.draftMessage = ""
            Task { await ModelRegressionRunner.shared.runAll() }
            notify("模型回归测试已启动", style: .info)
            return true
        }

        return false
    }

    /// Execute a predefined workflow
    private func executeWorkflow(
        taskTitle: String,
        workflow: WorkflowDefinition,
        context: TaskContext,
        message: String,
        decision: PlannerDecision? = nil,
        userParams: [String: String] = [:]
    ) {
        guard let connector = state.activeConnector else {
            notify("请先选择一个连接器", style: .error)
            return
        }
        let plannerDecision = decision ?? PlannerDecision(
            intent: .workflow(workflow.name),
            confidence: 0.95,
            reason: "用户手动选择了工作流。",
            routeLabel: "工作流",
            expectedCapabilities: workflow.steps.map(\.name)
        )

        let thread = Thread(
            title: String(taskTitle.prefix(32)),
            status: .running,
            steps: [
                TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false),
                TaskStep(
                    kind: .aiThinking,
                    text: Self.plannerStepText(for: plannerDecision),
                    isCollapsible: true,
                    isCollapsed: true
                )
            ],
            connectorID: state.activeConnectorID,
            workflowName: workflow.name,
            context: context
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
        state.modeLabel = "工作流"
        state.isGenerating = true
        state.generationStartedAt = Date()
        state.liveActivity = "正在执行工作流…"
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        let run = WorkflowRun(name: workflow.name, goal: message, statusLine: "执行中")
        state.workflowRuns.insert(run, at: 0)
        if state.workflowRuns.count > 20 { state.workflowRuns = Array(state.workflowRuns.prefix(20)) }
        persistThreads()

        let wfThreadID = thread.id
        generationTasks[wfThreadID] = Task { [weak self] in
            guard let self else { return }

            let steps = await StepExecutor.executeWorkflow(
                workflow,
                context: context,
                connector: connector,
                runtime: self.environment.runtimeClient,
                userParams: userParams,
                onStepProgress: { [weak self] progress in
                    guard let self else { return }
                    self.handleWorkflowStepProgress(progress, threadID: thread.id, runID: run.id)
                },
                onStreamDelta: { _ in }
            )

            guard !Task.isCancelled else { return }

            if let threadIndex = self.state.threads.firstIndex(where: { $0.id == thread.id }) {
                let hasError = steps.contains { $0.isFailure }
                self.state.threads[threadIndex].steps.append(Self.workflowCompletionCheckStep(steps: steps, hasError: hasError))
                self.state.threads[threadIndex].status = hasError ? .failed : .completed
                self.state.threads[threadIndex].updatedAt = .now
                if let runIndex = self.state.workflowRuns.firstIndex(where: { $0.id == run.id }) {
                    self.state.workflowRuns[runIndex].statusLine = hasError ? "失败" : "完成"
                    self.state.workflowRuns[runIndex].updatedAt = .now
                }
                self.persistThreadsNow()
            }

            self.generationTasks.removeValue(forKey: wfThreadID)
            if self.generationTasks.isEmpty {
                self.state.isGenerating = false
                self.state.generationStartedAt = nil
                self.state.liveActivity = ""
            }
        }
    }

    private func handleWorkflowStepProgress(_ progress: StepExecutor.StepProgress, threadID: UUID, runID: UUID) {
        if let idx = state.threads.firstIndex(where: { $0.id == threadID }) {
            state.threads[idx].steps.append(progress.taskStep)
            state.threads[idx].updatedAt = .now
            updateLiveActivity(from: progress.taskStep)
        }
        if let runIdx = state.workflowRuns.firstIndex(where: { $0.id == runID }) {
            state.workflowRuns[runIdx].statusLine = "步骤 \(progress.stepIndex + 1)/\(progress.totalSteps)：\(progress.stepName)"
        }
    }

    // MARK: - Multi-Agent Execution

    private func executeMultiAgent(
        message: String,
        context: TaskContext,
        connector: ConnectorProfile,
        plan: MultiAgentPlan,
        intent: UserIntent,
        decision: PlannerDecision
    ) {
        let thread = Thread(
            title: String(message.prefix(32)),
            status: .running,
            steps: [],
            connectorID: state.activeConnectorID,
            context: context,
            multiAgentPlan: plan
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
        state.modeLabel = "多Agent协同"
        state.isGenerating = true
        state.generationStartedAt = Date()
        state.liveActivity = "正在规划多Agent协同…"
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        persistThreads()

        let orchConfig = MultiAgentOrchestrator.Config(
            workspaceRoot: state.settings.workspacePath,
            contextMode: state.settings.contextMode
        )
        let orchestrator = MultiAgentOrchestrator(
            config: orchConfig,
            runtime: environment.runtimeClient
        )

        let maThreadID = thread.id
        generationTasks[maThreadID] = Task { [weak self] in
            guard let self else { return }
            do {
                let completedTask = try await orchestrator.run(
                    taskID: maThreadID,
                    message: message,
                    intent: intent,
                    connector: connector,
                    allConnectors: self.state.connectors,
                    context: context,
                    plan: plan,
                    onStep: { [weak self] step in
                        guard let self else { return }
                        self.appendTaskStep(step, to: maThreadID)
                    },
                    onStreamDelta: { [weak self] delta in
                        guard let self else { return }
                        self.appendStreamDelta(delta, to: maThreadID)
                    },
                    onPlanUpdate: { [weak self] updatedPlan in
                        guard let self else { return }
                        self.updateMultiAgentPlan(updatedPlan, for: maThreadID)
                    }
                )

                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: maThreadID)
                self.mergeCompletedTask(completedTask, into: maThreadID)
                self.persistThreadsNow()
            } catch {
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: maThreadID)
                if let idx = self.state.threads.firstIndex(where: { $0.id == maThreadID }) {
                    self.state.threads[idx].steps.append(
                        TaskStep(kind: .error, text: "多Agent执行失败：\(error.localizedDescription)", isFailure: true, recoverable: true)
                    )
                    self.state.threads[idx].status = .failed
                    self.state.threads[idx].updatedAt = .now
                    self.persistThreadsNow()
                }
            }
            self.generationTasks.removeValue(forKey: maThreadID)
            self.streamBuffers.removeValue(forKey: maThreadID)
            self.streamLastFlushAt.removeValue(forKey: maThreadID)
            if self.generationTasks.isEmpty {
                self.state.isGenerating = false
                self.state.generationStartedAt = nil
                self.state.liveActivity = ""
            }
        }
    }

    public func updateMultiAgentPlan(_ plan: MultiAgentPlan, for threadID: UUID) {
        if let idx = state.threads.firstIndex(where: { $0.id == threadID }) {
            state.threads[idx].multiAgentPlan = plan
        }
    }

    /// Execute a user-edited multi-agent plan (triggered from the plan editor UI).
    public func executeEditedPlan(threadID: UUID) {
        guard let idx = state.threads.firstIndex(where: { $0.id == threadID }),
              var plan = state.threads[idx].multiAgentPlan,
              plan.isEditable else { return }

        plan.isEditable = false
        plan.status = .running
        state.threads[idx].multiAgentPlan = plan
        state.threads[idx].status = .running
        state.threads[idx].updatedAt = .now

        let thread = state.threads[idx]
        let message = thread.steps.first(where: { $0.kind == .userInput })?.text ?? thread.title

        guard let connector = state.activeConnector else { return }

        state.isGenerating = true
        state.generationStartedAt = Date()
        let epThreadID = thread.id
        generationTasks[epThreadID] = Task { [weak self] in
            guard let self else { return }
            let orchestrator = MultiAgentOrchestrator(
                config: .init(
                    workspaceRoot: self.state.settings.workspacePath,
                    contextMode: self.state.settings.contextMode
                ),
                runtime: self.environment.runtimeClient
            )
            do {
                let completedTask = try await orchestrator.run(
                    taskID: epThreadID,
                    message: message,
                    intent: .task,
                    connector: connector,
                    allConnectors: self.state.connectors,
                    context: thread.context,
                    plan: plan,
                    onStep: { [weak self] step in
                        self?.appendTaskStep(step, to: epThreadID)
                    },
                    onStreamDelta: { [weak self] delta in
                        self?.appendStreamDelta(delta, to: epThreadID)
                    },
                    onPlanUpdate: { [weak self] updatedPlan in
                        self?.updateMultiAgentPlan(updatedPlan, for: epThreadID)
                    }
                )
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: epThreadID)
                self.mergeCompletedTask(completedTask, into: epThreadID)
                self.persistThreadsNow()
            } catch {
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: epThreadID)
                if let idx = self.state.threads.firstIndex(where: { $0.id == epThreadID }) {
                    self.state.threads[idx].steps.append(
                        TaskStep(kind: .error, text: "多Agent执行失败：\(error.localizedDescription)", isFailure: true, recoverable: true)
                    )
                    self.state.threads[idx].status = .failed
                    self.state.threads[idx].updatedAt = .now
                    self.persistThreadsNow()
                }
            }
            self.generationTasks.removeValue(forKey: epThreadID)
            self.streamBuffers.removeValue(forKey: epThreadID)
            self.streamLastFlushAt.removeValue(forKey: epThreadID)
            if self.generationTasks.isEmpty {
                self.state.isGenerating = false
                self.state.generationStartedAt = nil
                self.state.liveActivity = ""
            }
        }
    }

    /// Cancel a multi-agent plan (user chose to cancel from plan editor).
    public func cancelMultiAgentPlan(for threadID: UUID) {
        guard let idx = state.threads.firstIndex(where: { $0.id == threadID }) else { return }
        state.threads[idx].multiAgentPlan = nil
        state.threads[idx].status = .cancelled
        state.threads[idx].updatedAt = .now
        persistThreads()
    }

    /// Resume a failed multi-agent plan from where it left off.
    public func resumeFailedPlan(threadID: UUID) {
        guard let idx = state.threads.firstIndex(where: { $0.id == threadID }),
              var plan = state.threads[idx].multiAgentPlan,
              plan.status == .failed else { return }

        // Reset failed agents back to queued so orchestrator re-runs them
        for i in plan.agents.indices where plan.agents[i].status == .failed {
            plan.agents[i].status = .queued
            plan.agents[i].errorMessage = nil
            plan.agents[i].retryCount = 0
            plan.agents[i].updatedAt = .now
        }
        plan.status = .running
        plan.isEditable = false
        state.threads[idx].multiAgentPlan = plan
        state.threads[idx].status = .running
        state.threads[idx].updatedAt = .now

        let thread = state.threads[idx]
        let message = thread.steps.first(where: { $0.kind == .userInput })?.text ?? thread.title

        guard let connector = state.activeConnector else { return }

        state.isGenerating = true
        state.generationStartedAt = Date()
        let rpThreadID = thread.id
        generationTasks[rpThreadID] = Task { [weak self] in
            guard let self else { return }
            let orchestrator = MultiAgentOrchestrator(
                config: .init(
                    workspaceRoot: self.state.settings.workspacePath,
                    contextMode: self.state.settings.contextMode
                ),
                runtime: self.environment.runtimeClient
            )
            do {
                let completedTask = try await orchestrator.run(
                    taskID: rpThreadID,
                    message: message,
                    intent: .task,
                    connector: connector,
                    allConnectors: self.state.connectors,
                    context: thread.context,
                    plan: plan,
                    onStep: { [weak self] step in
                        self?.appendTaskStep(step, to: rpThreadID)
                    },
                    onStreamDelta: { [weak self] delta in
                        self?.appendStreamDelta(delta, to: rpThreadID)
                    },
                    onPlanUpdate: { [weak self] updatedPlan in
                        self?.updateMultiAgentPlan(updatedPlan, for: rpThreadID)
                    }
                )
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: rpThreadID)
                self.mergeCompletedTask(completedTask, into: rpThreadID)
                self.persistThreadsNow()
            } catch {
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: rpThreadID)
                if let idx = self.state.threads.firstIndex(where: { $0.id == rpThreadID }) {
                    self.state.threads[idx].steps.append(
                        TaskStep(kind: .error, text: "多Agent恢复执行失败：\(error.localizedDescription)", isFailure: true, recoverable: true)
                    )
                    self.state.threads[idx].status = .failed
                    self.state.threads[idx].updatedAt = .now
                    self.persistThreadsNow()
                }
            }
            self.generationTasks.removeValue(forKey: rpThreadID)
            self.streamBuffers.removeValue(forKey: rpThreadID)
            self.streamLastFlushAt.removeValue(forKey: rpThreadID)
            if self.generationTasks.isEmpty {
                self.state.isGenerating = false
                self.state.generationStartedAt = nil
                self.state.liveActivity = ""
            }
        }
    }

    // MARK: - Task Management

    public func approveReview(taskID: UUID, stepID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        guard let stepIndex = state.threads[threadIndex].steps.firstIndex(where: { $0.id == stepID }) else { return }

        let step = state.threads[threadIndex].steps[stepIndex]
        guard step.approved == nil else { return }
        guard let filePath = step.diffFilePath,
              let newContent = step.diffNewContent else {
            state.threads[threadIndex].steps[stepIndex].approved = false
            appendReviewResult(to: threadIndex, approved: false, text: "缺少文件变更内容，无法写入。")
            state.threads[threadIndex].updatedAt = .now
            persistThreads()
            return
        }

        let fullPath = step.toolParams?["fullPath"]
            ?? absolutePath(for: filePath, workspaceRoot: state.threads[threadIndex].context.workspaceRoot)
        let createDirectories = step.toolParams?["createDirectories"] != "false"

        if let securityError = SecurityManager.shared.checkWrite(path: fullPath) {
            state.threads[threadIndex].steps[stepIndex].approved = false
            appendReviewResult(to: threadIndex, approved: false, text: "写入被安全策略拦截：\(securityError)")
            let toolName = step.toolName ?? "file.write"
            AuditLog.shared.record(tool: toolName, input: filePath, output: securityError, success: false)
            recordToolActivity(name: toolName, summary: "写入被拦截", statusLine: filePath, isFailure: true)
            persistThreads()
            return
        }

        // Verify file hasn't been modified externally since review was created
        if let oldContent = step.diffOldContent,
           FileManager.default.fileExists(atPath: fullPath) {
            if let currentContent = try? String(contentsOfFile: fullPath, encoding: .utf8),
               currentContent != oldContent {
                state.threads[threadIndex].steps[stepIndex].approved = false
                appendReviewResult(to: threadIndex, approved: false, text: "文件在审查期间被外部修改，写入已取消。请重新读取文件并提交新变更。")
                let toolName = step.toolName ?? "file.write"
                AuditLog.shared.record(tool: toolName, input: filePath, output: "文件被外部修改", success: false)
                recordToolActivity(name: toolName, summary: "写入取消：文件被外部修改", statusLine: filePath, isFailure: true)
                persistThreads()
                return
            }
        }

        do {
            try WriteFileTool().performWrite(fullPath: fullPath, content: newContent, createDirectories: createDirectories)
            state.threads[threadIndex].steps[stepIndex].approved = true
            appendReviewResult(to: threadIndex, approved: true, text: "已写入 \(filePath)")
            let toolName = step.toolName ?? "file.write"
            AuditLog.shared.record(tool: toolName, input: filePath, output: "已写入 \(newContent.count) 字符", success: true)
            recordToolActivity(name: toolName, summary: "已写入文件", statusLine: filePath, isFailure: false)
            refreshSkillsIfNeeded(filePath: filePath)
            schedulePostWriteVerification(threadIndex: threadIndex, filePath: filePath)
        } catch {
            state.threads[threadIndex].steps[stepIndex].approved = false
            appendReviewResult(to: threadIndex, approved: false, text: "写入失败：\(error.localizedDescription)")
            let toolName = step.toolName ?? "file.write"
            AuditLog.shared.record(tool: toolName, input: filePath, output: error.localizedDescription, success: false)
            recordToolActivity(name: toolName, summary: "写入失败", statusLine: error.localizedDescription, isFailure: true)
        }
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
    }

    public func approveHunk(taskID: UUID, stepID: UUID, hunkID: UUID) {
        guard let ti = state.threads.firstIndex(where: { $0.id == taskID }),
              let si = state.threads[ti].steps.firstIndex(where: { $0.id == stepID }),
              var hunks = state.threads[ti].steps[si].diffHunks,
              let hi = hunks.firstIndex(where: { $0.id == hunkID }) else { return }
        hunks[hi].approved = true
        state.threads[ti].steps[si].diffHunks = hunks
        checkAllHunksDecided(threadIndex: ti, stepIndex: si)
        state.threads[ti].updatedAt = .now
        persistThreads()
    }

    public func rejectHunk(taskID: UUID, stepID: UUID, hunkID: UUID) {
        guard let ti = state.threads.firstIndex(where: { $0.id == taskID }),
              let si = state.threads[ti].steps.firstIndex(where: { $0.id == stepID }),
              var hunks = state.threads[ti].steps[si].diffHunks,
              let hi = hunks.firstIndex(where: { $0.id == hunkID }) else { return }
        hunks[hi].approved = false
        state.threads[ti].steps[si].diffHunks = hunks
        checkAllHunksDecided(threadIndex: ti, stepIndex: si)
        state.threads[ti].updatedAt = .now
        persistThreads()
    }

    private func checkAllHunksDecided(threadIndex ti: Int, stepIndex si: Int) {
        guard let hunks = state.threads[ti].steps[si].diffHunks,
              hunks.allSatisfy({ $0.approved != nil }) else { return }
        let approvedHunks = hunks.filter { $0.approved == true }
        if approvedHunks.isEmpty {
            state.threads[ti].steps[si].approved = false
            appendReviewResult(to: ti, approved: false, text: "所有 hunk 均已拒绝")
            return
        }
        guard let filePath = state.threads[ti].steps[si].diffFilePath,
              let oldContent = state.threads[ti].steps[si].diffOldContent else {
            state.threads[ti].steps[si].approved = false
            appendReviewResult(to: ti, approved: false, text: "缺少文件信息")
            return
        }
        var result = oldContent
        for hunk in approvedHunks.sorted(by: { $0.index < $1.index }) {
            result = result.replacingOccurrences(of: hunk.oldText, with: hunk.newText)
        }
        let fullPath = state.threads[ti].steps[si].toolParams?["fullPath"]
            ?? absolutePath(for: filePath, workspaceRoot: state.threads[ti].context.workspaceRoot)
        let createDirectories = state.threads[ti].steps[si].toolParams?["createDirectories"] != "false"
        if let securityError = SecurityManager.shared.checkWrite(path: fullPath) {
            state.threads[ti].steps[si].approved = false
            appendReviewResult(to: ti, approved: false, text: "安全策略拦截：\(securityError)")
            return
        }
        do {
            try WriteFileTool().performWrite(fullPath: fullPath, content: result, createDirectories: createDirectories)
            state.threads[ti].steps[si].approved = true
            let accepted = approvedHunks.count
            let rejected = hunks.count - accepted
            appendReviewResult(to: ti, approved: true, text: "已写入 \(filePath)（接受 \(accepted) / 拒绝 \(rejected) 个 hunk）")
            refreshSkillsIfNeeded(filePath: filePath)
            schedulePostWriteVerification(threadIndex: ti, filePath: filePath)
        } catch {
            state.threads[ti].steps[si].approved = false
            appendReviewResult(to: ti, approved: false, text: "写入失败：\(error.localizedDescription)")
        }
    }

    private func schedulePostWriteVerification(threadIndex: Int, filePath: String? = nil) {
        // Skip verification for files clearly unrelated to project tests
        if let fp = filePath?.lowercased() {
            let skipExtensions = [".json", ".md", ".txt", ".yaml", ".yml", ".toml", ".lock", ".png", ".jpg", ".svg", ".ico"]
            let skipDirectories = ["skills/", "docs/", "assets/", ".github/", ".vscode/"]
            if skipExtensions.contains(where: { fp.hasSuffix($0) })
                || skipDirectories.contains(where: { fp.contains($0) }) {
                return
            }
        }

        let taskID = state.threads[threadIndex].id
        let context = state.threads[threadIndex].context
        let command = ValidationEngine.suggestVerificationCommand(workspaceRoot: context.workspaceRoot)
        let callID = "call_verify_build_\(UUID().uuidString.prefix(8))"
        var params: [String: String] = [:]
        if let command { params["command"] = command }
        let callStep = TaskStep(
            kind: .toolCall,
            text: command.map { "正在自动验证：\($0)" } ?? "正在自动验证构建/测试",
            toolName: "verify.build",
            toolParams: params,
            toolCallId: callID,
            isCollapsible: true,
            isCollapsed: false
        )
        state.threads[threadIndex].steps.append(callStep)
        state.threads[threadIndex].updatedAt = .now
        persistThreads()

        Task { [weak self] in
            guard let self else { return }
            var jsonObject: [String: Any] = ["fix": true]
            if let command { jsonObject["command"] = command }
            let jsonData = (try? JSONSerialization.data(withJSONObject: jsonObject)) ?? Data("{}".utf8)
            let json = String(data: jsonData, encoding: .utf8) ?? "{}"
            let result: ToolResult
            do {
                result = try await VerifyBuildTool().execute(argumentsJSON: json, context: context)
            } catch {
                result = ToolResult(output: "自动验证失败：\(error.localizedDescription)", success: false, error: "verify_failed")
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendPostWriteVerificationResult(
                    taskID: taskID,
                    callID: callID,
                    params: params,
                    command: command,
                    result: result
                )
            }
        }
    }

    private func refreshSkillsIfNeeded(filePath: String) {
        let fp = filePath.lowercased()
        if fp.contains("/skills/") || fp.hasPrefix("skills/") || fp.contains(".laicai/skills") {
            SkillRegistry.shared.refresh(workspaceRoot: state.settings.workspacePath)
        }
    }

    private static let maxAutoRepairAttempts = 1

    private func appendPostWriteVerificationResult(
        taskID: UUID,
        callID: String,
        params: [String: String],
        command: String?,
        result: ToolResult
    ) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }

        // Count existing repair attempts
        let repairCount = state.threads[threadIndex].steps.filter {
            $0.toolName == "verify.build" && $0.kind == .toolResult && $0.isFailure
        }.count

        let canAutoRepair = !result.success && repairCount < Self.maxAutoRepairAttempts

        let resultStep = TaskStep(
            kind: .toolResult,
            text: result.output,
            toolName: "verify.build",
            toolParams: params,
            toolCallId: callID,
            isCollapsible: true,
            isCollapsed: false,
            isFailure: !result.success,
            recoverable: !result.success,
            retryAction: result.success ? nil : (canAutoRepair ? "正在自动修复…" : "已达最大重试次数，请手动修复")
        )
        state.threads[threadIndex].steps.append(resultStep)
        state.threads[threadIndex].updatedAt = Date()
        recordToolActivity(
            name: "verify.build",
            summary: result.success ? "自动验证通过" : "自动验证失败（\(repairCount + 1)/\(Self.maxAutoRepairAttempts)）",
            statusLine: result.data?["command"] ?? command ?? "自动检测",
            isFailure: !result.success
        )
        persistThreads()

        // Auto-repair loop: feed error back to agent for fix
        if canAutoRepair {
            scheduleAutoRepair(threadIndex: threadIndex, errorOutput: result.output, attempt: repairCount + 1)
        }
    }

    private func scheduleAutoRepair(threadIndex: Int, errorOutput: String, attempt: Int) {
        let taskID = state.threads[threadIndex].id
        let context = state.threads[threadIndex].context

        // Add a thinking step
        let thinkingStep = TaskStep(
            kind: .aiThinking,
            text: "自动修复循环（第 \(attempt)/\(Self.maxAutoRepairAttempts) 次）：分析构建错误并生成修复…"
        )
        state.threads[threadIndex].steps.append(thinkingStep)
        state.threads[threadIndex].updatedAt = .now
        persistThreads()

        // Truncate error to avoid context overflow
        let truncatedError = errorOutput.count > 2000 ? String(errorOutput.suffix(2000)) : errorOutput

        Task { [weak self] in
            guard let self else { return }
            // Compose a repair prompt and run agent loop
            let repairPrompt = """
            构建/测试验证失败（第 \(attempt) 次尝试），请分析以下错误并用 file.edit 工具修复：

            ```
            \(truncatedError)
            ```

            请：
            1. 分析错误原因
            2. 用 file.edit 提交精准修复
            3. 修复后自动触发 verify.build 重新验证
            """

            let connector = await MainActor.run { self.state.activeConnector }
            guard let connector else { return }
            var loopConfig = Self.agentLoopConfig(settings: self.state.settings, connector: connector)
            loopConfig.maxIterations = min(loopConfig.maxIterations, 6) // Repair is a sub-task, keep tight
            let repairLoop = AgentLoop(config: loopConfig, runtime: self.environment.runtimeClient)

            do {
                let repairTask = try await repairLoop.run(
                    message: repairPrompt,
                    intent: .task,
                    connector: connector,
                    context: context,
                    onStep: { @MainActor step in },
                    onStreamDelta: { _ in }
                )

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let ti = self.state.threads.firstIndex(where: { $0.id == taskID }) else { return }

                    // Merge repair steps into main thread
                    let repairSteps = repairTask.steps.map { step -> TaskStep in
                        var s = step
                        s.agentRole = .coder
                        return s
                    }
                    self.state.threads[ti].steps.append(contentsOf: repairSteps)

                    let hasNewReviews = repairSteps.contains { $0.kind == .reviewRequest && $0.approved == nil }
                    let summaryStep = TaskStep(
                        kind: .aiThinking,
                        text: hasNewReviews
                            ? "自动修复已生成变更，等待审查批准后将重新验证"
                            : "自动修复尝试完成（第 \(attempt) 次），未产生新的文件变更"
                    )
                    self.state.threads[ti].steps.append(summaryStep)
                    self.state.threads[ti].updatedAt = .now
                    self.persistThreadsNow()
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let ti = self.state.threads.firstIndex(where: { $0.id == taskID }) else { return }
                    self.state.threads[ti].steps.append(TaskStep(
                        kind: .error,
                        text: "自动修复失败：\(error.localizedDescription)",
                        isFailure: true
                    ))
                    self.state.threads[ti].updatedAt = .now
                    self.persistThreadsNow()
                }
            }
        }
    }

    public func rejectReview(taskID: UUID, stepID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        guard let stepIndex = state.threads[threadIndex].steps.firstIndex(where: { $0.id == stepID }) else { return }
        guard state.threads[threadIndex].steps[stepIndex].approved == nil else { return }
        let filePath = state.threads[threadIndex].steps[stepIndex].diffFilePath ?? "文件变更"
        state.threads[threadIndex].steps[stepIndex].approved = false
        appendReviewResult(to: threadIndex, approved: false, text: "已拒绝，未写入 \(filePath)。")
        let toolName = state.threads[threadIndex].steps[stepIndex].toolName ?? "file.write"
        AuditLog.shared.record(tool: toolName, input: filePath, output: "用户拒绝", success: false)
        recordToolActivity(name: toolName, summary: "已拒绝写入", statusLine: filePath, isFailure: true)
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
    }

    public func rollbackLastApprovedWrite(taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        guard let step = state.threads[threadIndex].steps.reversed().first(where: {
            $0.kind == .reviewRequest && $0.approved == true && $0.diffFilePath != nil && $0.diffOldContent != nil
        }) else {
            state.threads[threadIndex].steps.append(TaskStep(
                kind: .error,
                text: "没有可回滚的已批准文件变更。",
                isCollapsible: true,
                isCollapsed: true,
                isFailure: false,
                recoverable: false
            ))
            state.threads[threadIndex].updatedAt = .now
            persistThreads()
            return
        }
        performRollback(threadIndex: threadIndex, step: step)
    }

    public func approveAllPendingReviews(taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }

        let pendingIndices = state.threads[threadIndex].steps.enumerated().compactMap { index, step -> Int? in
            step.kind == .reviewRequest && step.approved == nil && step.diffFilePath != nil && step.diffNewContent != nil ? index : nil
        }
        guard !pendingIndices.isEmpty else {
            ToastCenter.shared.show("没有待审查的变更")
            return
        }

        // Phase 1: Pre-validate all writes
        var writeOps: [(stepIndex: Int, fullPath: String, newContent: String, oldContent: String?, createDirs: Bool)] = []
        for si in pendingIndices {
            let step = state.threads[threadIndex].steps[si]
            guard let filePath = step.diffFilePath, let newContent = step.diffNewContent else { continue }
            let fullPath = step.toolParams?["fullPath"]
                ?? absolutePath(for: filePath, workspaceRoot: state.threads[threadIndex].context.workspaceRoot)
            let createDirs = step.toolParams?["createDirectories"] != "false"
            if let securityError = SecurityManager.shared.checkWrite(path: fullPath) {
                state.threads[threadIndex].steps[si].approved = false
                appendReviewResult(to: threadIndex, approved: false, text: "批量写入被拦截（\(filePath)）：\(securityError)")
                state.threads[threadIndex].updatedAt = .now
                persistThreads()
                return
            }
            if let oldContent = step.diffOldContent, FileManager.default.fileExists(atPath: fullPath) {
                if let currentContent = try? String(contentsOfFile: fullPath, encoding: .utf8), currentContent != oldContent {
                    state.threads[threadIndex].steps[si].approved = false
                    appendReviewResult(to: threadIndex, approved: false, text: "批量写入取消：\(filePath) 在审查期间被外部修改")
                    state.threads[threadIndex].updatedAt = .now
                    persistThreads()
                    return
                }
            }
            writeOps.append((si, fullPath, newContent, step.diffOldContent, createDirs))
        }

        // Phase 2: Backup originals for rollback
        var backups: [(fullPath: String, content: String?)] = []
        for op in writeOps {
            let existing = try? String(contentsOfFile: op.fullPath, encoding: .utf8)
            backups.append((op.fullPath, existing))
        }

        // Phase 3: Atomic write - apply all or rollback
        var applied: [Int] = []
        var failed = false
        for op in writeOps {
            do {
                try WriteFileTool().performWrite(fullPath: op.fullPath, content: op.newContent, createDirectories: op.createDirs)
                state.threads[threadIndex].steps[op.stepIndex].approved = true
                applied.append(op.stepIndex)
            } catch {
                failed = true
                // Rollback everything we've applied so far
                for i in (0..<applied.count).reversed() {
                    let backup = backups[i]
                    if let originalContent = backup.content {
                        try? WriteFileTool().performWrite(fullPath: backup.fullPath, content: originalContent, createDirectories: false)
                    } else {
                        try? FileManager.default.removeItem(atPath: backup.fullPath)
                    }
                    state.threads[threadIndex].steps[applied[i]].approved = nil
                }
                for si in pendingIndices {
                    state.threads[threadIndex].steps[si].approved = false
                }
                let filePath = state.threads[threadIndex].steps[op.stepIndex].diffFilePath ?? "未知文件"
                appendReviewResult(to: threadIndex, approved: false, text: "批量写入失败并已回滚（\(applied.count) 个已恢复）：\(filePath) - \(error.localizedDescription)")
                AuditLog.shared.record(tool: "batch.apply", input: "\(writeOps.count) files", output: "事务回滚：\(error.localizedDescription)", success: false)
                recordToolActivity(name: "batch.apply", summary: "批量写入失败已回滚", statusLine: "\(applied.count) 个文件已恢复", isFailure: true)
                break
            }
        }

        if !failed {
            let paths = writeOps.compactMap { state.threads[threadIndex].steps[$0.stepIndex].diffFilePath }
            appendReviewResult(to: threadIndex, approved: true, text: "批量写入成功：\(paths.count) 个文件\n" + paths.joined(separator: "\n"))
            AuditLog.shared.record(tool: "batch.apply", input: "\(paths.count) files", output: "批量写入成功", success: true)
            recordToolActivity(name: "batch.apply", summary: "批量写入 \(paths.count) 个文件", statusLine: paths.first ?? "", isFailure: false)
            paths.forEach { refreshSkillsIfNeeded(filePath: $0) }
            // Pass first source-code file path for verification relevance check
            let sourceFilePath = paths.first(where: { p in
                let ext = (p as NSString).pathExtension.lowercased()
                return ["swift", "py", "js", "ts", "rs", "go", "java", "rb", "c", "cpp", "h", "m"].contains(ext)
            })
            schedulePostWriteVerification(threadIndex: threadIndex, filePath: sourceFilePath)
        }

        state.threads[threadIndex].updatedAt = .now
        persistThreads()
    }

    public func rollbackBatch(taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        let approvedSteps = state.threads[threadIndex].steps.enumerated().compactMap { index, step -> (Int, TaskStep)? in
            step.kind == .reviewRequest && step.approved == true && step.diffFilePath != nil && step.diffOldContent != nil ? (index, step) : nil
        }
        guard !approvedSteps.isEmpty else {
            ToastCenter.shared.show("没有可回滚的已批准变更")
            return
        }
        var rolledBack = 0
        for (_, step) in approvedSteps.reversed() {
            let filePath = step.diffFilePath ?? ""
            let fullPath = step.toolParams?["fullPath"]
                ?? absolutePath(for: filePath, workspaceRoot: state.threads[threadIndex].context.workspaceRoot)
            if SecurityManager.shared.checkWrite(path: fullPath) != nil { continue }
            do {
                try WriteFileTool().performWrite(fullPath: fullPath, content: step.diffOldContent ?? "", createDirectories: true)
                rolledBack += 1
            } catch {
                // continue best-effort
            }
        }
        for (si, _) in approvedSteps {
            state.threads[threadIndex].steps[si].approved = nil
        }
        appendReviewResult(to: threadIndex, approved: false, text: "批量回滚完成：\(rolledBack)/\(approvedSteps.count) 个文件已恢复")
        AuditLog.shared.record(tool: "batch.rollback", input: "\(approvedSteps.count) files", output: "回滚 \(rolledBack) 个文件", success: true)
        recordToolActivity(name: "batch.rollback", summary: "批量回滚 \(rolledBack) 个文件", statusLine: "", isFailure: false)
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
    }

    public func rollbackApprovedWrite(taskID: UUID, stepID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        guard let step = state.threads[threadIndex].steps.first(where: {
            $0.id == stepID && $0.kind == .reviewRequest && $0.approved == true && $0.diffFilePath != nil && $0.diffOldContent != nil
        }) else {
            ToastCenter.shared.warn("该步骤不可回滚")
            return
        }
        performRollback(threadIndex: threadIndex, step: step)
    }

    private func performRollback(threadIndex: Int, step: TaskStep) {
        let filePath = step.diffFilePath ?? "文件变更"
        let fullPath = step.toolParams?["fullPath"]
            ?? absolutePath(for: filePath, workspaceRoot: state.threads[threadIndex].context.workspaceRoot)
        if let securityError = SecurityManager.shared.checkWrite(path: fullPath) {
            appendReviewResult(to: threadIndex, approved: false, text: "回滚被安全策略拦截：\(securityError)")
            recordToolActivity(name: "file.rollback", summary: "回滚被拦截", statusLine: filePath, isFailure: true)
            state.threads[threadIndex].updatedAt = .now
            persistThreads()
            return
        }

        do {
            try WriteFileTool().performWrite(fullPath: fullPath, content: step.diffOldContent ?? "", createDirectories: true)
            appendReviewResult(to: threadIndex, approved: true, text: "已回滚 \(filePath)")
            AuditLog.shared.record(tool: "file.rollback", input: filePath, output: "已恢复旧内容", success: true)
            recordToolActivity(name: "file.rollback", summary: "已回滚文件", statusLine: filePath, isFailure: false)
        } catch {
            appendReviewResult(to: threadIndex, approved: false, text: "回滚失败：\(error.localizedDescription)")
            AuditLog.shared.record(tool: "file.rollback", input: filePath, output: error.localizedDescription, success: false)
            recordToolActivity(name: "file.rollback", summary: "回滚失败", statusLine: error.localizedDescription, isFailure: true)
        }
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
    }

    /// Undo the last auto-checkpoint by running `git reset HEAD~1`.
    /// This reverts all file changes made since the last checkpoint while keeping them staged.
    public func undoLastCheckpoint() {
        let root = state.settings.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            ToastCenter.shared.warn("未设置工作区，无法回滚")
            return
        }
        guard FileManager.default.fileExists(atPath: root + "/.git") else {
            ToastCenter.shared.warn("工作区不是 Git 仓库，无法回滚")
            return
        }
        // Check if last commit is a checkpoint
        let logProcess = Process()
        logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        logProcess.currentDirectoryURL = URL(fileURLWithPath: root)
        logProcess.arguments = ["git", "log", "-1", "--format=%s"]
        let logPipe = Pipe()
        logProcess.standardOutput = logPipe
        logProcess.standardError = Pipe()
        try? logProcess.run()
        logProcess.waitUntilExit()
        let logData = logPipe.fileHandleForReading.readDataToEndOfFile()
        let lastMessage = String(data: logData, encoding: .utf8) ?? ""

        guard lastMessage.contains("来财自动检查点") else {
            ToastCenter.shared.warn("最近一次提交不是来财检查点")
            return
        }

        let resetProcess = Process()
        resetProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        resetProcess.currentDirectoryURL = URL(fileURLWithPath: root)
        resetProcess.arguments = ["git", "reset", "HEAD~1"]
        let resetPipe = Pipe()
        resetProcess.standardOutput = resetPipe
        resetProcess.standardError = resetPipe
        try? resetProcess.run()
        resetProcess.waitUntilExit()
        let resetData = resetPipe.fileHandleForReading.readDataToEndOfFile()
        let resetOutput = String(data: resetData, encoding: .utf8) ?? ""

        if resetProcess.terminationStatus == 0 {
            ToastCenter.shared.success("已回滚到最近检查点（变更保留在工作区）")
            AuditLog.shared.record(tool: "git.reset", input: "undo checkpoint", output: resetOutput.prefix(200).description, success: true)
        } else {
            ToastCenter.shared.warn("回滚失败：\(resetOutput.prefix(100))")
            AuditLog.shared.record(tool: "git.reset", input: "undo checkpoint", output: resetOutput.prefix(200).description, success: false)
        }
    }

    public func deleteTask(id: UUID) {
        state.threads.removeAll(where: { $0.id == id })
        if state.selectedTaskID == id {
            state.selectThread(id: nil)
            selectThread(state.threads.first.map { ThreadRecord(thread: $0, includeEvents: false) })
        }
        do { try environment.taskRepository.deleteTask(id: id) }
        catch { recordToolActivity(name: "tasks.delete", summary: "任务删除失败", statusLine: error.localizedDescription, isFailure: true) }
    }

    public func selectTask(id: UUID?) {
        state.selectThread(id: id)
        if let id, let thread = state.threads.first(where: { $0.id == id }) {
            state.modeLabel = thread.workflowName == nil ? "任务" : "工作流"
        }
    }

    public func prepareTaskContinuation(id: UUID) {
        guard state.threads.contains(where: { $0.id == id }) else { return }
        state.selectThread(id: id)
        state.modeLabel = "任务"
        if state.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.draftMessage = "继续这个任务"
        }
    }

    public func selectThread(_ record: ThreadRecord?) {
        state.selectThread(id: record?.id)
        if let record {
            switch record.source {
            case .session:
                state.modeLabel = "聊天"
            case .task:
                state.modeLabel = record.task?.workflowName == nil ? "任务" : "工作流"
            }
        } else {
            state.modeLabel = "聊天"
        }
    }

    public func startWorkflow(named name: String, goal: String? = nil, userParams: [String: String] = [:]) {
        guard let workflow = WorkflowLibrary.find(named: name, workspaceRoot: state.settings.workspacePath) else {
            notify("未找到工作流：\(name)", style: .error)
            return
        }
        let trimmedGoal = goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = trimmedGoal.isEmpty ? "运行工作流：\(workflow.name)" : trimmedGoal
        let context = AutoContextEngine.buildContext(
            workspaceRoot: state.settings.workspacePath,
            vaultRoot: state.settings.vaultPath,
            userInput: message,
            fileLimit: state.settings.contextMode.relevantFileLimit,
            comfyUIServerURL: state.settings.comfyUIServerURL,
            comfyUIModelName: state.settings.comfyUIModelName
        )
        executeWorkflow(taskTitle: message, workflow: workflow, context: context, message: message, userParams: userParams)
    }

    public func useSkill(_ skill: SkillDefinition) {
        if let connector = ModelRouter.selectModel(for: skill, connectors: state.connectors, activeConnectorID: state.activeConnectorID),
           connector.id != state.activeConnectorID {
            selectConnector(id: connector.id)
        }

        if let workflowName = skill.workflowName {
            startWorkflow(named: workflowName, goal: "使用「\(skill.name)」")
            return
        }

        let tools = skill.tools.isEmpty ? "" : "，可用工具：\(skill.tools.joined(separator: "、"))"
        let hint = skill.systemHint.map { "\n\n执行指南：\($0)" } ?? ""
        state.draftMessage = "使用「\(skill.name)」：\(skill.description)\(tools)。\(hint)\n\n"
        notify("已套用技能：\(skill.name)", style: .success)
    }

    public func toggleStepCollapsed(taskID: UUID, stepID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        guard let stepIndex = state.threads[threadIndex].steps.firstIndex(where: { $0.id == stepID }) else { return }
        state.threads[threadIndex].steps[stepIndex].isCollapsed.toggle()
        persistThreads()
    }

    // MARK: - Settings

    public func updateDraft(_ value: String) { state.draftMessage = value }

    public func queueFollowUp(_ message: String) {
        state.pendingFollowUp = message
    }

    public func submitFollowUp() {
        guard let followUp = state.pendingFollowUp, !followUp.isEmpty else { return }
        state.pendingFollowUp = nil
        // Append follow-up as user input to current task
        if let taskID = state.selectedTaskID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) {
            let step = TaskStep(kind: .userInput, text: followUp, isCollapsible: false, isCollapsed: false)
            state.threads[threadIndex].steps.append(step)
            persistThreads()
        }
    }

    public func clearPendingFollowUp() {
        state.pendingFollowUp = nil
    }
    public func addDraftAttachments(_ paths: [String]) {
        let cleaned = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        var existing = state.draftAttachments
        for path in cleaned where !existing.contains(path) {
            existing.append(path)
        }
        state.draftAttachments = existing
    }

    public func removeDraftAttachment(_ path: String) {
        state.draftAttachments.removeAll { $0 == path }
    }

    // MARK: - Draft Images (multimodal vision)

    public func addDraftImage(_ attachment: ImageAttachment) {
        state.draftImages.append(attachment)
    }

    public func removeDraftImage(id: UUID) {
        state.draftImages.removeAll { $0.id == id }
    }

    public func clearDraftImages() {
        state.draftImages.removeAll()
    }

    public func updateWorkspacePath(_ value: String) {
        if WorkspaceSandbox.isOverlyBroadWorkspace(value) {
            notify("工作区不能设为 home 目录或根目录，请选择一个具体的项目文件夹。", style: .error)
            return
        }
        state.settings.workspacePath = value
        state.workspaceName = URL(fileURLWithPath: value).lastPathComponent
        WorkspaceSandbox.shared.workspaceRoot = value
        initializeEngines(workspaceRoot: value)
        persistSettings()
    }

    // G16: Switch workspace and track in recents
    public func switchWorkspace(to path: String) {
        state.settings.switchWorkspace(to: path)
        state.workspaceName = URL(fileURLWithPath: path).lastPathComponent
        WorkspaceSandbox.shared.workspaceRoot = path
        initializeEngines(workspaceRoot: path)
        persistSettings()
    }
    public func updateVaultPath(_ value: String) {
        state.settings.vaultPath = value
        persistSettings()
    }
    public func toggleCompactComposer(_ enabled: Bool) {
        state.settings.compactComposer = enabled
        persistSettings()
    }
    public func updateComfyUIServerURL(_ value: String) {
        state.settings.comfyUIServerURL = value
        persistSettings()
    }
    public func updateComfyUIModelName(_ value: String) {
        state.settings.comfyUIModelName = value
        persistSettings()
    }
    public func toggleDebugPanels(_ enabled: Bool) {
        state.settings.showDebugPanels = enabled
        persistSettings()
    }
    public func updateContextMode(_ mode: ContextMode) {
        state.settings.contextMode = mode
        persistSettings()
    }

    public func retryLastMessage() {
        guard !state.isGenerating else { return }

        if let thread = state.selectedThread, thread.source == .task {
            guard thread.status != .running else { return }
            guard let lastUserStep = thread.steps.last(where: { $0.kind == .userInput }) else { return }
            BehaviorSignalTracker.record(signal: .retry, thread: thread)
            state.draftMessage = Self.retryMessage(for: thread, lastUserMessage: lastUserStep.text)
            sendDraft()
            return
        }

        guard let thread = state.selectedThread, thread.source == .session else { return }
        guard let lastUserIndex = thread.steps.lastIndex(where: { $0.kind == .userInput }) else { return }
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == thread.id }) else { return }
        let lastUserStep = thread.steps[lastUserIndex]
        state.threads[threadIndex].steps = Array(thread.steps.prefix(lastUserIndex))
        state.threads[threadIndex].preview = thread.steps.prefix(lastUserIndex).last?.text ?? ""
        state.draftMessage = lastUserStep.text
        persistThreads()
        sendDraft()
    }

    /// Continue an incomplete task with the existing task context.
    /// This is triggered when the user clicks the continuation step after max iterations.
    public func continueTask() {
        guard !state.isGenerating else { return }
        guard let thread = state.selectedThread, thread.source == .task else { return }
        guard thread.status == .failed || thread.status == .completed else { return }

        // Mark the task as ready to continue
        if let threadIndex = state.threads.firstIndex(where: { $0.id == thread.id }) {
            state.threads[threadIndex].status = .queued
            state.threads[threadIndex].updatedAt = .now
            persistThreads()
        }

        state.draftMessage = "继续处理，并优先基于当前证据形成结论；不要重复已经完成的读取、搜索或执行步骤。"
        sendDraft()
    }

    public func clearSelectedThread() {
        guard let threadID = state.selectedThreadID,
              let threadIndex = state.threads.firstIndex(where: { $0.id == threadID }) else { return }
        state.threads[threadIndex].steps = []
        state.threads[threadIndex].status = .queued
        state.threads[threadIndex].preview = ""
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
    }
}
