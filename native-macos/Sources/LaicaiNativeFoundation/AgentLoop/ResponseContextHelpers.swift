import Foundation
import LaicaiNativeDomain

extension AgentLoop {
    /// Build a compact progress summary for auto-continuation rounds
    static func compactProgressSummary(task: AgentTask) -> String {
        var lines: [String] = []
        let reads = task.steps.filter { $0.kind == .toolResult && ["file.read", "file.extract"].contains($0.toolName ?? "") && !$0.isFailure }
        if !reads.isEmpty { lines.append("- 已读取 \(reads.count) 个文件") }
        let writes = task.steps.filter { $0.kind == .toolResult && isFileChangeTool($0.toolName ?? "") && !$0.isFailure }
        if !writes.isEmpty { lines.append("- 已修改 \(writes.count) 个文件") }
        let shells = task.steps.filter { $0.kind == .toolResult && $0.toolName == "shell.exec" && !$0.isFailure }
        if !shells.isEmpty { lines.append("- 已执行 \(shells.count) 个命令") }
        let searches = task.steps.filter { $0.kind == .toolResult && ["code.search", "web.search"].contains($0.toolName ?? "") && !$0.isFailure }
        if !searches.isEmpty { lines.append("- 已搜索 \(searches.count) 次") }
        let failures = task.steps.filter { ($0.kind == .toolResult || $0.kind == .error || $0.kind == .aiThinking) && $0.isFailure }
        if !failures.isEmpty { lines.append("- \(failures.count) 次工具调用失败") }
        if task.steps.contains(where: { $0.toolName == "file.read" && $0.isFailure && ($0.text.contains("unsupported_binary_file") || $0.text.contains("文档/表格")) }) {
            lines.append("- 表格/文档读取失败：下一步必须使用 file_extract 提取同一路径")
        }
        // Include last meaningful output
        if let lastOutput = task.steps.last(where: { $0.kind == .textOutput }) {
            let preview = compactSummaryText(lastOutput.text, limit: 300)
            lines.append("- 最近输出：\(preview)")
        }
        return lines.isEmpty ? "（暂无有效进展）" : lines.joined(separator: "\n")
    }

    static func compactSummaryText(_ text: String, limit: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(max(0, limit - 1))) + "…"
    }

    /// Build a context-aware nudge when the model returns an empty response.
    /// Instead of generic "继续", tell it specifically what to do next.
    static func buildEmptyResponseNudge(task: AgentTask, intent: UserIntent) -> String {
        let toolCalls = task.steps.filter { $0.kind == .toolCall }.count
        let writes = task.steps.filter { $0.kind == .reviewRequest }.count
        let failures = task.steps.filter { $0.isFailure }
        let lastUserMsg = task.steps.last(where: { $0.kind == .userInput })?.text ?? ""

        if toolCalls == 0 {
            return "你还没有调用任何工具。请立即使用工具开始执行任务。先调 workspace_index 了解项目，然后用 file_read 读取关键文件。"
        }
        if !failures.isEmpty, let lastFail = failures.last {
            if lastFail.toolName == "file.read", lastFail.text.contains("unsupported_binary_file") || lastFail.text.contains("文档/表格") || lastFail.text.contains("file_extract") {
                return "上一步用 file_read 读取表格/文档失败。请立即改用 file_extract 读取同一路径；提取成功后继续完成用户目标，不要把失败当作最终答案。"
            }
            return "上一步失败了：\(String(lastFail.text.prefix(100)))。请换一种方法继续。不要用相同参数重试。"
        }
        if writes > 0 && lastUserMsg.contains("空") {
            return "用户反馈文件内容为空。请用 file_read 验证刚写入的文件是否确实有内容。如果为空，重新用 file_write 写入完整内容。"
        }
        if intent == .research {
            return "请调用 web_search 搜索相关信息，然后整理结果回答用户。"
        }
        let progress = compactProgressSummary(task: task)
        return "你返回了空响应。当前进展：\n\(progress)\n\n请根据进展继续下一步操作，使用工具完成目标。不要返回空内容。"
    }

    /// Suggest concrete alternative tools/approaches when a tool fails repeatedly.
    static func suggestAlternatives(for toolName: String, target: String) -> String {
        switch toolName {
        case "code.search":
            return "1) shell_exec 用 grep -r 或 find 搜索  2) workspace_index 查看项目结构  3) 换不同的关键词"
        case "file.read":
            return "1) code_search 搜索文件路径  2) shell_exec ls/find 确认路径  3) workspace_index 查看目录结构"
        case "file.edit":
            return "1) file_read 重新读取最新内容再 file_edit  2) file_write 全量写入  3) 检查 search 字符串是否精确匹配"
        case "shell.exec":
            return "1) 换更简单的命令  2) 拆分为多个小命令  3) 检查命令路径和权限"
        case "web.search", "web.fetch":
            return "1) 换不同的搜索关键词  2) 尝试不同的 URL  3) 基于已有信息直接回答"
        case "verify.build":
            return "1) file_read 检查语法错误  2) shell_exec 手动运行构建命令看详细输出  3) 逐个修复编译错误"
        default:
            return "1) 换一种工具达成同样目的  2) 简化操作范围  3) 确认参数是否正确"
        }
    }

    /// C2: Detect plan-only responses — model says what it WILL do but doesn't call tools.
    static func looksLikePlanOnly(_ text: String) -> Bool {
        let lower = text.lowercased()
        let planIndicators = [
            "我将", "我会", "我来", "首先", "第一步", "步骤", "计划如下", "方案如下",
            "接下来", "让我", "需要先", "我打算", "执行计划", "分析如下",
            "先补齐", "先拆分", "先读取", "先整理", "继续整理", "继续处理", "继续执行",
            "i will", "i'll", "let me", "first,", "step 1", "here's my plan"
        ]
        let matchCount = planIndicators.filter { lower.contains($0) }.count
        // Short texts need only 1 indicator; longer texts need 2
        let threshold = text.count < 200 ? 1 : 2
        guard matchCount >= threshold else { return false }
        // If text contains actual code blocks or specific file paths, it might be useful output
        if text.contains("```") && text.components(separatedBy: "```").count > 2 { return false }
        return true
    }

    static func initialMessages(systemPrompt: String, message: String, priorSteps: [TaskStep], summaryCache: String? = nil, context: TaskContext = TaskContext(), imageAttachments: [ImageAttachment] = []) -> [ChatMessage] {
        var messages: [ChatMessage] = [ChatMessage(role: "system", content: systemPrompt)]
        if let memory = structuredTaskMemory(from: priorSteps, context: context) {
            messages.append(ChatMessage(
                role: "user",
                content: """
                下面是同一任务的结构化记忆。请优先使用它判断哪些文件已经读过、哪些工具失败过、目前阶段结论是什么；不要重复已经成功的读取或搜索。

                \(memory)
                """
            ))
        }
        if UserFrustrationDetector.isFrustrated(message) {
            messages.append(ChatMessage(
                role: "user",
                content: "用户当前在纠错或表达不满。\n\(UserFrustrationDetector.guidance)"
            ))
        }
        // Positive feedback reinforcement: boost learned skill Q-value when user praises
        if UserFrustrationDetector.isPositive(message),
           let skillID = context.metadata["learnedSkillID"].flatMap(Int.init) {
            SkillEvolutionEngine.shared.updateQ(skillID: skillID, outcomeScore: 90, succeeded: true)
        }
        // Use summary cache for early steps if available, otherwise compact full history
        if let cache = summaryCache, !cache.isEmpty {
            messages.append(ChatMessage(
                role: "user",
                content: """
                下面是同一任务早期步骤的摘要缓存，省略了详细内容。请把本轮当作续接，不要重新开始，不要重复已经完成的搜索、读取或解释；只在证据不足时继续调用工具。

                \(cache)
                """
            ))
            // Still include recent steps for precise context
            let recentHistory = compactHistoryMessages(from: Array(priorSteps.suffix(14)), contextMode: context.contextMode)
            if !recentHistory.isEmpty {
                messages.append(contentsOf: recentHistory)
            }
        } else {
            let history = compactHistoryMessages(from: priorSteps, contextMode: context.contextMode)
            if !history.isEmpty {
                messages.append(ChatMessage(
                    role: "user",
                    content: "下面是同一任务之前的关键上下文。请把本轮当作续接，不要重新开始，不要重复已经完成的搜索、读取或解释；只在证据不足时继续调用工具。"
                ))
                messages.append(contentsOf: history)
            }
        }
        // G12: Detect image file paths and convert to vision content parts
        let imagePathPattern = #"(?:^|\s|：)(/[^\s]+\.(?:png|jpg|jpeg|gif|webp|bmp|tiff))"#
        var imageParts: [ContentPart] = []
        if let regex = try? NSRegularExpression(pattern: imagePathPattern, options: .caseInsensitive) {
            let ns = message as NSString
            let matches = regex.matches(in: message, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let path = ns.substring(with: match.range(at: 1))
                if FileManager.default.fileExists(atPath: path),
                   let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   data.count < 20_000_000 {  // Skip files > 20MB
                    let ext = (path as NSString).pathExtension.lowercased()
                    let mediaType = ext == "png" ? "image/png" : ext == "gif" ? "image/gif" : ext == "webp" ? "image/webp" : "image/jpeg"
                    imageParts.append(.imageBase64(data: data, mediaType: mediaType))
                }
            }
        }

        // Merge user-pasted images from UI
        for img in imageAttachments {
            imageParts.append(img.toContentPart())
        }

        if !imageParts.isEmpty {
            var parts: [ContentPart] = [.text(message)]
            parts.append(contentsOf: imageParts)
            messages.append(ChatMessage(role: "user", contentParts: parts))
        } else {
            messages.append(ChatMessage(role: "user", content: message))
        }
        return messages
    }

    static func structuredTaskMemory(from steps: [TaskStep], context: TaskContext = TaskContext()) -> String? {
        let readFiles = uniqueValues(
            steps
                .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
                .compactMap { $0.toolParams?["path"] }
        ) + context.memory.readFiles.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let searchedQueries = uniqueValues(
            steps
                .filter { $0.kind == .toolCall && $0.toolName == "code.search" }
                .compactMap { $0.toolParams?["query"] }
        ) + context.memory.searchedQueries.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let indexedWorkspace = steps.contains {
            $0.toolName == "workspace.index" && $0.kind == .toolResult && !$0.isFailure
        }
        let failedTools = steps.filter { $0.kind == .toolResult && $0.isFailure }
        let failureGroups = Dictionary(grouping: failedTools, by: { $0.toolName ?? "tool" })
            .map { "\($0.key) ×\($0.value.count)" }
            .sorted() + context.memory.failedTools
        let recentConclusions = steps
            .filter { $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(3)
            .map { compactSummaryText($0.text, limit: 260) } + context.memory.stageConclusions
        // Note: deliberately do NOT pull "任务检查点" / "阶段总结" / "证据清单"
        // aiThinking steps into memory. They are orchestration audits that contain
        // boilerplate ("状态：仍需继续") and re-feeding them to the model encourages
        // it to mimic the same internal audit format in user-visible output.
        let checkpoints = context.memory.checkpoints

        var lines = ["结构化任务记忆"]
        if indexedWorkspace {
            lines.append("- 已建立工作区索引：是")
        }
        if !readFiles.isEmpty {
            lines.append("- 已读文件：\(uniqueValues(readFiles).prefix(12).joined(separator: "、"))")
        }
        if !searchedQueries.isEmpty {
            lines.append("- 已搜索：\(uniqueValues(searchedQueries).prefix(8).joined(separator: "、"))")
        }
        if !failureGroups.isEmpty {
            lines.append("- 失败工具：\(uniqueValues(failureGroups).joined(separator: "、"))")
        }
        if let lastFailure = failedTools.last?.text.trimmingCharacters(in: .whitespacesAndNewlines), !lastFailure.isEmpty {
            lines.append("- 最近失败：\(compactSummaryText(lastFailure, limit: 260))")
        }
        if !recentConclusions.isEmpty {
            lines.append("- 阶段结论：\(recentConclusions.joined(separator: " / "))")
        }
        if !checkpoints.isEmpty {
            lines.append("- 最近检查点：\(uniqueValues(checkpoints).joined(separator: " / "))")
        }
        if let verification = context.memory.verificationStatus?.trimmingCharacters(in: .whitespacesAndNewlines), !verification.isEmpty {
            lines.append("- 验证状态：\(verification)")
        }
        if !context.memory.pendingFiles.isEmpty {
            lines.append("- 未读候选：\(uniqueValues(context.memory.pendingFiles).prefix(12).joined(separator: "、"))")
        }
        if !context.memory.userDecisions.isEmpty {
            lines.append("- 用户决策：\(uniqueValues(context.memory.userDecisions).prefix(8).joined(separator: " / "))")
        }

        guard lines.count > 1 else { return nil }
        return lines.joined(separator: "\n")
    }

    static func uniqueValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    static func compactHistoryMessages(from steps: [TaskStep], contextMode: ContextMode = .balanced) -> [ChatMessage] {
        let history = steps
            .filter { step in
                switch step.kind {
                case .userInput, .textOutput, .toolCall, .toolResult, .error, .reviewResult:
                    return !step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .aiThinking, .reviewRequest:
                    return false
                }
            }
            .suffix(14)

        // Budget-aware compression: allocate character budget per step kind
        let totalBudget: Int
        switch contextMode {
        case .economy: totalBudget = 4_000
        case .balanced: totalBudget = 9_000
        case .deep: totalBudget = 18_000
        }
        var remainingBudget = totalBudget

        return history.map { step in
            let role: String = step.kind == .userInput ? "user" : "assistant"
            let prefix: String
            let stepBudget: Int
            switch step.kind {
            case .toolCall:
                prefix = "上一轮工具调用："
                stepBudget = min(600, max(200, remainingBudget / 4))
            case .toolResult:
                prefix = step.isFailure ? "上一轮工具失败：" : "上一轮工具结果："
                stepBudget = min(800, max(200, remainingBudget / 3))
            case .error:
                prefix = "上一轮出现错误："
                stepBudget = min(600, max(200, remainingBudget / 4))
            case .reviewResult:
                prefix = "上一轮审查结果："
                stepBudget = min(400, max(150, remainingBudget / 5))
            case .userInput:
                prefix = ""
                stepBudget = min(1_400, max(400, remainingBudget / 2))
            default:
                prefix = ""
                stepBudget = min(2_000, max(400, remainingBudget / 2))
            }
            let content = prefix + compactHistoryText(step.text, limit: stepBudget)
            remainingBudget = max(0, remainingBudget - content.count)
            return ChatMessage(role: role, content: content)
        }
    }

    /// Compress mid-task conversation history when it grows too long.
    /// Keeps the system prompt, first user message, and recent messages intact;
    /// replaces older messages with a structured semantic summary.
    static func compressMidTaskHistory(_ messages: [ChatMessage], maxMessages: Int = 16) -> [ChatMessage] {
        guard messages.count > maxMessages else { return messages }

        // Always keep: system prompt (index 0), first user message, last N messages
        var result: [ChatMessage] = []

        // Keep system prompt
        if let first = messages.first, first.role == "system" {
            result.append(first)
        }

        // Identify the first user message (keep it for task context)
        let firstUserIdx = messages.firstIndex(where: { $0.role == "user" }) ?? 1

        // Collect messages to compress (between first user and last N)
        let keepRecent = maxMessages - result.count - 1 // -1 for first user
        let compressEnd = max(messages.count - keepRecent, firstUserIdx + 1)

        // Keep first user message
        if firstUserIdx < messages.count {
            result.append(messages[firstUserIdx])
        }

        // Semantic extraction from compressed block
        var filesRead: Set<String> = []
        var filesWritten: Set<String> = []
        var searchQueries: [String] = []
        var errors: [String] = []
        var decisions: [String] = []
        var toolSuccessCount = 0
        var toolFailCount = 0

        for i in (firstUserIdx + 1)..<compressEnd {
            let msg = messages[i]
            let content = msg.content ?? ""

            if msg.role == "tool" || msg.toolCallId != nil {
                let isFail = content.contains("❌") || content.contains("Error") || content.contains("失败")
                if isFail {
                    toolFailCount += 1
                    errors.append(String(content.prefix(120)))
                } else {
                    toolSuccessCount += 1
                }
                // Extract file paths from tool results
                if let path = extractPath(from: content) {
                    if content.contains("已读取") || content.contains("file.read") {
                        filesRead.insert(path)
                    } else if content.contains("已写入") || content.contains("file_edit") || content.contains("file_write") {
                        filesWritten.insert(path)
                    }
                }
                if content.contains("搜索") || content.contains("code.search") {
                    if let q = extractSearchQuery(from: content) { searchQueries.append(q) }
                }
            } else if msg.role == "assistant" {
                // Extract key decisions/code changes only
                if content.contains("```") || content.contains("file_edit") || content.contains("file_write") {
                    // Extract the first meaningful line as a decision
                    let firstLine = content.components(separatedBy: .newlines)
                        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("```") })
                    if let line = firstLine {
                        decisions.append(String(line.prefix(80)))
                    }
                }
            }
            // System messages are dropped entirely — they're already processed
        }

        // Build compact structured summary
        var summaryParts: [String] = []
        if !filesRead.isEmpty {
            summaryParts.append("已读: \(filesRead.sorted().map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))")
        }
        if !filesWritten.isEmpty {
            summaryParts.append("已改: \(filesWritten.sorted().map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))")
        }
        if !searchQueries.isEmpty {
            summaryParts.append("已搜索: \(searchQueries.prefix(5).joined(separator: ", "))")
        }
        if toolSuccessCount > 0 || toolFailCount > 0 {
            summaryParts.append("工具: \(toolSuccessCount)成功 \(toolFailCount)失败")
        }
        if !errors.isEmpty {
            summaryParts.append("错误: " + errors.prefix(3).joined(separator: "; "))
        }
        if !decisions.isEmpty {
            summaryParts.append("决策: " + decisions.prefix(3).joined(separator: "; "))
        }

        if !summaryParts.isEmpty {
            let summary = summaryParts.joined(separator: "\n")
            result.append(ChatMessage(
                role: "user",
                content: "[上下文摘要 · 已压缩 \(compressEnd - firstUserIdx - 1) 条消息]\n\(summary)\n\n请基于以上摘要和后续消息继续任务，不要重复已完成的步骤。"
            ))
        }

        // Keep recent messages intact
        for i in compressEnd..<messages.count {
            result.append(messages[i])
        }

        return result
    }

    /// Extract file path from tool result content
    private static func extractPath(from content: String) -> String? {
        // Pattern: "已读取 /path/to/file" or "path": "/path/to/file"
        let patterns = [
            #"已读取\s+(\S+)"#,
            #"已写入\s+(\S+)"#,
            #"\"path\"\s*:\s*\"([^\"]+)\""#,
            #"·\s+(/\S+)"#
        ]
        for pattern in patterns {
            if let match = content.range(of: pattern, options: .regularExpression) {
                let captured = String(content[match])
                // Extract the path part
                let path = captured.components(separatedBy: .whitespaces).last ?? captured
                let cleaned = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"·"))
                if cleaned.contains("/") { return cleaned }
            }
        }
        return nil
    }

    /// Extract search query from tool content
    private static func extractSearchQuery(from content: String) -> String? {
        let patterns = [#"搜索[：:]\s*(.{2,40})"#, #"query[：:]\s*\"?([^\"]{2,40})"#]
        for pattern in patterns {
            if let range = content.range(of: pattern, options: .regularExpression) {
                let match = String(content[range])
                let parts = match.components(separatedBy: CharacterSet(charactersIn: "：:"))
                return parts.last?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
            }
        }
        return nil
    }

    static func compactHistoryText(_ text: String, limit: Int = 1400) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        let head = cleaned.prefix(Int(Double(limit) * 0.65))
        let tail = cleaned.suffix(Int(Double(limit) * 0.25))
        return "\(head)\n... 历史内容已压缩 ...\n\(tail)"
    }

    /// Truncate tool result messages to fit within token budget.
    /// Keeps tool call messages intact, only truncates long tool result content.
    static func truncateToolResults(_ messages: [ChatMessage], maxTokens: Int) -> [ChatMessage] {
        var result = messages
        var totalChars = result.reduce(0) { $0 + (($1.content ?? "").count) + (($1.reasoningContent ?? "").count) }
        let charBudget = maxTokens * 4

        // Truncate from oldest tool results first
        for i in 0..<result.count {
            guard totalChars > charBudget else { break }
            let msg = result[i]
            guard let content = msg.content, content.count > 2000 else { continue }
            // Tool results have role "tool" or contain tool result patterns
            if msg.role == "tool" || msg.role == "assistant" && msg.toolCalls != nil && !msg.toolCalls!.isEmpty {
                continue // Don't truncate tool call messages
            }
            if msg.role == "tool" || content.hasPrefix("[TOOL_RESULT]") || content.hasPrefix("工具结果") {
                let truncated = String(content.prefix(800)) + "\n... [内容过长已截断，原始长度 \(content.count) 字符] ..."
                let saved = content.count - truncated.count
                totalChars -= saved
                result[i] = ChatMessage(
                    role: msg.role,
                    content: truncated,
                    reasoningContent: msg.reasoningContent,
                    toolCalls: msg.toolCalls
                )
            }
        }
        return result
    }

    /// Unified detection: model writing tool calls as text instead of using function calling API.
    /// Covers both fake syntax patterns and tool name spam.
    static func containsFakeToolCallSyntax(_ text: String) -> Bool {
        // Pattern 0: high-confidence single-match patterns (DSML, antml, function_calls XML, etc.)
        // These are unambiguous — model is leaking tool-call template syntax.
        let strongPatterns = [
            "<|DSML|", "<|dsml|",
            "<function_calls", "<invoke",
            "<function_calls>", "</function_calls>",
            "<invoke name=",
            "<tool_call>", "</tool_call>",
            "<|tool_call|>", "<|/tool_call|>",
            "<|assistant_tool_call|>"
        ]
        if strongPatterns.contains(where: { text.contains($0) }) { return true }
        // Pattern 1: explicit tool call syntax in text
        let syntaxPatterns = [
            "[tool:", "[TOOL:", "tool:web_search", "tool:file_read", "tool:code_search",
            "tool:workspace_index", "tool:shell_exec", "tool:diff_apply",
            "<file_read", "<code_search", "<web_search", "<shell_exec",
            "web_search(query=", "file_read(path=", "code_search(query=",
            "workspace_index(path=", "shell_exec(command=", "diff_apply(path="
        ]
        let syntaxMatches = syntaxPatterns.filter { text.contains($0) }.count
        if syntaxMatches >= 2 { return true }
        // Pattern 2: spam list of tool names (10+ mentions)
        let toolNames = ["shell.exec", "file.read", "file.write", "file.edit", "diff.apply",
                         "web.search", "web.fetch", "code.search", "workspace.index",
                         "shell_exec", "file_read", "file_write", "file_edit", "diff_apply",
                         "web_search", "web_fetch", "code_search", "workspace_index"]
        let totalMentions = toolNames.reduce(0) { count, name in
            count + text.components(separatedBy: name).count - 1
        }
        return totalMentions >= 10
    }

    /// Alias for backward compat — same as containsFakeToolCallSyntax
    static func looksLikeToolSpam(_ text: String) -> Bool {
        containsFakeToolCallSyntax(text)
    }

    /// Strip fake tool-call blocks from user-visible text. Used when the model leaks
    /// DSML / function_calls / invoke syntax inline. Returns cleaned prose; if everything
    /// would be stripped, returns nil so caller can fall back to a generic message.
    static func stripFakeToolCallBlocks(from text: String) -> String? {
        var cleaned = text
        // Remove block-style fakes: <|DSML| ... |>  and  <function_calls>...</function_calls>
        let blockPatterns: [String] = [
            #"<\|DSML\|[\s\S]*?(\|>|$)"#,
            #"<\|dsml\|[\s\S]*?(\|>|$)"#,
            #"<function_calls>[\s\S]*?</function_calls>"#,
            #"<function_calls[\s\S]*?(?=\n\n|$)"#,
            #"<invoke[\s\S]*?</invoke>"#,
            #"<invoke[\s\S]*?(?=\n\n|$)"#,
            #"<tool_call>[\s\S]*?</tool_call>"#,
            #"<\|tool_call\|>[\s\S]*?(<\|/tool_call\|>|$)"#,
            #"<\|assistant_tool_call\|>[\s\S]*?(?=\n\n|$)"#
        ]
        for pattern in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
            }
        }
        cleaned = cleaned.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func looksLikeProviderError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        // Only match if text is short (error messages are typically brief, not full answers)
        let isShort = text.count < 500
        let hasErrorPrefix = text.hasPrefix("请求格式不被")
            || text.hasPrefix("请求失败")
            || text.hasPrefix("无法连接")
        let hasErrorKeyword = lowered.contains("invalid_request_error")
            || lowered.contains("provider returned")
        // URL pattern only counts as error if at start of text (error format: "...URL: http://...")
        let hasErrorURL = isShort && (text.contains("URL: http://") || text.contains("URL: https://"))
            && (lowered.contains("返回") || lowered.contains("failed") || lowered.contains("error"))
        return hasErrorPrefix || hasErrorKeyword || hasErrorURL
    }

    static func isTransientError(_ error: Error) -> Bool {
        let desc = error.localizedDescription.lowercased()
        // Network / connection errors
        if desc.contains("timeout") || desc.contains("超时") { return true }
        if desc.contains("connection") || desc.contains("连接") { return true }
        if desc.contains("network") || desc.contains("网络") { return true }
        if desc.contains("reset") || desc.contains("broken pipe") { return true }
        // Rate limiting
        if desc.contains("429") || desc.contains("rate limit") || desc.contains("限流") { return true }
        if desc.contains("too many requests") { return true }
        // Server errors (5xx)
        if desc.contains("500") || desc.contains("502") || desc.contains("503") || desc.contains("504") { return true }
        if desc.contains("server error") || desc.contains("服务不可用") { return true }
        // Parse / decode errors (often transient — proxy returned bad data)
        if desc.contains("cannot parse") || desc.contains("parse response") { return true }
        if desc.contains("decode") && desc.contains("response") { return true }
        // URLSession specific
        if desc.contains("urlerror") || desc.contains("not connected") { return true }
        if desc.contains("cannot find host") { return true }
        return false
    }

    /// Auto-checkpoint selected files before write operations.
    /// This creates a safety net the user can roll back to with `git reset HEAD~1`.
    /// Using commit instead of stash because stash hides all uncommitted changes,
    /// while commit preserves them in history for easy inspection and rollback.
    static func gitCheckpoint(workspaceRoot: String, paths: [String] = []) {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }
        // Only checkpoint if it's a git repo
        let gitDir = root + "/.git"
        guard FileManager.default.fileExists(atPath: gitDir) else { return }
        let stagePaths = normalizedCheckpointPaths(paths, workspaceRoot: root)
        guard !stagePaths.isEmpty else { return }

        // Stage only the files touched by the current tool call.
        let addProcess = Process()
        addProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        addProcess.currentDirectoryURL = URL(fileURLWithPath: root)
        addProcess.arguments = ["git", "add", "--"] + stagePaths
        let pipe = Pipe()
        addProcess.standardOutput = pipe
        addProcess.standardError = pipe
        try? addProcess.run()
        addProcess.waitUntilExit()

        // Check if there are staged changes to commit
        let statusProcess = Process()
        statusProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        statusProcess.currentDirectoryURL = URL(fileURLWithPath: root)
        statusProcess.arguments = ["git", "diff", "--cached", "--quiet"]
        let statusPipe = Pipe()
        statusProcess.standardOutput = statusPipe
        statusProcess.standardError = statusPipe
        try? statusProcess.run()
        statusProcess.waitUntilExit()

        // If there are staged changes (exit code 1 = differences exist), commit them
        if statusProcess.terminationStatus != 0 {
            let commitProcess = Process()
            commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            commitProcess.currentDirectoryURL = URL(fileURLWithPath: root)
            commitProcess.arguments = ["git", "commit", "-m", "来财自动检查点", "--allow-empty-message"]
            commitProcess.standardOutput = pipe
            commitProcess.standardError = pipe
            try? commitProcess.run()
            commitProcess.waitUntilExit()
        }
    }

    static func checkpointPaths(toolName: String, arguments: [String: String], workspaceRoot: String) -> [String] {
        switch toolName {
        case "file.write", "file.edit", "diff.apply":
            return [arguments["path"], arguments["target"], arguments["file"]].compactMap { $0 }
        default:
            return []
        }
    }

    static func normalizedCheckpointPaths(_ paths: [String], workspaceRoot: String) -> [String] {
        let rootURL = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        let rootPath = rootURL.path
        return Array(Set(paths.compactMap { rawPath -> String? in
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let url = URL(fileURLWithPath: trimmed, relativeTo: trimmed.hasPrefix("/") ? nil : rootURL).standardizedFileURL
            let path = url.path
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
            let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? nil : relative
        })).sorted()
    }

    // MARK: - Context Window Compression

    /// Compress message history to stay within token budget.
    /// Strategy: keep system prompt + recent N messages intact, compress older messages.
    /// - Summarize old tool results into one-line summaries
    /// - Fold consecutive failed tool calls into a single summary
    /// - Deduplicate repeated file.read results for the same file
    static func compressMessages(_ messages: inout [ChatMessage], estimatedTokenBudget: Int) {
        let estimatedTokens = messages.reduce(0) { $0 + roughTokenCount($1.content ?? "") }
        guard estimatedTokens > estimatedTokenBudget else { return }

        // Keep first message (system prompt) and last 8 messages intact
        let keepHead = 1
        let keepTail = 8
        guard messages.count > keepHead + keepTail else { return }

        let compressibleRange = keepHead..<(messages.count - keepTail)
        var compressed: [ChatMessage] = Array(messages[0..<keepHead])

        // Group compressible messages and compress
        var i = compressibleRange.lowerBound
        while i < compressibleRange.upperBound {
            let msg = messages[i]
            let content = msg.content ?? ""

            // Compress tool results: keep only summary
            if msg.role == "user" && content.hasPrefix("工具") && content.count > 500 {
                let firstLine = content.components(separatedBy: "\n").first ?? content
                compressed.append(ChatMessage(role: msg.role, content: String(firstLine.prefix(200)) + " [已压缩]"))
                i += 1
                continue
            }

            // Compress tool call result pairs
            if msg.role == "tool" && content.count > 800 {
                // Extract first meaningful line as summary
                let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let summary = lines.prefix(3).joined(separator: "\n")
                compressed.append(ChatMessage(role: msg.role, content: String(summary.prefix(400)) + "\n[…已压缩]", toolCallId: msg.toolCallId))
                i += 1
                continue
            }

            // Fold consecutive system messages into one
            if msg.role == "system" {
                var combined = content
                while i + 1 < compressibleRange.upperBound && messages[i + 1].role == "system" {
                    i += 1
                    combined += "\n" + (messages[i].content ?? "")
                }
                if combined.count > 600 {
                    combined = String(combined.prefix(600)) + " [已压缩]"
                }
                compressed.append(ChatMessage(role: "system", content: combined))
                i += 1
                continue
            }

            // Keep other messages but truncate if very long
            if content.count > 2000 {
                compressed.append(ChatMessage(role: msg.role, content: String(content.prefix(1500)) + "\n[…已压缩]", toolCallId: msg.toolCallId))
            } else {
                compressed.append(msg)
            }
            i += 1
        }

        // Append tail
        compressed.append(contentsOf: messages[(messages.count - keepTail)...])
        messages = compressed
    }

    /// Rough token estimate: ~1.5 chars per token for mixed CJK/English
    static func roughTokenCount(_ text: String) -> Int {
        max(1, text.count * 2 / 3)
    }

    /// Deduplicate tool call cache entries that are semantically equivalent.
    /// Returns true if the new query is a semantic duplicate of a cached one.
    static func isSemanticDuplicate(newQuery: String, cachedQueries: [String], toolName: String) -> Bool {
        guard toolName == "code.search" || toolName == "web.search" else { return false }
        let newNorm = newQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for cached in cachedQueries {
            let cachedNorm = cached.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            // Exact match
            if newNorm == cachedNorm { return true }
            // Containment match
            if newNorm.contains(cachedNorm) || cachedNorm.contains(newNorm) { return true }
            // Word overlap: if >80% words overlap, it's a duplicate
            let newWords = Set(newNorm.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 1 })
            let cachedWords = Set(cachedNorm.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 1 })
            guard !newWords.isEmpty && !cachedWords.isEmpty else { continue }
            let overlap = newWords.intersection(cachedWords).count
            let maxSize = max(newWords.count, cachedWords.count)
            if Double(overlap) / Double(maxSize) > 0.8 { return true }
        }
        return false
    }

}
