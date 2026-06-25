import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    static func autoExtractUnsupportedRead(path: String, extractTool: any LaicaiTool, context: TaskContext) async -> ToolResult? {
        let extractArgs: [String: Any] = ["path": path, "limit": 60_000]
        let extractJSON = (try? JSONSerialization.data(withJSONObject: extractArgs)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let extractResult = try? await extractTool.execute(argumentsJSON: extractJSON, context: context)
        guard let extractResult, extractResult.success else { return nil }
        return extractResult
    }

    static func runBootstrapFileExtract(
        path: String,
        extractTool: any LaicaiTool,
        taskContext: inout TaskContext,
        task: inout AgentTask,
        callId: String = "call_bootstrap_file_extract",
        maxTokens: Int,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> ChatMessage {
        let argumentsJSON = bootstrapExtractArgumentsJSON(for: path)
        let toolParams = displayParamsFromJSON(argumentsJSON)
        let callStep = TaskStep(
            kind: .toolCall,
            text: ToolStepFormatter.callText(toolName: "file.extract", arguments: toolParams),
            toolName: "file.extract",
            toolParams: toolParams,
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true
        )
        task.steps.append(callStep)
        onStep(callStep)

        let (toolResult, _) = await ValidationEngine.executeWithValidationJSON(
            tool: extractTool,
            argumentsJSON: argumentsJSON,
            context: taskContext
        )
        let resultStep = TaskStep(
            kind: .toolResult,
            text: ToolResultFormatter.displayText(toolName: "file.extract", arguments: toolParams, result: toolResult),
            toolName: "file.extract",
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true,
            isFailure: !toolResult.success
        )
        task.steps.append(resultStep)
        onStep(resultStep)
        if toolResult.success {
            taskContext.memory.readFiles.append(path)
            taskContext.memory.fileContentCache[path] = toolResult.output
        }

        let resultContent = ToolResultFormatter.modelContent(
            toolName: "file.extract",
            result: toolResult,
            limit: maxTokens
        )
        let instruction = toolResult.success
            ? "我已直接提取用户提供的表格/文档。请基于真实提取结果继续推进当前会话目标；如果用户要求整理到 Wiki，必须调用 wiki_build(save=true) 保存笔记。"
            : "我尝试提取用户提供的表格/文档但失败。请明确说明失败原因，不能编造文件内容。"
        return ChatMessage(
            role: "user",
            content: """
            \(instruction)

            \(resultContent)
            """
        )
    }

    static func runBootstrapFileRead(
        path: String,
        readTool: any LaicaiTool,
        taskContext: inout TaskContext,
        task: inout AgentTask,
        callId: String = "call_bootstrap_file_read",
        maxTokens: Int,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> String {
        let argumentsJSON = bootstrapReadArgumentsJSON(for: path)
        let toolParams = displayParamsFromJSON(argumentsJSON)
        let callStep = TaskStep(
            kind: .toolCall,
            text: ToolStepFormatter.callText(toolName: "file.read", arguments: toolParams),
            toolName: "file.read",
            toolParams: toolParams,
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true
        )
        task.steps.append(callStep)
        onStep(callStep)

        let (toolResult, _) = await ValidationEngine.executeWithValidationJSON(
            tool: readTool,
            argumentsJSON: argumentsJSON,
            context: taskContext
        )
        let resultStep = TaskStep(
            kind: .toolResult,
            text: ToolResultFormatter.displayText(toolName: "file.read", arguments: toolParams, result: toolResult),
            toolName: "file.read",
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true,
            isFailure: !toolResult.success
        )
        task.steps.append(resultStep)
        onStep(resultStep)

        let readContent = ToolResultFormatter.modelContent(
            toolName: "file.read",
            result: toolResult,
            limit: maxTokens
        )
        return """

        自动读取的首个高相关文件片段（\(path)）：
        \(readContent)
        """
    }

    static func shouldBootstrapExtract(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["xlsx", "xlsm", "csv", "tsv"].contains(ext)
    }
}
