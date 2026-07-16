import Foundation
import LaicaiNativeDomain

extension AgentLoop {
    /// Build a compact progress summary for auto-continuation rounds
    static func compactProgressSummary(task: AgentTask) -> String {
        var lines: [String] = []
        let reads = task.steps.filter {
            $0.kind == .toolResult && ["file.read", "file.extract", "document.transform"].contains($0.toolName ?? "") && !$0.isFailure
        }
        if !reads.isEmpty { lines.append("- 已读取 \(reads.count) 个文件") }
        let writes = task.steps.filter { step in
            step.kind == .toolResult && !step.isFailure && (isFileChangeTool(step.toolName ?? "") || isSuccessfulDocumentWrite(step))
        }
        if !writes.isEmpty { lines.append("- 已修改 \(writes.count) 个文件") }
        let shells = task.steps.filter { $0.kind == .toolResult && $0.toolName == "shell.exec" && !$0.isFailure }
        if !shells.isEmpty { lines.append("- 已执行 \(shells.count) 个命令") }
        let searches = task.steps.filter {
            $0.kind == .toolResult && ["code.search", "web.search"].contains($0.toolName ?? "") && !$0.isFailure
        }
        if !searches.isEmpty { lines.append("- 已搜索 \(searches.count) 次") }
        let failures = task.steps.filter { ($0.kind == .toolResult || $0.kind == .error || $0.kind == .aiThinking) && $0.isFailure }
        if !failures.isEmpty { lines.append("- \(failures.count) 次工具调用失败") }
        if task.steps.contains(where: {
            $0.toolName == "file.read" && $0.isFailure && ($0.text.contains("unsupported_binary_file") || $0.text.contains("文档/表格"))
        }) {
            lines.append("- 表格/文档读取失败：阅读用 file_extract；要生成/翻译/改写 Office 文档用 document_transform")
        }
        // Include last meaningful output
        if let lastOutput = task.steps.last(where: { $0.kind == .textOutput }) {
            let preview = compactSummaryText(lastOutput.text, limit: 300)
            lines.append("- 最近输出：\(preview)")
        }
        return lines.isEmpty ? "（暂无有效进展）" : lines.joined(separator: "\n")
    }

    static func compactSummaryText(_ text: String, limit: Int) -> String {
        let cleaned =
            text
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
            return "你还没有调用任何工具。请立即使用工具推进当前会话目标。先调 workspace_index 了解项目，然后用 file_read 读取关键文件。"
        }
        if !failures.isEmpty, let lastFail = failures.last {
            if lastFail.toolName == "file.read",
                lastFail.text.contains("unsupported_binary_file") || lastFail.text.contains("文档/表格")
                    || lastFail.text.contains("file_extract")
            {
                return
                    "上一步用 file_read 读取表格/文档失败。若只是阅读请改用 file_extract；若用户要生成、翻译、改写或保存 Office 文档，请改用 document_transform(action=prepare/apply)。不要把失败当作最终答案。"
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
            return "1) 文档/表格/演示文稿改用 document_transform 或 file_extract  2) code_search 搜索文件路径  3) workspace_index 查看目录结构"
        case "file.extract":
            return "1) 若目标是生成/改写 Office 文档，改用 document_transform  2) 若只是阅读，尝试 shell_exec 调系统转换工具  3) 明确说明缺少 OCR/转换组件"
        case "document.transform":
            return "1) 如果 prepare 已成功但 apply/render 重复失败，停止重试 document_transform  2) 改用 shell_exec 调系统工具/脚本真实生成交付物  3) 不支持图片文字或版式时明确列为未完成项"
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
            "i will", "i'll", "let me", "first,", "step 1", "here's my plan",
        ]
        let matchCount = planIndicators.filter { lower.contains($0) }.count
        // Short texts need only 1 indicator; longer texts need 2
        let threshold = text.count < 200 ? 1 : 2
        guard matchCount >= threshold else { return false }
        // If text contains actual code blocks or specific file paths, it might be useful output
        if text.contains("```") && text.components(separatedBy: "```").count > 2 { return false }
        return true
    }

    static func initialMessages(
        systemPrompt: String,
        message: String,
        priorSteps: [TaskStep],
        summaryCache: String? = nil,
        context: TaskContext = TaskContext(),
        imageAttachments: [ImageAttachment] = []
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = [ChatMessage(role: "system", content: systemPrompt)]
        appendStructuredMemory(to: &messages, priorSteps: priorSteps, context: context)
        appendContinuationRecovery(to: &messages, message: message, priorSteps: priorSteps, context: context)
        appendLastOutput(to: &messages, priorSteps: priorSteps)
        appendFrustrationGuidance(to: &messages, message: message)
        reinforcePositiveFeedback(message: message, context: context)
        appendHistoryContext(to: &messages, priorSteps: priorSteps, summaryCache: summaryCache, context: context)
        appendUserMessage(to: &messages, message: message, imageAttachments: imageAttachments)
        return messages
    }

    private static func appendStructuredMemory(
        to messages: inout [ChatMessage],
        priorSteps: [TaskStep],
        context: TaskContext
    ) {
        if let memory = structuredTaskMemory(from: priorSteps, context: context) {
            messages.append(
                ChatMessage(
                    role: "user",
                    content: """
                        下面是当前会话 的结构化记忆。请优先使用它判断哪些文件已经读过、哪些工具失败过、目前阶段结论是什么；不要重复已经成功的读取或搜索。

                        \(memory)
                        """
                ))
        }
    }

    private static func appendContinuationRecovery(
        to messages: inout [ChatMessage],
        message: String,
        priorSteps: [TaskStep],
        context: TaskContext
    ) {
        if let recoveryBrief = continuationRecoveryBrief(message: message, priorSteps: priorSteps, context: context) {
            messages.append(
                ChatMessage(
                    role: "user",
                    content: recoveryBrief
                ))
        }
    }

    private static func appendLastOutput(to messages: inout [ChatMessage], priorSteps: [TaskStep]) {
        if let lastOutput = priorSteps.reversed().first(where: {
            $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?
        .text {
            messages.append(ChatMessage(role: "assistant", content: compactHistoryText(lastOutput, limit: 2_000)))
        }
    }

    private static func appendFrustrationGuidance(to messages: inout [ChatMessage], message: String) {
        if UserFrustrationDetector.isFrustrated(message) {
            messages.append(
                ChatMessage(
                    role: "user",
                    content: "用户当前在纠错或表达不满。\n\(UserFrustrationDetector.guidance)"
                ))
        }
    }

    private static func reinforcePositiveFeedback(message: String, context: TaskContext) {
        if UserFrustrationDetector.isPositive(message),
            let skillID = context.metadata["learnedSkillID"].flatMap(Int.init)
        {
            SkillEvolutionEngine.shared.updateQ(skillID: skillID, outcomeScore: 90, succeeded: true)
        }
    }

    private static func appendHistoryContext(
        to messages: inout [ChatMessage],
        priorSteps: [TaskStep],
        summaryCache: String?,
        context: TaskContext
    ) {
        if let cache = summaryCache, !cache.isEmpty {
            messages.append(
                ChatMessage(
                    role: "user",
                    content: """
                        下面是当前会话 早期步骤的摘要缓存，省略了详细内容。请把本轮当作续接，不要重新开始，不要重复已经完成的搜索、读取或解释；只在证据不足时继续调用工具。

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
                messages.append(
                    ChatMessage(
                        role: "user",
                        content: "下面是当前会话 之前的关键上下文。请把本轮当作续接，不要重新开始，不要重复已经完成的搜索、读取或解释；只在证据不足时继续调用工具。"
                    ))
                messages.append(contentsOf: history)
            }
        }
    }

    private static func appendUserMessage(
        to messages: inout [ChatMessage],
        message: String,
        imageAttachments: [ImageAttachment]
    ) {
        let imageParts = imageContentParts(from: message) + imageAttachments.map { $0.toContentPart() }
        guard !imageParts.isEmpty else {
            messages.append(ChatMessage(role: "user", content: message))
            return
        }
        var parts: [ContentPart] = [.text(message)]
        parts.append(contentsOf: imageParts)
        messages.append(ChatMessage(role: "user", contentParts: parts))
    }

    private static func imageContentParts(from message: String) -> [ContentPart] {
        let imagePathPattern = #"(?:^|\s|：)(/[^\s]+\.(?:png|jpg|jpeg|gif|webp|bmp|tiff))"#
        var imageParts: [ContentPart] = []
        if let regex = try? NSRegularExpression(pattern: imagePathPattern, options: .caseInsensitive) {
            let nsString = message as NSString
            let matches = regex.matches(in: message, range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                let path = nsString.substring(with: match.range(at: 1))
                if FileManager.default.fileExists(atPath: path),
                    let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                    data.count < 20_000_000
                {  // Skip files > 20MB
                    imageParts.append(.imageBase64(data: data, mediaType: imageMediaType(path)))
                }
            }
        }
        return imageParts
    }

    private static func imageMediaType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/jpeg"
        }
    }

    static func continuationRecoveryBrief(message: String, priorSteps: [TaskStep], context: TaskContext) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isContinuationRequest(trimmed, context: context), !priorSteps.isEmpty else { return nil }

        let evidence = ContinuationEvidence(
            originalGoal: originalGoal(from: priorSteps),
            recentUserGoal: recentUserGoal(from: priorSteps, excluding: trimmed),
            successfulReads: successfulReads(from: priorSteps, context: context),
            successfulWrites: successfulWrites(from: priorSteps),
            recentFailures: recentFailures(from: priorSteps),
            userDecisions: continuationUserDecisions(from: context)
        )

        let lines: [String] =
            [
                "## 续跑恢复现场",
                "本轮用户是在续接当前会话，不是提出一个只包含「\(trimmed)」的新目标。请以原始目标和已有证据为准，继续推进到可验证交付。",
            ] + continuationEvidenceLines(evidence)
            + ["- 规则：不要把「继续」当作搜索词或命令；不要把「继续」「？」当作搜索词或命令；不要重复已经失败的空工具调用；如果需要工具，必须给出完整参数。"]
        return lines.joined(separator: "\n")
    }

    private struct ContinuationEvidence {
        let originalGoal: String?
        let recentUserGoal: String?
        let successfulReads: [String]
        let successfulWrites: [String]
        let recentFailures: [String]
        let userDecisions: [String]
    }

    private static func isContinuationRequest(_ trimmed: String, context: TaskContext) -> Bool {
        let phrases = [
            "继续处理当前" + "任务",
            "继续处理当前会话",
            "继续这个会话",
            "从未完成处继续",
        ]
        return isPureContinuationCommand(trimmed)
            || phrases.contains { trimmed.localizedCaseInsensitiveContains($0) }
            || context.memory.userDecisions.contains { $0.contains("[continuation]") }
    }

    private static func originalGoal(from priorSteps: [TaskStep]) -> String? {
        priorSteps.first(where: isNonContinuationUserInput)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func recentUserGoal(from priorSteps: [TaskStep], excluding trimmed: String) -> String? {
        priorSteps.reversed().first {
            isNonContinuationUserInput($0) && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) != trimmed
        }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isNonContinuationUserInput(_ step: TaskStep) -> Bool {
        step.kind == .userInput
            && !step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isPureContinuationCommand(step.text)
    }

    private static func successfulReads(from priorSteps: [TaskStep], context: TaskContext) -> [String] {
        uniqueValues(
            priorSteps
                .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
                .compactMap { $0.toolParams?["path"] } + context.memory.readFiles)
    }

    private static func successfulWrites(from priorSteps: [TaskStep]) -> [String] {
        uniqueValues(
            priorSteps.compactMap { step -> String? in
                guard step.kind == .toolResult || step.kind == .reviewRequest else { return nil }
                guard !step.isFailure else { return nil }
                if isSuccessfulDocumentWrite(step) { return step.toolParams?["outputPath"] ?? step.toolParams?["pdfPath"] }
                guard isFileChangeTool(step.toolName ?? "") else { return nil }
                return step.toolParams?["path"] ?? step.diffFilePath
            })
    }

    private static func recentFailures(from priorSteps: [TaskStep]) -> [String] {
        priorSteps
            .filter { $0.kind == .toolResult && $0.isFailure || $0.kind == .error }
            .suffix(4)
            .map { step in
                let tool = step.toolName ?? (step.kind == .error ? "error" : "tool")
                return "- \(tool): \(compactSummaryText(step.text, limit: 180))"
            }
    }

    private static func continuationUserDecisions(from context: TaskContext) -> [String] {
        context.memory.userDecisions
            .filter { $0.contains("[continuation]") }
            .suffix(2)
            .map { compactSummaryText($0, limit: 600) }
    }

    private static func continuationEvidenceLines(_ evidence: ContinuationEvidence) -> [String] {
        [
            evidence.originalGoal.map { "- 原始目标：\(compactSummaryText($0, limit: 500))" },
            recentGoalLine(evidence),
            evidence.successfulReads.isEmpty ? nil : "- 已读文件：\(evidence.successfulReads.prefix(10).joined(separator: "、"))",
            evidence.successfulWrites.isEmpty ? nil : "- 已写/交付文件：\(evidence.successfulWrites.prefix(10).joined(separator: "、"))",
            evidence.recentFailures.isEmpty ? nil : "- 最近失败，下一步需恢复或换路：\n\(evidence.recentFailures.joined(separator: "\n"))",
            evidence.userDecisions.isEmpty ? nil : "- 编排恢复摘要：\(evidence.userDecisions.joined(separator: " / "))",
        ].compactMap { $0 }
    }

    private static func recentGoalLine(_ evidence: ContinuationEvidence) -> String? {
        guard let recentUserGoal = evidence.recentUserGoal,
            recentUserGoal != evidence.originalGoal
        else {
            return nil
        }
        return "- 最近用户要求：\(compactSummaryText(recentUserGoal, limit: 500))"
    }

    static func structuredTaskMemory(from steps: [TaskStep], context: TaskContext = TaskContext()) -> String? {
        let snapshot = TaskMemorySnapshot(steps: steps, context: context)
        let lines = ["结构化会话记忆"] + structuredTaskMemoryLines(snapshot)
        guard lines.count > 1 else { return nil }
        return lines.joined(separator: "\n")
    }

    private struct TaskMemorySnapshot {
        let readFiles: [String]
        let searchedQueries: [String]
        let indexedWorkspace: Bool
        let failedTools: [TaskStep]
        let failureGroups: [String]
        let recentConclusions: [String]
        let checkpoints: [String]
        let verificationStatus: String?
        let pendingFiles: [String]
        let userDecisions: [String]

        @MainActor
        init(steps: [TaskStep], context: TaskContext) {
            readFiles = AgentLoop.memoryReadFiles(steps: steps, context: context)
            searchedQueries = AgentLoop.memorySearchedQueries(steps: steps, context: context)
            indexedWorkspace = steps.contains {
                $0.toolName == "workspace.index" && $0.kind == .toolResult && !$0.isFailure
            }
            failedTools = steps.filter { $0.kind == .toolResult && $0.isFailure }
            failureGroups = AgentLoop.memoryFailureGroups(failedTools: failedTools, context: context)
            recentConclusions = AgentLoop.memoryRecentConclusions(steps: steps, context: context)
            checkpoints = context.memory.checkpoints
            verificationStatus = context.memory.verificationStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingFiles = context.memory.pendingFiles
            userDecisions = context.memory.userDecisions
        }
    }

    private static func memoryReadFiles(steps: [TaskStep], context: TaskContext) -> [String] {
        uniqueValues(
            steps
                .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
                .compactMap { $0.toolParams?["path"] }
        ) + context.memory.readFiles.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func memorySearchedQueries(steps: [TaskStep], context: TaskContext) -> [String] {
        uniqueValues(
            steps
                .filter { $0.kind == .toolCall && $0.toolName == "code.search" }
                .compactMap { $0.toolParams?["query"] }
        ) + context.memory.searchedQueries.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func memoryFailureGroups(failedTools: [TaskStep], context: TaskContext) -> [String] {
        Dictionary(grouping: failedTools, by: { $0.toolName ?? "tool" })
            .map { "\($0.key) ×\($0.value.count)" }
            .sorted() + context.memory.failedTools
    }

    private static func memoryRecentConclusions(steps: [TaskStep], context: TaskContext) -> [String] {
        steps
            .filter { $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(3)
            .map { compactSummaryText($0.text, limit: 260) } + context.memory.stageConclusions
    }

    private static func structuredTaskMemoryLines(_ snapshot: TaskMemorySnapshot) -> [String] {
        [
            snapshot.indexedWorkspace ? "- 已建立工作区索引：是" : nil,
            snapshot.readFiles.isEmpty ? nil : "- 已读文件：\(uniqueValues(snapshot.readFiles).prefix(12).joined(separator: "、"))",
            snapshot.searchedQueries.isEmpty ? nil : "- 已搜索：\(uniqueValues(snapshot.searchedQueries).prefix(8).joined(separator: "、"))",
            snapshot.failureGroups.isEmpty ? nil : "- 失败工具：\(uniqueValues(snapshot.failureGroups).joined(separator: "、"))",
            lastFailureLine(snapshot.failedTools),
            snapshot.recentConclusions.isEmpty ? nil : "- 阶段结论：\(snapshot.recentConclusions.joined(separator: " / "))",
            snapshot.checkpoints.isEmpty ? nil : "- 最近检查点：\(uniqueValues(snapshot.checkpoints).joined(separator: " / "))",
            verificationLine(snapshot.verificationStatus),
            snapshot.pendingFiles.isEmpty ? nil : "- 未读候选：\(uniqueValues(snapshot.pendingFiles).prefix(12).joined(separator: "、"))",
            snapshot.userDecisions.isEmpty ? nil : "- 用户决策：\(uniqueValues(snapshot.userDecisions).prefix(8).joined(separator: " / "))",
        ].compactMap { $0 }
    }

    private static func lastFailureLine(_ failedTools: [TaskStep]) -> String? {
        guard let lastFailure = failedTools.last?.text.trimmingCharacters(in: .whitespacesAndNewlines),
            !lastFailure.isEmpty
        else {
            return nil
        }
        return "- 最近失败：\(compactSummaryText(lastFailure, limit: 260))"
    }

    private static func verificationLine(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return "- 验证状态：\(value)"
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
        let history =
            steps
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
            let presentation = historyPresentation(for: step, remainingBudget: remainingBudget)
            let content = presentation.prefix + compactHistoryText(step.text, limit: presentation.budget)
            remainingBudget = max(0, remainingBudget - content.count)
            return ChatMessage(role: role, content: content)
        }
    }

    private static func historyPresentation(
        for step: TaskStep,
        remainingBudget: Int
    ) -> (prefix: String, budget: Int) {
        switch step.kind {
        case .toolCall:
            return ("上一轮工具调用：", min(600, max(200, remainingBudget / 4)))
        case .toolResult:
            return (step.isFailure ? "上一轮工具失败：" : "上一轮工具结果：", min(800, max(200, remainingBudget / 3)))
        case .error:
            return ("上一轮出现错误：", min(600, max(200, remainingBudget / 4)))
        case .reviewResult:
            return ("上一轮审查结果：", min(400, max(150, remainingBudget / 5)))
        case .userInput:
            return ("", min(1_400, max(400, remainingBudget / 2)))
        default:
            return ("", min(2_000, max(400, remainingBudget / 2)))
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
        let keepRecent = maxMessages - result.count - 1  // -1 for first user
        let compressEnd = max(messages.count - keepRecent, firstUserIdx + 1)

        // Keep first user message
        if firstUserIdx < messages.count {
            result.append(messages[firstUserIdx])
        }

        var summary = MidTaskCompressionSummary()
        for index in (firstUserIdx + 1)..<compressEnd {
            summary.record(messages[index])
        }

        if let summaryMessage = summary.message(compressedCount: compressEnd - firstUserIdx - 1) {
            result.append(summaryMessage)
        }

        // Keep recent messages intact
        for index in compressEnd..<messages.count {
            result.append(messages[index])
        }

        return result
    }

    @MainActor
    private struct MidTaskCompressionSummary {
        var filesRead: Set<String> = []
        var filesWritten: Set<String> = []
        var searchQueries: [String] = []
        var errors: [String] = []
        var decisions: [String] = []
        var toolSuccessCount = 0
        var toolFailCount = 0

        mutating func record(_ message: ChatMessage) {
            let content = message.content ?? ""
            if message.role == "tool" || message.toolCallId != nil {
                recordToolContent(content)
            } else if message.role == "assistant" {
                recordAssistantContent(content)
            }
        }

        mutating func recordToolContent(_ content: String) {
            if content.contains("❌") || content.contains("Error") || content.contains("失败") {
                toolFailCount += 1
                errors.append(String(content.prefix(120)))
            } else {
                toolSuccessCount += 1
            }
            recordFilePath(from: content)
            if content.contains("搜索") || content.contains("code.search"),
                let query = AgentLoop.extractSearchQuery(from: content)
            {
                searchQueries.append(query)
            }
        }

        mutating func recordFilePath(from content: String) {
            guard let path = AgentLoop.extractPath(from: content) else { return }
            if content.contains("已读取") || content.contains("file.read") {
                filesRead.insert(path)
            } else if content.contains("已写入") || content.contains("file_edit") || content.contains("file_write") {
                filesWritten.insert(path)
            }
        }

        mutating func recordAssistantContent(_ content: String) {
            guard content.contains("```") || content.contains("file_edit") || content.contains("file_write") else { return }
            let firstLine = content.components(separatedBy: .newlines)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("```") }
            if let firstLine {
                decisions.append(String(firstLine.prefix(80)))
            }
        }

        func message(compressedCount: Int) -> ChatMessage? {
            let parts = summaryParts()
            guard !parts.isEmpty else { return nil }
            return ChatMessage(
                role: "user",
                content: "[上下文摘要 · 已压缩 \(compressedCount) 条消息]\n\(parts.joined(separator: "\n"))\n\n请基于以上摘要和后续消息继续当前会话，不要重复已完成的步骤。"
            )
        }

        private func summaryParts() -> [String] {
            var parts: [String] = []
            if !filesRead.isEmpty {
                parts.append("已读: \(fileNames(filesRead).joined(separator: ", "))")
            }
            if !filesWritten.isEmpty {
                parts.append("已改: \(fileNames(filesWritten).joined(separator: ", "))")
            }
            if !searchQueries.isEmpty {
                parts.append("已搜索: \(searchQueries.prefix(5).joined(separator: ", "))")
            }
            if toolSuccessCount > 0 || toolFailCount > 0 {
                parts.append("工具: \(toolSuccessCount)成功 \(toolFailCount)失败")
            }
            appendIssueParts(to: &parts)
            return parts
        }

        private func appendIssueParts(to parts: inout [String]) {
            if !errors.isEmpty {
                parts.append("错误: " + errors.prefix(3).joined(separator: "; "))
            }
            if !decisions.isEmpty {
                parts.append("决策: " + decisions.prefix(3).joined(separator: "; "))
            }
        }

        private func fileNames(_ paths: Set<String>) -> [String] {
            paths.sorted().map { URL(fileURLWithPath: $0).lastPathComponent }
        }
    }

    /// Extract file path from tool result content
    private static func extractPath(from content: String) -> String? {
        // Pattern: "已读取 /path/to/file" or "path": "/path/to/file"
        let patterns = [
            #"已读取\s+(\S+)"#,
            #"已写入\s+(\S+)"#,
            #"\"path\"\s*:\s*\"([^\"]+)\""#,
            #"·\s+(/\S+)"#,
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
        for index in 0..<result.count {
            guard totalChars > charBudget else { break }
            let msg = result[index]
            guard let content = msg.content, content.count > 2000 else { continue }
            // Tool results have role "tool" or contain tool result patterns
            if msg.role == "tool" || msg.role == "assistant" && msg.toolCalls != nil && !msg.toolCalls!.isEmpty {
                continue  // Don't truncate tool call messages
            }
            if msg.role == "tool" || content.hasPrefix("[TOOL_RESULT]") || content.hasPrefix("工具结果") {
                let truncated = String(content.prefix(800)) + "\n... [内容过长已截断，原始长度 \(content.count) 字符] ..."
                let saved = content.count - truncated.count
                totalChars -= saved
                result[index] = ChatMessage(
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
            "<|tool_call|>", "<|/tool_call|>", "</|tool_call|>",
            "<|assistant_tool_call|>",
        ]
        if strongPatterns.contains(where: { text.contains($0) }) { return true }
        // Pattern 1: explicit tool call syntax in text
        let syntaxPatterns = [
            "[tool:", "[TOOL:", "tool:web_search", "tool:file_read", "tool:code_search",
            "tool:workspace_index", "tool:shell_exec", "tool:diff_apply",
            "<file_read", "<code_search", "<web_search", "<shell_exec",
            "web_search(query=", "file_read(path=", "code_search(query=",
            "workspace_index(path=", "shell_exec(command=", "diff_apply(path=",
        ]
        let syntaxMatches = syntaxPatterns.filter { text.contains($0) }.count
        if syntaxMatches >= 2 { return true }
        if containsInlineCommandJSON(text) { return true }
        // Pattern 2: spam list of tool names (10+ mentions)
        let toolNames = [
            "shell.exec", "file.read", "file.write", "file.edit", "diff.apply",
            "web.search", "web.fetch", "code.search", "workspace.index",
            "shell_exec", "file_read", "file_write", "file_edit", "diff_apply",
            "web_search", "web_fetch", "code_search", "workspace_index",
        ]
        let totalMentions = toolNames.reduce(0) { count, name in
            count + text.components(separatedBy: name).count - 1
        }
        return totalMentions >= 10
    }

    /// Alias for backward compat — same as containsFakeToolCallSyntax
    static func looksLikeToolSpam(_ text: String) -> Bool {
        if containsInlineCommandJSON(text) { return false }
        return containsFakeToolCallSyntax(text)
    }

    static func sanitizeAssistantVisibleText(_ text: String) -> (text: String?, sanitized: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, false) }
        guard let cleaned = stripFakeToolCallBlocks(from: trimmed) else {
            return ("（已隐藏一段未执行的伪工具调用文本，请重新提问或切换支持 function calling 的模型）", true)
        }
        return (cleaned, cleaned != trimmed)
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
            #"<\|tool_call\|>[\s\S]*?(<\|/tool_call\|>|</\|tool_call\|>|$)"#,
            #"<\|assistant_tool_call\|>[\s\S]*?(?=\n\n|$)"#,
        ]
        for pattern in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
            }
        }
        cleaned = stripInlineCommandJSON(from: cleaned)
        cleaned = cleaned.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func containsInlineCommandJSON(_ text: String) -> Bool {
        inlineCommandJSONRanges(in: text).isEmpty == false
    }

    private static func stripInlineCommandJSON(from text: String) -> String {
        let ranges = inlineCommandJSONRanges(in: text)
        guard !ranges.isEmpty else { return text }
        var cleaned = text
        for range in ranges.reversed() {
            cleaned.removeSubrange(range)
        }
        return cleaned
    }

    private static func inlineCommandJSONRanges(in text: String) -> [Range<String.Index>] {
        let pattern =
            #"(?is)\{[\s\n\r]*"(cmd|command|tool|tool_name|name)"[\s\n\r]*:[\s\n\r]*"[^"]{1,4000}""#
            + #"([\s\n\r]*,[\s\n\r]*"[^"]+"[\s\n\r]*:[\s\n\r]*(?:"[^"]*"|true|false|null|-?\d+(\.\d+)?|\[[\s\S]*?\]|\{[\s\S]*?\}))*[\s\n\r]*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            guard !isInsideMarkdownCode(text, range: range) else { return nil }
            let block = String(text[range])
            return isLikelyLeakedToolCommandJSON(block) ? range : nil
        }
    }

    private static func isInsideMarkdownCode(_ text: String, range: Range<String.Index>) -> Bool {
        let before = text[..<range.lowerBound]
        let fenceCount = before.components(separatedBy: "```").count - 1
        if fenceCount % 2 == 1 { return true }
        let previous = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
        let next = range.upperBound < text.endIndex ? text[range.upperBound] : nil
        return previous == "`" || next == "`"
    }

    private static func isLikelyLeakedToolCommandJSON(_ block: String) -> Bool {
        guard let data = block.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let keys = Set(json.keys.map { $0.lowercased() })
        if let tool = (json["tool"] ?? json["tool_name"] ?? json["name"]) as? String {
            let normalizedTool = tool.lowercased()
            let knownToolPrefixes = [
                "shell", "file", "code", "workspace", "web", "diff", "browser",
                "wiki", "document", "skill", "image", "git",
            ]
            if knownToolPrefixes.contains(where: { normalizedTool.contains($0) }) {
                return true
            }
        }
        guard let command = (json["cmd"] ?? json["command"]) as? String else { return false }
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return false }
        let commandKeys = ["cmd", "command"]
        let toolArgumentKeys = [
            "cwd", "path", "timeout", "timeout_ms", "max_output_tokens", "sandbox_permissions",
            "justification", "workdir", "yield_time_ms",
        ]
        let shellPrefixes = [
            "ls", "cat", "sed", "rg", "grep", "find", "pwd", "python", "python3",
            "node", "npm", "pnpm", "yarn", "swift", "xcodebuild", "git", "bash",
            "sh", "zip", "unzip", "mkdir", "cp", "mv", "open", "defaults",
        ]
        let firstToken = trimmedCommand.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init) ?? ""
        let looksLikeShell = shellPrefixes.contains(firstToken) || trimmedCommand.contains(" && ") || trimmedCommand.contains("; ")
        return keys.intersection(Set(commandKeys + toolArgumentKeys)).count >= 2 || looksLikeShell
    }

    static func looksLikeProviderError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        // Only match if text is short (error messages are typically brief, not full answers)
        let isShort = text.count < 500
        let hasErrorPrefix =
            text.hasPrefix("请求格式不被")
            || text.hasPrefix("请求失败")
            || text.hasPrefix("无法连接")
        let hasErrorKeyword =
            lowered.contains("invalid_request_error")
            || lowered.contains("provider returned")
        // URL pattern only counts as error if at start of text (error format: "...URL: http://...")
        let hasErrorURL =
            isShort && (text.contains("URL: http://") || text.contains("URL: https://"))
            && (lowered.contains("返回") || lowered.contains("failed") || lowered.contains("error"))
        return hasErrorPrefix || hasErrorKeyword || hasErrorURL
    }

    static func isTransientError(_ error: Error) -> Bool {
        let desc = error.localizedDescription.lowercased()
        let transientKeywords = [
            "timeout", "超时", "connection", "连接", "network", "网络",
            "reset", "broken pipe", "429", "rate limit", "限流", "too many requests",
            "500", "502", "503", "504", "server error", "服务不可用",
            "cannot parse", "parse response", "urlerror", "not connected", "cannot find host",
        ]
        return transientKeywords.contains { desc.contains($0) }
            || (desc.contains("decode") && desc.contains("response"))
    }

    static func fallbackConnector(after failed: ConnectorProfile, allConnectors: [ConnectorProfile]) -> ConnectorProfile? {
        let candidates = allConnectors.filter { connector in
            connector.id != failed.id
                && connector.health != .offline
                && !ConnectorCapabilityProfile.isImageOnlyModel(connector.modelName)
        }
        return candidates.first(where: { $0.health == .ready }) ?? candidates.first
    }

    static func connectorFailoverStep(from failed: ConnectorProfile, to fallback: ConnectorProfile, reason: String) -> TaskStep {
        TaskStep(
            kind: .aiThinking,
            text: "模型连接不稳定，已从 \(displayConnectorName(failed)) 自动切换到 \(displayConnectorName(fallback)) 继续。\n原因：\(reason)",
            isCollapsible: true,
            isCollapsed: false,
            retryAction: connectorFailoverAction
        )
    }

    static func connectorFailoverMessage(from failed: ConnectorProfile, to fallback: ConnectorProfile, reason: String) -> ChatMessage {
        ChatMessage(
            role: "system",
            content:
                "连接器 \(displayConnectorName(failed)) 请求失败（\(reason)）。系统已自动切换到 \(displayConnectorName(fallback))，请基于同一用户目标继续，不要要求用户手动重试。"
        )
    }

    static func displayConnectorName(_ connector: ConnectorProfile) -> String {
        connector.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? connector.name
            : connector.modelName
    }

    // MARK: - Unified Error Recovery

    enum ErrorRecoveryAction {
        case connectorFailover(connector: ConnectorProfile)
        case transientRetry(delaySeconds: Int)
        case fatal
    }

    struct ErrorRecoveryContext {
        let error: Error
        let currentConnector: ConnectorProfile
        let allConnectors: [ConnectorProfile]
        let didConnectorFailover: Bool
        let transientRetryCount: Int
        let maxTransientRetries: Int
        let iteration: Int
        let effectiveMaxIterations: Int
    }

    /// Unified error recovery: decides whether to failover, retry, or give up.
    /// Consolidates the duplicated logic that was scattered across `run()`.
    static func resolveErrorRecovery(_ context: ErrorRecoveryContext) -> ErrorRecoveryAction {
        let isTransient = isTransientError(context.error)

        // 1. Transient + haven't failovered yet → try another connector
        if isTransient, !context.didConnectorFailover,
            let fallback = fallbackConnector(after: context.currentConnector, allConnectors: context.allConnectors)
        {
            return .connectorFailover(connector: fallback)
        }

        // 2. Transient + still have retries left → retry with backoff
        if isTransient,
            context.transientRetryCount < context.maxTransientRetries,
            context.iteration < context.effectiveMaxIterations
        {
            let delaySec = min(Int(pow(2.0, Double(context.transientRetryCount + 1))), 8)
            return .transientRetry(delaySeconds: delaySec)
        }

        // 3. Non-transient or retries exhausted + haven't failovered → try another connector
        if !context.didConnectorFailover,
            let fallback = fallbackConnector(after: context.currentConnector, allConnectors: context.allConnectors)
        {
            return .connectorFailover(connector: fallback)
        }

        // 4. Nothing left to try
        return .fatal
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
        guard
            let addResult = try? ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["git", "add", "--"] + stagePaths,
                currentDirectoryURL: URL(fileURLWithPath: root),
                timeout: 30
            ), addResult.exitCode == 0, !addResult.timedOut
        else { return }

        // Check if there are staged changes to commit
        guard
            let statusResult = try? ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["git", "diff", "--cached", "--quiet"],
                currentDirectoryURL: URL(fileURLWithPath: root),
                timeout: 15
            ), !statusResult.timedOut
        else { return }

        // If there are staged changes (exit code 1 = differences exist), commit them
        if statusResult.exitCode == 1 {
            _ = try? ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["git", "commit", "-m", "来财自动检查点", "--allow-empty-message"],
                currentDirectoryURL: URL(fileURLWithPath: root),
                timeout: 60
            )
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
        return Array(
            Set(
                paths.compactMap { rawPath -> String? in
                    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    let url = URL(fileURLWithPath: trimmed, relativeTo: trimmed.hasPrefix("/") ? nil : rootURL).standardizedFileURL
                    let path = url.path
                    guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
                    let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return relative.isEmpty ? nil : relative
                })
        ).sorted()
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
        var index = compressibleRange.lowerBound
        while index < compressibleRange.upperBound {
            let msg = messages[index]
            let content = msg.content ?? ""

            // Compress tool results: keep only summary
            if msg.role == "user" && content.hasPrefix("工具") && content.count > 500 {
                let firstLine = content.components(separatedBy: "\n").first ?? content
                compressed.append(ChatMessage(role: msg.role, content: String(firstLine.prefix(200)) + " [已压缩]"))
                index += 1
                continue
            }

            // Compress tool call result pairs
            if msg.role == "tool" && content.count > 800 {
                // Extract first meaningful line as summary
                let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let summary = lines.prefix(3).joined(separator: "\n")
                compressed.append(
                    ChatMessage(role: msg.role, content: String(summary.prefix(400)) + "\n[…已压缩]", toolCallId: msg.toolCallId))
                index += 1
                continue
            }

            // Fold consecutive system messages into one
            if msg.role == "system" {
                var combined = content
                while index + 1 < compressibleRange.upperBound && messages[index + 1].role == "system" {
                    index += 1
                    combined += "\n" + (messages[index].content ?? "")
                }
                if combined.count > 600 {
                    combined = String(combined.prefix(600)) + " [已压缩]"
                }
                compressed.append(ChatMessage(role: "system", content: combined))
                index += 1
                continue
            }

            // Keep other messages but truncate if very long
            if content.count > 2000 {
                compressed.append(
                    ChatMessage(role: msg.role, content: String(content.prefix(1500)) + "\n[…已压缩]", toolCallId: msg.toolCallId))
            } else {
                compressed.append(msg)
            }
            index += 1
        }

        // Append tail
        compressed.append(contentsOf: messages[(messages.count - keepTail)...])
        messages = compressed
    }

}
