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
                "shell_exec", "workspace_index"
            ]
            return defs
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
        var d = def
        // Truncate long descriptions to 100 chars
        if d.function.description.count > 100 {
            d.function.description = String(d.function.description.prefix(97)) + "..."
        }
        // Truncate parameter descriptions
        var props = d.function.parameters.properties
        for (key, prop) in props {
            if let desc = prop.description, desc.count > 60 {
                props[key] = FunctionProperty(
                    type: prop.type,
                    description: String(desc.prefix(57)) + "...",
                    enumValues: prop.enumValues
                )
            }
        }
        d.function.parameters.properties = props
        return d
    }

    static func shouldRetryWithoutTools(
        response: SendMessageResponse,
        requestedTools: [ToolDefinition],
        hasRetriedWithoutTools: Bool
    ) -> Bool {
        guard !requestedTools.isEmpty, !hasRetriedWithoutTools else { return false }
        let text = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("请求格式不被")
                || text.hasPrefix("请求被拒绝")
                || text.localizedCaseInsensitiveContains("HTTP 400")
                || text.localizedCaseInsensitiveContains("HTTP 403") else { return false }
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
        let instruction = "\n\n## 工具兼容限制\n当前连接器不兼容工具调用。后续禁止再调用任何工具，也不要声称已经读取文件、搜索项目、联网、运行命令或写入文件。只能基于当前已知上下文直接回答；如果完成任务必须依赖工具，请明确说明当前连接器暂不兼容工具调用，并建议用户切换支持工具的连接器后重试。"
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
            "新建", "创建文件", "生成文件", "添加到",
            "整理到", "归档到", "导出到"
        ]
        return writeMarkers.contains { message.contains($0) }
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
            "已完成"
        ]
        return claims.contains { text.contains($0) }
    }

    static func expectsWikiOutput(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("wiki")
            || lower.contains("知识库")
            || lower.contains("整理到")
            || lower.contains("整理成笔记")
            || lower.contains("obsidian")
    }

    /// F2: Rewrite tool arguments to fix common model mistakes before execution
    static func rewriteToolArguments(toolName: String, argumentsJSON: String, workspaceRoot: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return argumentsJSON
        }
        var changed = false

        // Fix 1: Relative paths → absolute paths for file tools
        if ["file.read", "file.write", "file.edit", "diff.apply"].contains(toolName),
           let path = dict["path"] as? String,
           !path.hasPrefix("/") && !workspaceRoot.isEmpty {
            dict["path"] = (workspaceRoot as NSString).appendingPathComponent(path)
            changed = true
        }

        // Fix 2: shell.exec — ensure 'command' param exists (some models use 'cmd')
        if toolName == "shell.exec" {
            if dict["command"] == nil, let cmd = dict["cmd"] as? String {
                dict["command"] = cmd
                dict.removeValue(forKey: "cmd")
                changed = true
            }
        }

        // Fix 3: code.search — ensure 'query' param (some models use 'keyword' or 'search')
        if toolName == "code.search" {
            if dict["query"] == nil {
                let alt = dict["keyword"] as? String ?? dict["search"] as? String ?? dict["pattern"] as? String
                if let alt {
                    dict["query"] = alt
                    changed = true
                }
            }
        }

        // Fix 4: file.write — ensure both path and content exist
        if toolName == "file.write" {
            if dict["content"] == nil, let text = dict["text"] as? String ?? dict["data"] as? String {
                dict["content"] = text
                changed = true
            }
        }

        guard changed, let rewritten = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: rewritten, encoding: .utf8) else {
            return argumentsJSON
        }
        return json
    }

    /// Extract newText values from a file.edit edits JSON string.
    /// Used by circuit breaker auto-repair to salvage content from failed edits.
    static func extractNewTexts(from editsJSON: String) -> [String] {
        guard let data = editsJSON.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { $0["newText"] as? String }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
