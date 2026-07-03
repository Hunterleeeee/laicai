import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    /// Send a lightweight no-tools LLM call to produce an execution plan.
    /// Returns nil if planning fails or times out (non-blocking: agent proceeds without plan).
    @MainActor
    static func generatePlan(
        message: String,
        intent: UserIntent,
        context: TaskContext,
        connector: ConnectorProfile,
        runtime: any ChatRuntimeClient,
        maxTokens: Int = 1024
    ) async throws -> String? {
        let modeLabel: String
        switch intent {
        case .task: modeLabel = "会话 执行"
        case .research: modeLabel = "会话 研究"
        case .workflow(let name): modeLabel = "会话 工作流(\(name))"
        default: return nil
        }

        let fileContext: String
        if !context.relevantFiles.isEmpty {
            let list = context.relevantFiles.prefix(10)
                .map { "- \($0.path)" }
                .joined(separator: "\n")
            fileContext = "\n已知工作区文件：\n\(list)"
        } else {
            fileContext = ""
        }

        let planPrompt = """
        你是执行计划生成器。用户的\(modeLabel)请求如下：

        「\(message)」
        \(fileContext)

        请用 3-6 行输出一个精简的执行计划，格式：
        1. [具体动作] — [目标文件或工具]
        2. …

        规则：
        - 每步必须是具体可执行的动作（读取X文件、搜索Y、编辑Z函数、运行命令W）
        - 不要写"理解需求"、"制定计划"这类废话
        - 如果请求是继续/追问/修复已有会话，不要重新探索全项目；先沿用已有检查点、最近失败和已读文件，从断点推进
        - 如果用户问“为什么/还有什么/哪里不对”，先基于当前会话 现场解释或补一小步验证，不要新开目标
        - 优先 file_edit 而非 file_write
        - 最后一步必须是验证或总结
        """

        let planMessages = [
            ChatMessage(role: "system", content: "你是计划生成器，只输出执行步骤，不要解释。"),
            ChatMessage(role: "user", content: planPrompt)
        ]

        let request = SendMessageRequest(
            sessionID: UUID(),
            message: planPrompt,
            connector: connector,
            modeLabel: "计划",
            systemPrompt: "你是计划生成器，只输出执行步骤，不要解释。",
            tools: [],
            messages: planMessages,
            maxOutputTokens: maxTokens
        )

        let response: SendMessageResponse = try await withThrowingTaskGroup(of: SendMessageResponse.self) { group in
            group.addTask {
                try await runtime.sendMessage(request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000) // 8s timeout
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let plan = response.assistantText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !plan.isEmpty, plan.count > 10 else { return nil }
        return String(plan.prefix(800))
    }

    static func stagePlan(for message: String, intent: UserIntent) -> String {
        guard intent != .chat else { return "" }
        let lowered = message.lowercased()
        let needsProjectPass = ["全量", "全部", "整个", "整体", "项目", "工作区", "代码", "repo", "repository"]
            .contains { lowered.localizedCaseInsensitiveContains($0) }
        let needsDebugPass = ["找问题", "排查", "检查", "审查", "优化", "修复", "bug", "error"]
            .contains { lowered.localizedCaseInsensitiveContains($0) }
        guard needsProjectPass || needsDebugPass || expectsWriteOutput(message) else { return "" }

        var lines = ["执行计划"]
        if needsProjectPass {
            lines.append("1. 建立工作区索引，确认入口、配置、测试和风险文件。")
        } else {
            lines.append("1. 先定位与请求最相关的文件和上下文。")
        }
        if needsDebugPass {
            lines.append("2. 搜索可疑模式并读取高相关文件，形成问题证据。")
        } else {
            lines.append("2. 基于真实文件内容执行用户目标。")
        }
        lines.append("3. 验证结果并输出阶段总结与证据清单。")
        return lines.joined(separator: "\n")
    }

    static func stageSummaryStep(for task: AgentTask, didComplete: Bool, hadFailure: Bool, wasTruncated: Bool) -> TaskStep {
        let toolCalls = task.steps.filter { $0.kind == .toolCall }.count
        let failedTools = task.steps.filter { $0.kind == .toolResult && $0.isFailure }.count
        let readFiles = Set(task.steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] })
        var lines = ["阶段总结"]
        lines.append("Plan：已建立执行路径。")
        lines.append("Execute：执行 \(toolCalls) 次工具调用，读取 \(readFiles.count) 个文件。")
        if wasTruncated {
            lines.append("Verify：输出被截断，已进入续写保护。")
        } else if hadFailure || failedTools > 0 {
            lines.append("Verify：发现 \(failedTools) 个失败工具，需要继续恢复或换路径。")
        } else if didComplete {
            lines.append("Verify：已形成回复，未发现未恢复的失败工具。")
        } else {
            lines.append("Verify：尚未形成完整最终回复。")
        }
        lines.append("Summarize：\(didComplete && !hadFailure && !wasTruncated ? "本轮可视为完成。" : "本轮仍需继续。")")
        return TaskStep(
            kind: .aiThinking,
            text: lines.joined(separator: "\n"),
            isCollapsible: true,
            isCollapsed: true,
            isFailure: hadFailure
        )
    }

    static func shouldEmitStageSummary(for task: AgentTask, hasPlan: Bool, hadFailure: Bool, wasTruncated: Bool, isReadOnlyRun: Bool = false) -> Bool {
        if hasPlan || hadFailure || wasTruncated {
            return true
        }
        if isReadOnlyRun {
            return false
        }
        return task.steps.contains { step in
            isFileChangeTool(step.toolName ?? "") || ["document.transform", "shell.exec", "verify.build"].contains(step.toolName ?? "") || step.kind == .error
        }
    }

    static func evidenceChecklistStep(for task: AgentTask, didComplete: Bool, hadFailure: Bool, wasTruncated: Bool, isReadOnlyRun: Bool = false) -> TaskStep? {
        let toolCalls = task.steps.filter { $0.kind == .toolCall }
        guard !toolCalls.isEmpty || hadFailure || wasTruncated else { return nil }
        let hasPlan = task.steps.contains { $0.kind == .aiThinking && $0.text.hasPrefix("执行计划") }
        guard shouldEmitEvidenceChecklist(
            toolCalls: toolCalls,
            hadFailure: hadFailure,
            wasTruncated: wasTruncated,
            hasPlan: hasPlan,
            isReadOnlyRun: isReadOnlyRun
        ) else { return nil }

        let readFiles = uniqueValues(task.steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] })
        let searchQueries = uniqueValues(toolCalls
            .filter { $0.toolName == "code.search" || $0.toolName == "web.search" }
            .compactMap { $0.toolParams?["query"] })
        let indexed = task.steps.contains { $0.kind == .toolResult && $0.toolName == "workspace.index" && !$0.isFailure }
        let commands = uniqueValues(toolCalls
            .filter { $0.toolName == "shell.exec" || $0.toolName == "verify.build" }
            .compactMap { $0.toolParams?["command"] })
        let documents = uniqueValues(task.steps
            .filter { $0.kind == .toolResult && $0.toolName == "document.transform" && !$0.isFailure }
            .compactMap { $0.toolParams?["outputPath"] ?? $0.toolParams?["sourcePath"] ?? $0.toolParams?["path"] })
        let writeReviews = task.steps.filter { $0.kind == .reviewRequest }.compactMap(\.diffFilePath)
        let failedTools = Dictionary(grouping: task.steps.filter { $0.kind == .toolResult && $0.isFailure }, by: { $0.toolName ?? "tool" })
            .map { "\($0.key) ×\($0.value.count)" }
            .sorted()

        var lines = [
            "证据清单",
            "状态：\(didComplete && !hadFailure && !wasTruncated ? "已形成结果" : "仍需继续")"
        ] + evidenceDetailLines(EvidenceDetailInput(
            indexed: indexed,
            readFiles: readFiles,
            searchQueries: searchQueries,
            commands: commands,
            documents: documents,
            writeReviews: writeReviews,
            failedTools: failedTools,
            wasTruncated: wasTruncated,
            hadFailure: hadFailure
        ))
        if lines.count == 2 && !indexed {
            lines.append("已调用工具：\(uniqueValues(toolCalls.compactMap(\.toolName)).joined(separator: "、"))")
        }

        return TaskStep(
            kind: .aiThinking,
            text: lines.joined(separator: "\n"),
            isCollapsible: true,
            isCollapsed: false,
            isFailure: hadFailure
        )
    }

    private static func shouldEmitEvidenceChecklist(
        toolCalls: [TaskStep],
        hadFailure: Bool,
        wasTruncated: Bool,
        hasPlan: Bool,
        isReadOnlyRun: Bool
    ) -> Bool {
        hadFailure
            || wasTruncated
            || hasWriteOrCommand(toolCalls)
            || hasPlan
            || (!isReadOnlyRun && toolCalls.count >= 4)
    }

    private static func hasWriteOrCommand(_ toolCalls: [TaskStep]) -> Bool {
        toolCalls.contains {
            isFileChangeTool($0.toolName ?? "") || ["document.transform", "shell.exec", "verify.build"].contains($0.toolName ?? "")
        }
    }

    private struct EvidenceDetailInput {
        let indexed: Bool
        let readFiles: [String]
        let searchQueries: [String]
        let commands: [String]
        let documents: [String]
        let writeReviews: [String]
        let failedTools: [String]
        let wasTruncated: Bool
        let hadFailure: Bool
    }

    private static func evidenceDetailLines(_ input: EvidenceDetailInput) -> [String] {
        [
            input.indexed ? "已建立项目索引：是" : nil,
            input.readFiles.isEmpty ? nil : "已读文件：\(input.readFiles.prefix(12).joined(separator: "、"))",
            input.searchQueries.isEmpty ? nil : "已搜索：\(input.searchQueries.prefix(8).joined(separator: "、"))",
            input.commands.isEmpty ? nil : "已运行命令：\(input.commands.prefix(6).joined(separator: "、"))",
            input.documents.isEmpty ? nil : "已处理文档：\(input.documents.prefix(8).joined(separator: "、"))",
            input.writeReviews.isEmpty ? nil : "待审查/已审查文件：\(uniqueValues(input.writeReviews).prefix(8).joined(separator: "、"))",
            input.failedTools.isEmpty ? nil : "失败工具：\(input.failedTools.joined(separator: "、"))",
            input.wasTruncated ? "未验证：输出仍可能被截断，需要沿用当前会话 继续。" : nil,
            input.hadFailure ? "未验证：存在未恢复失败，需要重试或换路径。" : nil
        ].compactMap { $0 }
    }

}
