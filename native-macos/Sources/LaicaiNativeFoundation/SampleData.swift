import Foundation
import LaicaiNativeDomain

enum SampleData {
    static let now = Date()

    static let connectors: [ConnectorProfile] = []

    static let sessions: [ChatSession] = []

    static let toolActivities: [ToolActivity] = []

    static let workflowRuns: [WorkflowRun] = []

    static let appState = AppState(
        workspaceName: "来财",
        modeLabel: "聊天",

        threads: sessions.map(Thread.init(session:)),
        selectedThreadID: sessions.first?.id,
        workbenchTab: .tools,
        connectors: connectors,
        activeConnectorID: connectors.first?.id,
        toolActivities: toolActivities,
        workflowRuns: workflowRuns,
        draftMessage: "",
        isGenerating: false,
        settings: AppSettings(
            workspacePath: defaultWorkspacePath(),
            defaultConnectorName: "无模型",
            compactComposer: false,
            showDebugPanels: false
        )
    )
}

private func defaultWorkspacePath() -> String {
    return FileManager.default.homeDirectoryForCurrentUser.path
}
