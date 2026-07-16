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
