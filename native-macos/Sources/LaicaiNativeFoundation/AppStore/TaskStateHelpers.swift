import Foundation
import LaicaiNativeDomain

extension AppStore {
    func absolutePath(for path: String, workspaceRoot: String) -> String {
        if path.hasPrefix("/") { return path }
        return (workspaceRoot as NSString).appendingPathComponent(path)
    }

    func notify(_ message: String, style: AppNoticeStyle = .info) {
        state.notice = AppNotice(message: message, style: style)
    }

    static func agentLoopConfig(settings: AppSettings, connector: ConnectorProfile? = nil) -> AgentLoop.Config {
        let profile = ConnectorCapabilityProfile.infer(for: connector, mode: settings.contextMode)
        return AgentLoop.Config(
            maxIterations: profile.maxIterations,
            maxTokensPerTurn: profile.maxTokensPerTurn,
            workspaceRoot: settings.workspacePath,
            supportsToolCalling: profile.supportsToolCalling,
            contextMode: settings.contextMode,
            contextWindow: profile.contextWindow,
            modelName: connector?.modelName ?? "",
            usePipeline: settings.usePipeline
        )
    }

    static func agentLoopConfig(settings: AppSettings, connector: ConnectorProfile? = nil, decision: PlannerDecision) -> AgentLoop.Config {
        var config = agentLoopConfig(settings: settings, connector: connector)
        let needsProjectDepth = decision.expectedCapabilities.contains("读取工作区")
            || decision.expectedCapabilities.contains("提出文件修改")
            || {
                if case .workflow = decision.intent { return true }
                return false
            }()
        if needsProjectDepth {
            // Ensure at least the mode's iteration budget — profile already handles local vs remote caps
            config.maxIterations = max(config.maxIterations, settings.contextMode.maxIterations)
        }
        return config
    }

    static func plannerStepText(for decision: PlannerDecision) -> String {
        var lines = [
            "规划：\(decision.routeLabel) · 置信度 \(Int((decision.confidence * 100).rounded()))%",
            decision.reason
        ]
        if !decision.expectedCapabilities.isEmpty {
            lines.append("预计使用：\(decision.expectedCapabilities.joined(separator: "、"))")
        }
        return lines.joined(separator: "\n")
    }

    static func workflowCompletionCheckStep(steps: [TaskStep], hasError: Bool) -> TaskStep {
        let toolFailures = steps.filter { $0.kind == .toolResult && $0.isFailure }.count
        let text = hasError
            ? "完成检查：工作流发现 \(toolFailures) 个失败步骤，建议展开失败项后重试或调整目标。"
            : "完成检查：工作流已完成，未发现失败步骤。"
        return TaskStep(
            kind: .aiThinking,
            text: text,
            isCollapsible: true,
            isCollapsed: true,
            isFailure: hasError
        )
    }

    static func relevantFileLimit(settings: AppSettings, connector: ConnectorProfile) -> Int {
        ConnectorCapabilityProfile.infer(for: connector, mode: settings.contextMode).relevantFileLimit
    }

    static func directOutputLimit(for connector: ConnectorProfile) -> Int? {
        ConnectorCapabilityProfile.infer(for: connector, mode: .balanced).directOutputLimit
    }

    static func chatPrompt(context: TaskContext, message: String) -> String {
        var prompt = PromptComposer.composeChatPrompt(context: context)
        if UserFrustrationDetector.isFrustrated(message) {
            prompt += "\n\n## 用户纠错/挫败信号\n\(UserFrustrationDetector.guidance)"
        }
        return prompt
    }

    static func isLocalConnector(_ connector: ConnectorProfile) -> Bool {
        ConnectorCapabilityProfile.isLocalConnector(connector)
    }

    static func directHistory(for steps: [TaskStep], message: String) -> [TaskStep] {
        // Always carry history in chat sessions — losing context is the #1 complaint.
        // The runtime layer (compactHistory) will handle truncation if history is too long.
        return steps
            .filter { step in
                !step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && step.kind != .aiThinking
                    && step.kind != .reviewRequest
                    && step.kind != .reviewResult
            }
            .suffix(20)
    }

    nonisolated static func mergePersistedThreads(_ incoming: [Thread], into state: inout AppState) {
        guard !incoming.isEmpty else { return }

        for thread in incoming {
            if let index = state.threads.firstIndex(where: { $0.id == thread.id }) {
                if thread.updatedAt >= state.threads[index].updatedAt {
                    state.threads[index] = thread
                }
            } else {
                state.threads.append(thread)
            }
        }

        state.threads.sort { $0.updatedAt > $1.updatedAt }

        if let selectedID = state.selectedThreadID,
           !state.threads.contains(where: { $0.id == selectedID }) {
            state.selectThread(id: nil)
        }
    }

}
