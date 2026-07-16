import Foundation
import LaicaiNativeDomain

extension AppStore {
    func handlePostRunSelfImprovement(completedTask: AgentTask, targetTaskID: UUID) {
        if completedTask.context.metadata["selfImproveTask"] == nil,
            let threadIndex = state.threads.firstIndex(where: { $0.id == targetTaskID })
        {
            let thread = state.threads[threadIndex]
            let report = SessionPostMortem.shared.analyze(thread: thread)
            if report.hasCritical {
                AuditLog.shared.record(
                    tool: "postmortem",
                    input: "thread:\(thread.id)",
                    output: report.summary,
                    success: false
                )
                let precisePrompt = SelfImprovementEngine.shared.generatePreciseFixPrompt(
                    from: report,
                    steps: thread.steps
                )
                triggerPreciseSelfImprovement(prompt: precisePrompt, report: report)
            }
        }

        if completedTask.context.metadata["selfImproveTask"] == nil {
            checkAndTriggerSelfImprovement()
        } else {
            let succeeded = completedTask.status == .completed
            if succeeded {
                SelfImprovementEngine.shared.onImprovementSuccess()
            } else {
                SelfImprovementEngine.shared.onImprovementFailure()
            }
        }
    }

}
