import LaicaiNativeDomain

extension ToolExecutionEngine {
    static func dynamicTokenLimit(toolName: String, success: Bool, config: AgentLoop.Config) -> Int {
        if !success { return config.maxTokensPerTurn }
        if toolName == "file.read" { return config.maxTokensPerTurn }
        if toolName == "document.transform" { return min(max(config.maxTokensPerTurn, 8000), 40_000) }
        if toolName == "verify.build" { return 200 }
        if toolName == "workspace.index" || toolName == "code.search" {
            return min(3000, config.maxTokensPerTurn)
        }
        if toolName == "shell.exec" { return config.maxTokensPerTurn / 2 }
        return config.maxTokensPerTurn
    }

    static func isToolAllowed(_ name: String, config: AgentLoop.Config) -> Bool {
        AgentLoop.allowsTool(name, allowedTools: config.allowedTools)
    }

    static func isDeterministicUnsupportedFileFailure(toolName: String, result: ToolResult) -> Bool {
        guard ["file.read", "file.extract", "document.transform"].contains(toolName) else { return false }
        let code = result.error ?? ""
        return code == "unsupported_binary_file" || code == "unsupported_file_type"
    }

    static func diagnosticHintForFailure(toolName: String, error: String) -> String {
        let lower = error.lowercased()
        let hintRules: [(keywords: [String], hint: String)] = [
            (["timeout", "超时"], "诊断：请求超时。可能是网络不稳定或服务端响应慢。"),
            (["connection", "连接", "cannot find host"], "诊断：连接失败。请检查网络连接和服务端地址是否正确。"),
            (["429", "rate limit", "限流"], "诊断：触发限流。请稍后重试或降低请求频率。"),
            (["401", "403", "unauthorized", "forbidden"], "诊断：认证失败。请检查 API Key 是否正确且未过期。"),
            (["404", "not found"], "诊断：资源不存在。请检查路径或端点是否正确。"),
            (["500", "502", "503", "server error"], "诊断：服务端错误。可能是服务暂时不可用，请稍后重试。"),
            (["no such file", "文件不存在", "not found"], "诊断：文件不存在。请先用 file_read 确认路径，或用 file_write 创建新文件。"),
            (["permission", "权限"], "诊断：权限不足。请检查文件权限或工作区访问权限。"),
            (["encoding", "编码", "utf"], "诊断：编码问题。文件可能包含非文本内容。"),
            (["match", "匹配"], "诊断：内容匹配失败。请先 file_read 获取最新内容，再用新内容重试。"),
            (["not allowed", "blocked", "禁止"], "诊断：工具被阻止。请检查执行级别设置。"),
        ]
        return hintRules.first { rule in
            rule.keywords.contains { lower.contains($0) }
        }?.hint ?? ""
    }
}
