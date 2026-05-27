import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func exportThread(id: UUID) -> String? {
        guard let thread = state.threads.first(where: { $0.id == id }) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(thread) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func exportSession(id: UUID) -> String? {
        guard let thread = state.threads.first(where: { $0.id == id }) else { return nil }
        let session = ChatSession(thread: thread)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func exportTask(id: UUID) -> String? {
        guard let thread = state.threads.first(where: { $0.id == id }) else { return nil }
        let task = AgentTask(thread: thread)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(task) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func exportSelectedThreadMarkdown() -> String? {
        guard let thread = state.selectedThread else { return nil }
        let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新会话" : thread.title
        var lines: [String] = ["# \(title)", ""]
        lines.append("- 类型：会话")
        lines.append("- 状态：\(thread.executionState.title)")
        if let goal = thread.goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty {
            lines.append("- 目标：\(goal)")
        }
        if !thread.currentPlan.isEmpty {
            lines.append("- 当前计划：\(thread.currentPlan.prefix(5).joined(separator: " / "))")
        }
        lines.append("- 更新时间：\(thread.updatedAt)")
        lines.append("")

        for step in thread.steps {
            lines.append("## \(step.kind.title)")
            if let toolName = step.toolName { lines.append("- 工具：\(toolName)") }
            if step.isFailure { lines.append("- 状态：失败") }
            lines.append("")
            lines.append(step.text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    public func exportSelectedThreadJSON() -> String? {
        guard let thread = state.selectedThread else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(thread) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func archiveThread(id: UUID) {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        state.threads[index].isArchived.toggle()
        syncAgentSnapshot(at: index)
        state.invalidateThreadSummaryCache()
        if state.threads[index].isArchived && state.selectedThread?.id == id {
            state.selectedThreadID = nil
        }
        persistThreads()
    }

    public func exportSelectedTaskEvidenceMarkdown() -> String? {
        guard let thread = state.selectedThread, thread.canContinue else { return nil }
        let steps = thread.steps
        let toolCalls = steps.filter { $0.kind == .toolCall }
        let readFiles = Self.uniqueMemoryValues(steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] })
        let searchQueries = Self.uniqueMemoryValues(toolCalls
            .filter { $0.toolName == "code.search" || $0.toolName == "web.search" }
            .compactMap { $0.toolParams?["query"] })
        let commands = Self.uniqueMemoryValues(toolCalls
            .filter { $0.toolName == "shell.exec" }
            .compactMap { $0.toolParams?["command"] })
        let writeReviews = Self.uniqueMemoryValues(steps
            .filter { $0.kind == .reviewRequest }
            .compactMap(\.diffFilePath))
        let failedTools = Dictionary(grouping: steps.filter { $0.kind == .toolResult && $0.isFailure }, by: { $0.toolName ?? "tool" })
            .map { "\($0.key) ×\($0.value.count)" }
            .sorted()
        let indexed = steps.contains { $0.kind == .toolResult && $0.toolName == "workspace.index" && !$0.isFailure }

        let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新会话" : thread.title
        var lines: [String] = ["# 会话证据清单：\(title)", ""]
        lines.append("- 状态：\(thread.executionState.title)")
        lines.append("- 步骤：\(steps.count)")
        lines.append("- 更新时间：\(thread.updatedAt)")
        if indexed { lines.append("- 项目索引：已建立") }
        if !readFiles.isEmpty { lines.append("- 已读文件：\(readFiles.prefix(12).joined(separator: "、"))") }
        if !searchQueries.isEmpty { lines.append("- 已搜索：\(searchQueries.prefix(8).joined(separator: "、"))") }
        if !commands.isEmpty { lines.append("- 已运行命令：\(commands.prefix(6).joined(separator: "、"))") }
        if !writeReviews.isEmpty { lines.append("- 审查文件：\(writeReviews.prefix(8).joined(separator: "、"))") }
        if !failedTools.isEmpty { lines.append("- 失败工具：\(failedTools.joined(separator: "、"))") }
        if let verification = thread.context.memory.verificationStatus {
            lines.append("- 验证状态：\(verification)")
        }
        if lines.count <= 4 {
            lines.append("- 说明：这个会话还没有形成足够工具证据。")
        }
        return lines.joined(separator: "\n")
    }

    public func exportSelectedThreadShellScript() -> String? {
        guard let thread = state.selectedThread else { return nil }
        let commands = thread.steps
            .filter { $0.kind == .toolCall && $0.toolName == "shell.exec" }
            .compactMap { $0.toolParams?["command"] }
        guard !commands.isEmpty else { return nil }

        var script = "#!/bin/bash\n"
        script += "# 来财导出 — \(thread.title)\n"
        script += "# 时间：\(thread.updatedAt)\n"
        script += "set -euo pipefail\n\n"
        for cmd in commands {
            script += "\(cmd)\n"
        }
        return script
    }

    public func exportSelectedThreadWorkflowYAML() -> String? {
        guard let thread = state.selectedThread else { return nil }
        let toolSteps = thread.steps.filter { $0.kind == .toolCall && $0.toolName != nil }
        guard !toolSteps.isEmpty else { return nil }

        var lines: [String] = [
            "name: \(thread.title)",
            "description: 从会话自动导出",
            "category: custom",
            "steps:"
        ]
        for (i, step) in toolSteps.enumerated() {
            let toolName = step.toolName ?? "unknown"
            lines.append("  - name: \"\(step.text.prefix(40).replacingOccurrences(of: "\n", with: " "))\"")
            lines.append("    tool: \(toolName)")
            if let params = step.toolParams, !params.isEmpty {
                lines.append("    params:")
                for (k, v) in params.sorted(by: { $0.key < $1.key }) {
                    let escaped = v.replacingOccurrences(of: "\"", with: "\\\"")
                    lines.append("      \(k): \"\(escaped)\"")
                }
            }
            if i > 0 { lines.append("    on_failure: skip") }
        }
        return lines.joined(separator: "\n")
    }

    public func importSession(json: String) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let session = try? decoder.decode(ChatSession.self, from: data) else { return false }
        let imported = Thread(session: session)
        state.threads.insert(imported, at: 0)
        state.selectThread(id: imported.id)
        persistThreads()
        notify("已导入会话", style: .success)
        return true
    }

    public func deleteTurn(sessionID: UUID, turnID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == sessionID }) else { return }
        state.threads[threadIndex].steps.removeAll(where: { $0.id == turnID })
        state.threads[threadIndex].preview = normalizedSessionPreview(state.threads[threadIndex].steps.last?.text ?? "")
        persistThreads()
    }
}
