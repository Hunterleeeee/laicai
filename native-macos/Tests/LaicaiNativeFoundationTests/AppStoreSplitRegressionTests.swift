import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreSplitRegressionTests: LaicaiNativeFoundationTestCase {
    func testAppStateDerivedPropertiesStayConsistentAfterSplit() {
        let connector = ConnectorProfile(
            name: "Test",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test",
            note: "",
            health: .ready
        )
        let task = AgentTask(
            title: "Refactor task",
            status: .running,
            steps: [
                TaskStep(kind: .toolCall, text: "读取文件", toolName: "file.read"),
                TaskStep(kind: .reviewRequest, text: "修改 AppState", diffFilePath: "AppState.swift")
            ],
            connectorID: connector.id,
            context: TaskContext(workspaceRoot: "/tmp", metadata: ["expectedIterations": "4"])
        )

        var state = testState(
            tasks: [task],
            selectedThreadID: task.id,
            connectors: [connector],
            activeConnectorID: connector.id
        )
        state.isGenerating = true

        XCTAssertEqual(state.selectedThreadID, task.id)
        XCTAssertEqual(state.selectedThread?.title, "Refactor task")
        XCTAssertEqual(state.activeConnector?.id, connector.id)
        XCTAssertEqual(state.pendingReviewCount, 1)
        XCTAssertEqual(state.estimatedProgress ?? -1, 0.25, accuracy: 0.001)
    }

    func testFilteredThreadRecordSummariesUsesLightweightIndex() {
        let session = ChatSession(title: "闲聊", preview: "你好", modelName: "test")
        let task = AgentTask(title: "任务", steps: [
            TaskStep(kind: .toolResult, text: "发现 SplitRegressionNeedle")
        ])
        var state = testState(sessions: [session], tasks: [task])

        state.searchText = "SplitRegressionNeedle"

        XCTAssertEqual(state.filteredThreadRecordSummaries.map(\.id), [task.id])
        XCTAssertTrue(state.filteredThreadRecordSummaries.first?.events.isEmpty ?? true)
    }

    func testFilteredThreadRecordSummariesDoesNotScanDeepStepHistory() {
        let oldNeedleStep = TaskStep(kind: .toolResult, text: "发现 OldDeepNeedle")
        let recentStep = TaskStep(kind: .textOutput, text: "普通收尾")
        let task = AgentTask(title: "任务", steps: [oldNeedleStep, recentStep])
        var state = testState(tasks: [task])

        state.searchText = "OldDeepNeedle"

        XCTAssertEqual(state.filteredThreadRecordSummaries.map(\.id), [])
    }

    func testThreadRecordsHideQueuedEmptyPlaceholdersEvenWithTypedTitle() {
        let placeholder = Thread(
            title: "前段时间比较火的酒馆 是什么东西",
            preview: "",
            status: .queued,
            steps: [],
        )
        let real = Thread(
            title: "真实会话",
            preview: "你好",
            status: .completed,
            steps: [TaskStep(kind: .userInput, text: "你好")]
        )
        let state = testState(threads: [placeholder, real])

        XCTAssertTrue(placeholder.isEmptyPlaceholder)
        XCTAssertEqual(state.threadRecordSummaries.map(\.id), [real.id])
    }

    func testThreadDefaultTitleUsesNewSessionLabel() {
        let thread = Thread()

        XCTAssertEqual(thread.title, "新会话")
        XCTAssertTrue(Thread.isPlaceholderTitle("新会话"))
    }

    func testSelectedEmptyPlaceholderStaysVisibleAsDraftAgent() {
        let placeholder = Thread(
            title: "新会话",
            preview: "",
            status: .queued,
            steps: [],
            executionState: .idle
        )
        let real = Thread(
            title: "真实会话",
            preview: "你好",
            status: .completed,
            steps: [TaskStep(kind: .userInput, text: "你好")],
        )
        let state = testState(threads: [placeholder, real], selectedSessionID: placeholder.id)

        XCTAssertTrue(placeholder.isEmptyPlaceholder)
        XCTAssertTrue(state.threadRecordSummaries.contains { $0.id == placeholder.id })
        XCTAssertEqual(state.selectedAgent?.id, placeholder.id)
    }

    func testSelectedEmptyRunningThreadIsNotTreatedAsDraftPlaceholder() {
        let running = Thread(
            title: "你了解易经吗",
            preview: "",
            status: .running,
            steps: [],
            executionState: .running,
            goal: "你了解易经吗"
        )
        var state = testState(threads: [running], selectedThreadID: running.id)
        state.isGenerating = true

        XCTAssertFalse(running.isEmptyPlaceholder)
        XCTAssertEqual(state.threadRecordSummaries.map(\.id), [running.id])
        XCTAssertEqual(state.selectedThread?.id, running.id)
        XCTAssertEqual(state.selectedThread?.executionState, .running)
    }

    func testMultiAgentStartCreatesVisibleInitialSteps() {
        let connector = makeConnector(modelName: "gpt-5.5")
        let store = AppStore(
            state: testState(
                workspacePath: "/tmp/laicai-project",
                connectors: [connector],
                activeConnectorID: connector.id
            ),
            environment: makeTestEnvironment()
        )
        let decision = PlannerDecision(
            intent: .task,
            confidence: 0.9,
            reason: "测试多 Agent",
            routeLabel: "会话 执行",
            expectedCapabilities: ["读取工作区", "提出文件修改"]
        )
        let plan = MultiAgentPlan(
            title: "规划 → 编码",
            agents: [
                AgentNode(role: .planner, connectorID: connector.id),
                AgentNode(role: .coder, connectorID: connector.id)
            ]
        )

        store.executeMultiAgent(
            message: "优化项目 UI 并运行验证",
            context: TaskContext(workspaceRoot: "/tmp/laicai-project"),
            connector: connector,
            plan: plan,
            intent: .task,
            decision: decision
        )

        XCTAssertEqual(store.state.selectedThread?.steps.first?.kind, .userInput)
        XCTAssertTrue(store.state.selectedThread?.steps.contains { $0.kind == .aiThinking && $0.text.contains("多会话协同已创建") } == true)
        XCTAssertNotNil(store.state.selectedThread?.taskProtocol)
        XCTAssertNotNil(store.state.selectedThread?.executionLedger)
        store.stopGenerating()
    }

    func testNewAgentClearsSearchAndDraftState() {
        let store = AppStore(state: testState())
        store.updateSearchText("旧搜索")
        store.updateDraft("旧草稿")
        store.addDraftAttachments(["/tmp/a.swift"])
        store.addDraftImage(ImageAttachment(data: Data([1]), thumbnailName: "a.png", width: 1, height: 1))
        store.queueFollowUp("继续")

        store.newThread()

        XCTAssertEqual(store.state.searchText, "")
        XCTAssertEqual(store.state.draftMessage, "")
        XCTAssertEqual(store.state.draftAttachments, [])
        XCTAssertEqual(store.state.draftImages, [])
        XCTAssertNil(store.state.pendingFollowUp)
        XCTAssertEqual(store.state.selectedAgent?.title, "新对话")
        XCTAssertTrue(store.state.threadRecordSummaries.contains { $0.id == store.state.selectedThreadID })
    }

    func testDraftAttachmentAndFollowUpActionsSurviveSplit() {
        let task = AgentTask(title: "任务", status: .running)
        let store = AppStore(state: testState(tasks: [task], selectedThreadID: task.id))

        store.addDraftAttachments([" /tmp/a.swift ", "", "/tmp/a.swift", "/tmp/b.swift"])
        XCTAssertEqual(store.state.draftAttachments, ["/tmp/a.swift", "/tmp/b.swift"])

        store.removeDraftAttachment("/tmp/a.swift")
        XCTAssertEqual(store.state.draftAttachments, ["/tmp/b.swift"])

        let image = ImageAttachment(data: Data([1, 2, 3]), thumbnailName: "shot.png", width: 10, height: 20)
        store.addDraftImage(image)
        XCTAssertEqual(store.state.draftImages.map(\.id), [image.id])

        store.removeDraftImage(id: image.id)
        XCTAssertTrue(store.state.draftImages.isEmpty)

        store.updateDraft("继续执行")
        store.submitFollowUp()

        XCTAssertEqual(store.state.pendingFollowUp, "继续执行")
        XCTAssertEqual(store.state.draftMessage, "")
        XCTAssertEqual(store.state.selectedThread?.executionLedger?.pendingFollowUp, "继续执行")
        XCTAssertEqual(store.state.selectedThread?.steps.map(\.text), [])

        store.clearPendingFollowUp()
        XCTAssertNil(store.state.pendingFollowUp)
        XCTAssertEqual(store.state.draftMessage, "")
    }

    func testAutoResumeInterruptedTaskAddsSingleRecoverableHint() {
        let interrupted = AgentTask(
            title: "中断任务",
            status: .cancelled,
            steps: [
                TaskStep(
                    kind: .error,
                    text: "上次运行被中断，已自动标记为已暂停。",
                    isFailure: false,
                    recoverable: true
                )
            ],
            updatedAt: Date.now.addingTimeInterval(-60)
        )
        let store = AppStore(state: testState(tasks: [interrupted]))

        store.autoResumeInterruptedTask()
        store.autoResumeInterruptedTask()

        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertTrue(store.state.threads.first?.steps.contains(where: { $0.text.contains("已自动标记") }) == true)
    }

    func testPreviewAndVagueMessageHelpersStayAvailableAfterSplit() {
        let providerError = #"请求失败：provider returned {"error":{"type":"invalid_request_error"}}"#
        XCTAssertEqual(normalizedSessionPreview(providerError), "请求失败，请检查连接器配置。")

        let thread = Thread(
            title: "README 任务",
            steps: [
                TaskStep(kind: .userInput, text: "帮我生成 README")
            ],
        )

        XCTAssertEqual(
            AppStore.enrichVagueMessage("继续", thread: thread),
            "继续处理当前会话，优先基于已有证据形成结论；不要重复已完成的读取、搜索或执行步骤。"
        )
        XCTAssertTrue(AppStore.enrichVagueMessage("做", thread: thread).contains("帮我生成 README"))
        XCTAssertTrue(AppStore.enrichVagueMessage("重试", thread: thread).contains("注意避免之前的失败原因"))
    }

    func testBootstrapPromotesHistoricalSessionWithToolCallsToTask() {
        let historical = Thread(
            title: "生成一个雪碧的介绍图",
            preview: "Request failed",
            status: .failed,
            steps: [
                TaskStep(kind: .userInput, text: "生成一个雪碧的介绍图"),
                TaskStep(kind: .toolCall, text: "生成图片", toolName: "image.generate")
            ]
        )
        let environment = makeTestEnvironment(threadRepository: FixedThreadRepository(threads: [historical]))

        let state = AppState.bootstrap(environment: environment)

        XCTAssertEqual(state.selectedThreadID, historical.id)
    }

    func testBootstrapClearsProjectFromPlainHistoricalSession() {
        let projectID = UUID()
        let plain = Thread(
            title: "普通问题",
            preview: "你好",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "你好"),
                TaskStep(kind: .textOutput, text: "你好")
            ],
            projectID: projectID
        )
        let environment = makeTestEnvironment(threadRepository: FixedThreadRepository(threads: [plain]))

        let state = AppState.bootstrap(environment: environment)

        XCTAssertNil(state.threads.first?.projectID)
        XCTAssertEqual(state.selectedThreadID, plain.id)
    }

    func testPlainNewSessionNeverInheritsActiveProject() {
        let previousActiveProjectID = ProjectManager.shared.activeProjectID
        ProjectManager.shared.activeProjectID = UUID()
        defer { ProjectManager.shared.activeProjectID = previousActiveProjectID }
        let store = AppStore(state: testState())

        store.newThread()

        XCTAssertNil(store.state.selectedThread?.projectID)
    }

    func testTaskStartedBesideRunningProjectThreadKeepsProjectScope() throws {
        let projectID = UUID()
        let runningProjectThread = Thread(
            title: "项目里正在执行",
            status: .running,
            steps: [TaskStep(kind: .userInput, text: "修复项目问题")],
            projectID: projectID
        )
        let connector = makeConnector(modelName: "gpt-5.5")
        let store = AppStore(
            state: testState(
                threads: [runningProjectThread],
                selectedThreadID: runningProjectThread.id,
                workspacePath: "/tmp/laicai-project",
                connectors: [connector],
                activeConnectorID: connector.id
            ),
            environment: makeTestEnvironment()
        )
        store.state.threads[0].status = .running
        let decision = PlannerDecision(
            intent: .task,
            confidence: 0.9,
            reason: "测试任务路由",
            routeLabel: "会话 执行",
            expectedCapabilities: []
        )

        store.sendTaskDraft(message: "整理 README", decision: decision)

        XCTAssertNotEqual(store.state.selectedThreadID, runningProjectThread.id)
        XCTAssertEqual(store.state.selectedThread?.projectID, projectID)
        store.stopGenerating()
    }
}
