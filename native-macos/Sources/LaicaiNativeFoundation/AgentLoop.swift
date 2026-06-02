import Foundation
import LaicaiNativeDomain

/// Runs a local task by asking the model, executing requested tools, and feeding results back.
@MainActor
public final class AgentLoop: ObservableObject {
    // G1: Shared repository for persistent memory access
    public static var sharedRepository: SQLiteRepository?

    static let toolCompatibilityFallbackAction = "connector.disableToolCalling"

    let config: Config
    let runtime: any ChatRuntimeClient
    let toolRegistry: ToolRegistry

    // Codex-style steer: inject a user correction into a running loop
    var pendingSteer: String?

    /// Steer: inject a new instruction into the running agent loop.
    /// The message will be inserted as a user message at the next iteration.
    public func steer(_ message: String) {
        pendingSteer = message
    }

    public init(
        config: Config,
        runtime: any ChatRuntimeClient,
        toolRegistry: ToolRegistry? = nil
    ) {
        self.config = config
        self.runtime = runtime
        self.toolRegistry = toolRegistry ?? .shared
    }

    /// Run the agent loop for a user message.
    /// Returns the completed AgentTask with all steps.
    public func run(
        taskID: UUID? = nil,
        message: String,
        intent: UserIntent,
        connector: ConnectorProfile,
        allConnectors: [ConnectorProfile] = [],
        context: TaskContext?,
        priorSteps: [TaskStep] = [],
        summaryCache: String? = nil,
        imageAttachments: [ImageAttachment] = [],
        onStep: @MainActor (TaskStep) -> Void = { _ in },
        onStreamDelta: @Sendable @MainActor (String) -> Void = { _ in },
        onReasoningDelta: @Sendable @MainActor (String) -> Void = { _ in },
        onCheckInterrupt: @MainActor () -> String? = { nil }
    ) async throws -> AgentTask {
        // Delegate to the pipeline orchestrator which stages the work through:
        // ContextBuilder → BootstrapEngine → IterationEngine → ToolExecutionEngine → ResponseHandler → TaskFinalizer
        return try await runPipeline(
            taskID: taskID,
            message: message,
            intent: intent,
            connector: connector,
            allConnectors: allConnectors,
            context: context,
            priorSteps: priorSteps,
            summaryCache: summaryCache,
            imageAttachments: imageAttachments,
            onStep: onStep,
            onStreamDelta: onStreamDelta,
            onReasoningDelta: onReasoningDelta,
            onCheckInterrupt: onCheckInterrupt
        )
    }
}
