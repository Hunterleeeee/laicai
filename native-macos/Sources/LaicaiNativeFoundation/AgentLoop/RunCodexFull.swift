import Foundation
import LaicaiNativeDomain

extension AgentLoop {
    /// codexFull execution path.
    ///
    /// Reuses the existing full-capability orchestration loop (plan/execute/verify/summarize,
    /// recovery, quality gates, completion checks) by delegating into the legacy full kernel
    /// implementation with compatibility flags disabled.
    public func runCodexFull(
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
        var fullConfig = config
        fullConfig.kernelMode = .codexFull

        let fullKernel = AgentLoop(
            config: fullConfig,
            runtime: runtime,
            toolRegistry: toolRegistry
        )

        return try await fullKernel.run(
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
