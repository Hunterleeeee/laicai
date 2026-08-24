import XCTest

@testable import LaicaiNativeDomain
@testable import LaicaiNativeFoundation

@MainActor
final class TaskFinalizerTelemetryTests: LaicaiNativeFoundationTestCase {
    func testExecutionModeLabelReturnsCodexFullOrInspect() {
        let root = NSTemporaryDirectory()

        func makeState(allowedTools: Set<String>?) -> PipelineState {
            PipelineState(
                task: AgentTask(
                    id: UUID(),
                    title: "telemetry",
                    status: .running,
                    connectorID: UUID(),
                    context: TaskContext()
                ),
                taskContext: TaskContext(),
                connector: ConnectorProfile(
                    name: "Test",
                    kind: "openai-compatible",
                    endpoint: "https://api.example.com/v1/chat/completions",
                    modelName: "gpt-5.5",
                    note: "",
                    health: .ready
                ),
                allConnectors: [],
                intent: .task,
                message: "做点事情",
                imageAttachments: [],
                priorSteps: [],
                summaryCache: nil,
                config: AgentLoop.Config(
                    maxIterations: 1,
                    maxTokensPerTurn: 256,
                    workspaceRoot: root,
                    supportsToolCalling: true,
                    contextMode: .balanced,
                    contextWindow: 200_000,
                    customSystemPrompt: nil,
                    allowedTools: allowedTools,
                    modelName: "gpt-5.5",
                    connectorEndpoint: "https://api.example.com/v1/chat/completions",
                    apiKey: "",
                    emitDebugSteps: false
                )
            )
        }

        let readOnlyState = makeState(allowedTools: Set(["file.read"]))
        let config = AgentLoop.Config(workspaceRoot: root)
        XCTAssertEqual(TaskFinalizer.executionModeLabel(state: readOnlyState, config: config), "inspect")

        let writableState = makeState(allowedTools: nil)
        XCTAssertEqual(TaskFinalizer.executionModeLabel(state: writableState, config: config), "codexFull")
    }
}

    func testOutcomeRouteLabelMatchesIntent() {
        XCTAssertEqual(TaskFinalizer.outcomeRouteLabel(for: .chat), "会话 问答")
        XCTAssertEqual(TaskFinalizer.outcomeRouteLabel(for: .research), "会话 研究")
        XCTAssertEqual(TaskFinalizer.outcomeRouteLabel(for: .task), "会话 执行")
        XCTAssertEqual(TaskFinalizer.outcomeRouteLabel(for: .workflow("code-review")), "会话 工作流")
    }

    func testConfirmationAfterDestructiveClarification() {
        let question = TaskStep(kind: .textOutput, text: "这是一个删除/清空类操作。当前工作区是「demo」，你要清理的是它的测试数据吗？")
        let unrelated = TaskStep(kind: .textOutput, text: "已完成分析。")

        // 上一条助手正文就是反问 → 用户回复放行
        XCTAssertTrue(AppStore.isConfirmationAfterDestructiveClarification(message: "清掉吧", priorSteps: [question]))
        // 没有反问上下文，但消息带确认词 → 放行
        XCTAssertTrue(AppStore.isConfirmationAfterDestructiveClarification(message: "确认，删除测试数据", priorSteps: [unrelated]))
        // 无反问、无确认词 → 仍需反问
        XCTAssertFalse(AppStore.isConfirmationAfterDestructiveClarification(message: "清掉缓存", priorSteps: [unrelated]))
    }
