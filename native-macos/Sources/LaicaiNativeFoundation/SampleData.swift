import Foundation
import LaicaiNativeDomain

enum SampleData {
    static let now = Date()

    static let connectors: [ConnectorProfile] = [
        ConnectorProfile(
            name: "Preview", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "preview-model", note: "",
            health: .ready),
        ConnectorProfile(
            name: "Preview Local", kind: "ollama", endpoint: "http://127.0.0.1:11434/v1", modelName: "qwen3.5:9b-q4_K_M", note: "",
            health: .ready),
    ]

    static let sessions: [ChatSession] = [
        ChatSession(
            title: "欢迎",
            preview: "你好，我是来财。",
            category: .engineering,
            modelName: "preview-model",
            turns: [
                ChatTurn(role: .user, text: "你好"),
                ChatTurn(role: .assistant, text: "你好，我是来财。"),
            ]
        )
    ]

    static let toolActivities: [ToolActivity] = []

    static let workflowRuns: [WorkflowRun] = []

    static let appState = AppState(
        workspaceName: "来财",
        modeLabel: "会话 问答",

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
    // Never default to home directory — that gives the agent access to everything.
    // An empty path forces the user to set a project-specific workspace.
    return ""
}
