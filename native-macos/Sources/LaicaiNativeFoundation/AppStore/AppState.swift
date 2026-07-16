import Foundation
import LaicaiNativeDomain

public struct AppState: Equatable {
    public var workspaceName: String
    public var modeLabel: String
    public var executionMode: ExecutionMode
    public var searchText: String
    public var debouncedSearchText: String
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

    // Cache invalidation token — increment to force recomputation
    public var threadSummaryGeneration: UInt64 = 0

    public init(
        workspaceName: String,
        modeLabel: String,
        executionMode: ExecutionMode = .auto,
        searchText: String = "",
        debouncedSearchText: String = "",
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
        self.debouncedSearchText = debouncedSearchText
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
        debouncedSearchText: String = "",
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
        notice: AppNotice? = nil
    ) {
        self.workspaceName = workspaceName
        self.modeLabel = modeLabel
        self.executionMode = executionMode
        self.searchText = searchText
        self.debouncedSearchText = debouncedSearchText
        self.threads = sessions.map(Thread.init(session:)) + tasks.map(Thread.init(task:))
        if let selectedThreadID {
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

}

extension AppState {
    /// Production startup state. Preview/demo content lives exclusively in SampleData.
    public static var empty: AppState {
        AppState(
            workspaceName: "来财",
            modeLabel: "会话 问答",
            threads: [],
            selectedThreadID: nil,
            workbenchTab: .tools,
            connectors: [],
            activeConnectorID: nil,
            toolActivities: [],
            workflowRuns: [],
            draftMessage: "",
            isGenerating: false,
            settings: AppSettings(
                workspacePath: "",
                defaultConnectorName: "无模型",
                compactComposer: false,
                showDebugPanels: false
            )
        )
    }
}
