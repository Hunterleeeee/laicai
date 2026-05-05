import AppKit
import Combine
import Foundation
import LaicaiNativeDomain

// MARK: - Product Notices

public enum AppNoticeStyle: String, Equatable, Sendable {
    case info
    case success
    case warning
    case error
}

public struct AppNotice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var message: String
    public var style: AppNoticeStyle

    public init(id: UUID = UUID(), message: String, style: AppNoticeStyle = .info) {
        self.id = id
        self.message = message
        self.style = style
    }
}

func normalizedSessionPreview(_ text: String, limit: Int = 80) -> String {
    let preview = text
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !preview.isEmpty else { return "" }

    if preview.hasPrefix("Request failed (404)") || preview.hasPrefix("未找到") || preview.contains("HTTP 404") {
        return "未找到接口，请检查端点地址是否正确。"
    }
    if preview.hasPrefix("Request failed (401)") || preview.hasPrefix("鉴权") || preview.contains("HTTP 401") {
        return "鉴权失败，请检查 API 密钥是否正确。"
    }
    if preview.hasPrefix("请求失败")
        || preview.hasPrefix("请求格式不被")
        || preview.hasPrefix("任务执行失败")
        || preview.contains("Request failed")
        || preview.contains("provider returned")
        || preview.contains("{\"error\"")
        || preview.localizedCaseInsensitiveContains("\"error\"")
        || preview.localizedCaseInsensitiveContains("invalid_request_error") {
        return "请求失败，请检查连接器配置。"
    }
    if preview.count > limit {
        return String(preview.prefix(max(0, limit - 1))) + "…"
    }
    return preview
}

// MARK: - App State

public enum ExecutionMode: String, CaseIterable, Codable, Equatable, Sendable {
    case auto
    case ask
    case inspect
    case act

    public var title: String {
        switch self {
        case .auto: return "自动"
        case .ask: return "问一问"
        case .inspect: return "看项目"
        case .act: return "执行"
        }
    }

    public var subtitle: String {
        switch self {
        case .auto: return "自动判断是否需要工具"
        case .ask: return "只回答，不读取项目"
        case .inspect: return "可读文件和搜索，不写入"
        case .act: return "可执行任务，高风险需确认"
        }
    }

    public var icon: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .ask: return "bubble.left.and.bubble.right"
        case .inspect: return "folder.badge.questionmark"
        case .act: return "hammer"
        }
    }
}

// MARK: - Image Attachment (multimodal vision)

public struct ImageAttachment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let data: Data           // PNG or JPEG bytes
    public let mediaType: String    // "image/png" or "image/jpeg"
    public let thumbnailName: String // display name e.g. "截图 1"
    public let width: Int
    public let height: Int

    public init(id: UUID = UUID(), data: Data, mediaType: String = "image/png", thumbnailName: String = "图片", width: Int = 0, height: Int = 0) {
        self.id = id
        self.data = data
        self.mediaType = mediaType
        self.thumbnailName = thumbnailName
        self.width = width
        self.height = height
    }

    public static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool {
        lhs.id == rhs.id
    }

    /// Convert to OpenAI vision ContentPart
    public func toContentPart() -> ContentPart {
        .imageBase64(data: data, mediaType: mediaType, detail: "auto")
    }
}

public struct AppState: Equatable {
    public var workspaceName: String
    public var modeLabel: String
    public var executionMode: ExecutionMode
    public var searchText: String
    public var threads: [Thread]
    public var selectedThreadID: UUID?
    public var workbenchTab: WorkbenchTab
    public var connectors: [ConnectorProfile]
    public var activeConnectorID: UUID?
    public var toolActivities: [ToolActivity]
    public var workflowRuns: [WorkflowRun]
    public var draftMessage: String
    public var draftAttachments: [String]
    public var draftImages: [ImageAttachment]
    public var isGenerating: Bool
    public var liveActivity: String  // Human-readable description of current AI activity
    public var pendingFollowUp: String?  // Queued follow-up instruction when task is running
    public var userCreatedNewThread: Bool = false  // Set when user explicitly creates new thread; prevents auto-merge
    public var settings: AppSettings
    public var notice: AppNotice?

    // MARK: - Computed compatibility (legacy consumers)

    public var selectedThreadSource: ThreadSource? {
        threads.first(where: { $0.id == selectedThreadID })?.source
    }

    public var sessions: [ChatSession] {
        threads.filter { $0.source == .session }.map { ChatSession(thread: $0) }
    }

    public var selectedSessionID: UUID? {
        threads.first(where: { $0.id == selectedThreadID })?.source == .session ? selectedThreadID : nil
    }

    public var tasks: [AgentTask] {
        threads.filter { $0.source == .task }.map { AgentTask(thread: $0) }
    }

    public var selectedTaskID: UUID? {
        threads.first(where: { $0.id == selectedThreadID })?.source == .task ? selectedThreadID : nil
    }

    public var selectedSession: ChatSession? {
        guard let id = selectedThreadID, let thread = threads.first(where: { $0.id == id }), thread.source == .session else { return nil }
        return ChatSession(thread: thread)
    }

    public var activeConnector: ConnectorProfile? {
        connectors.first(where: { $0.id == activeConnectorID })
    }

    public var selectedTask: AgentTask? {
        guard let id = selectedThreadID, let thread = threads.first(where: { $0.id == id }), thread.source == .task else { return nil }
        return AgentTask(thread: thread)
    }

    public var selectedThread: Thread? {
        guard let id = selectedThreadID else { return nil }
        return threads.first(where: { $0.id == id })
    }

    // MARK: - ThreadRecord-based views (sidebar)

    public var threadRecords: [ThreadRecord] {
        threads.map { ThreadRecord(thread: $0, includeEvents: true) }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public var threadRecordSummaries: [ThreadRecord] {
        threads.map { ThreadRecord(thread: $0, includeEvents: false) }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public var filteredThreadRecords: [ThreadRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return threadRecords }
        return threadRecords.filter { record in
            record.title.localizedCaseInsensitiveContains(query)
                || record.preview.localizedCaseInsensitiveContains(query)
                || record.events.contains { event in
                    event.text.localizedCaseInsensitiveContains(query)
                }
        }
    }

    public var filteredThreadRecordSummaries: [ThreadRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return threadRecordSummaries }
        return filteredThreadRecords
    }

    // MARK: - Legacy compatibility aliases

    /// Alias for `threadRecords` to ease migration of existing UI consumers.
    public var threads_legacy: [ThreadRecord] { threadRecords }

    /// Alias for `threadRecordSummaries`.
    public var threadSummaries: [ThreadRecord] { threadRecordSummaries }

    /// Alias for `filteredThreadRecords`.
    public var filteredThreads: [ThreadRecord] { filteredThreadRecords }

    /// Alias for `filteredThreadRecordSummaries`.
    public var filteredThreadSummaries: [ThreadRecord] { filteredThreadRecordSummaries }

    // MARK: - Init

    public init(
        workspaceName: String,
        modeLabel: String,
        executionMode: ExecutionMode = .auto,
        searchText: String = "",
        threads: [Thread] = [],
        selectedThreadID: UUID? = nil,
        workbenchTab: WorkbenchTab,
        connectors: [ConnectorProfile],
        activeConnectorID: UUID?,
        toolActivities: [ToolActivity],
        workflowRuns: [WorkflowRun],
        draftMessage: String,
        draftAttachments: [String] = [],
        isGenerating: Bool,
        liveActivity: String = "",
        pendingFollowUp: String? = nil,
        settings: AppSettings,
        notice: AppNotice? = nil
    ) {
        self.workspaceName = workspaceName
        self.modeLabel = modeLabel
        self.executionMode = executionMode
        self.searchText = searchText
        self.threads = threads
        self.selectedThreadID = selectedThreadID
        self.workbenchTab = workbenchTab
        self.connectors = connectors
        self.activeConnectorID = activeConnectorID
        self.toolActivities = toolActivities
        self.workflowRuns = workflowRuns
        self.draftMessage = draftMessage
        self.draftAttachments = draftAttachments
        self.draftImages = []
        self.isGenerating = isGenerating
        self.liveActivity = liveActivity
        self.pendingFollowUp = pendingFollowUp
        self.settings = settings
        self.notice = notice
    }

    /// Legacy init from sessions + tasks (for migration paths).
    public init(
        workspaceName: String,
        modeLabel: String,
        executionMode: ExecutionMode = .auto,
        searchText: String = "",
        sessions: [ChatSession],
        selectedSessionID: UUID?,
        workbenchTab: WorkbenchTab,
        connectors: [ConnectorProfile],
        activeConnectorID: UUID?,
        toolActivities: [ToolActivity],
        workflowRuns: [WorkflowRun],
        draftMessage: String,
        draftAttachments: [String] = [],
        isGenerating: Bool,
        settings: AppSettings,
        tasks: [AgentTask] = [],
        selectedTaskID: UUID? = nil,
        selectedThreadID: UUID? = nil,
        selectedThreadSource: ThreadSource? = nil,
        notice: AppNotice? = nil
    ) {
        self.workspaceName = workspaceName
        self.modeLabel = modeLabel
        self.executionMode = executionMode
        self.searchText = searchText
        self.threads = sessions.map(Thread.init(session:)) + tasks.map(Thread.init(task:))
        if let selectedThreadID, let _ = selectedThreadSource {
            self.selectedThreadID = selectedThreadID
        } else if let selectedTaskID {
            self.selectedThreadID = selectedTaskID
        } else if let selectedSessionID {
            self.selectedThreadID = selectedSessionID
        } else {
            self.selectedThreadID = nil
        }
        self.workbenchTab = workbenchTab
        self.connectors = connectors
        self.activeConnectorID = activeConnectorID
        self.toolActivities = toolActivities
        self.workflowRuns = workflowRuns
        self.draftMessage = draftMessage
        self.draftAttachments = draftAttachments
        self.draftImages = []
        self.isGenerating = isGenerating
        self.liveActivity = ""
        self.settings = settings
        self.notice = notice
    }

    public mutating func selectThread(id: UUID?) {
        selectedThreadID = id
    }
}

@MainActor
public final class AppStore: ObservableObject {
    @Published public private(set) var state: AppState
    @Published public var isShowingTaskModeInfo = false
    private let environment: AppEnvironment
    private var agentLoop: AgentLoop?
    private static let streamingOutputID = "__streaming_output__"
    private static let readOnlyToolNames: Set<String> = ["file.read", "code.search", "workspace.index", "web.search", "web.fetch"]
    private var streamBuffers: [UUID: String] = [:]
    private var streamLastFlushAt: [UUID: Date] = [:]
    private var chatStreamBuffers: [UUID: String] = [:]
    private var chatStreamLastFlushAt: [UUID: Date] = [:]
    private var healthChecksInFlight: Set<UUID> = []
    private let streamFlushCharacterThreshold = 96
    private let streamFlushInterval: TimeInterval = 0.14
    private let chatStreamFlushCharacterThreshold = 160
    private let chatStreamFlushInterval: TimeInterval = 0.22
    private var shellStreamObserver: NSObjectProtocol?

    public init(state: AppState, environment: AppEnvironment = .preview) {
        var initialState = state
        Self.markStaleRunningTasks(in: &initialState)
        self.state = initialState
        self.environment = environment
        self.agentLoop = AgentLoop(
            config: Self.agentLoopConfig(settings: initialState.settings, connector: initialState.activeConnector),
            runtime: environment.runtimeClient
        )
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

    private func handleShellStreamNotification(_ info: [AnyHashable: Any]) {
        guard let stepID = info["stepID"] as? UUID,
              let callID = info["callID"] as? String,
              let command = info["command"] as? String,
              let text = info["text"] as? String,
              let isFailure = info["isFailure"] as? Bool else { return }
        let isFinal = info["isFinal"] as? Bool ?? false

        let step = TaskStep(
            id: stepID,
            kind: .toolResult,
            text: text,
            toolName: "shell.exec",
            toolParams: ["command": command],
            toolCallId: callID,
            isCollapsible: true,
            isCollapsed: false,
            isFailure: isFailure,
            recoverable: isFinal && isFailure,
            retryAction: isFinal && isFailure ? "根据终端输出修复后重试" : nil
        )

        // Find current running thread and update/insert the step
        if let threadIndex = state.threads.firstIndex(where: { $0.status == .running }) {
            if let existingIndex = state.threads[threadIndex].steps.firstIndex(where: { $0.id == stepID }) {
                state.threads[threadIndex].steps[existingIndex] = step
            } else {
                state.threads[threadIndex].steps.append(step)
            }
            updateLiveActivity(from: step)
            state.threads[threadIndex].updatedAt = Date()
            if isFinal {
                persistThreads()
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

    // MARK: - Session Management

    public var filteredSessions: [ChatSession] {
        state.sessions
    }

    public func updateSearchText(_ value: String) { state.searchText = value }

    public func newSession() {
        let connectorName = state.activeConnector?.name ?? state.settings.defaultConnectorName
        let thread = Thread(
            title: "新线程",
            preview: "从一个具体任务开始，而不是空白页。",
            modelName: connectorName,
            category: .engineering
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
        state.userCreatedNewThread = true  // Prevent auto-merge into old threads
        persistThreads()
    }

    public func selectSession(id: UUID?) {
        state.selectThread(id: id)
        state.modeLabel = "问一问"
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
        notify("已克隆线程", style: .success)
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
        lines.append("- 类型：\(thread.source == .task ? "任务" : "聊天")")
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
        notify("已导入线程", style: .success)
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
        agentLoop = AgentLoop(
            config: Self.agentLoopConfig(settings: state.settings, connector: connector),
            runtime: environment.runtimeClient
        )
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
            agentLoop = AgentLoop(
                config: Self.agentLoopConfig(settings: state.settings, connector: normalized),
                runtime: environment.runtimeClient
            )
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
            agentLoop = AgentLoop(
                config: Self.agentLoopConfig(settings: state.settings, connector: normalized),
                runtime: environment.runtimeClient
            )
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
        guard let index = state.connectors.firstIndex(where: { $0.id == id }) else { return }
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
    private func updateLiveActivity(from step: TaskStep) {
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

    private static func friendlyActivityName(_ toolName: String, params: [String: String]?) -> String {
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

    private var generationTask: Task<Void, Never>?

    public func stopGenerating() {
        generationTask?.cancel()
        generationTask = nil
        state.isGenerating = false
        state.liveActivity = ""
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
            }
        }
        chatStreamBuffers.removeAll()
        chatStreamLastFlushAt.removeAll()
        persistThreads()
    }

    public func sendDraft() {
        let message = composedDraftMessage()
        guard !message.isEmpty, !state.isGenerating else { return }

        // Slash commands: /goal, /background, /schedule, /gateway
        if handleSlashCommand(message) { return }

        let agentInvocation = customAgentInvocation(from: message)
        let effectiveMessage = agentInvocation?.message ?? message

        restoreRecentTaskSelectionForTinyFollowUp(effectiveMessage)
        reconcileSelectedRunningTaskIfIdle()
        if answerSelectedTaskStatusQuestion(effectiveMessage) {
            state.userCreatedNewThread = false
            return
        }
        var decision = IntentRouter.plan(effectiveMessage)
        if let agent = agentInvocation?.agent {
            decision = PlannerDecision(
                intent: .task,
                confidence: 0.95,
                reason: "用户选择了自定义 Agent「\(agent.name)」。",
                routeLabel: "Agent",
                expectedCapabilities: agent.tools.isEmpty ? ["按 Agent 提示词执行"] : agent.tools
            )
        } else if decision.intent == .chat, shouldContinueSelectedTask(with: effectiveMessage) {
            decision = PlannerDecision(
                intent: .task,
                confidence: 0.76,
                reason: "当前选中的是可继续任务，用户输入像是在追问或推进同一任务。",
                routeLabel: "任务",
                expectedCapabilities: ["延续上下文", "必要时调用工具", "总结结果"]
            )
        }

        // Self-evolution: check routing drift from historical outcomes
        let outcomeStats = TaskOutcomeRecorder.shared.stats(days: 7)
        if let suggestion = ResultEvaluator.suggestRoutingAdjustment(
            outcomes: outcomeStats,
            intent: decision.intent,
            currentRouteLabel: decision.routeLabel
        ), suggestion.confidence > 0.85 {
            // Inject routing drift hint into thinking step when sending task
            // but do not override explicit user mode selection
            if state.executionMode == .auto, suggestion.direction == .relax,
               (decision.intent == .task && Self.shouldUseReadOnlyTools(for: decision)) {
                decision.confidence = max(0.5, decision.confidence - 0.1)
                decision.reason = "历史数据显示当前路由取消率偏高，本次降低置信度、优先只读分析。"
            }
        }

        switch state.executionMode {
        case .ask:
            // Detect explicit upgrade request: user in chat mode asking to switch to task
            if Self.isExplicitModeUpgradeRequest(effectiveMessage) || (decision.intent == .task && decision.confidence >= 0.80) {
                state.executionMode = .auto
                ToastCenter.shared.show("已自动切换到自动模式")
                // Re-route through auto logic
                if Self.shouldUseReadOnlyTools(for: decision) && !Self.containsMutationIntent(effectiveMessage) {
                    sendTaskDraft(
                        message: effectiveMessage,
                        decision: decision,
                        customAgent: agentInvocation?.agent,
                        allowedToolsOverride: Self.readOnlyToolNames
                    )
                } else {
                    sendTaskDraft(message: effectiveMessage, decision: decision, customAgent: agentInvocation?.agent)
                }
                return
            }
            sendDirectDraft(message: effectiveMessage)
        case .inspect:
            let inspectDecision = PlannerDecision(
                intent: .task,
                confidence: 0.95,
                reason: "用户选择了“看项目”：允许读取文件和搜索代码，但不写入、不执行命令。",
                routeLabel: "看项目",
                expectedCapabilities: ["读取文件", "搜索代码", "分析项目"]
            )
            sendTaskDraft(
                message: effectiveMessage,
                decision: inspectDecision,
                customAgent: agentInvocation?.agent,
                allowedToolsOverride: Self.readOnlyToolNames
            )
        case .act:
            let actDecision = PlannerDecision(
                intent: .task,
                confidence: max(decision.confidence, 0.95),
                reason: "用户选择了“执行”：允许完成任务，高风险操作仍需确认。",
                routeLabel: agentInvocation == nil ? "执行" : "Agent",
                expectedCapabilities: decision.expectedCapabilities.isEmpty ? ["读取文件", "搜索代码", "提出文件修改", "执行命令"] : decision.expectedCapabilities
            )
            sendTaskDraft(message: effectiveMessage, decision: actDecision, customAgent: agentInvocation?.agent)
        case .auto:
            // Claude Code insight: don't override the planner's intent.
            // Chat = direct response (no tools, fast). Task/research/workflow = agent loop.
            if decision.intent == .chat {
                sendDirectDraft(message: effectiveMessage)
            } else {
                sendTaskDraft(message: effectiveMessage, decision: decision, customAgent: agentInvocation?.agent)
            }
        }
        // Clear after all routing is done — sendTaskDraft/sendDirectDraft need to see it
        state.userCreatedNewThread = false
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

    /// Send a plain chat draft directly to the model, without Agent orchestration or tools.
    private func sendDirectDraft(message: String) {
        guard let connector = state.activeConnector else {
            notify("请先选择一个连接器", style: .error)
            return
        }

        let context = AutoContextEngine.buildContext(
            workspaceRoot: state.settings.workspacePath,
            vaultRoot: state.settings.vaultPath,
            userInput: message,
            fileLimit: 0,
            comfyUIServerURL: state.settings.comfyUIServerURL,
            comfyUIModelName: state.settings.comfyUIModelName
        )

        let sessionID: UUID
        let priorSteps: [TaskStep]
        let assistantStepID = UUID()
        // If user explicitly created a new thread but stale selection points to non-empty thread, force new
        let forceNewThread = state.userCreatedNewThread
            && state.selectedThreadID != nil
            && state.threads.first(where: { $0.id == state.selectedThreadID })?.steps.isEmpty == false
        if !forceNewThread,
           let selectedID = state.selectedThreadID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == selectedID }) {
            sessionID = selectedID
            priorSteps = Self.directHistory(for: state.threads[threadIndex].steps, message: message)
            state.threads[threadIndex].steps.append(TaskStep(id: UUID(), kind: .userInput, text: message, isCollapsible: false, isCollapsed: false))
            state.threads[threadIndex].steps.append(TaskStep(id: assistantStepID, kind: .textOutput, text: "", isCollapsible: false, isCollapsed: false))
            if state.threads[threadIndex].title.isEmpty
                || state.threads[threadIndex].title == "新线程"
                || state.threads[threadIndex].title == "新对话" {
                state.threads[threadIndex].title = directSessionTitle(for: message)
            }
            state.threads[threadIndex].preview = normalizedSessionPreview(message)
            state.threads[threadIndex].modelName = connector.name
            state.threads[threadIndex].updatedAt = .now
        } else {
            let thread = Thread(
                title: directSessionTitle(for: message),
                preview: normalizedSessionPreview(message),
                steps: [
                    TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false),
                    TaskStep(id: assistantStepID, kind: .textOutput, text: "", isCollapsible: false, isCollapsed: false)
                ],
                modelName: connector.name,
                category: .engineering
            )
            sessionID = thread.id
            priorSteps = []
            state.threads.insert(thread, at: 0)
        }

        state.selectThread(id: sessionID)
        state.modeLabel = "聊天"
        let capturedImages = state.draftImages
        state.isGenerating = true
        state.liveActivity = "正在生成回复…"
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        persistThreads()

        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = SendMessageRequest(
                    sessionID: sessionID,
                    message: message,
                    connector: connector,
                    modeLabel: "聊天",
                    history: priorSteps,
                    systemPrompt: Self.chatPrompt(context: context, message: message),
                    tools: nil,
                    messages: nil,
                    maxOutputTokens: Self.directOutputLimit(for: connector),
                    imageAttachments: capturedImages
                )
                let response = try await self.environment.runtimeClient.sendMessageStream(
                    request,
                    onChunk: { [weak self] delta in
                        guard let self else { return }
                        self.appendAssistantDelta(delta, stepID: assistantStepID, in: sessionID, connectorName: connector.name)
                    }
                )
                guard !Task.isCancelled else { return }
                self.flushAssistantBuffer(stepID: assistantStepID, in: sessionID, connectorName: connector.name)
                self.updateAssistantStep(
                    assistantStepID,
                    in: sessionID,
                    finalText: response.assistantText,
                    metrics: response.metrics,
                    connectorName: connector.name
                )
                self.recordConnectorOutcome(response, connectorID: connector.id)
                for activity in response.toolActivities {
                    self.recordToolActivity(activity)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.flushAssistantBuffer(stepID: assistantStepID, in: sessionID, connectorName: connector.name)
                self.updateAssistantStep(
                    assistantStepID,
                    in: sessionID,
                    finalText: "请求失败：\(error.localizedDescription)",
                    connectorName: connector.name
                )
                self.updateConnectorHealth(connector.id, to: .offline)
                self.recordToolActivity(name: "chat.error", summary: "直接回复失败", statusLine: error.localizedDescription, isFailure: true)
            }

            self.state.isGenerating = false
            self.state.liveActivity = ""
            self.generationTask = nil
        }
    }

    /// Send a task draft through the local task engine.
    private func sendTaskDraft(
        message: String,
        decision: PlannerDecision,
        customAgent: CustomAgentDefinition? = nil,
        allowedToolsOverride: Set<String>? = nil
    ) {
        // Fallback: if nothing is selected but a recent completed thread exists,
        // and the message looks like a follow-up, restore it so context is preserved.
        // NEVER do this when user explicitly created a new thread.
        if state.selectedThreadID == nil,
           !state.userCreatedNewThread,
           let recentThread = state.threads
               .filter({ $0.status == .completed || $0.status == .failed || $0.status == .cancelled })
               .sorted(by: { $0.updatedAt > $1.updatedAt })
               .first,
           Date().timeIntervalSince(recentThread.updatedAt) < 10 * 60,
           Self.isLikelyTaskFollowUp(message) {
            state.selectThread(id: recentThread.id)
        }

        let selectedConnector = customAgent?.preferredConnectorID.flatMap { id in
            state.connectors.first(where: { $0.id == id })
        } ?? state.activeConnector
        guard let connector = selectedConnector else {
            notify("请先选择一个连接器", style: .error)
            return
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
           !Self.shouldUseReadOnlyTools(for: decision),
           MultiAgentOrchestrator.shouldUseMultiAgent(message: message, intent: intent),
           let plan = MultiAgentOrchestrator.createPlan(for: message, intent: intent, connectors: state.connectors, activeConnectorID: state.activeConnectorID) {
            executeMultiAgent(message: message, context: context, connector: connector, plan: plan, intent: intent, decision: decision)
            return
        }

        let userStep = TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false)
        let planStep = TaskStep(
            kind: .aiThinking,
            text: Self.plannerStepText(for: decision),
            isCollapsible: true,
            isCollapsed: true
        )
        let targetTaskID: UUID
        let loopPriorSteps: [TaskStep]
        // Defense: if user created a new thread, never append to a non-empty existing thread
        let taskForceNew = state.userCreatedNewThread
            && state.selectedThreadID != nil
            && state.threads.first(where: { $0.id == state.selectedThreadID })?.steps.isEmpty == false
        if !taskForceNew,
           let selectedID = state.selectedThreadID,
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
            if isEmptyPlaceholder || currentTitle.isEmpty || currentTitle == "新线程" || currentTitle == "新对话" {
                state.threads[threadIndex].title = String(message.prefix(32))
            }
            state.threads[threadIndex].status = .running
            state.threads[threadIndex].connectorID = state.activeConnectorID
            state.threads[threadIndex].workflowName = workflowName
            state.threads[threadIndex].context = context
            state.threads[threadIndex].steps.append(userStep)
            state.threads[threadIndex].steps.append(planStep)
            loopPriorSteps = isEmptyPlaceholder ? [userStep, planStep] : state.threads[threadIndex].steps
            state.threads[threadIndex].updatedAt = .now
            targetTaskID = selectedID
        } else {
            let thread = Thread(
                title: String(message.prefix(32)),
                status: .running,
                steps: [userStep, planStep],
                connectorID: state.activeConnectorID,
                workflowName: workflowName,
                context: context
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
        state.liveActivity = "正在分析任务…"
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        var loopConfig = Self.agentLoopConfig(settings: state.settings, connector: connector, decision: decision)
        if let customAgent {
            loopConfig.customSystemPrompt = customAgent.systemPrompt
            let agentTools = Set(customAgent.tools.map { ToolNameCodec.canonicalName($0) })
            if let allowedToolsOverride {
                loopConfig.allowedTools = agentTools.isEmpty ? allowedToolsOverride : agentTools.intersection(allowedToolsOverride)
            } else {
                loopConfig.allowedTools = agentTools
            }
        } else if let allowedToolsOverride {
            loopConfig.allowedTools = allowedToolsOverride
        }
        if allowedToolsOverride != nil {
            loopConfig.maxIterations = min(loopConfig.maxIterations, 20)
        }
        let attemptedToolCalling = loopConfig.supportsToolCalling
        let loop = AgentLoop(
            config: loopConfig,
            runtime: environment.runtimeClient
        )
        agentLoop = loop

        generationTask = Task { [weak self] in
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
                self.persistThreads()

                // Record tool activities
                for step in completedTask.steps where step.kind == .toolCall {
                    self.recordToolActivity(name: step.toolName ?? "tool", summary: step.text, statusLine: "", isFailure: false)
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
                    self.persistThreads()
                }
                self.recordToolActivity(name: "task.error", summary: "任务执行失败", statusLine: error.localizedDescription, isFailure: true)
            }

            // Append pending follow-up if exists
            if let followUp = self.state.pendingFollowUp, !followUp.isEmpty {
                if let threadIndex = self.state.threads.firstIndex(where: { $0.id == targetTaskID }) {
                    let step = TaskStep(kind: .userInput, text: followUp, isCollapsible: false, isCollapsed: false)
                    self.state.threads[threadIndex].steps.append(step)
                    self.state.threads[threadIndex].updatedAt = .now
                    self.persistThreads()
                }
                self.state.pendingFollowUp = nil
            }

            self.state.isGenerating = false
            self.state.liveActivity = ""
            self.generationTask = nil
            self.streamBuffers.removeValue(forKey: targetTaskID)
            self.streamLastFlushAt.removeValue(forKey: targetTaskID)
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
        agentLoop = loop

        generationTask = Task { [weak self] in
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
                self.persistThreads()

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
                    self.persistThreads()
                }
                SelfImprovementEngine.shared.onImprovementFailure()
            }

            self.state.isGenerating = false
            self.state.liveActivity = ""
            self.generationTask = nil
            self.streamBuffers.removeValue(forKey: targetID)
            self.streamLastFlushAt.removeValue(forKey: targetID)
        }
    }

    /// Detects when user explicitly asks to switch from chat to task/action mode
    private static func isExplicitModeUpgradeRequest(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let upgradePatterns = [
            "转任务", "切换任务", "切到任务", "换成任务", "进入任务",
            "转执行", "切换执行", "切到执行", "换成执行", "进入执行",
            "用任务模式", "用执行模式", "切任务模式", "切执行模式",
            "别聊了", "不要聊天", "别光说", "动手吧", "开始执行", "开始做",
            "帮我做", "帮我改", "帮我修", "帮我写", "帮我创建", "帮我删",
            "帮我重构", "帮我优化", "帮我生成", "帮我运行", "帮我部署",
            "帮我查", "帮我搜", "帮我找", "帮我看看", "帮我分析",
            "帮我读", "帮我审查", "帮我检查", "帮我测试", "帮我调试",
            "请执行", "请修改", "请创建", "请写", "请重构", "请优化",
            "读一下", "看一下代码", "看下代码", "看下文件", "看一下文件",
            "打开文件", "读取文件", "搜索代码", "搜索文件",
            "执行一下", "跑一下", "运行一下", "试一下", "测一下"
        ]
        return upgradePatterns.contains { normalized.contains($0) }
    }

    private static func shouldUseReadOnlyTools(for decision: PlannerDecision) -> Bool {
        let capabilities = Set(decision.expectedCapabilities)
        let readSignals = ["理解意图", "读取工作区", "搜索代码", "输出建议", "分析项目"]
        let writeSignals = ["提出文件修改", "运行命令", "执行命令", "生成测试"]
        return readSignals.contains { capabilities.contains($0) }
            && !writeSignals.contains { capabilities.contains($0) }
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

    /// Detect if user message contains explicit mutation intent (delete, modify, fix, etc.)
    /// Used to auto-upgrade from read-only to full tool access
    private static func containsMutationIntent(_ message: String) -> Bool {
        let lower = message.lowercased()
        let mutationKeywords = [
            "删掉", "删除", "去掉", "移除", "清掉", "清理", "清除",
            "改一下", "修改", "修复", "修一下", "改掉", "替换", "更新",
            "写入", "创建", "新建", "添加", "加上", "执行", "运行",
            "重构", "重写", "部署", "安装", "提交", "commit", "push",
            "fix", "delete", "remove", "update", "create", "write",
            "你去做", "你来做", "帮我做", "动手", "去吧", "搞定"
        ]
        return mutationKeywords.contains(where: { lower.contains($0) })
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
        state.liveActivity = "正在执行工作流…"
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        let run = WorkflowRun(name: workflow.name, goal: message, statusLine: "执行中")
        state.workflowRuns.insert(run, at: 0)
        if state.workflowRuns.count > 20 { state.workflowRuns = Array(state.workflowRuns.prefix(20)) }
        persistThreads()

        generationTask = Task { [weak self] in
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
                self.persistThreads()
            }

            self.state.isGenerating = false
            self.state.liveActivity = ""
            self.generationTask = nil
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

        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let completedTask = try await orchestrator.run(
                    taskID: thread.id,
                    message: message,
                    intent: intent,
                    connector: connector,
                    allConnectors: self.state.connectors,
                    context: context,
                    plan: plan,
                    onStep: { [weak self] step in
                        guard let self else { return }
                        self.appendTaskStep(step, to: thread.id)
                    },
                    onStreamDelta: { [weak self] delta in
                        guard let self else { return }
                        self.appendStreamDelta(delta, to: thread.id)
                    },
                    onPlanUpdate: { [weak self] updatedPlan in
                        guard let self else { return }
                        self.updateMultiAgentPlan(updatedPlan, for: thread.id)
                    }
                )

                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: thread.id)
                self.mergeCompletedTask(completedTask, into: thread.id)
                self.persistThreads()
            } catch {
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: thread.id)
                if let idx = self.state.threads.firstIndex(where: { $0.id == thread.id }) {
                    self.state.threads[idx].steps.append(
                        TaskStep(kind: .error, text: "多Agent执行失败：\(error.localizedDescription)", isFailure: true, recoverable: true)
                    )
                    self.state.threads[idx].status = .failed
                    self.state.threads[idx].updatedAt = .now
                    self.persistThreads()
                }
            }
            self.state.isGenerating = false
            self.state.liveActivity = ""
            self.generationTask = nil
            self.streamBuffers.removeValue(forKey: thread.id)
            self.streamLastFlushAt.removeValue(forKey: thread.id)
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
        generationTask = Task { [weak self] in
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
                    taskID: thread.id,
                    message: message,
                    intent: .task,
                    connector: connector,
                    allConnectors: self.state.connectors,
                    context: thread.context,
                    plan: plan,
                    onStep: { [weak self] step in
                        self?.appendTaskStep(step, to: thread.id)
                    },
                    onStreamDelta: { [weak self] delta in
                        self?.appendStreamDelta(delta, to: thread.id)
                    },
                    onPlanUpdate: { [weak self] updatedPlan in
                        self?.updateMultiAgentPlan(updatedPlan, for: thread.id)
                    }
                )
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: thread.id)
                self.mergeCompletedTask(completedTask, into: thread.id)
                self.persistThreads()
            } catch {
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: thread.id)
                if let idx = self.state.threads.firstIndex(where: { $0.id == thread.id }) {
                    self.state.threads[idx].steps.append(
                        TaskStep(kind: .error, text: "多Agent执行失败：\(error.localizedDescription)", isFailure: true, recoverable: true)
                    )
                    self.state.threads[idx].status = .failed
                    self.state.threads[idx].updatedAt = .now
                    self.persistThreads()
                }
            }
            self.state.isGenerating = false
            self.state.liveActivity = ""
            self.generationTask = nil
            self.streamBuffers.removeValue(forKey: thread.id)
            self.streamLastFlushAt.removeValue(forKey: thread.id)
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
        generationTask = Task { [weak self] in
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
                    taskID: thread.id,
                    message: message,
                    intent: .task,
                    connector: connector,
                    allConnectors: self.state.connectors,
                    context: thread.context,
                    plan: plan,
                    onStep: { [weak self] step in
                        self?.appendTaskStep(step, to: thread.id)
                    },
                    onStreamDelta: { [weak self] delta in
                        self?.appendStreamDelta(delta, to: thread.id)
                    },
                    onPlanUpdate: { [weak self] updatedPlan in
                        self?.updateMultiAgentPlan(updatedPlan, for: thread.id)
                    }
                )
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: thread.id)
                self.mergeCompletedTask(completedTask, into: thread.id)
                self.persistThreads()
            } catch {
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: thread.id)
                if let idx = self.state.threads.firstIndex(where: { $0.id == thread.id }) {
                    self.state.threads[idx].steps.append(
                        TaskStep(kind: .error, text: "多Agent恢复执行失败：\(error.localizedDescription)", isFailure: true, recoverable: true)
                    )
                    self.state.threads[idx].status = .failed
                    self.state.threads[idx].updatedAt = .now
                    self.persistThreads()
                }
            }
            self.state.isGenerating = false
            self.state.liveActivity = ""
            self.generationTask = nil
            self.streamBuffers.removeValue(forKey: thread.id)
            self.streamLastFlushAt.removeValue(forKey: thread.id)
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
                    self.persistThreads()
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
                    self.persistThreads()
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
            state.userCreatedNewThread = false
            switch record.source {
            case .session:
                state.modeLabel = "聊天"
            case .task:
                state.modeLabel = record.task?.workflowName == nil ? "任务" : "工作流"
            }
        } else {
            // User explicitly created a new thread — prevent auto-merge
            state.userCreatedNewThread = true
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
        state.settings.workspacePath = value
        state.workspaceName = URL(fileURLWithPath: value).lastPathComponent
        WorkspaceSandbox.shared.workspaceRoot = value
        // Update agentLoop config
        agentLoop = AgentLoop(
            config: Self.agentLoopConfig(settings: state.settings, connector: state.activeConnector),
            runtime: environment.runtimeClient
        )
        initializeEngines(workspaceRoot: value)
        persistSettings()
    }

    // G16: Switch workspace and track in recents
    public func switchWorkspace(to path: String) {
        state.settings.switchWorkspace(to: path)
        state.workspaceName = URL(fileURLWithPath: path).lastPathComponent
        WorkspaceSandbox.shared.workspaceRoot = path
        agentLoop = AgentLoop(
            config: Self.agentLoopConfig(settings: state.settings, connector: state.activeConnector),
            runtime: environment.runtimeClient
        )
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
        agentLoop = AgentLoop(
            config: Self.agentLoopConfig(settings: state.settings, connector: state.activeConnector),
            runtime: environment.runtimeClient
        )
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

    // MARK: - Private Helpers

    private func discardEmptySelectedSessionPlaceholder() {
        guard let id = state.selectedSessionID,
              let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        let thread = state.threads[index]
        guard thread.source == .session && Self.isEmptySessionPlaceholder(ChatSession(thread: thread)) else { return }
        state.threads.remove(at: index)
        state.selectThread(id: nil)
        persistThreads()
    }

    private func composedDraftMessage() -> String {
        var text = state.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        // G8: Expand @-mention file references (e.g. @src/main.swift or @/absolute/path)
        var mentionedPaths: [String] = []
        let mentionPattern = #"@((?:/[\w./-]+)|(?:[\w./-]+\.[\w]+))"#
        if let regex = try? NSRegularExpression(pattern: mentionPattern) {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let pathRange = match.range(at: 1)
                var path = ns.substring(with: pathRange)
                if !path.hasPrefix("/") {
                    let fullPath = (state.settings.workspacePath as NSString).appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: fullPath) {
                        path = fullPath
                    }
                }
                if FileManager.default.fileExists(atPath: path) {
                    mentionedPaths.append(path)
                }
            }
        }

        // Add mentioned files to attachments
        var allAttachments = state.draftAttachments + mentionedPaths
        allAttachments = Array(Set(allAttachments))

        guard !allAttachments.isEmpty else { return text }
        let attachmentText: String
        if allAttachments.count == 1, let path = allAttachments.first {
            attachmentText = "请读取这个附件：\(path)"
        } else {
            attachmentText = "请读取这些附件：\n" + allAttachments.joined(separator: "\n")
        }
        return text.isEmpty ? attachmentText : "\(text)\n\(attachmentText)"
    }

    private func promoteSelectedSessionToTaskIfNeeded() {
        guard let sessionID = state.selectedSessionID,
              let threadIndex = state.threads.firstIndex(where: { $0.id == sessionID }) else { return }
        let thread = state.threads[threadIndex]
        guard thread.source == .session && !thread.steps.isEmpty else { return }
        // Session already has steps as TaskStep; just add context to promote to task
        state.threads[threadIndex].context = TaskContext(workspaceRoot: state.settings.workspacePath, vaultRoot: cleanVaultPath())
        state.threads[threadIndex].connectorID = state.activeConnectorID
        // Source will automatically become .task now that context is non-empty
        persistThreads()
    }

    private func taskStepKind(for role: ChatRole) -> TaskStepKind {
        switch role {
        case .user: return .userInput
        case .assistant: return .textOutput
        case .tool: return .toolResult
        case .system: return .aiThinking
        }
    }

    private func cleanVaultPath() -> String? {
        let trimmed = state.settings.vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedConnector(_ connector: ConnectorProfile, previous: ConnectorProfile? = nil) -> ConnectorProfile {
        var normalized = connector
        normalized.name = connector.name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.kind = connector.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.endpoint = connector.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.modelName = connector.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.note = connector.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let previous,
           Self.toolCallingIdentityChanged(from: previous, to: normalized) {
            normalized.toolCallingCapability = nil
            normalized.toolCallingCapabilitySource = nil
            normalized.toolCallingCapabilityLearnedAt = nil
        }
        if let previous, Self.connectorConfigurationChanged(from: previous, to: normalized) {
            normalized.health = .attention
        }
        return normalized
    }

    private func scheduleConnectorHealthRefreshIfNeeded(for connector: ConnectorProfile, force: Bool = false) {
        guard canAutoCheckConnectorHealth(connector) else { return }
        guard force || connector.health != .ready else { return }
        checkConnectorHealth(id: connector.id, showsToast: false, probeToolCalling: false)
    }

    private func canAutoCheckConnectorHealth(_ connector: ConnectorProfile) -> Bool {
        !connector.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !connector.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func recordToolActivity(name: String, summary: String, statusLine: String, isFailure: Bool) {
        recordToolActivity(ToolActivity(name: name, summary: summary, statusLine: statusLine, isFailure: isFailure))
    }

    private func recordToolActivity(_ activity: ToolActivity) {
        if let first = state.toolActivities.first,
           first.name == activity.name,
           first.summary == activity.summary,
           first.statusLine == activity.statusLine,
           first.isFailure == activity.isFailure {
            return
        }
        state.toolActivities.removeAll {
            $0.name == activity.name
                && $0.summary == activity.summary
                && $0.statusLine == activity.statusLine
                && $0.isFailure == activity.isFailure
        }
        state.toolActivities.insert(activity, at: 0)
        if state.toolActivities.count > 12 { state.toolActivities = Array(state.toolActivities.prefix(12)) }
    }

    private func appendTaskStep(_ step: TaskStep, to taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        if let existingIndex = state.threads[threadIndex].steps.firstIndex(where: { $0.id == step.id }) {
            if step.kind == .toolResult {
                state.threads[threadIndex].steps[existingIndex] = step
                state.threads[threadIndex].updatedAt = Date()
                persistThreads()
            }
            return
        }
        if shouldCollapseDuplicateStep(step, in: state.threads[threadIndex].steps) { return }
        if step.kind == .textOutput,
           let streamingIndex = state.threads[threadIndex].steps.lastIndex(where: { $0.kind == .textOutput && $0.toolCallId == Self.streamingOutputID }) {
            streamBuffers.removeValue(forKey: taskID)
            streamLastFlushAt.removeValue(forKey: taskID)
            var finalStep = step
            finalStep.toolCallId = nil
            state.threads[threadIndex].steps[streamingIndex] = finalStep
            state.threads[threadIndex].updatedAt = Date()
            persistThreads()
            return
        }
        guard !state.threads[threadIndex].steps.contains(where: { $0.kind == step.kind && $0.text == step.text }) else { return }
        state.threads[threadIndex].steps.append(step)
        state.threads[threadIndex].updatedAt = Date()
        persistThreads()
    }

    private func appendStreamDelta(_ delta: String, to taskID: UUID) {
        guard !delta.isEmpty else { return }
        streamBuffers[taskID, default: ""] += delta
        let now = Date()
        let pending = streamBuffers[taskID] ?? ""
        let lastFlush = streamLastFlushAt[taskID] ?? .distantPast
        guard pending.count >= streamFlushCharacterThreshold || now.timeIntervalSince(lastFlush) >= streamFlushInterval else {
            return
        }
        flushStreamBuffer(for: taskID)
    }

    private func flushStreamBuffer(for taskID: UUID) {
        guard let pending = streamBuffers[taskID], !pending.isEmpty else { return }
        streamBuffers[taskID] = ""
        streamLastFlushAt[taskID] = Date()
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        state.liveActivity = "正在生成回复…"
        if let streamIndex = state.threads[threadIndex].steps.lastIndex(where: { $0.kind == .textOutput && $0.toolCallId == Self.streamingOutputID }) {
            state.threads[threadIndex].steps[streamIndex].text += pending
        } else {
            state.threads[threadIndex].steps.append(TaskStep(
                kind: .textOutput,
                text: pending,
                toolCallId: Self.streamingOutputID,
                isCollapsible: false,
                isCollapsed: false
            ))
        }
        state.threads[threadIndex].updatedAt = Date()
    }

    private func mergeCompletedTask(_ completedTask: AgentTask, into taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        for step in completedTask.steps {
            if shouldCollapseDuplicateStep(step, in: state.threads[threadIndex].steps) { continue }
            let alreadyExists = state.threads[threadIndex].steps.contains {
                $0.id == step.id || ($0.kind == step.kind && $0.text == step.text)
            }
            if !alreadyExists {
                state.threads[threadIndex].steps.append(step)
                updateLiveActivity(from: step)
            }
        }
        state.threads[threadIndex].status = completedTask.status
        state.liveActivity = ""
        state.threads[threadIndex].context = completedTask.context
        state.threads[threadIndex].context.memory = Self.taskMemory(from: state.threads[threadIndex])
        if let plan = completedTask.multiAgentPlan {
            state.threads[threadIndex].multiAgentPlan = plan
        }
        state.threads[threadIndex].updatedAt = completedTask.updatedAt
        Self.ensureCheckpointIfNeeded(&state.threads[threadIndex])
        state.selectThread(id: taskID)

        // System notification when app is in background
        let appIsActive = NSApplication.shared.isActive
        if !appIsActive {
            let threadTitle = state.threads[threadIndex].title
            let noteTitle: String
            switch completedTask.status {
            case .completed: noteTitle = "任务完成"
            case .failed: noteTitle = "任务失败"
            default: noteTitle = "任务状态更新"
            }
            NotificationManager.shared.post(
                title: noteTitle,
                body: threadTitle,
                threadID: taskID.uuidString
            )
        }
    }

    private func shouldCollapseDuplicateStep(_ step: TaskStep, in steps: [TaskStep]) -> Bool {
        switch step.kind {
        case .userInput, .aiThinking:
            return steps.contains { $0.kind == step.kind && $0.text == step.text }
        default:
            return false
        }
    }

    private func appendAssistantStep(_ text: String, to sessionID: UUID, connectorName: String, metrics: ResponseMetrics? = nil) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == sessionID }) else { return }
        let assistantText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        state.threads[threadIndex].steps.append(TaskStep(kind: .textOutput, text: assistantText, isCollapsible: false, isCollapsed: false, metrics: metrics))
        state.threads[threadIndex].preview = normalizedSessionPreview(assistantText)
        state.threads[threadIndex].modelName = connectorName
        state.threads[threadIndex].updatedAt = .now
        state.selectThread(id: sessionID)
        persistThreads()
    }

    private func appendAssistantDelta(_ delta: String, stepID: UUID, in sessionID: UUID, connectorName: String) {
        guard !delta.isEmpty else { return }
        chatStreamBuffers[stepID, default: ""] += delta
        let now = Date()
        let pending = chatStreamBuffers[stepID] ?? ""
        let lastFlush = chatStreamLastFlushAt[stepID] ?? .distantPast
        guard pending.count >= chatStreamFlushCharacterThreshold || now.timeIntervalSince(lastFlush) >= chatStreamFlushInterval else {
            return
        }
        flushAssistantBuffer(stepID: stepID, in: sessionID, connectorName: connectorName)
    }

    private func flushAssistantBuffer(stepID: UUID, in sessionID: UUID, connectorName: String) {
        guard let pending = chatStreamBuffers[stepID], !pending.isEmpty else { return }
        chatStreamBuffers[stepID] = ""
        chatStreamLastFlushAt[stepID] = Date()
        updateAssistantStep(stepID, in: sessionID, delta: pending, connectorName: connectorName, persist: false)
    }

    private func updateAssistantStep(
        _ stepID: UUID,
        in sessionID: UUID,
        delta: String? = nil,
        finalText: String? = nil,
        metrics: ResponseMetrics? = nil,
        connectorName: String,
        persist shouldPersist: Bool = true
    ) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == sessionID }) else { return }
        guard let stepIndex = state.threads[threadIndex].steps.firstIndex(where: { $0.id == stepID }) else {
            appendAssistantStep(finalText ?? delta ?? "", to: sessionID, connectorName: connectorName, metrics: metrics)
            return
        }

        if let finalText {
            state.threads[threadIndex].steps[stepIndex].text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let delta, !delta.isEmpty {
            state.threads[threadIndex].steps[stepIndex].text += delta
        }
        if let metrics {
            state.threads[threadIndex].steps[stepIndex].metrics = metrics
        }

        let text = state.threads[threadIndex].steps[stepIndex].text
        state.threads[threadIndex].preview = normalizedSessionPreview(text)
        state.threads[threadIndex].modelName = connectorName
        state.threads[threadIndex].updatedAt = .now
        state.selectThread(id: sessionID)
        if shouldPersist {
            chatStreamBuffers.removeValue(forKey: stepID)
            chatStreamLastFlushAt.removeValue(forKey: stepID)
            persistThreads()
        }
    }

    private func directSessionTitle(for message: String) -> String {
        let normalized = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "新线程" }
        if Self.isTinyFollowUp(normalized), let title = state.selectedThread?.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return String(normalized.prefix(32))
    }

    private func shouldContinueSelectedTask(with message: String) -> Bool {
        guard let taskID = state.selectedTaskID,
              let thread = state.threads.first(where: { $0.id == taskID }) else {
            return false
        }
        guard state.executionMode != .ask else { return false }
        if thread.status == .running {
            return !state.isGenerating
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if UserFrustrationDetector.shouldRecoverRecentTask(trimmed) {
            return true
        }
        return Self.shouldRouteChatFollowUpIntoSelectedTask(message: trimmed, task: AgentTask(thread: thread))
    }

    private func reconcileSelectedRunningTaskIfIdle() {
        guard !state.isGenerating,
              let taskID = state.selectedTaskID,
              let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }),
              state.threads[threadIndex].status == .running else { return }

        state.threads[threadIndex].status = .cancelled
        state.threads[threadIndex].updatedAt = .now
        state.threads[threadIndex].steps.append(TaskStep(
            kind: .error,
            text: "上次执行没有正常结束，已转为可继续状态。本轮会沿着这条任务继续。",
            isCollapsible: true,
            isCollapsed: true,
            isFailure: false,
            recoverable: true,
            retryAction: "继续"
        ))
        persistThreads()
    }

    private func restoreRecentTaskSelectionForTinyFollowUp(_ message: String) {
        guard state.executionMode != .ask else { return }
        // User explicitly created a new thread — never auto-merge back into old threads
        guard !state.userCreatedNewThread else { return }
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitTaskContinuation = Self.isContinuationCommand(normalized)
            && (normalized.contains("任务") || normalized.contains("刚才") || normalized.contains("上个") || normalized.contains("上一"))
        let contextualTaskReference = Self.isContextualTaskReference(normalized)
        let frustratedTaskReference = UserFrustrationDetector.shouldRecoverRecentTask(normalized)
        let likelyTaskFollowUp = Self.isLikelyTaskFollowUp(normalized)
        guard explicitTaskContinuation || contextualTaskReference || frustratedTaskReference || likelyTaskFollowUp else { return }
        let canReplaceSelectedSession: Bool = {
            guard let sessionID = state.selectedSessionID else { return true }
            guard explicitTaskContinuation || contextualTaskReference || frustratedTaskReference || likelyTaskFollowUp else { return false }
            // If message is clearly a task follow-up, always allow switching back,
            // even if the current session is not an empty placeholder.
            if likelyTaskFollowUp { return true }
            guard let thread = state.threads.first(where: { $0.id == sessionID }) else { return true }
            return Self.isEmptySessionPlaceholder(ChatSession(thread: thread))
        }()
        guard state.selectedTaskID == nil,
              canReplaceSelectedSession,
              let latestTaskThread = state.threads.filter({ $0.source == .task }).sorted(by: { $0.updatedAt > $1.updatedAt }).first,
              Date().timeIntervalSince(latestTaskThread.updatedAt) < 30 * 60 else { return }

        discardEmptySelectedSessionPlaceholder()
        state.selectThread(id: latestTaskThread.id)
        state.modeLabel = latestTaskThread.workflowName == nil ? "任务" : "工作流"
    }

    private func answerSelectedTaskStatusQuestion(_ message: String) -> Bool {
        guard let taskID = state.selectedTaskID,
              let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }),
              state.threads[threadIndex].status != .running,
              Self.isTaskStatusQuestion(message) else { return false }

        let answer = Self.taskStatusAnswer(for: AgentTask(thread: state.threads[threadIndex]), question: message)
        state.threads[threadIndex].steps.append(TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false))
        state.threads[threadIndex].steps.append(TaskStep(kind: .textOutput, text: answer, isCollapsible: false, isCollapsed: false))
        state.threads[threadIndex].updatedAt = .now
        state.selectThread(id: taskID)
        state.modeLabel = state.threads[threadIndex].workflowName == nil ? "任务" : "工作流"
        state.draftMessage = ""
        persistThreads()
        return true
    }

    private func appendReviewResult(to threadIndex: Int, approved: Bool, text: String) {
        let result = TaskStep(
            kind: .reviewResult,
            text: text,
            isCollapsible: false,
            isCollapsed: false,
            isFailure: !approved,
            approved: approved
        )
        state.threads[threadIndex].steps.append(result)
    }

    private func markConnectorReady(_ id: UUID) {
        updateConnectorHealth(id, to: .ready)
    }

    private func updateConnectorHealth(_ id: UUID, to health: ConnectorHealth) {
        guard let index = state.connectors.firstIndex(where: { $0.id == id }) else { return }
        state.connectors[index].health = health
        state.connectors[index].lastCheckedAt = .now
        persistConnectors()
    }

    private func recordConnectorOutcome(_ response: SendMessageResponse, connectorID: UUID) {
        if let health = Self.connectorFailureHealth(from: response) {
            updateConnectorHealth(connectorID, to: health)
            return
        }
        markConnectorReady(connectorID)
    }

    private func recordConnectorOutcome(_ task: AgentTask, connectorID: UUID, attemptedToolCalling: Bool) {
        rememberToolCallingCapabilityIfNeeded(from: task, connectorID: connectorID, attemptedToolCalling: attemptedToolCalling)
        if let health = Self.connectorFailureHealth(from: task) {
            updateConnectorHealth(connectorID, to: health)
            return
        }
        markConnectorReady(connectorID)
    }

    private static func connectorConfigurationChanged(from previous: ConnectorProfile, to next: ConnectorProfile) -> Bool {
        previous.kind.trimmingCharacters(in: .whitespacesAndNewlines) != next.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) != next.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.modelName.trimmingCharacters(in: .whitespacesAndNewlines) != next.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.note.trimmingCharacters(in: .whitespacesAndNewlines) != next.note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func toolCallingIdentityChanged(from previous: ConnectorProfile, to next: ConnectorProfile) -> Bool {
        previous.kind.trimmingCharacters(in: .whitespacesAndNewlines) != next.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) != next.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.modelName.trimmingCharacters(in: .whitespacesAndNewlines) != next.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rememberToolCallingCapabilityIfNeeded(from task: AgentTask, connectorID: UUID, attemptedToolCalling: Bool) {
        guard attemptedToolCalling else { return }
        let fallbackDetected = task.steps.contains(where: { $0.retryAction == AgentLoop.toolCompatibilityFallbackAction })
        let producedAgentContent = task.steps.contains {
            $0.kind == .textOutput || $0.kind == .toolCall || $0.kind == .toolResult || $0.kind == .reviewResult
        }
        let nextCapability: ConnectorToolCallingCapability?
        if fallbackDetected {
            nextCapability = .unsupported
        } else if producedAgentContent {
            nextCapability = .supported
        } else {
            nextCapability = nil
        }
        if rememberToolCallingCapability(nextCapability, connectorID: connectorID, activitySource: .taskRun) {
            persistConnectors()
        }
    }

    @discardableResult
    private func rememberToolCallingCapability(
        _ capability: ConnectorToolCallingCapability?,
        connectorID: UUID,
        activitySource: ConnectorToolCallingCapabilityObservationSource?
    ) -> Bool {
        guard let capability,
              let index = state.connectors.firstIndex(where: { $0.id == connectorID }) else { return false }
        let previousCapability = state.connectors[index].toolCallingCapability
        let previousSource = state.connectors[index].toolCallingCapabilitySource
        let capabilityChanged = previousCapability != capability
        let sourceChanged = activitySource != nil && previousSource != activitySource
        let observedAgain = activitySource != nil
        guard capabilityChanged || observedAgain else { return false }
        state.connectors[index].toolCallingCapability = capability
        if capabilityChanged {
            refreshActiveAgentLoopIfNeeded(for: connectorID)
        }
        if let activitySource {
            state.connectors[index].toolCallingCapabilitySource = activitySource
            state.connectors[index].toolCallingCapabilityLearnedAt = .now
        } else if capabilityChanged {
            state.connectors[index].toolCallingCapabilitySource = nil
            state.connectors[index].toolCallingCapabilityLearnedAt = nil
        }
        guard let activitySource,
              capabilityChanged || sourceChanged else { return true }
        let statusLine: String
        switch (activitySource, capability) {
        case (.connectorProbe, .supported):
            statusLine = "已通过连接测试验证 tools 请求兼容，automatic 模式会继续保留工具调用。"
        case (.connectorProbe, .unsupported):
            statusLine = "已通过连接测试验证 tools 请求不兼容，automatic 模式后续将默认不再发送 tools。"
        case (.taskRun, .supported):
            statusLine = "本次任务已成功携带 tools 请求，automatic 模式后续会继续保留工具调用。"
        case (.taskRun, .unsupported):
            statusLine = "检测到请求格式不兼容，automatic 模式后续将默认不再发送 tools。"
        }
        recordToolActivity(
            name: "connector.capability",
            summary: capability == .supported
                ? "已验证 \(state.connectors[index].name) 支持工具调用"
                : "已验证 \(state.connectors[index].name) 不兼容工具调用",
            statusLine: statusLine,
            isFailure: false
        )
        return true
    }

    private func refreshActiveAgentLoopIfNeeded(for connectorID: UUID) {
        guard state.activeConnectorID == connectorID,
              let connector = state.connectors.first(where: { $0.id == connectorID }) else { return }
        agentLoop = AgentLoop(
            config: Self.agentLoopConfig(settings: state.settings, connector: connector),
            runtime: environment.runtimeClient
        )
    }

    private static func connectorFailureHealth(from response: SendMessageResponse) -> ConnectorHealth? {
        let text = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("无法连接") || text.hasPrefix("请求失败：") || text.hasPrefix("模型请求失败：") {
            return .offline
        }
        if response.toolActivities.contains(where: { $0.isFailure }) || looksLikeConnectorFailure(text) {
            return .attention
        }
        return nil
    }

    private static func connectorFailureHealth(from task: AgentTask) -> ConnectorHealth? {
        guard let errorStep = task.steps.reversed().first(where: { $0.kind == .error && $0.isFailure }) else { return nil }
        if errorStep.retryAction == "检查端点、模型名和请求兼容性后重试" {
            return .attention
        }
        let text = errorStep.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("模型请求失败：") || text.hasPrefix("请求失败：") || text.hasPrefix("无法连接") {
            return .offline
        }
        return nil
    }

    private static func looksLikeConnectorFailure(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let preview = normalizedSessionPreview(text)
        return preview == "未找到接口，请检查端点地址是否正确。"
            || preview == "鉴权失败，请检查 API 密钥是否正确。"
            || preview == "请求失败，请检查连接器配置。"
            || text.contains("HTTP 400")
            || text.contains("HTTP 401")
            || text.contains("HTTP 404")
    }

    private static func taskMemory(from thread: Thread) -> TaskMemory {
        let readFiles = uniqueMemoryValues(thread.steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] })
        let searchedQueries = uniqueMemoryValues(thread.steps
            .filter { $0.kind == .toolCall && $0.toolName == "code.search" }
            .compactMap { $0.toolParams?["query"] })
        let failedTools = uniqueMemoryValues(Dictionary(grouping: thread.steps.filter { $0.kind == .toolResult && $0.isFailure }, by: { $0.toolName ?? "tool" })
            .map { "\($0.key) ×\($0.value.count)" }
            .sorted())
        let conclusions = thread.steps
            .filter { $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(3)
            .map { compactMemoryText($0.text, limit: 240) }
        let checkpoints = thread.steps
            .filter { $0.kind == .aiThinking && ($0.text.hasPrefix("任务检查点") || $0.text.hasPrefix("阶段总结")) }
            .suffix(2)
            .map { compactMemoryText($0.text, limit: 360) }
        let verification: String?
        if thread.status == .completed {
            verification = "已形成最终回复，需以后续验证命令为准。"
        } else if thread.status == .failed {
            verification = "任务失败或未完成，继续时优先恢复失败工具或补齐证据。"
        } else if thread.status == .cancelled {
            verification = "任务被取消，继续时沿用已读上下文并从未完成处推进。"
        } else {
            verification = nil
        }

        return TaskMemory(
            readFiles: readFiles,
            searchedQueries: searchedQueries,
            failedTools: failedTools,
            stageConclusions: uniqueMemoryValues(conclusions),
            checkpoints: uniqueMemoryValues(checkpoints),
            verificationStatus: verification,
            pendingFiles: pendingFileCandidates(from: thread.steps, alreadyRead: Set(readFiles)),
            userDecisions: thread.steps
                .filter { $0.kind == .reviewResult }
                .suffix(5)
                .map { compactMemoryText($0.text, limit: 160) },
            updatedAt: .now
        )
    }

    /// Extract unread file candidates from search/index results that haven't been read yet.
    private static func pendingFileCandidates(from steps: [TaskStep], alreadyRead: Set<String>) -> [String] {
        var candidates: [String] = []
        // From code.search results: extract file paths mentioned
        for step in steps where step.kind == .toolResult && step.toolName == "code.search" && !step.isFailure {
            let lines = step.text.components(separatedBy: "\n")
            for line in lines {
                // Search results typically show "path:line: content"
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("src/") || trimmed.hasPrefix("Sources/") {
                    let path = trimmed.components(separatedBy: ":").first ?? trimmed
                    let cleanPath = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
                    if !alreadyRead.contains(cleanPath) && !cleanPath.isEmpty {
                        candidates.append(cleanPath)
                    }
                }
            }
        }
        // From workspace.index results: extract key file paths
        for step in steps where step.kind == .toolResult && step.toolName == "workspace.index" && !step.isFailure {
            let lines = step.text.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("入口") || trimmed.hasPrefix("测试") || trimmed.hasPrefix("配置") {
                    // Extract path after colon
                    if let colonRange = trimmed.range(of: "：") ?? trimmed.range(of: ":") {
                        let afterColon = trimmed[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)
                        if !afterColon.isEmpty && !alreadyRead.contains(afterColon) {
                            candidates.append(afterColon)
                        }
                    }
                }
            }
        }
        return Array(uniqueMemoryValues(candidates).prefix(12))
    }

    private static func uniqueMemoryValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private static func compactMemoryText(_ text: String, limit: Int) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return "\(cleaned.prefix(limit))…"
    }

    private func absolutePath(for path: String, workspaceRoot: String) -> String {
        if path.hasPrefix("/") { return path }
        return (workspaceRoot as NSString).appendingPathComponent(path)
    }

    private func notify(_ message: String, style: AppNoticeStyle = .info) {
        state.notice = AppNotice(message: message, style: style)
    }

    private static func agentLoopConfig(settings: AppSettings, connector: ConnectorProfile? = nil) -> AgentLoop.Config {
        let profile = ConnectorCapabilityProfile.infer(for: connector, mode: settings.contextMode)
        return AgentLoop.Config(
            maxIterations: profile.maxIterations,
            maxTokensPerTurn: profile.maxTokensPerTurn,
            workspaceRoot: settings.workspacePath,
            supportsToolCalling: profile.supportsToolCalling,
            contextMode: settings.contextMode,
            contextWindow: profile.contextWindow,
            modelName: connector?.modelName ?? ""
        )
    }

    private static func agentLoopConfig(settings: AppSettings, connector: ConnectorProfile? = nil, decision: PlannerDecision) -> AgentLoop.Config {
        var config = agentLoopConfig(settings: settings, connector: connector)
        let needsProjectDepth = decision.expectedCapabilities.contains("读取工作区")
            || decision.expectedCapabilities.contains("提出文件修改")
            || {
                if case .workflow = decision.intent { return true }
                return false
            }()
        if needsProjectDepth {
            // Ensure at least the mode's iteration budget — profile already handles local vs remote caps
            config.maxIterations = max(config.maxIterations, settings.contextMode.maxIterations)
        }
        return config
    }

    private static func plannerStepText(for decision: PlannerDecision) -> String {
        var lines = [
            "规划：\(decision.routeLabel) · 置信度 \(Int((decision.confidence * 100).rounded()))%",
            decision.reason
        ]
        if !decision.expectedCapabilities.isEmpty {
            lines.append("预计使用：\(decision.expectedCapabilities.joined(separator: "、"))")
        }
        return lines.joined(separator: "\n")
    }

    private static func workflowCompletionCheckStep(steps: [TaskStep], hasError: Bool) -> TaskStep {
        let toolFailures = steps.filter { $0.kind == .toolResult && $0.isFailure }.count
        let text = hasError
            ? "完成检查：工作流发现 \(toolFailures) 个失败步骤，建议展开失败项后重试或调整目标。"
            : "完成检查：工作流已完成，未发现失败步骤。"
        return TaskStep(
            kind: .aiThinking,
            text: text,
            isCollapsible: true,
            isCollapsed: true,
            isFailure: hasError
        )
    }

    private static func prepareThreadForContinuation(_ thread: inout Thread, message: String) {
        let checkpoint = latestCheckpoint(in: thread)
        thread.steps.removeAll { step in
            if step.kind == .textOutput,
               step.toolCallId == streamingOutputID,
               step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            guard step.kind == .error else { return false }
            let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if step.recoverable && !step.isFailure { return true }
            if text.contains("已达到最大迭代次数") { return true }
            if text.contains("上次运行被中断") || text.contains("已自动标记为已暂停") || text.contains("已自动标记为已取消") { return true }
            return false
        }

        guard (isContinuationCommand(message) || isLikelyTaskFollowUp(message)),
              !thread.steps.contains(where: { $0.kind == .aiThinking && $0.text.contains("继续策略") }) else { return }
        let checkpointText = checkpoint.map { "\n\n最近检查点：\($0)" } ?? ""
        thread.steps.append(TaskStep(
            kind: .aiThinking,
            text: "继续策略：沿用这条任务里已经读取到的结果，从未完成处继续；只有证据不足时再补充搜索或读取。\(checkpointText)",
            isCollapsible: true,
            isCollapsed: true
        ))
    }

    private static func ensureCheckpointIfNeeded(_ thread: inout Thread) {
        guard thread.status == .failed || thread.status == .cancelled || thread.steps.contains(where: { $0.text.contains("已达到最大迭代次数") }) else { return }
        guard latestCheckpoint(in: thread) == nil else { return }
        thread.steps.append(makeCheckpointStep(for: thread))
    }

    private static func makeCheckpointStep(for thread: Thread) -> TaskStep {
        let toolCalls = thread.steps.filter { $0.kind == .toolCall }.count
        let failedTools = thread.steps.filter { $0.kind == .toolResult && $0.isFailure }
        let readFiles = thread.steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] }
        let lastOutput = thread.steps.reversed().first {
            $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastFailure = thread.steps.reversed().first {
            $0.kind == .error || $0.isFailure
        }?.text.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines = ["任务检查点"]
        lines.append("状态：\(thread.status.title)")
        lines.append("已执行：\(toolCalls) 次工具调用")
        if !readFiles.isEmpty {
            lines.append("已读取：\(Array(Set(readFiles)).sorted().prefix(8).joined(separator: "、"))")
        }
        if !failedTools.isEmpty {
            let grouped = Dictionary(grouping: failedTools, by: { $0.toolName ?? "tool" })
                .map { "\($0.key) ×\($0.value.count)" }
                .sorted()
                .joined(separator: "、")
            lines.append("失败：\(grouped)")
        }
        if let lastFailure, !lastFailure.isEmpty {
            lines.append("最近失败：\(String(lastFailure.prefix(220)))")
        }
        if let lastOutput, !lastOutput.isEmpty {
            lines.append("阶段输出：\(String(lastOutput.prefix(260)))")
        }
        lines.append("建议下一步：基于已读结果继续，优先补齐未读关键文件；如果是整项目任务，先使用 workspace.index 或已有索引，不要重复低效 shell 遍历。")
        return TaskStep(
            kind: .aiThinking,
            text: lines.joined(separator: "\n"),
            isCollapsible: true,
            isCollapsed: true,
            isFailure: thread.status == .failed
        )
    }

    private static func latestCheckpoint(in thread: Thread) -> String? {
        thread.steps.reversed().first {
            $0.kind == .aiThinking && $0.text.hasPrefix("任务检查点")
        }?.text
    }

    private static func retryMessage(for thread: Thread, lastUserMessage: String) -> String {
        let original = lastUserMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        // Don't wrap the message — prepareThreadForContinuation already injects
        // the continuation strategy as an aiThinking step. Wrapping the message
        // causes the bootstrap to search for the wrapper text in the codebase.
        return original
    }

    private static func taskHasUsefulProgress(_ thread: Thread) -> Bool {
        thread.steps.contains { step in
            switch step.kind {
            case .toolCall, .toolResult, .textOutput, .reviewRequest, .reviewResult:
                return !step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .userInput, .aiThinking, .error:
                return false
            }
        }
    }

    private static func relevantFileLimit(settings: AppSettings, connector: ConnectorProfile) -> Int {
        ConnectorCapabilityProfile.infer(for: connector, mode: settings.contextMode).relevantFileLimit
    }

    private static func directOutputLimit(for connector: ConnectorProfile) -> Int? {
        ConnectorCapabilityProfile.infer(for: connector, mode: .balanced).directOutputLimit
    }

    private static func chatPrompt(context: TaskContext, message: String) -> String {
        var prompt = PromptComposer.composeChatPrompt(context: context)
        if UserFrustrationDetector.isFrustrated(message) {
            prompt += "\n\n## 用户纠错/挫败信号\n\(UserFrustrationDetector.guidance)"
        }
        return prompt
    }

    private static func isLocalConnector(_ connector: ConnectorProfile) -> Bool {
        ConnectorCapabilityProfile.isLocalConnector(connector)
    }

    private static func directHistory(for steps: [TaskStep], message: String) -> [TaskStep] {
        // Always carry history in chat sessions — losing context is the #1 complaint.
        // The runtime layer (compactHistory) will handle truncation if history is too long.
        return steps
            .filter { step in
                !step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && step.kind != .aiThinking
                    && step.kind != .reviewRequest
                    && step.kind != .reviewResult
            }
            .suffix(20)
    }

    private static func isTinyFollowUp(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["?", "？", "??", "？？"].contains(normalized)
            || normalized.count <= 4 && ["然后", "继续", "接着", "为啥", "为什么"].contains(where: { normalized.contains($0) })
    }

    private static func isEmptySessionPlaceholder(_ session: ChatSession) -> Bool {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.turns.isEmpty && (title.isEmpty || title == "新线程" || title == "新对话")
    }

    private static func isContinuationCommand(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return normalized.contains("继续")
            || normalized.contains("接着")
            || normalized.contains("续跑")
            || normalized.contains("未完成")
            || normalized.localizedCaseInsensitiveContains("continue")
    }

    private static func isContextualTaskReference(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let threadMarkers = [
            "这个会话", "那个会话", "当前会话", "这轮对话", "那轮对话", "这条对话",
            "新线程", "上下文", "丢了", "丢失", "没上下文"
        ]
        let taskMarkers = [
            "这个任务", "那个任务", "刚才的任务", "上个任务", "读取本地项目",
            "本地项目", "输出没结束", "被截断", "截断了", "没发完", "没写完", "没说完"
        ]
        return threadMarkers.contains { normalized.contains($0) }
            || taskMarkers.contains { normalized.contains($0) }
    }

    /// Detects messages that are likely follow-ups to a recent task even without explicit task references.
    private static func isLikelyTaskFollowUp(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        // Standalone capability/concept questions are NOT task follow-ups
        if isStandaloneCapabilityOrConceptQuestion(normalized) { return false }
        // Standalone fresh-info questions are NOT task follow-ups
        if isStandaloneInfoQuestion(normalized) { return false }
        // Very short messages are almost always follow-ups
        if normalized.count <= 12 { return true }
        // Common follow-up action patterns
        let actionMarkers = [
            "下一步", "接着", "然后", "继续", "再", "还", "另外", "也", "帮我", "改一下", "修一下",
            "优化", "调整", "补充", "完善", "修复", "修改", "改进", "重构", "测试", "运行",
            "确认", "验证", "检查", "看看", "核对", "对比", "比较", "分析一下", "总结一下",
            "刚才", "之前", "上面的", "这样", "那样", "把它", "把这个", "把那个"
        ]
        if actionMarkers.contains(where: { normalized.contains($0) }) { return true }
        // Short questions are usually follow-ups
        if (normalized.hasSuffix("？") || normalized.hasSuffix("?")) && normalized.count <= 24 {
            return true
        }
        return false
    }

    private static func shouldRouteChatFollowUpIntoSelectedTask(message: String, task: AgentTask) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if isStandaloneCapabilityOrConceptQuestion(normalized) {
            return false
        }
        if taskHasTruncatedOutput(task), isTruncationContinuation(normalized) {
            return true
        }
        if UserFrustrationDetector.shouldRecoverRecentTask(normalized) {
            return true
        }
        if isTinyFollowUp(normalized) || isContinuationCommand(normalized) || isTaskStatusQuestion(normalized) || isLikelyTaskFollowUp(normalized) {
            return true
        }

        let explicitTaskMarkers = ["这个任务", "那个任务", "这个会话", "那个会话", "当前会话", "这轮对话", "这条任务", "刚才", "最近的", "最近这个", "上个", "上一轮", "前面", "上面", "上下文", "新线程", "丢失", "接着这个", "继续这个"]
        if explicitTaskMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        let taskActionMarkers = ["再读", "补读", "继续读", "总结", "列出", "修复", "修改", "优化", "跑一下", "测试一下", "重新跑", "重试", "按这个", "基于这个", "把它"]
        if taskActionMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        let pronounOnlyMarkers = ["这个", "那个", "它", "这里", "上面的"]
        if normalized.count <= 16, pronounOnlyMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        let lastUserInput = task.steps.reversed().first { $0.kind == .userInput }?.text ?? task.title
        let sharedKeywords = semanticOverlapKeywords(in: normalized).intersection(semanticOverlapKeywords(in: lastUserInput))
        return sharedKeywords.count >= 2
    }

    private static func isStandaloneInfoQuestion(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasSuffix("？") || normalized.hasSuffix("?") else { return false }
        let infoStarts = ["今天", "最近", "最新", "现在", "有什么新", "有哪些新"]
        let infoTopics = ["新闻", "消息", "动态", "进展", "更新", "发布"]
        let startsLike = infoStarts.contains { normalized.hasPrefix($0) }
        let hasTopic = infoTopics.contains { normalized.contains($0) }
        return startsLike && hasTopic
    }

    private static func isStandaloneCapabilityOrConceptQuestion(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasSuffix("？") || normalized.hasSuffix("?") || normalized.contains("吗") else { return false }
        let capabilityStarts = [
            "你能", "你现在能", "你可以", "你会", "能不能", "能否", "是否可以",
            "可不可以", "会不会", "你支持", "你是什么", "你是谁"
        ]
        let conceptStarts = ["什么是", "为什么", "怎么理解", "如何理解"]
        let startsLikeStandalone = capabilityStarts.contains { normalized.hasPrefix($0) }
            || conceptStarts.contains { normalized.hasPrefix($0) }
        guard startsLikeStandalone else { return false }
        let taskAnchors = [
            "这个任务", "这条任务", "刚才", "上面", "前面", "继续", "接着", "被截断",
            "没发完", "文件", "代码", "项目", "报错", "工具失败"
        ]
        return !taskAnchors.contains { normalized.contains($0) }
    }

    private static func taskHasTruncatedOutput(_ task: AgentTask) -> Bool {
        task.steps.contains { step in
            step.text.contains("输出达到当前上限")
                || step.text.contains("回复已被截断")
                || step.text.contains("输出上限截断")
                || step.text.contains("内容可能被截断")
        }
    }

    private static func isTruncationContinuation(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let markers = [
            "接着说", "继续输出", "继续说", "接着输出", "没发完", "没写完",
            "没说完", "没结束", "被截断", "截断了", "断了", "后面呢",
            "剩下的", "接上", "继续"
        ]
        return markers.contains { normalized.contains($0) }
    }

    private static func semanticOverlapKeywords(in text: String) -> Set<String> {
        let normalized = text.lowercased()
        let stopwords: Set<String> = ["这个", "那个", "一下", "为什么", "怎么", "什么", "可以", "是不是", "我", "你", "帮我", "请", "的", "了", "吧", "吗", "呢"]
        var tokens: [String] = []
        var current = ""
        for scalar in normalized.unicodeScalars {
            let isAsciiToken = CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "." || scalar == "-"
            let isHan = scalar.value >= 0x4E00 && scalar.value <= 0x9FFF
            if isAsciiToken || isHan {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return Set(tokens.filter { $0.count >= 2 && !stopwords.contains($0) })
    }

    private static func isTaskStatusQuestion(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let statusMarkers = ["什么情况", "怎么了", "哪里失败", "失败原因", "几个工具失败", "工具失败", "没完成", "卡住", "还在执行", "执行中", "进度", "状态"]
        let whyAboutCurrentTask = (normalized.contains("为什么") || normalized.contains("为啥"))
            && ["失败", "没完成", "卡住", "中断", "新线程", "上下文", "任务", "工具"].contains { normalized.contains($0) }
        let asksStatus = statusMarkers.contains { normalized.contains($0) }
            || whyAboutCurrentTask
            || ["?", "？"].contains(normalized)
        guard asksStatus else { return false }
        let actionMarkers = ["继续执行", "继续做", "继续任务", "重试", "重新跑", "改", "修复", "写入", "读取", "搜索", "联网", "跑测试", "接着说", "继续输出", "没发完", "没写完", "没说完", "被截断"]
        return !actionMarkers.contains { normalized.contains($0) }
    }

    private static func taskStatusAnswer(for task: AgentTask, question: String) -> String {
        let toolCalls = task.steps.filter { $0.kind == .toolCall }.count
        let failures = task.steps.filter { $0.isFailure || $0.kind == .error }
        let failedTools = task.steps.filter { $0.kind == .toolResult && $0.isFailure }
        let lastOutput = task.steps.reversed().first {
            $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastFailure = failures.last?.text.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = []
        lines.append("这条任务当前是“\(task.status.title)”。")
        if toolCalls > 0 {
            lines.append("已经调用过 \(toolCalls) 次工具，其中失败 \(failedTools.count) 次。")
        }
        if !failedTools.isEmpty {
            let grouped = Dictionary(grouping: failedTools, by: { $0.toolName ?? "tool" })
                .map { "\($0.key) ×\($0.value.count)" }
                .sorted()
                .joined(separator: "、")
            lines.append("失败主要来自：\(grouped)。")
        }
        if let lastFailure, !lastFailure.isEmpty {
            lines.append("最近的失败信息是：\(String(lastFailure.prefix(180)))")
        }
        if let lastOutput, !lastOutput.isEmpty {
            lines.append("已经形成过阶段性输出：\(String(lastOutput.prefix(220)))")
        }

        let hasShellFailure = failedTools.contains { $0.toolName == "shell.exec" }
        if hasShellFailure {
            lines.append("判断：它不是单纯“模型不会做”，而是执行路径不稳。模型多次尝试 shell 命令列项目文件，其中部分命令被安全策略或系统退出码拦住。更好的下一步是走受控的项目索引/文件读取，而不是继续让模型自由拼 shell。")
        } else if !failedTools.isEmpty {
            lines.append("判断：任务有工具失败，需要换执行路径或补充目标后续跑。")
        } else if task.status == .completed {
            lines.append("判断：任务已完成。如果你追问细节，我会基于这条任务已有上下文解释，不再重复调用工具。")
        } else {
            lines.append("判断：任务没有检测到明确工具失败，但还需要补充下一步目标。")
        }
        lines.append("建议下一步：先让来财总结已读到的项目结构，再按关键模块继续读取；需要改代码时再进入审查写入。")
        return lines.joined(separator: "\n")
    }

    private static func markStaleRunningTasks(in state: inout AppState, now: Date = .now) {
        let timeout: TimeInterval = 20 * 60
        for index in state.threads.indices where state.threads[index].source == .task {
            let shouldCancelRunning = state.threads[index].status == .running
            let shouldCancelStaleReview = state.threads[index].status == .waitingReview
                && now.timeIntervalSince(state.threads[index].updatedAt) > timeout
            guard shouldCancelRunning || shouldCancelStaleReview else { continue }
            state.threads[index].status = .cancelled
            state.threads[index].updatedAt = now
            if state.threads[index].steps.contains(where: { $0.kind == .error && $0.text.contains("上次运行被中断") }) {
                continue
            }
            state.threads[index].steps.append(TaskStep(
                kind: .error,
                text: "上次运行被中断，已自动标记为已暂停。可以从这条任务继续或重新发送。",
                isFailure: false,
                recoverable: true,
                retryAction: "继续"
            ))
            ensureCheckpointIfNeeded(&state.threads[index])
        }
    }

    nonisolated static func mergePersistedThreads(_ incoming: [Thread], into state: inout AppState) {
        guard !incoming.isEmpty else { return }

        for thread in incoming {
            if let index = state.threads.firstIndex(where: { $0.id == thread.id }) {
                if thread.updatedAt >= state.threads[index].updatedAt {
                    state.threads[index] = thread
                }
            } else {
                state.threads.append(thread)
            }
        }

        state.threads.sort { $0.updatedAt > $1.updatedAt }

        if let selectedID = state.selectedThreadID,
           !state.threads.contains(where: { $0.id == selectedID }) {
            state.selectThread(id: nil)
        }
    }

    private func persistThreads() {
        updateSummaryCaches()
        do { try environment.threadRepository.saveThreads(state.threads) }
        catch { recordToolActivity(name: "threads.save", summary: "线程持久化失败", statusLine: error.localizedDescription, isFailure: true) }
    }

    /// For threads with >20 steps, generate a summary cache of early steps
    /// so that continuation runs don't need to re-compress the full history.
    private func updateSummaryCaches() {
        let summaryThreshold = 20
        for index in state.threads.indices {
            let thread = state.threads[index]
            guard thread.steps.count > summaryThreshold else { continue }
            // Only regenerate if cache is stale (fewer steps cached than current - recent)
            let recentStepCount = min(14, thread.steps.count)
            let earlyStepsCount = thread.steps.count - recentStepCount
            let needsUpdate: Bool
            if let cache = thread.summaryCache {
                // Regenerate if cache doesn't mention enough early steps
                needsUpdate = !cache.contains("\(earlyStepsCount) 条早期步骤")
            } else {
                needsUpdate = true
            }
            guard needsUpdate else { continue }
            state.threads[index].summaryCache = Self.generateSummaryCache(for: thread)
        }
    }

    nonisolated static func generateSummaryCache(for thread: Thread) -> String {
        let recentStepCount = min(14, thread.steps.count)
        let earlySteps = thread.steps.dropLast(recentStepCount)
        guard !earlySteps.isEmpty else { return "" }

        var lines = ["\(earlySteps.count) 条早期步骤摘要"]
        // Collect key info from early steps
        let readFiles = uniqueValues(
            earlySteps.filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
                .compactMap { $0.toolParams?["path"] }
        )
        let searchedQueries = uniqueValues(
            earlySteps.filter { $0.kind == .toolCall && $0.toolName == "code.search" }
                .compactMap { $0.toolParams?["query"] }
        )
        let failedTools = earlySteps.filter { $0.kind == .toolResult && $0.isFailure }
            .map { "\($0.toolName ?? "工具") 失败" }
        let conclusions = earlySteps.filter { $0.kind == .textOutput }
            .suffix(3)
            .map { compactSummaryText($0.text, limit: 260) }

        if !readFiles.isEmpty {
            lines.append("- 已读文件：\(readFiles.prefix(12).joined(separator: "、"))")
        }
        if !searchedQueries.isEmpty {
            lines.append("- 已搜索：\(searchedQueries.prefix(8).joined(separator: "、"))")
        }
        if !failedTools.isEmpty {
            lines.append("- 失败工具：\(uniqueValues(failedTools).prefix(6).joined(separator: "、"))")
        }
        if !conclusions.isEmpty {
            lines.append("- 早期结论：\(conclusions.joined(separator: " / "))")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func uniqueValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    nonisolated private static func compactSummaryText(_ text: String, limit: Int = 260) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(max(0, limit - 1))) + "…"
    }

    private func persistConnectors() {
        do { try environment.connectorRepository.saveConnectors(state.connectors, activeConnectorID: state.activeConnectorID) }
        catch { recordToolActivity(name: "connectors.save", summary: "连接器持久化失败", statusLine: error.localizedDescription, isFailure: true) }
    }

    private func persistSettings() {
        AppSettingsStorage.save(state.settings)
    }

    // MARK: - Engine Initialization (Hooks, Scheduler, Goals, Gateway)

    private func initializeEngines(workspaceRoot: String) {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }

        HookEngine.shared.loadHooks(workspaceRoot: root)

        // Persistent memory engine
        MemoryEngine.shared.open()

        SchedulerEngine.shared.onExecuteTask = { [weak self] message, workflowName in
            guard let self else { return "未初始化" }
            if let wfName = workflowName {
                self.startWorkflow(named: wfName, goal: message)
            } else {
                self.state.draftMessage = message
                self.sendDraft()
            }
            return "已触发"
        }
        SchedulerEngine.shared.start(workspaceRoot: root)

        GoalEngine.shared.onExecuteStep = { [weak self] message, threadID in
            guard let self else { return (false, "未初始化") }
            self.state.draftMessage = message
            self.sendDraft()
            return (true, "已发送")
        }

        MessagingGateway.shared.onProcessMessage = { [weak self] message in
            guard let self else { return "来财未初始化" }
            self.state.draftMessage = message.text
            self.sendDraft()
            return "已处理"
        }

        // Skill composition callbacks
        SkillCompositionEngine.shared.onExecuteStep = { [weak self] message, skillName in
            guard let self else { return ("", false) }
            await MainActor.run {
                self.state.draftMessage = message
                self.sendDraft()
            }
            return (message, true)
        }
        SkillCompositionEngine.shared.onExpandGlob = { glob, wsRoot in
            let dir = URL(fileURLWithPath: wsRoot)
            guard let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }
            let ext = glob.replacingOccurrences(of: "*.", with: "")
            var files: [String] = []
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension == ext { files.append(url.path) }
                if files.count >= 100 { break }
            }
            return files
        }

        // Load workflow chains
        WorkflowChainRegistry.shared.load(workspaceRoot: root)
    }

    // MARK: - Background Agent Support

    public func sendToBackground(threadID: UUID) {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }),
              state.threads[index].status == .running else { return }
        let title = state.threads[index].title
        let bgTaskID = BackgroundTaskManager.shared.startTask(title: title)
        state.threads[index].context.metadata["backgroundTaskID"] = bgTaskID.uuidString
        state.threads[index].context.metadata["isBackground"] = "true"
        notify("任务已转入后台：\(title)", style: .info)
    }

    public func isBackgroundThread(_ threadID: UUID) -> Bool {
        guard let thread = state.threads.first(where: { $0.id == threadID }) else { return false }
        return thread.context.metadata["isBackground"] == "true"
    }

    // MARK: - Goal Management Shortcuts

    public func createGoal(title: String, message: String, steps: [GoalStep] = []) {
        let goal = GoalEngine.shared.createGoal(title: title, message: message, steps: steps)
        notify("目标已创建：\(goal.title)", style: .success)
    }

    public func pauseGoal(id: UUID) { GoalEngine.shared.pauseGoal(id: id) }
    public func resumeGoal(id: UUID) { GoalEngine.shared.resumeGoal(id: id) }
    public func cancelGoal(id: UUID) { GoalEngine.shared.cancelGoal(id: id) }

    // MARK: - Messaging Gateway Shortcuts

    public func startGateway(port: Int = 18789) {
        MessagingGateway.shared.start(workspaceRoot: state.settings.workspacePath, port: port)
        notify("消息网关已启动（端口 \(port)）", style: .success)
    }

    public func stopGateway() {
        MessagingGateway.shared.stop()
        notify("消息网关已停止", style: .info)
    }
}

private enum AppSettingsStorage {
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

// MARK: - Bootstrap

private func migrateFromPythonConnectorCatalog(workspacePath: String) -> ConnectorCatalog? {
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
            state.settings = settings
            let last = URL(fileURLWithPath: settings.workspacePath).lastPathComponent
            if !last.isEmpty { state.workspaceName = last }
        }

        // Load unified threads (auto-migrates from legacy session/task tables if needed)
        if let savedThreads = try? environment.threadRepository.loadThreads(), !savedThreads.isEmpty {
            state.threads = savedThreads
        }

        if let catalog = try? environment.connectorRepository.loadConnectorCatalog(), !catalog.connectors.isEmpty {
            state.connectors = catalog.connectors
            state.activeConnectorID = catalog.activeConnectorID ?? catalog.connectors.first?.id
            state.settings.defaultConnectorName = state.activeConnector?.name ?? catalog.connectors.first?.name ?? state.settings.defaultConnectorName
        } else if let migrated = migrateFromPythonConnectorCatalog(workspacePath: state.settings.workspacePath) {
            state.connectors = migrated.connectors
            state.activeConnectorID = migrated.activeConnectorID ?? migrated.connectors.first?.id
            state.settings.defaultConnectorName = state.activeConnector?.name ?? migrated.connectors.first?.name ?? state.settings.defaultConnectorName
        }

        if state.workspaceName == "来采原生版" { state.workspaceName = "来财原生版" }
        DispatchQueue.main.async { WorkspaceSandbox.shared.workspaceRoot = state.settings.workspacePath }

        // Migrate session titles from first user step
        for index in state.threads.indices where state.threads[index].source == .session {
            if state.threads[index].title.isEmpty || state.threads[index].title == "新对话" || state.threads[index].title == "新线程" {
                let firstMsg = state.threads[index].steps.first(where: { $0.kind == .userInput })?.text ?? ""
                let title = String(firstMsg.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
                if !title.isEmpty { state.threads[index].title = title }
            }
            state.threads[index].preview = normalizedSessionPreview(state.threads[index].preview)
        }

        // Select latest thread
        if let latest = state.threads.first {
            state.selectThread(id: latest.id)
        }

        return state
    }
}
