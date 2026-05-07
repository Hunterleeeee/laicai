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

public enum ExecutionMode: String, CaseIterable, Equatable, Sendable, Codable {
    case auto

    public var title: String { "自动" }
    public var icon: String { "wand.and.stars" }

    public init(from decoder: Decoder) throws {
        let _ = try decoder.singleValueContainer().decode(String.self)
        self = .auto
    }
}

public struct ImageAttachment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let data: Data
    public let mediaType: String
    public let thumbnailName: String
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

    /// Convert to OpenAI vision ContentPart.
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
    public var generationStartedAt: Date?
    public var liveActivity: String
    public var pendingFollowUp: String?
    public var settings: AppSettings
    public var notice: AppNotice?

    // MARK: - Computed compatibility

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

    public var threads_legacy: [ThreadRecord] { threadRecords }
    public var threadSummaries: [ThreadRecord] { threadRecordSummaries }
    public var filteredThreads: [ThreadRecord] { filteredThreadRecords }
    public var filteredThreadSummaries: [ThreadRecord] { filteredThreadRecordSummaries }

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

    /// Legacy init from sessions + tasks.
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
        if let selectedThreadID, selectedThreadSource != nil {
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
