import Foundation
import LaicaiNativeDomain

// MARK: - Memory Tool (agent-callable)

private struct MemoryToolParams: Codable {
    var action: String
    var content: String?
    var query: String?
    var kind: String?
    var tags: String?
    var key: String?
    var value: String?
}

/// Allows the agent to store and recall cross-Agent memories.
public struct MemoryTool: LaicaiTool {
    public var name: String { "memory" }
    public var description: String { "跨会话持久记忆：存储知识、召回相关记忆、搜索历史" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "action": FunctionProperty(type: "string", description: "动作：store / recall / search / preference / stats"),
                    "content": FunctionProperty(type: "string", description: "要存储的内容（store 时必填）"),
                    "query": FunctionProperty(type: "string", description: "搜索/召回查询词（recall/search 时必填）"),
                    "kind": FunctionProperty(type: "string", description: "记忆类型：fact/preference/outcome/skill/note（默认 fact）"),
                    "tags": FunctionProperty(type: "string", description: "标签，逗号分隔"),
                    "key": FunctionProperty(type: "string", description: "偏好键名（preference 动作时用）"),
                    "value": FunctionProperty(type: "string", description: "偏好值（preference 动作时用）")
                ],
                required: ["action"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        let params: MemoryToolParams
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(MemoryToolParams.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        switch params.action {
        case "store":
            return await storeMemory(params)
        case "recall":
            return await recallMemory(params)
        case "search":
            return await searchMemory(params)
        case "preference":
            return await handlePreference(params)
        case "stats":
            let stats = await MainActor.run { MemoryEngine.shared.stats }
            return ToolResult(output: "记忆统计：共 \(stats.total) 条（知识 \(stats.facts)，历史 \(stats.outcomes)，偏好 \(stats.preferences)）")

        default:
            return ToolResult(output: "未知动作 '\(params.action)'，支持：store / recall / search / preference / stats", success: false, error: "unknown_action")
        }
    }

    private func storeMemory(_ params: MemoryToolParams) async -> ToolResult {
        guard let content = params.content, !content.isEmpty else {
            return ToolResult(output: "缺少 content 参数", success: false, error: "missing_content")
        }
        let kind = MemoryEntry.Kind(rawValue: params.kind ?? "fact") ?? .fact
        let tags = (params.tags ?? "")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let entry = MemoryEntry(kind: kind, content: content, tags: tags)
        let didStore = await MainActor.run { MemoryEngine.shared.store(entry) }
        return didStore
            ? ToolResult(output: "已存储记忆（\(kind.rawValue)）")
            : ToolResult(output: "存储失败", success: false, error: "store_failed")
    }

    private func recallMemory(_ params: MemoryToolParams) async -> ToolResult {
        guard let query = params.query, !query.isEmpty else {
            return ToolResult(output: "缺少 query 参数", success: false, error: "missing_query")
        }
        let results = await MainActor.run { MemoryEngine.shared.recall(query: query, limit: 8) }
        guard !results.isEmpty else {
            return ToolResult(output: "未找到相关记忆")
        }
        let lines = results.map { entry -> String in
            let tags = entry.tags.isEmpty ? "" : " [\(entry.tags.joined(separator: ","))]"
            return "[\(kindLabel(entry.kind))]\(tags) \(entry.content.prefix(300))"
        }
        return ToolResult(output: "找到 \(results.count) 条记忆：\n" + lines.joined(separator: "\n"))
    }

    private func searchMemory(_ params: MemoryToolParams) async -> ToolResult {
        guard let query = params.query, !query.isEmpty else {
            return ToolResult(output: "缺少 query 参数", success: false, error: "missing_query")
        }
        let results = await MainActor.run { MemoryEngine.shared.recallByKeyword(query, limit: 10) }
        guard !results.isEmpty else {
            return ToolResult(output: "未找到匹配记忆")
        }
        let lines = results.map { "[\($0.kind.rawValue)] \($0.content.prefix(200))" }
        return ToolResult(output: "找到 \(results.count) 条：\n" + lines.joined(separator: "\n"))
    }

    private func handlePreference(_ params: MemoryToolParams) async -> ToolResult {
        guard let key = params.key, !key.isEmpty else {
            return ToolResult(output: "缺少 key 参数", success: false, error: "missing_key")
        }
        if let value = params.value, !value.isEmpty {
            await MainActor.run { MemoryEngine.shared.storePreference(key: key, value: value) }
            return ToolResult(output: "已保存偏好：\(key) = \(value)")
        }
        let results = await MainActor.run { MemoryEngine.shared.recallByKeyword("偏好:\(key)", limit: 1) }
        if let found = results.first {
            return ToolResult(output: found.content)
        }
        return ToolResult(output: "未找到偏好 \(key)")
    }

    private func kindLabel(_ kind: MemoryEntry.Kind) -> String {
        switch kind {
        case .fact: return "知识"
        case .preference: return "偏好"
        case .outcome: return "历史"
        case .skill: return "技能"
        case .note: return "笔记"
        }
    }
}
