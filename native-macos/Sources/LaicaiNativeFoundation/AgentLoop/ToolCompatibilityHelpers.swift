import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    // MARK: - Model-Specific Tool Schema Adaptation

    /// Simplify tool definitions for models that struggle with complex schemas.
    /// Some models (especially local Ollama models, older DeepSeek versions) have trouble
    /// with too many tools or complex parameter descriptions.
    static func adaptToolDefsForModel(_ defs: [ToolDefinition], modelName: String) -> [ToolDefinition] {
        let model = modelName.lowercased()
        let isLocalOllama = model.contains("ollama") || model.contains("local")
        let isDeepSeek = model.contains("deepseek")
        let isQwen = model.contains("qwen")

        // Local models: limit to core tools, simplify descriptions
        if isLocalOllama {
            let coreTools: Set<String> = [
                "file_read", "file_write", "file_edit", "code_search",
                "shell_exec", "workspace_index",
            ]
            return
                defs
                .filter { coreTools.contains($0.function.name) }
                .map { simplifyDescription($0) }
        }

        // DeepSeek: keep all tools but shorten descriptions (sensitive to long schemas)
        if isDeepSeek {
            return defs.map { simplifyDescription($0) }
        }

        // Qwen: sometimes wraps tool calls in markdown — add strict formatting note
        // (handled in system prompt, not schema)
        if isQwen {
            return defs
        }

        return defs
    }

    private static func simplifyDescription(_ def: ToolDefinition) -> ToolDefinition {
        var definition = def
        // Truncate long descriptions to 100 chars
        if definition.function.description.count > 100 {
            definition.function.description = String(definition.function.description.prefix(97)) + "..."
        }
        // Truncate parameter descriptions
        var props = definition.function.parameters.properties
        for (key, prop) in props {
            if let desc = prop.description, desc.count > 60 {
                props[key] = FunctionProperty(
                    type: prop.type,
                    description: String(desc.prefix(57)) + "...",
                    enumValues: prop.enumValues
                )
            }
        }
        definition.function.parameters.properties = props
        return definition
    }

    static func shouldRetryWithoutTools(
        response: SendMessageResponse,
        requestedTools: [ToolDefinition],
        hasRetriedWithoutTools: Bool
    ) -> Bool {
        guard !requestedTools.isEmpty, !hasRetriedWithoutTools else { return false }
        let text = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            text.hasPrefix("请求格式不被")
                || text.hasPrefix("请求被拒绝")
                || text.localizedCaseInsensitiveContains("HTTP 400")
                || text.localizedCaseInsensitiveContains("HTTP 403")
        else { return false }
        let detail = ([text] + response.toolActivities.map { "\($0.summary) \($0.statusLine)" })
            .joined(separator: " ")
            .lowercased()
        return detail.contains("tool")
            || detail.contains("function")
            || detail.contains("schema")
            || detail.contains("400")
            || detail.contains("422")
            || detail.contains("兼容")
    }

    static func applyToolCompatibilityFallbackInstruction(to messages: inout [ChatMessage]) {
        let instruction =
            "\n\n## 工具兼容限制\n当前连接器不兼容工具调用。后续禁止再调用任何工具，也不要声称已经读取文件、搜索项目、联网、运行命令或写入文件。只能基于当前已知上下文直接回答；如果完成当前会话目标必须依赖工具，请明确说明当前连接器暂不兼容工具调用，并建议用户切换支持工具的连接器后重试。"
        if !messages.isEmpty, messages[0].role == "system" {
            messages[0].content = (messages[0].content ?? "") + instruction
            return
        }
        messages.insert(
            ChatMessage(role: "system", content: instruction.trimmingCharacters(in: .whitespacesAndNewlines)),
            at: 0
        )
    }

    /// User asked for a write/save/edit operation. Used by completion-claim guard.
    static func expectsWriteOutput(_ message: String) -> Bool {
        if expectsWikiOutput(message) { return true }
        let writeMarkers = [
            "写入", "写到", "保存", "存到", "落地", "记录到", "追加到",
            "修改", "改一下", "改成", "更新", "替换", "重写", "插入",
            "新建", "创建", "创建文件", "生成", "生成文件", "输出", "输出到", "放到", "添加到",
            "整理到", "归档到", "导出", "导出到",
        ]
        return writeMarkers.contains { message.contains($0) }
    }

    static func expectsWriteAction(_ message: String) -> Bool {
        let markers = [
            "写入", "写到", "保存", "存到", "落地", "记录到", "追加到",
            "修改", "改一下", "改成", "更新", "替换", "重写", "插入",
            "新建", "创建", "创建文件", "生成文件", "输出到", "放到", "添加到",
            "整理到", "归档到", "导出", "导出到",
        ]
        return markers.contains { message.contains($0) }
    }

    struct ToolEvidenceRequirementContext {
        let message: String
        let intent: UserIntent
        let isReadOnlyRun: Bool
        let toolCallCount: Int
        let toolDefs: [ToolDefinition]
        let usedToolCompatibilityFallback: Bool
    }

    static func shouldRequireToolEvidenceBeforeFinalText(_ context: ToolEvidenceRequirementContext) -> Bool {
        guard context.intent != .chat,
            !context.isReadOnlyRun,
            context.toolCallCount == 0,
            !context.toolDefs.isEmpty,
            !context.usedToolCompatibilityFallback
        else {
            return false
        }
        if Self.isPureContinuationCommand(context.message) {
            return false
        }

        let lower = context.message.lowercased()
        let explicitReadOnlyMarkers = [
            "只分析", "先别改", "不要改", "别改", "不用改", "只给建议", "不要执行", "先不执行", "只要方案",
        ]
        guard !explicitReadOnlyMarkers.contains(where: { lower.contains($0) }) else {
            return false
        }

        let actionMarkers = [
            "项目", "代码", "文件", "工作区", "页面", "按钮", "bug", "报错", "异常",
            "卡顿", "卡死", "很卡", "各种卡", "性能", "优化", "修复", "调整", "改进",
            "实现", "创建", "生成", "修改", "读取", "查看", "检查", "排查", "诊断",
            "最新进展", "进展", "继续", "接着", "没反应", "不生效",
            "workspace", "code", "file", "bug", "error", "fix", "implement", "optimize", "performance",
        ]
        return actionMarkers.contains { lower.contains($0) } || expectsWriteOutput(context.message)
    }

    /// Detect if model output claims completion of a write/save action.
    /// Used by the completion-claim guard to append a correction when no write actually succeeded.
    static func containsFalseCompletionClaim(_ text: String) -> Bool {
        let claims = [
            "已修改", "已经修改", "修改完成", "改完了", "改好了",
            "已写入", "已经写入", "写入完成",
            "已保存", "已经保存", "保存完成", "保存好了",
            "已落地", "已经落地",
            "已更新", "已经更新", "更新完成",
            "已添加", "已新增",
            "已创建", "已经创建",
            "已整理到", "已归档",
            "已完成",
        ]
        return claims.contains { text.contains($0) }
    }

    static func expectsWikiOutput(_ message: String) -> Bool {
        RoutingTextHeuristics.requestsWikiPersistence(message)
    }

    /// F2: Rewrite tool arguments to fix common model mistakes before execution
    static func rewriteToolArguments(toolName: String, argumentsJSON: String, workspaceRoot: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
            var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return argumentsJSON
        }
        var changed = false

        changed = normalizeDocumentTransformArguments(&dict, toolName: toolName) || changed
        changed = absolutizePrimaryPath(&dict, toolName: toolName, workspaceRoot: workspaceRoot) || changed
        changed = absolutizeDocumentTransformPaths(&dict, toolName: toolName, workspaceRoot: workspaceRoot) || changed
        changed = normalizeShellArguments(&dict, toolName: toolName) || changed
        changed = normalizeCodeSearchArguments(&dict, toolName: toolName) || changed
        changed = normalizeFileWriteArguments(&dict, toolName: toolName) || changed

        guard changed, let rewritten = try? JSONSerialization.data(withJSONObject: dict),
            let json = String(data: rewritten, encoding: .utf8)
        else {
            return argumentsJSON
        }
        return json
    }

    private static func normalizeDocumentTransformArguments(_ dict: inout [String: Any], toolName: String) -> Bool {
        guard isDocumentTransformTool(toolName) else { return false }
        var changed = false
        if dict["sourcePath"] == nil, let path = dict["path"] {
            dict["sourcePath"] = path
            changed = true
        }
        if dict["action"] == nil, let mode = dict["mode"] as? String {
            dict["action"] = mode
            changed = true
        }
        if dict["action"] == nil, dict["workspace"] != nil || dict["workflowPath"] != nil {
            dict["action"] = "workspace"
            changed = true
        }
        return changed
    }

    private static func absolutizePrimaryPath(
        _ dict: inout [String: Any],
        toolName: String,
        workspaceRoot: String
    ) -> Bool {
        if ["file.read", "file.write", "file.edit", "diff.apply", "document.transform", "document_transform"].contains(toolName),
            let path = dict["path"] as? String,
            !path.hasPrefix("/") && !workspaceRoot.isEmpty
        {
            dict["path"] = (workspaceRoot as NSString).appendingPathComponent(path)
            return true
        }
        return false
    }

    private static func absolutizeDocumentTransformPaths(
        _ dict: inout [String: Any],
        toolName: String,
        workspaceRoot: String
    ) -> Bool {
        guard isDocumentTransformTool(toolName), !workspaceRoot.isEmpty else { return false }
        var changed = false
        for key in ["sourcePath", "outputPath", "workflowPath", "renderDir"] {
            changed = absolutizePathValue(&dict, key: key, workspaceRoot: workspaceRoot) || changed
        }
        return changed
    }

    private static func absolutizePathValue(
        _ dict: inout [String: Any],
        key: String,
        workspaceRoot: String
    ) -> Bool {
        guard let path = dict[key] as? String, !path.hasPrefix("/") else { return false }
        dict[key] = (workspaceRoot as NSString).appendingPathComponent(path)
        return true
    }

    private static func normalizeShellArguments(_ dict: inout [String: Any], toolName: String) -> Bool {
        guard toolName == "shell.exec", dict["command"] == nil, let cmd = dict["cmd"] as? String else {
            return false
        }
        dict["command"] = cmd
        dict.removeValue(forKey: "cmd")
        return true
    }

    private static func normalizeCodeSearchArguments(_ dict: inout [String: Any], toolName: String) -> Bool {
        guard toolName == "code.search", dict["query"] == nil else { return false }
        let alt = dict["keyword"] as? String ?? dict["search"] as? String ?? dict["pattern"] as? String
        if let alt {
            dict["query"] = alt
            return true
        }
        return false
    }

    private static func normalizeFileWriteArguments(_ dict: inout [String: Any], toolName: String) -> Bool {
        guard toolName == "file.write",
            dict["content"] == nil,
            let text = dict["text"] as? String ?? dict["data"] as? String
        else {
            return false
        }
        dict["content"] = text
        return true
    }

    private static func isDocumentTransformTool(_ toolName: String) -> Bool {
        toolName == "document.transform" || toolName == "document_transform"
    }

    /// Extract newText values from a file.edit edits JSON string.
    /// Used by circuit breaker auto-repair to salvage content from failed edits.
    static func extractNewTexts(from editsJSON: String) -> [String] {
        guard let data = editsJSON.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return arr.compactMap { $0["newText"] as? String }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
