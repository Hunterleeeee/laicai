import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreThreadStateTests: LaicaiNativeFoundationTestCase {
    func testDeleteSession() {
        let store = AppStore.preview()
        let firstID = store.state.sessions.first?.id

        if let id = firstID {
            store.deleteSession(id: id)
            XCTAssertNil(store.state.sessions.first(where: { $0.id == id }))
        }
    }
    func testPinSession() {
        let store = AppStore.preview()
        let firstID = try XCTUnwrap(store.state.sessions.first?.id)
        let wasPinned = store.state.sessions.first?.isPinned ?? false

        store.pinSession(id: firstID)
        XCTAssertEqual(store.state.sessions.first?.isPinned, !wasPinned)
    }
    func testSelectingSessionClearsSelectedTask() {
        let session = ChatSession(title: "会话", preview: "", modelName: "test")
        let task = AgentTask(title: "任务")
        let store = AppStore(state: .init(
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
            settings: .init(workspacePath: "/tmp", defaultConnectorName: "None", compactComposer: false, showDebugPanels: false),
            tasks: [task],
            selectedTaskID: task.id
        ))

        store.selectSession(id: session.id)

        XCTAssertEqual(store.state.selectedSessionID, session.id)
        XCTAssertNil(store.state.selectedTaskID)
        XCTAssertEqual(store.state.selectedThreadID, session.id)
        XCTAssertEqual(store.state.selectedThreadSource, .session)
    }
    func testSelectingTaskSetsAuthoritativeThreadSelection() {
        let session = ChatSession(title: "会话", preview: "", modelName: "test")
        let task = AgentTask(title: "任务")
        let store = AppStore(state: testState(sessions: [session], tasks: [task], selectedTaskID: task.id))

        store.selectSession(id: session.id)
        XCTAssertEqual(store.state.selectedThreadID, session.id)
        XCTAssertEqual(store.state.selectedThreadSource, .session)

        store.selectTask(id: task.id)
        XCTAssertEqual(store.state.selectedThreadID, task.id)
        XCTAssertEqual(store.state.selectedThreadSource, .task)
        XCTAssertEqual(store.state.selectedTaskID, task.id)
        XCTAssertNil(store.state.selectedSessionID)
    }
    func testUnifiedThreadSearchMatchesTaskStepsAndTools() {
        let session = ChatSession(title: "普通聊天", preview: "你好", modelName: "test")
        let task = AgentTask(title: "任务", steps: [
            TaskStep(kind: .toolCall, text: "正在读取文件", toolName: "file.read"),
            TaskStep(kind: .toolResult, text: "发现 selectedThreadID 双轨状态")
        ])
        var state = testState(sessions: [session], tasks: [task])
        state.searchText = "selectedThreadID"

        XCTAssertEqual(state.filteredThreads.map(\.id), [task.id])

        state.searchText = "file.read"
        XCTAssertEqual(state.filteredThreads.map(\.id), [task.id])
    }
    func testDeleteTurnUpdatesPreviewToRemainingLastMessage() {
        let first = ChatTurn(role: .user, text: "第一条")
        let second = ChatTurn(role: .assistant, text: "第二条")
        let session = ChatSession(title: "会话", preview: second.text, modelName: "test", turns: [first, second])
        let store = AppStore(state: .init(
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
            settings: .init(workspacePath: "/tmp", defaultConnectorName: "None", compactComposer: false, showDebugPanels: false)
        ))

        store.deleteTurn(sessionID: session.id, turnID: second.id)

        XCTAssertEqual(store.state.selectedSession?.turns.map(\.id), [first.id])
        XCTAssertEqual(store.state.selectedSession?.preview, first.text)
    }
}
