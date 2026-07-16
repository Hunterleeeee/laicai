import XCTest

@testable import LaicaiNativeDomain
@testable import LaicaiNativeFoundation

@MainActor
final class AppStoreThreadStateTests: LaicaiNativeFoundationTestCase {
    func testDeleteSession() {
        let store = AppStore.preview()
        let firstID = store.state.threads.first?.id

        if let id = firstID {
            store.deleteThread(id: id)
            XCTAssertNil(store.state.threads.first(where: { $0.id == id }))
        }
    }
    func testPinSession() throws {
        let store = AppStore.preview()
        let firstID = try XCTUnwrap(store.state.threads.first?.id)
        let wasPinned = store.state.threads.first?.isPinned ?? false

        store.pinThread(id: firstID)
        XCTAssertEqual(store.state.threads.first?.isPinned, !wasPinned)
    }
    func testSelectingSessionClearsSelectedTask() {
        let session = ChatSession(title: "会话", preview: "", modelName: "test")
        let task = AgentTask(title: "任务")
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Build",
                sessions: [session],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [],
                activeConnectorID: nil,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "None",
                    compactComposer: false,
                    showDebugPanels: false),
                tasks: [task],
                selectedTaskID: task.id
            ))

        store.selectThread(id: session.id)

        XCTAssertEqual(store.state.selectedThreadID, session.id)
    }
    func testSelectingTaskSetsAuthoritativeThreadSelection() {
        let session = ChatSession(title: "会话", preview: "", modelName: "test")
        let task = AgentTask(title: "任务")
        let store = AppStore(state: testState(sessions: [session], tasks: [task], selectedThreadID: task.id))

        store.selectThread(id: session.id)
        XCTAssertEqual(store.state.selectedThreadID, session.id)

        store.selectThread(id: task.id)
        XCTAssertEqual(store.state.selectedThreadID, task.id)
    }
    func testUnifiedThreadSearchMatchesTaskStepsAndTools() {
        let session = ChatSession(title: "普通聊天", preview: "你好", modelName: "test")
        let task = AgentTask(
            title: "任务",
            steps: [
                TaskStep(kind: .toolCall, text: "正在读取文件", toolName: "file.read"),
                TaskStep(kind: .toolResult, text: "发现 selectedThreadID 双轨状态"),
            ])
        var state = testState(sessions: [session], tasks: [task])
        state.searchText = "selectedThreadID"

        XCTAssertEqual(state.filteredThreads.map(\.id), [task.id])

        state.searchText = "file.read"
        XCTAssertEqual(state.filteredThreads.map(\.id), [task.id])
    }
    func testSidebarSummarySearchUsesDebouncedQuery() {
        let session = ChatSession(title: "普通聊天", preview: "你好", modelName: "test")
        let task = AgentTask(
            title: "性能优化任务",
            steps: [
                TaskStep(kind: .userInput, text: "优化侧栏卡顿")
            ])
        var state = testState(sessions: [session], tasks: [task])
        state.searchText = "性能"

        XCTAssertEqual(state.filteredThreadRecordSummaries.map(\.id), [task.id])

        state.debouncedSearchText = "普通"
        XCTAssertEqual(state.filteredThreadRecordSummaries.map(\.id), [session.id])
    }
    func testAgentSnapshotInfersWaitingApprovalGoalPlanAndArtifact() {
        var thread = Thread(
            title: "修改文件",
            status: .running,
            steps: [
                TaskStep(kind: .userInput, text: "修改 App.swift"),
                TaskStep(
                    kind: .reviewRequest,
                    text: "准备写入",
                    toolName: "file.write",
                    diffFilePath: "App.swift",
                    diffOldContent: "old",
                    diffNewContent: "new"
                ),
            ]
        )

        AppStore.syncAgentSnapshot(&thread)

        XCTAssertEqual(thread.executionState, .waitingForApproval)
        XCTAssertEqual(thread.goal, "修改 App.swift")
        XCTAssertFalse(thread.currentPlan.isEmpty)
        XCTAssertEqual(thread.artifacts.map(\.path), ["App.swift"])
    }
    func testDeleteTurnUpdatesPreviewToRemainingLastMessage() {
        let first = ChatTurn(role: .user, text: "第一条")
        let second = ChatTurn(role: .assistant, text: "第二条")
        let session = ChatSession(title: "会话", preview: second.text, modelName: "test", turns: [first, second])
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Build",
                sessions: [session],
                selectedSessionID: session.id,
                workbenchTab: .tools,
                connectors: [],
                activeConnectorID: nil,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "None",
                    compactComposer: false,
                    showDebugPanels: false)
            ))

        store.deleteTurn(sessionID: session.id, turnID: second.id)

        XCTAssertEqual(store.state.selectedThread?.steps.map(\.id), [first.id])
        XCTAssertEqual(store.state.selectedThread?.preview, first.text)
    }

    func testWorkbenchAgentsTabTitleUsesSessionWording() {
        XCTAssertEqual(WorkbenchTab.agents.title, "会话")
    }
}
