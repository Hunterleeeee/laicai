import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    struct RecoveryToolRequest {
        let displayName: String
        let argumentsJSON: String
        let context: TaskContext
    }

    func executeRecoveryTool(
        request: RecoveryToolRequest,
        task: inout AgentTask,
        messages: inout [ChatMessage],
        onStep: @MainActor (TaskStep) -> Void
    ) async -> Bool {
        let canonicalName = ToolNameCodec.canonicalName(request.displayName)
        guard isToolAllowed(canonicalName) else {
            let blockedStep = TaskStep(
                kind: .toolResult,
                text: "已跳过自动恢复工具：\(canonicalName)。当前执行级别不允许该工具；不会为了恢复而升级权限。",
                toolName: canonicalName,
                isCollapsible: true,
                isCollapsed: true,
                isFailure: false
            )
            task.steps.append(blockedStep)
            onStep(blockedStep)
            return false
        }
        guard let tool = toolRegistry.tool(named: request.displayName) else {
            return false
        }

        let params = parseParamsFromJSON(request.argumentsJSON)
        let callId = "call_recovery_\(ToolNameCodec.apiName(canonicalName))_\(UUID().uuidString.prefix(8))"
        let callStep = TaskStep(
            kind: .toolCall,
            text: "自动恢复：" + ToolStepFormatter.callText(toolName: canonicalName, arguments: params),
            toolName: canonicalName,
            toolParams: params,
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true
        )
        task.steps.append(callStep)
        onStep(callStep)

        let result: ToolResult
        if Self.requiresExplicitUserApprovalBeforeExecution(toolName: canonicalName, tool: tool) {
            result = Self.approvalRequiredToolResult(toolName: canonicalName)
        } else {
            let validated = await ValidationEngine.executeWithValidationJSON(
                tool: tool,
                argumentsJSON: request.argumentsJSON,
                context: request.context,
                maxRetries: 1
            )
            result = validated.result
        }
        let resultText = ToolResultFormatter.displayText(
            toolName: canonicalName,
            arguments: params,
            result: result
        )
        let resultStep = TaskStep(
            kind: .toolResult,
            text: result.success ? "自动恢复成功：\(resultText)" : "自动恢复失败：\(resultText)",
            toolName: canonicalName,
            toolParams: params,
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true,
            isFailure: !result.success
        )
        task.steps.append(resultStep)
        onStep(resultStep)

        let resultContent = ToolResultFormatter.modelContent(
            toolName: canonicalName,
            result: result,
            limit: config.maxTokensPerTurn
        )
        messages.append(ChatMessage(
            role: "user",
            content: """
            自动恢复工具 \(canonicalName) 执行结果如下。请基于这些真实结果继续推进当前会话目标，不要重复已经失败的工具路径。

            \(resultContent)
            """
        ))
        return result.success
    }
}
