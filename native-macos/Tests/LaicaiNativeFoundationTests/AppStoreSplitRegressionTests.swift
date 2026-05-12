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
            selectedTaskID: task.id,
            connectors: [connector],
            activeConnectorID: connector.id
        )
        state.isGenerating = true

        XCTAssertEqual(state.selectedThreadSource, .task)
        XCTAssertEqual(state.selectedTaskID, task.id)
        XCTAssertNil(state.selectedSessionID)
        XCTAssertEqual(state.selectedTask?.title, "Refactor task")
        XCTAssertEqual(state.activeConnector?.id, connector.id)
        XCTAssertEqual(state.pendingReviewCount, 1)
        XCTAssertEqual(state.estimatedProgress ?? -1, 0.25, accuracy: 0.001)
    }

    func testFilteredThreadRecordSummariesSearchesStepText() {
        let session = ChatSession(title: "闲聊", preview: "你好", modelName: "test")
        let task = AgentTask(title: "任务", steps: [
            TaskStep(kind: .toolResult, text: "发现 SplitRegressionNeedle")
        ])
        var state = testState(sessions: [session], tasks: [task])

        state.searchText = "SplitRegressionNeedle"

        XCTAssertEqual(state.filteredThreadRecordSummaries.map(\.id), [task.id])
        XCTAssertEqual(state.filteredThreadRecordSummaries.first?.events.first?.text, "发现 SplitRegressionNeedle")
    }

    func testThreadRecordsHideQueuedEmptyPlaceholdersEvenWithTypedTitle() {
        let placeholder = Thread(
            title: "前段时间比较火的酒馆 是什么东西",
            status: .queued,
            steps: [],
            preview: "",
            source: .session
        )
        let real = Thread(
            title: "真实会话",
            status: .completed,
            steps: [TaskStep(kind: .userInput, text: "你好")],
            preview: "你好",
            source: .session
        )
        let state = testState(threads: [placeholder, real])

        XCTAssertTrue(placeholder.isEmptyPlaceholder)
        XCTAssertEqual(state.threadRecordSummaries.map(\.id), [real.id])
    }

    func testDraftAttachmentAndFollowUpActionsSurviveSplit() {
        let task = AgentTask(title: "任务", status: .running)
        let store = AppStore(state: testState(tasks: [task], selectedTaskID: task.id))

        store.addDraftAttachments([" /tmp/a.swift ", "", "/tmp/a.swift", "/tmp/b.swift"])
        XCTAssertEqual(store.state.draftAttachments, ["/tmp/a.swift", "/tmp/b.swift"])

        store.removeDraftAttachment("/tmp/a.swift")
        XCTAssertEqual(store.state.draftAttachments, ["/tmp/b.swift"])

        let image = ImageAttachment(data: Data([1, 2, 3]), thumbnailName: "shot.png", width: 10, height: 20)
        store.addDraftImage(image)
        XCTAssertEqual(store.state.draftImages.map(\.id), [image.id])

        store.removeDraftImage(id: image.id)
        XCTAssertTrue(store.state.draftImages.isEmpty)

        store.queueFollowUp("继续执行")
        store.submitFollowUp()

        XCTAssertNil(store.state.pendingFollowUp)
        XCTAssertEqual(store.state.draftMessage, "")
        XCTAssertEqual(store.state.selectedTask?.steps.map(\.text), ["继续执行"])
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

        XCTAssertEqual(store.state.selectedTaskID, interrupted.id)
        let resumeHints = store.state.selectedTask?.steps.filter {
            $0.kind == .error && $0.text.contains("自动恢复")
        } ?? []
        XCTAssertEqual(resumeHints.count, 1)
        XCTAssertEqual(resumeHints.first?.retryAction, "继续执行")
    }

    func testPreviewAndVagueMessageHelpersStayAvailableAfterSplit() {
        let providerError = #"请求失败：provider returned {"error":{"type":"invalid_request_error"}}"#
        XCTAssertEqual(normalizedSessionPreview(providerError), "请求失败，请检查连接器配置。")

        let thread = Thread(
            title: "README 任务",
            steps: [
                TaskStep(kind: .userInput, text: "帮我生成 README")
            ],
            source: .task
        )

        XCTAssertEqual(
            AppStore.enrichVagueMessage("继续", thread: thread),
            "继续处理当前任务，优先基于已有证据形成结论；不要重复已完成的读取、搜索或执行步骤。"
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
            ],
            source: .session
        )
        let environment = makeTestEnvironment(threadRepository: FixedThreadRepository(threads: [historical]))

        let state = AppState.bootstrap(environment: environment)

        XCTAssertEqual(state.threads.first?.source, .task)
        XCTAssertEqual(state.selectedTaskID, historical.id)
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
            source: .session,
            projectID: projectID
        )
        let environment = makeTestEnvironment(threadRepository: FixedThreadRepository(threads: [plain]))

        let state = AppState.bootstrap(environment: environment)

        XCTAssertEqual(state.threads.first?.source, .session)
        XCTAssertNil(state.threads.first?.projectID)
        XCTAssertEqual(state.selectedSessionID, plain.id)
    }

    func testPlainNewSessionNeverInheritsActiveProject() {
        let previousActiveProjectID = ProjectManager.shared.activeProjectID
        ProjectManager.shared.activeProjectID = UUID()
        defer { ProjectManager.shared.activeProjectID = previousActiveProjectID }
        let store = AppStore(state: testState())

        store.newSession()

        XCTAssertEqual(store.state.selectedThread?.source, .session)
        XCTAssertNil(store.state.selectedThread?.projectID)
    }

    func testTaskStartedBesideRunningProjectThreadKeepsProjectScope() throws {
        let projectID = UUID()
        let runningProjectThread = Thread(
            title: "项目里正在执行",
            status: .running,
            steps: [TaskStep(kind: .userInput, text: "修复项目问题")],
            source: .task,
            projectID: projectID
        )
        let connector = makeConnector(modelName: "gpt-5.5")
        let store = AppStore(
            state: testState(
                threads: [runningProjectThread],
                selectedTaskID: runningProjectThread.id,
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
            routeLabel: "任务",
            expectedCapabilities: []
        )

        store.sendTaskDraft(message: "整理 README", decision: decision)

        XCTAssertNotEqual(store.state.selectedThreadID, runningProjectThread.id)
        XCTAssertEqual(store.state.selectedThread?.source, .task)
        XCTAssertEqual(store.state.selectedThread?.projectID, projectID)
        store.stopGenerating()
    }
}
