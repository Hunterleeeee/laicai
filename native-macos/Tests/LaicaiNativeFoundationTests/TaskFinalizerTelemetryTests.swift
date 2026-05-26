import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class TaskFinalizerTelemetryTests: LaicaiNativeFoundationTestCase {
    func testExecutionModeLabelUsesKernelMode() {
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
                    emitDebugSteps: false,
                    kernelMode: .legacy
                )
            )
        }

        let readOnlyState = makeState(allowedTools: Set(["file.read"]))
        var codexConfig = AgentLoop.Config(workspaceRoot: root)
        codexConfig.kernelMode = .codexFull
        XCTAssertEqual(TaskFinalizer.executionModeLabel(state: readOnlyState, config: codexConfig), "inspect")

        let writableState = makeState(allowedTools: nil)

        var legacyConfig = AgentLoop.Config(workspaceRoot: root)
        legacyConfig.kernelMode = .legacy
        XCTAssertEqual(TaskFinalizer.executionModeLabel(state: writableState, config: legacyConfig), "legacy")

        var pipelineConfig = AgentLoop.Config(workspaceRoot: root)
        pipelineConfig.kernelMode = .pipeline
        XCTAssertEqual(TaskFinalizer.executionModeLabel(state: writableState, config: pipelineConfig), "pipeline")

        var codexFullConfig = AgentLoop.Config(workspaceRoot: root)
        codexFullConfig.kernelMode = .codexFull
        XCTAssertEqual(TaskFinalizer.executionModeLabel(state: writableState, config: codexFullConfig), "codexFull")

    }
}
