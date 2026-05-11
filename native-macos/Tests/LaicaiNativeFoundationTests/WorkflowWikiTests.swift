import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class WorkflowWikiTests: LaicaiNativeFoundationTestCase {
    func testStartWorkflowCreatesTaskAndRunRecord() {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let store = AppStore(state: .init(
            workspaceName: "Test",
            modeLabel: "Build",
            sessions: [],
            selectedSessionID: nil,
            workbenchTab: .workflows,
            connectors: [connector],
            activeConnectorID: connector.id,
            toolActivities: [],
            workflowRuns: [],
            draftMessage: "",
            isGenerating: false,
            settings: .init(workspacePath: "/tmp", defaultConnectorName: "Test", compactComposer: false, showDebugPanels: false)
        ))

        store.startWorkflow(named: "code-review")

        XCTAssertEqual(store.state.workflowRuns.first?.name, "code-review")
        XCTAssertEqual(store.state.workflowRuns.first?.statusLine, "执行中")
        XCTAssertEqual(store.state.tasks.first?.workflowName, "code-review")
        XCTAssertEqual(store.state.selectedTaskID, store.state.tasks.first?.id)
        XCTAssertGreaterThanOrEqual(store.state.tasks.first?.steps.count ?? 0, 2)
        XCTAssertEqual(store.state.tasks.first?.steps[1].kind, .aiThinking)
        XCTAssertTrue(store.state.tasks.first?.steps[1].text.contains("规划：工作流") == true)
    }
    func testWorkflowParserSupportsFailureStrategyConditionsAndPromptBlocks() {
        let source = """
        name: custom-review
        description: 自定义审查
        steps:
          - name: 搜索
            tool: code.search
            on_failure: skip
            params:
              query: AppStore
              scope: content
          - name: 总结
            tool: llm
            when: previous.success
            prompt: |
              请总结：
              {{previous.output}}
        """

        let workflow = WorkflowParser.parse(source)

        XCTAssertEqual(workflow?.name, "custom-review")
        XCTAssertEqual(workflow?.steps.count, 2)
        XCTAssertEqual(workflow?.steps.first?.onFailure, "skip")
        XCTAssertEqual(workflow?.steps.first?.params["query"], "AppStore")
        XCTAssertEqual(workflow?.steps.last?.condition, "previous.success")
        XCTAssertTrue(workflow?.steps.last?.prompt?.contains("{{previous.output}}") == true)
    }
    func testWorkflowLibraryLoadsCustomYamlFromWorkspace() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let dir = workspace.appendingPathComponent(".laicai/workflows", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        name: custom
        description: custom workflow
        steps:
          - name: list
            tool: shell.exec
            params:
              command: pwd
        """.write(to: dir.appendingPathComponent("custom.yaml"), atomically: true, encoding: .utf8)

        let workflows = WorkflowLibrary.available(workspaceRoot: workspace.path)

        XCTAssertTrue(workflows.contains { $0.name == "custom" })
        XCTAssertTrue(workflows.contains { $0.name == "code-review" })
    }
    func testSkillRegistryCreatesAndLoadsLocalDraft() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = SkillRegistry.shared

        let skill = try registry.createDraft(
            name: "整理日报",
            description: "生成项目日报",
            tools: ["code.search", "file.read"],
            workspaceRoot: workspace.path
        )
        registry.refresh(workspaceRoot: workspace.path)

        XCTAssertFalse(skill.isBuiltin)
        XCTAssertTrue(registry.skills.contains { $0.name == "整理日报" })
        XCTAssertTrue(SkillRegistry.loadLocalSkills(workspaceRoot: workspace.path).contains { $0.name == "整理日报" })
    }
    func testBootstrapSelectsLatestThreadAcrossSessionsAndTasks() {
        let olderSession = ChatSession(
            title: "旧线程",
            preview: "",
            updatedAt: Date(timeIntervalSince1970: 10),
            category: .engineering,
            modelName: "test"
        )
        let newerTask = AgentTask(
            title: "新任务",
            status: .completed,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let environment = AppEnvironment(
            runtimeClient: PreviewChatRuntime(),
            sessionRepository: FixedSessionRepository(sessions: [olderSession]),
            connectorRepository: NoopConnectorRepository(),
            taskRepository: FixedTaskRepository(tasks: [newerTask]),
            threadRepository: NoopThreadRepository()
        )

        let state = AppState.bootstrap(environment: environment)

        XCTAssertEqual(state.selectedTaskID, newerTask.id)
        XCTAssertNil(state.selectedSessionID)
        XCTAssertEqual(state.selectedThreadID, newerTask.id)
        XCTAssertEqual(state.selectedThreadSource, .task)
    }
    func testBootstrapRestoresPersistedThreadSnapshotAsAuthoritativeSource() {
        let staleSession = ChatSession(
            title: "旧标题",
            preview: "旧",
            updatedAt: Date(timeIntervalSince1970: 10),
            category: .engineering,
            modelName: "test",
            turns: [ChatTurn(role: .user, text: "旧")]
        )
        let restoredTask = AgentTask(
            id: staleSession.id,
            title: "已升级任务",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "读取项目"),
                TaskStep(kind: .textOutput, text: "完成")
            ],
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let environment = AppEnvironment(
            runtimeClient: PreviewChatRuntime(),
            sessionRepository: FixedSessionRepository(sessions: [staleSession]),
            connectorRepository: NoopConnectorRepository(),
            taskRepository: FixedTaskRepository(tasks: []),
            threadRepository: FixedThreadRepository(threads: [Thread(task: restoredTask)])
        )

        let state = AppState.bootstrap(environment: environment)

        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertEqual(state.tasks.first?.id, restoredTask.id)
        XCTAssertEqual(state.tasks.first?.title, "已升级任务")
        XCTAssertEqual(state.selectedThreadID, restoredTask.id)
        XCTAssertEqual(state.selectedThreadSource, .task)
    }
    func testBootstrapCancelsStaleRunningTasks() {
        let staleTask = AgentTask(
            title: "旧任务",
            status: .running,
            updatedAt: Date(timeIntervalSinceNow: -3600)
        )
        let store = AppStore(
            state: testState(tasks: [staleTask], selectedTaskID: staleTask.id),
            environment: AppEnvironment(
                runtimeClient: PreviewChatRuntime(),
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        XCTAssertEqual(store.state.tasks.first?.status, .cancelled)
        XCTAssertTrue(store.state.tasks.first?.steps.contains { $0.text.contains("上次运行被中断") } == true)
        XCTAssertTrue(store.state.tasks.first?.steps.contains { $0.text.hasPrefix("任务检查点") } == true)
        XCTAssertEqual(store.state.selectedTaskID, staleTask.id)
    }
    func testWikiPreviewDoesNotWriteUntilSaved() async throws {
        let vault = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: vault) }
        let notes = vault.appendingPathComponent("02 Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "# Python\nPython is useful for automation.".write(to: notes.appendingPathComponent("python.md"), atomically: true, encoding: .utf8)

        let preview = try await WikiBuildTool().execute(
            argumentsJSON: #"{"topic":"Python","save":false}"#,
            context: TaskContext(workspaceRoot: vault.path, vaultRoot: vault.path)
        )

        XCTAssertTrue(preview.success)
        XCTAssertEqual(preview.data?["saved"], "false")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent("02 Atomic/Python.md").path))
        XCTAssertTrue(preview.output.contains("[[python]]"))
    }
    func testWikiSaveWritesTopicPage() async throws {
        let vault = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: vault) }

        let saved = try await WikiBuildTool().execute(
            argumentsJSON: #"{"topic":"Python","save":true}"#,
            context: TaskContext(workspaceRoot: vault.path, vaultRoot: vault.path)
        )

        let target = vault.appendingPathComponent("02 Atomic/Python.md")
        XCTAssertTrue(saved.success)
        XCTAssertEqual(saved.data?["saved"], "true")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains(#"topic: "Python""#))
    }
    func testWikiEngineReturnsSourcesAndDiffForExistingTopic() async throws {
        let vault = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: vault) }
        let notes = vault.appendingPathComponent("02 Notes", isDirectory: true)
        let topics = vault.appendingPathComponent("02 Atomic", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: topics, withIntermediateDirectories: true)
        try "# AI\n人工智能基础知识包括模型、数据和评估。".write(to: notes.appendingPathComponent("ai.md"), atomically: true, encoding: .utf8)
        try "# 人工智能\n旧内容".write(to: topics.appendingPathComponent("人工智能.md"), atomically: true, encoding: .utf8)

        let result = await WikiEngine.buildTopic(
            topic: "人工智能",
            vaultRoot: vault.path,
            save: false,
            useWeb: false,
            topK: 4
        )

        XCTAssertFalse(result.saved)
        XCTAssertEqual(result.notePath, "02 Atomic/人工智能.md")
        XCTAssertNotNil(result.previousMarkdown)
        XCTAssertTrue(result.diffSummary.contains("更新"))
        XCTAssertTrue(result.sources.contains { $0.path == "02 Notes/ai.md" })
        XCTAssertTrue(result.renderedMarkdown.contains("## Related Notes"))
    }
    func testWikiTopicSanitizesPathSeparators() async throws {
        let vault = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: vault) }

        let saved = try await WikiBuildTool().execute(
            argumentsJSON: #"{"topic":"API/Token: 安全?","save":true}"#,
            context: TaskContext(workspaceRoot: vault.path, vaultRoot: vault.path)
        )

        XCTAssertTrue(saved.success)
        XCTAssertEqual(saved.data?["path"], "02 Atomic/API - Token - 安全.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.appendingPathComponent("02 Atomic/API - Token - 安全.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent("02 Atomic/API/Token: 安全?.md").path))
    }
    func testCompletionCriteriaRequiresSavedWikiForWikiTasks() {
        let task = AgentTask(
            title: "整理到 wiki",
            steps: [
                TaskStep(kind: .userInput, text: "整理到 wiki\n请读取这个附件：/tmp/a.xlsx"),
                TaskStep(kind: .toolCall, text: "读取", toolName: "file.read", toolParams: ["path": "/tmp/a.xlsx"]),
                TaskStep(kind: .toolResult, text: "已读取目录", toolName: "file.read"),
                TaskStep(kind: .textOutput, text: "我会整理成 Wiki。")
            ]
        )

        XCTAssertFalse(AgentLoop.meetsCompletionCriteria(task: task, intent: .task, didComplete: true, hadFailure: false, wasTruncated: false))

        var saved = task
        saved.steps.append(TaskStep(kind: .toolCall, text: "保存 Wiki", toolName: "wiki.build", toolParams: ["topic": "迁移", "save": "true"]))
        saved.steps.append(TaskStep(kind: .toolResult, text: "已保存 Wiki：迁移 → 02 Atomic/迁移.md", toolName: "wiki.build", toolParams: ["save": "true"]))

        XCTAssertTrue(AgentLoop.meetsCompletionCriteria(task: saved, intent: .task, didComplete: true, hadFailure: false, wasTruncated: false))
    }
}
