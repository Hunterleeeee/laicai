import Foundation
import LaicaiNativeDomain

extension AppStore {
    static func taskMemory(from thread: Thread) -> TaskMemory {
        let readFiles = uniqueMemoryValues(thread.steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] })
        let searchedQueries = uniqueMemoryValues(thread.steps
            .filter { $0.kind == .toolCall && $0.toolName == "code.search" }
            .compactMap { $0.toolParams?["query"] })
        let failedTools = uniqueMemoryValues(Dictionary(grouping: thread.steps.filter { $0.kind == .toolResult && $0.isFailure }, by: { $0.toolName ?? "tool" })
            .map { "\($0.key) ×\($0.value.count)" }
            .sorted())
        let conclusions = thread.steps
            .filter { $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(3)
            .map { compactMemoryText($0.text, limit: 240) }
        let checkpoints = thread.steps
            .filter { $0.kind == .aiThinking && ($0.text.hasPrefix("任务检查点") || $0.text.hasPrefix("阶段总结")) }
            .suffix(2)
            .map { compactMemoryText($0.text, limit: 360) }
        let verification: String?
        if thread.status == .completed {
            verification = "已形成最终回复，需以后续验证命令为准。"
        } else if thread.status == .failed {
            verification = "任务失败或未完成，继续时优先恢复失败工具或补齐证据。"
        } else if thread.status == .cancelled {
            verification = "任务被取消，继续时沿用已读上下文并从未完成处推进。"
        } else {
            verification = nil
        }

        return TaskMemory(
            readFiles: readFiles,
            searchedQueries: searchedQueries,
            failedTools: failedTools,
            stageConclusions: uniqueMemoryValues(conclusions),
            checkpoints: uniqueMemoryValues(checkpoints),
            verificationStatus: verification,
            pendingFiles: pendingFileCandidates(from: thread.steps, alreadyRead: Set(readFiles)),
            userDecisions: thread.steps
                .filter { $0.kind == .reviewResult }
                .suffix(5)
                .map { compactMemoryText($0.text, limit: 160) },
            updatedAt: .now
        )
    }

    /// Extract unread file candidates from search/index results that haven't been read yet.
    static func pendingFileCandidates(from steps: [TaskStep], alreadyRead: Set<String>) -> [String] {
        var candidates: [String] = []
        // From code.search results: extract file paths mentioned
        for step in steps where step.kind == .toolResult && step.toolName == "code.search" && !step.isFailure {
            let lines = step.text.components(separatedBy: "\n")
            for line in lines {
                // Search results typically show "path:line: content"
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("src/") || trimmed.hasPrefix("Sources/") {
                    let path = trimmed.components(separatedBy: ":").first ?? trimmed
                    let cleanPath = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
                    if !alreadyRead.contains(cleanPath) && !cleanPath.isEmpty {
                        candidates.append(cleanPath)
                    }
                }
            }
        }
        // From workspace.index results: extract key file paths
        for step in steps where step.kind == .toolResult && step.toolName == "workspace.index" && !step.isFailure {
            let lines = step.text.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("入口") || trimmed.hasPrefix("测试") || trimmed.hasPrefix("配置") {
                    // Extract path after colon
                    if let colonRange = trimmed.range(of: "：") ?? trimmed.range(of: ":") {
                        let afterColon = trimmed[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)
                        if !afterColon.isEmpty && !alreadyRead.contains(afterColon) {
                            candidates.append(afterColon)
                        }
                    }
                }
            }
        }
        return Array(uniqueMemoryValues(candidates).prefix(12))
    }

    static func uniqueMemoryValues(_ values: [String]) -> [String] {
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

    static func compactMemoryText(_ text: String, limit: Int) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return "\(cleaned.prefix(limit))…"
    }

    func absolutePath(for path: String, workspaceRoot: String) -> String {
        if path.hasPrefix("/") { return path }
        return (workspaceRoot as NSString).appendingPathComponent(path)
    }

    func notify(_ message: String, style: AppNoticeStyle = .info) {
        state.notice = AppNotice(message: message, style: style)
    }

    static func agentLoopConfig(settings: AppSettings, connector: ConnectorProfile? = nil) -> AgentLoop.Config {
        let profile = ConnectorCapabilityProfile.infer(for: connector, mode: settings.contextMode)
        return AgentLoop.Config(
            maxIterations: profile.maxIterations,
            maxTokensPerTurn: profile.maxTokensPerTurn,
            workspaceRoot: settings.workspacePath,
            supportsToolCalling: profile.supportsToolCalling,
            contextMode: settings.contextMode,
            contextWindow: profile.contextWindow,
            modelName: connector?.modelName ?? "",
            usePipeline: settings.usePipeline
        )
    }

    static func agentLoopConfig(settings: AppSettings, connector: ConnectorProfile? = nil, decision: PlannerDecision) -> AgentLoop.Config {
        var config = agentLoopConfig(settings: settings, connector: connector)
        let needsProjectDepth = decision.expectedCapabilities.contains("读取工作区")
            || decision.expectedCapabilities.contains("提出文件修改")
            || {
                if case .workflow = decision.intent { return true }
                return false
            }()
        if needsProjectDepth {
            // Ensure at least the mode's iteration budget — profile already handles local vs remote caps
            config.maxIterations = max(config.maxIterations, settings.contextMode.maxIterations)
        }
        return config
    }

    static func plannerStepText(for decision: PlannerDecision) -> String {
        var lines = [
            "规划：\(decision.routeLabel) · 置信度 \(Int((decision.confidence * 100).rounded()))%",
            decision.reason
        ]
        if !decision.expectedCapabilities.isEmpty {
            lines.append("预计使用：\(decision.expectedCapabilities.joined(separator: "、"))")
        }
        return lines.joined(separator: "\n")
    }

    static func workflowCompletionCheckStep(steps: [TaskStep], hasError: Bool) -> TaskStep {
        let toolFailures = steps.filter { $0.kind == .toolResult && $0.isFailure }.count
        let text = hasError
            ? "完成检查：工作流发现 \(toolFailures) 个失败步骤，建议展开失败项后重试或调整目标。"
            : "完成检查：工作流已完成，未发现失败步骤。"
        return TaskStep(
            kind: .aiThinking,
            text: text,
            isCollapsible: true,
            isCollapsed: true,
            isFailure: hasError
        )
    }

    static func prepareThreadForContinuation(_ thread: inout Thread, message: String) {
        let checkpoint = latestCheckpoint(in: thread)
        thread.steps.removeAll { step in
            if step.kind == .textOutput,
               step.toolCallId == streamingOutputID,
               step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            guard step.kind == .error else { return false }
            let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if step.recoverable && !step.isFailure { return true }
            if text.contains("已达到最大迭代次数") { return true }
            if text.contains("上次运行被中断") || text.contains("已自动标记为已暂停") || text.contains("已自动标记为已取消") { return true }
            return false
        }

        guard (isContinuationCommand(message) || isLikelyTaskFollowUp(message)),
              !thread.context.memory.userDecisions.contains(where: { $0.contains("[continuation]") }) else { return }
        let checkpointText = checkpoint.map { "\n\n最近检查点：\($0)" } ?? ""

        // Build detailed operation summary for continuation
        let readFiles = thread.steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] }
        let writtenFiles = thread.steps
            .filter { $0.kind == .reviewRequest && $0.toolName == "file.write" }
            .compactMap(\.diffFilePath)
        let failedOps = thread.steps
            .filter { $0.isFailure }
            .prefix(5)
            .map { "  - \($0.toolName ?? "?")：\(String($0.text.prefix(80)))" }
        var summary = "继续策略：沿用已有结果，从未完成处继续。\n\n"
        summary += "## 已完成操作\n"
        if !readFiles.isEmpty {
            summary += "- 已读取 \(Set(readFiles).count) 个文件：\(Array(Set(readFiles)).sorted().prefix(10).joined(separator: "、"))\n"
        }
        if !writtenFiles.isEmpty {
            summary += "- 已写入 \(Set(writtenFiles).count) 个文件：\(Array(Set(writtenFiles)).sorted().prefix(10).joined(separator: "、"))\n"
        }
        if readFiles.isEmpty && writtenFiles.isEmpty {
            summary += "- 暂无有效操作记录\n"
        }
        if !failedOps.isEmpty {
            summary += "\n## 失败操作（不要重复同样的错误）\n\(failedOps.joined(separator: "\n"))\n"
        }
        summary += "\n## 要求\n"
        summary += "- 不要重复读取已读文件，不要重新 workspace_index\n"
        summary += "- 从上次中断处继续执行\n"
        summary += "- 如果用户反馈某些文件内容为空，先用 file_read 验证再重写"
        summary += checkpointText

        // Inject as context memory, NOT as visible step — user should never see this
        thread.context.memory.appendDecision("[continuation] \(summary)")
    }

    static func ensureCheckpointIfNeeded(_ thread: inout Thread) {
        guard thread.status == .failed || thread.status == .cancelled || thread.steps.contains(where: { $0.text.contains("已达到最大迭代次数") }) else { return }
        guard latestCheckpoint(in: thread) == nil else { return }
        thread.steps.append(makeCheckpointStep(for: thread))
    }

    static func makeCheckpointStep(for thread: Thread) -> TaskStep {
        let toolCalls = thread.steps.filter { $0.kind == .toolCall }.count
        let failedTools = thread.steps.filter { $0.kind == .toolResult && $0.isFailure }
        let readFiles = thread.steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] }
        let lastOutput = thread.steps.reversed().first {
            $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastFailure = thread.steps.reversed().first {
            $0.kind == .error || $0.isFailure
        }?.text.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines = ["任务检查点"]
        lines.append("状态：\(thread.status.title)")
        lines.append("已执行：\(toolCalls) 次工具调用")
        if !readFiles.isEmpty {
            lines.append("已读取：\(Array(Set(readFiles)).sorted().prefix(8).joined(separator: "、"))")
        }
        if !failedTools.isEmpty {
            let grouped = Dictionary(grouping: failedTools, by: { $0.toolName ?? "tool" })
                .map { "\($0.key) ×\($0.value.count)" }
                .sorted()
                .joined(separator: "、")
            lines.append("失败：\(grouped)")
        }
        if let lastFailure, !lastFailure.isEmpty {
            lines.append("最近失败：\(String(lastFailure.prefix(220)))")
        }
        if let lastOutput, !lastOutput.isEmpty {
            lines.append("阶段输出：\(String(lastOutput.prefix(260)))")
        }
        lines.append("建议下一步：基于已读结果继续，优先补齐未读关键文件；如果是整项目任务，先使用 workspace.index 或已有索引，不要重复低效 shell 遍历。")
        return TaskStep(
            kind: .aiThinking,
            text: lines.joined(separator: "\n"),
            isCollapsible: true,
            isCollapsed: true,
            isFailure: thread.status == .failed
        )
    }

    static func latestCheckpoint(in thread: Thread) -> String? {
        thread.steps.reversed().first {
            $0.kind == .aiThinking && $0.text.hasPrefix("任务检查点")
        }?.text
    }

    static func retryMessage(for thread: Thread, lastUserMessage: String) -> String {
        let original = lastUserMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        // Don't wrap the message — prepareThreadForContinuation already injects
        // the continuation strategy as an aiThinking step. Wrapping the message
        // causes the bootstrap to search for the wrapper text in the codebase.
        return original
    }

    static func taskHasUsefulProgress(_ thread: Thread) -> Bool {
        thread.steps.contains { step in
            switch step.kind {
            case .toolCall, .toolResult, .textOutput, .reviewRequest, .reviewResult:
                return !step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .userInput, .aiThinking, .error:
                return false
            }
        }
    }

    static func relevantFileLimit(settings: AppSettings, connector: ConnectorProfile) -> Int {
        ConnectorCapabilityProfile.infer(for: connector, mode: settings.contextMode).relevantFileLimit
    }

    static func directOutputLimit(for connector: ConnectorProfile) -> Int? {
        ConnectorCapabilityProfile.infer(for: connector, mode: .balanced).directOutputLimit
    }

    static func chatPrompt(context: TaskContext, message: String) -> String {
        var prompt = PromptComposer.composeChatPrompt(context: context)
        if UserFrustrationDetector.isFrustrated(message) {
            prompt += "\n\n## 用户纠错/挫败信号\n\(UserFrustrationDetector.guidance)"
        }
        return prompt
    }

    static func isLocalConnector(_ connector: ConnectorProfile) -> Bool {
        ConnectorCapabilityProfile.isLocalConnector(connector)
    }

    static func directHistory(for steps: [TaskStep], message: String) -> [TaskStep] {
        // Always carry history in chat sessions — losing context is the #1 complaint.
        // The runtime layer (compactHistory) will handle truncation if history is too long.
        return steps
            .filter { step in
                !step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && step.kind != .aiThinking
                    && step.kind != .reviewRequest
                    && step.kind != .reviewResult
            }
            .suffix(20)
    }

    /// Lightweight clarification/status query — NOT a request to do more work.
    /// Used to decide whether to strip tool history when continuing a heavy thread.
    static func isLightweightStatusQuery(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 30 else { return false }
        // Pure punctuation
        if ["?", "？", "??", "？？"].contains(normalized) { return true }
        // Status / clarification phrases
        let statusMarkers = [
            "怎么回事", "怎么了", "为啥", "为什么", "啥情况", "什么情况",
            "怎么这么", "是不是", "有没有",
            "你确定", "真的吗", "对吗", "好了吗", "完事了吗",
            "卡住了吗", "出错了吗", "断了吗", "停了吗",
            "你是什么", "你能", "你会", "现在能", "现在有"
        ]
        if statusMarkers.contains(where: { normalized.contains($0) }) { return true }
        // Short question without action verb
        let actionVerbs = ["改", "写", "建", "做", "执行", "运行", "搜", "查", "读", "整理", "保存", "翻译", "重写"]
        let hasAction = actionVerbs.contains(where: { normalized.contains($0) })
        let endsWithQuestion = normalized.hasSuffix("？") || normalized.hasSuffix("?") || normalized.hasSuffix("吗")
        return endsWithQuestion && !hasAction
    }

    static func isTinyFollowUp(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["?", "？", "??", "？？"].contains(normalized)
            || normalized.count <= 4 && ["然后", "继续", "接着", "为啥", "为什么"].contains(where: { normalized.contains($0) })
    }

    static func isEmptySessionPlaceholder(_ session: ChatSession) -> Bool {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.turns.isEmpty && (title.isEmpty || title == "新会话" || title == "新对话")
    }

    static func isContinuationCommand(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return normalized.contains("继续")
            || normalized.contains("接着")
            || normalized.contains("续跑")
            || normalized.contains("未完成")
            || normalized.localizedCaseInsensitiveContains("continue")
    }

    static func isContextualTaskReference(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let threadMarkers = [
            "这个会话", "那个会话", "当前会话", "这轮对话", "那轮对话", "这条对话",
            "新会话", "上下文", "丢了", "丢失", "没上下文"
        ]
        let taskMarkers = [
            "这个任务", "那个任务", "刚才的任务", "上个任务", "读取本地项目",
            "本地项目", "输出没结束", "被截断", "截断了", "没发完", "没写完", "没说完"
        ]
        return threadMarkers.contains { normalized.contains($0) }
            || taskMarkers.contains { normalized.contains($0) }
    }

    /// Detects messages that are likely follow-ups to a recent task even without explicit task references.
    static func isLikelyTaskFollowUp(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        // Standalone capability/concept questions are NOT task follow-ups
        if isStandaloneCapabilityOrConceptQuestion(normalized) { return false }
        // Standalone fresh-info questions are NOT task follow-ups
        if isStandaloneInfoQuestion(normalized) { return false }
        // Very short messages are almost always follow-ups
        if normalized.count <= 12 { return true }
        // Common follow-up action patterns
        let actionMarkers = [
            "下一步", "接着", "然后", "继续", "再", "还", "另外", "也", "帮我", "改一下", "修一下",
            "优化", "调整", "补充", "完善", "修复", "修改", "改进", "重构", "测试", "运行",
            "确认", "验证", "检查", "看看", "核对", "对比", "比较", "分析一下", "总结一下",
            "刚才", "之前", "上面的", "这样", "那样", "把它", "把这个", "把那个"
        ]
        if actionMarkers.contains(where: { normalized.contains($0) }) { return true }
        // Short questions are usually follow-ups
        if (normalized.hasSuffix("？") || normalized.hasSuffix("?")) && normalized.count <= 24 {
            return true
        }
        return false
    }

    static func shouldRouteChatFollowUpIntoSelectedTask(message: String, task: AgentTask) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if isStandaloneCapabilityOrConceptQuestion(normalized) {
            return false
        }
        if taskHasTruncatedOutput(task), isTruncationContinuation(normalized) {
            return true
        }
        if UserFrustrationDetector.shouldRecoverRecentTask(normalized) {
            return true
        }
        if isTinyFollowUp(normalized) || isContinuationCommand(normalized) || isTaskStatusQuestion(normalized) || isLikelyTaskFollowUp(normalized) {
            return true
        }

        let explicitTaskMarkers = ["这个任务", "那个任务", "这个会话", "那个会话", "当前会话", "这轮对话", "这条任务", "刚才", "最近的", "最近这个", "上个", "上一轮", "前面", "上面", "上下文", "新会话", "丢失", "接着这个", "继续这个"]
        if explicitTaskMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        let taskActionMarkers = ["再读", "补读", "继续读", "总结", "列出", "修复", "修改", "优化", "跑一下", "测试一下", "重新跑", "重试", "按这个", "基于这个", "把它"]
        if taskActionMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        let pronounOnlyMarkers = ["这个", "那个", "它", "这里", "上面的"]
        if normalized.count <= 16, pronounOnlyMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        let lastUserInput = task.steps.reversed().first { $0.kind == .userInput }?.text ?? task.title
        let sharedKeywords = semanticOverlapKeywords(in: normalized).intersection(semanticOverlapKeywords(in: lastUserInput))
        return sharedKeywords.count >= 2
    }

    static func isStandaloneInfoQuestion(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasSuffix("？") || normalized.hasSuffix("?") else { return false }
        let infoStarts = ["今天", "最近", "最新", "现在", "有什么新", "有哪些新"]
        let infoTopics = ["新闻", "消息", "动态", "进展", "更新", "发布"]
        let startsLike = infoStarts.contains { normalized.hasPrefix($0) }
        let hasTopic = infoTopics.contains { normalized.contains($0) }
        return startsLike && hasTopic
    }

    static func isStandaloneCapabilityOrConceptQuestion(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasSuffix("？") || normalized.hasSuffix("?") || normalized.contains("吗") else { return false }
        let capabilityStarts = [
            "你能", "你现在能", "你可以", "你会", "能不能", "能否", "是否可以",
            "可不可以", "会不会", "你支持", "你是什么", "你是谁"
        ]
        let conceptStarts = ["什么是", "为什么", "怎么理解", "如何理解"]
        let startsLikeStandalone = capabilityStarts.contains { normalized.hasPrefix($0) }
            || conceptStarts.contains { normalized.hasPrefix($0) }
        guard startsLikeStandalone else { return false }
        let taskAnchors = [
            "这个任务", "这条任务", "刚才", "上面", "前面", "继续", "接着", "被截断",
            "没发完", "文件", "代码", "项目", "报错", "工具失败"
        ]
        return !taskAnchors.contains { normalized.contains($0) }
    }

    static func taskHasTruncatedOutput(_ task: AgentTask) -> Bool {
        task.steps.contains { step in
            step.text.contains("输出达到当前上限")
                || step.text.contains("回复已被截断")
                || step.text.contains("输出上限截断")
                || step.text.contains("内容可能被截断")
        }
    }

    static func isTruncationContinuation(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let markers = [
            "接着说", "继续输出", "继续说", "接着输出", "没发完", "没写完",
            "没说完", "没结束", "被截断", "截断了", "断了", "后面呢",
            "剩下的", "接上", "继续"
        ]
        return markers.contains { normalized.contains($0) }
    }

    static func semanticOverlapKeywords(in text: String) -> Set<String> {
        let normalized = text.lowercased()
        let stopwords: Set<String> = ["这个", "那个", "一下", "为什么", "怎么", "什么", "可以", "是不是", "我", "你", "帮我", "请", "的", "了", "吧", "吗", "呢"]
        var tokens: [String] = []
        var current = ""
        for scalar in normalized.unicodeScalars {
            let isAsciiToken = CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "." || scalar == "-"
            let isHan = scalar.value >= 0x4E00 && scalar.value <= 0x9FFF
            if isAsciiToken || isHan {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return Set(tokens.filter { $0.count >= 2 && !stopwords.contains($0) })
    }

    static func isTaskStatusQuestion(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let statusMarkers = ["什么情况", "怎么了", "哪里失败", "失败原因", "几个工具失败", "工具失败", "没完成", "卡住", "还在执行", "执行中", "进度", "状态"]
        let whyAboutCurrentTask = (normalized.contains("为什么") || normalized.contains("为啥"))
            && ["失败", "没完成", "卡住", "中断", "新会话", "上下文", "任务", "工具"].contains { normalized.contains($0) }
        let asksStatus = statusMarkers.contains { normalized.contains($0) }
            || whyAboutCurrentTask
            || ["?", "？"].contains(normalized)
        guard asksStatus else { return false }
        let actionMarkers = ["继续执行", "继续做", "继续任务", "重试", "重新跑", "改", "修复", "写入", "读取", "搜索", "联网", "跑测试", "接着说", "继续输出", "没发完", "没写完", "没说完", "被截断"]
        return !actionMarkers.contains { normalized.contains($0) }
    }

    static func taskStatusAnswer(for task: AgentTask, question: String) -> String {
        let toolCalls = task.steps.filter { $0.kind == .toolCall }.count
        let failures = task.steps.filter { $0.isFailure || $0.kind == .error }
        let failedTools = task.steps.filter { $0.kind == .toolResult && $0.isFailure }
        let lastOutput = task.steps.reversed().first {
            $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastFailure = failures.last?.text.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = []
        lines.append("这条任务当前是“\(task.status.title)”。")
        if toolCalls > 0 {
            lines.append("已经调用过 \(toolCalls) 次工具，其中失败 \(failedTools.count) 次。")
        }
        if !failedTools.isEmpty {
            let grouped = Dictionary(grouping: failedTools, by: { $0.toolName ?? "tool" })
                .map { "\($0.key) ×\($0.value.count)" }
                .sorted()
                .joined(separator: "、")
            lines.append("失败主要来自：\(grouped)。")
        }
        if let lastFailure, !lastFailure.isEmpty {
            lines.append("最近的失败信息是：\(String(lastFailure.prefix(180)))")
        }
        if let lastOutput, !lastOutput.isEmpty {
            lines.append("已经形成过阶段性输出：\(String(lastOutput.prefix(220)))")
        }

        let hasShellFailure = failedTools.contains { $0.toolName == "shell.exec" }
        if hasShellFailure {
            lines.append("判断：它不是单纯“模型不会做”，而是执行路径不稳。模型多次尝试 shell 命令列项目文件，其中部分命令被安全策略或系统退出码拦住。更好的下一步是走受控的项目索引/文件读取，而不是继续让模型自由拼 shell。")
        } else if !failedTools.isEmpty {
            lines.append("判断：任务有工具失败，需要换执行路径或补充目标后续跑。")
        } else if task.status == .completed {
            lines.append("判断：任务已完成。如果你追问细节，我会基于这条任务已有上下文解释，不再重复调用工具。")
        } else {
            lines.append("判断：任务没有检测到明确工具失败，但还需要补充下一步目标。")
        }
        lines.append("建议下一步：先让来财总结已读到的项目结构，再按关键模块继续读取；需要改代码时再进入审查写入。")
        return lines.joined(separator: "\n")
    }

    static func markStaleRunningTasks(in state: inout AppState, now: Date = .now) {
        let timeout: TimeInterval = 20 * 60
        for index in state.threads.indices where state.threads[index].source == .task {
            let shouldCancelRunning = state.threads[index].status == .running
            let shouldCancelStaleReview = state.threads[index].status == .waitingReview
                && now.timeIntervalSince(state.threads[index].updatedAt) > timeout
            guard shouldCancelRunning || shouldCancelStaleReview else { continue }
            state.threads[index].status = .cancelled
            state.threads[index].updatedAt = now
            if state.threads[index].steps.contains(where: { $0.kind == .error && $0.text.contains("上次运行被中断") }) {
                continue
            }
            state.threads[index].steps.append(TaskStep(
                kind: .error,
                text: "上次运行被中断，已自动标记为已暂停。可以从这条任务继续或重新发送。",
                isFailure: false,
                recoverable: true,
                retryAction: "继续"
            ))
            ensureCheckpointIfNeeded(&state.threads[index])
        }
    }

    nonisolated static func mergePersistedThreads(_ incoming: [Thread], into state: inout AppState) {
        guard !incoming.isEmpty else { return }

        for thread in incoming {
            if let index = state.threads.firstIndex(where: { $0.id == thread.id }) {
                if thread.updatedAt >= state.threads[index].updatedAt {
                    state.threads[index] = thread
                }
            } else {
                state.threads.append(thread)
            }
        }

        state.threads.sort { $0.updatedAt > $1.updatedAt }

        if let selectedID = state.selectedThreadID,
           !state.threads.contains(where: { $0.id == selectedID }) {
            state.selectThread(id: nil)
        }
    }

    nonisolated static func generateSummaryCache(for thread: Thread) -> String {
        let recentStepCount = min(14, thread.steps.count)
        let earlySteps = thread.steps.dropLast(recentStepCount)
        guard !earlySteps.isEmpty else { return "" }

        var lines = ["\(earlySteps.count) 条早期步骤摘要"]
        // Collect key info from early steps
        let readFiles = uniqueValues(
            earlySteps.filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
                .compactMap { $0.toolParams?["path"] }
        )
        let searchedQueries = uniqueValues(
            earlySteps.filter { $0.kind == .toolCall && $0.toolName == "code.search" }
                .compactMap { $0.toolParams?["query"] }
        )
        let failedTools = earlySteps.filter { $0.kind == .toolResult && $0.isFailure }
            .map { "\($0.toolName ?? "工具") 失败" }
        let conclusions = earlySteps.filter { $0.kind == .textOutput }
            .suffix(3)
            .map { compactSummaryText($0.text, limit: 260) }

        if !readFiles.isEmpty {
            lines.append("- 已读文件：\(readFiles.prefix(12).joined(separator: "、"))")
        }
        if !searchedQueries.isEmpty {
            lines.append("- 已搜索：\(searchedQueries.prefix(8).joined(separator: "、"))")
        }
        if !failedTools.isEmpty {
            lines.append("- 失败工具：\(uniqueValues(failedTools).prefix(6).joined(separator: "、"))")
        }
        if !conclusions.isEmpty {
            lines.append("- 早期结论：\(conclusions.joined(separator: " / "))")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func uniqueValues(_ values: [String]) -> [String] {
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

    nonisolated static func compactSummaryText(_ text: String, limit: Int = 260) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(max(0, limit - 1))) + "…"
    }

    /// Build a concise progress summary from completed steps for error display.
    nonisolated static func errorProgressSummary(steps: [TaskStep]) -> String {
        let filesRead = Set(steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] })
        let filesWritten = Set(steps
            .filter { $0.kind == .reviewRequest && $0.approved == true }
            .compactMap(\.diffFilePath))
        let toolCalls = steps.filter { $0.kind == .toolCall }.count
        let searches = steps.filter { $0.kind == .toolCall && ($0.toolName == "code.search" || $0.toolName == "web.search") }.count

        var parts: [String] = []
        if !filesRead.isEmpty { parts.append("读 \(filesRead.count) 文件") }
        if !filesWritten.isEmpty { parts.append("写 \(filesWritten.count) 文件") }
        if searches > 0 { parts.append("搜索 \(searches) 次") }
        if toolCalls > 0 && parts.isEmpty { parts.append("工具调用 \(toolCalls) 次") }
        return parts.joined(separator: "、")
    }

}
