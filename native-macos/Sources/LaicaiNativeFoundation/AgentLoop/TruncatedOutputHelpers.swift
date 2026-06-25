import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    static func shouldContinueTruncatedOutputOnly(message: String, priorSteps: [TaskStep]) -> Bool {
        guard hasTruncatedOutput(in: priorSteps) else { return false }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let markers = [
            "继续", "接着说", "继续输出", "继续说", "接着输出", "没发完", "没写完",
            "没说完", "没结束", "被截断", "截断了", "断了", "后面呢", "剩下的", "接上"
        ]
        return markers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func hasTruncatedOutput(in steps: [TaskStep]) -> Bool {
        steps.contains { step in
            step.text.contains("输出达到当前上限")
                || step.text.contains("回复已被截断")
                || step.text.contains("回复仍被截断")
                || step.text.contains("内容可能被截断")
                || step.text.contains("输出上限截断")
        }
    }

    static func lastTextOutput(in steps: [TaskStep]) -> String? {
        steps.reversed().first {
            $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func continueTruncatedOutput(
        taskID: UUID,
        originalMessage: String,
        previousText: String,
        messages: [ChatMessage],
        connector: ConnectorProfile,
        runtime: any ChatRuntimeClient,
        maxOutputTokens: Int,
        originalStepID: UUID? = nil
    ) async throws -> TaskStep? {
        var continuationMessages = messages
        continuationMessages.append(ChatMessage(role: "assistant", content: previousText))
        continuationMessages.append(ChatMessage(
            role: "user",
            content: """
            上一条回复因为输出上限被截断。请从截断处无缝继续，直接输出剩余内容：
            - 不要重写开头
            - 不要总结已经写过的部分
            - 不要重新调用工具
            - 如果确实已经完成，只输出最后缺失的收尾

            原始用户目标：\(originalMessage)
            """
        ))

        let response = try await runtime.sendMessage(SendMessageRequest(
            sessionID: taskID,
            message: "继续输出被截断的上一段",
            connector: connector,
            modeLabel: "会话 执行",
            history: [],
            systemPrompt: nil,
            tools: nil,
            messages: continuationMessages,
            maxOutputTokens: maxOutputTokens
        ))
        let text = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !looksLikeProviderError(text) else { return nil }
        let finalText = response.finishReason == "length"
            ? text + "\n\n（回复仍被截断，可以继续在当前会话 里发送“接着说”。）"
            : text
        return TaskStep(
            kind: .textOutput,
            text: finalText,
            isCollapsible: false,
            isCollapsed: false,
            metrics: response.metrics,
            continuationOf: originalStepID
        )
    }
}
