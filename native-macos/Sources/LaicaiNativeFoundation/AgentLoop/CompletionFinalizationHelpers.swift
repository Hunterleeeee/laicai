import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    struct EvidenceFinalizationRequest {
        let task: AgentTask
        let originalMessage: String
        let connector: ConnectorProfile
        let runtime: any ChatRuntimeClient
        let systemPrompt: String
        let maxOutputTokens: Int
    }

    static func completionCheckStep(
        for task: AgentTask, didComplete: Bool, hadFailure: Bool, wasTruncated: Bool = false, isReadOnlyRun: Bool = false
    )
        -> TaskStep
    {
        let toolFailures = task.steps.filter { $0.kind == .toolResult && $0.isFailure }.count
        let hasRecoverySuccess = task.steps.contains {
            $0.kind == .toolResult && !$0.isFailure && $0.text.contains("自动恢复成功")
        }
        let hasOutput = task.steps.contains {
            $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasApprovedWrite = task.steps.contains { $0.kind == .reviewRequest && $0.approved == true }
        let hasVerificationFailure = task.steps.contains {
            ["shell.exec", "verify.build"].contains($0.toolName ?? "") && $0.kind == .toolResult && $0.isFailure
        }
        let hasSatisfiedImageGeneration = Self.hasSatisfiedImageGenerationRequest(task)

        let text: String
        let isFailure: Bool
        if wasTruncated {
            text = "完成检查：回复被输出上限截断，尚未形成完整最终回复。请继续输出时沿用当前会话 上下文。"
            isFailure = false
        } else if hasSatisfiedImageGeneration {
            text =
                toolFailures > 0
                ? "完成检查：图片已成功生成；后续重复生图失败已记录，不影响本次图片交付。"
                : "完成检查：图片已成功生成。"
            isFailure = false
        } else if isReadOnlyRun && didComplete && hasOutput {
            text =
                toolFailures > 0
                ? "完成检查：已形成只读结论；\(toolFailures) 个工具失败被作为证据记录，不再自动升级为执行或重试。"
                : "完成检查：已形成只读结论，未发现失败工具。"
            isFailure = false
        } else if hasApprovedWrite && hasVerificationFailure {
            text = "完成检查：已批准写入但验证失败，建议根据错误信息生成修正 patch 并重新审查。"
            isFailure = true
        } else if toolFailures > 0 && didComplete && hasOutput {
            text = "完成检查：\(toolFailures) 个工具失败已被后续成功操作绕过，已形成最终回复。"
            isFailure = false
        } else if (hadFailure || toolFailures > 0) && !(didComplete && hasRecoverySuccess) {
            text = "完成检查：发现 \(toolFailures) 个工具失败或模型错误，建议根据错误步骤重试或换一个执行路径。"
            isFailure = true
        } else if toolFailures > 0 && hasRecoverySuccess {
            text = "完成检查：发现 \(toolFailures) 个工具失败，但已自动降级恢复并形成最终回复。"
            isFailure = false
        } else if !didComplete || !hasOutput {
            text = "完成检查：会话 没有形成明确输出，建议继续追问或补充目标。"
            isFailure = false
        } else {
            text = "完成检查：已形成最终回复，未发现失败工具。"
            isFailure = false
        }
        return TaskStep(
            kind: .aiThinking,
            text: text,
            isCollapsible: true,
            isCollapsed: true,
            isFailure: isFailure
        )
    }

    static func finalizeFromCollectedEvidence(_ request: EvidenceFinalizationRequest) async throws -> TaskStep? {
        let evidence = request.task.steps
            .filter { $0.kind == .toolResult || $0.kind == .textOutput || $0.kind == .error }
            .suffix(12)
            .map { step -> String in
                let label: String
                switch step.kind {
                case .toolResult:
                    label = "工具结果\(step.toolName.map { "(\($0))" } ?? "")"
                case .textOutput:
                    label = "中间输出"
                case .error:
                    label = step.isFailure ? "错误" : "提示"
                default:
                    label = "记录"
                }
                return "- \(label)：\(compactSummaryText(step.text, limit: 700))"
            }
            .joined(separator: "\n")

        guard !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Check if any real execution happened
        let hasExecution = request.task.steps.contains { step in
            step.kind == .toolCall
                && (isFileChangeTool(step.toolName ?? "") || step.toolName == "document.transform" || step.toolName == "shell.exec")
        }

        let prompt: String
        if hasExecution {
            prompt = """
                本轮处理已结束，不要再调用工具。
                请基于下面已收集的真实结果，给用户一个简明最终回复：
                1. 已经执行了什么操作，结果如何
                2. 还没完成什么，为什么
                3. 用户接下来应该怎么做

                用户原始目标：
                \(request.originalMessage)

                已收集结果：
                \(evidence)
                """
        } else {
            prompt = """
                本轮处理已结束，不要再调用工具，也不要写研究报告。
                你只做了搜索和读取，没有真正执行任何操作。请直接告诉用户：
                1. 根据你收集的信息，用户应该运行什么具体命令来完成目标
                2. 给出可直接复制粘贴的命令（如 npm install、pip install、git clone 等）
                3. 如果需要创建文件，给出文件内容

                不要长篇分析。给出行动方案。

                用户原始目标：
                \(request.originalMessage)

                已收集结果：
                \(evidence)
                """
        }

        var messages = Self.compactHistoryMessages(
            from: request.task.steps,
            contextMode: request.task.context.contextMode
        )
        messages.insert(ChatMessage(role: "system", content: request.systemPrompt), at: 0)
        messages.append(ChatMessage(role: "user", content: prompt))

        let response = try await request.runtime.sendMessage(
            SendMessageRequest(
                sessionID: request.task.id,
                message: "",
                connector: request.connector,
                modeLabel: "收尾",
                systemPrompt: request.systemPrompt,
                tools: nil,
                messages: messages,
                maxOutputTokens: min(request.maxOutputTokens, 2000)
            ))
        let text = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !looksLikeProviderError(text) else { return nil }
        return TaskStep(
            kind: .textOutput,
            text: text,
            isCollapsible: false,
            isCollapsed: false,
            metrics: response.metrics
        )
    }
}
