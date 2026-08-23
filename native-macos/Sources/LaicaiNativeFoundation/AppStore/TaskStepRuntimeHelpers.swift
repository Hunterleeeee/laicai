import AppKit
import Foundation
import LaicaiNativeDomain

@MainActor
extension AppStore {
    func appendTaskStep(_ step: TaskStep, to taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        let steps = state.threads[threadIndex].steps

        let searchSlice = steps.suffix(20)
        if let existingIndex = searchSlice.lastIndex(where: { $0.id == step.id }) {
            if step.kind == .toolResult {
                state.threads[threadIndex].steps[existingIndex] = step
                state.threads[threadIndex].updatedAt = Date()
                persistThreads()
            }
            return
        }

        if step.kind == .textOutput,
            let streamingIndex = steps.lastIndex(where: { $0.kind == .textOutput && $0.toolCallId == Self.streamingOutputID })
        {
            streamBuffers.removeValue(forKey: taskID)
            streamLastFlushAt.removeValue(forKey: taskID)
            // The final step supersedes everything streamed so far.
            streamPresentation.clearText(threadID: taskID)
            var finalStep = step
            finalStep.toolCallId = nil
            state.threads[threadIndex].steps[streamingIndex] = finalStep
            state.threads[threadIndex].updatedAt = Date()
            persistThreads()
            return
        }

        if shouldCollapseDuplicateStep(step, in: steps) { return }
        if generationTasks[taskID] == nil, steps.contains(where: { $0.kind == step.kind && $0.text == step.text }) { return }

        state.threads[threadIndex].steps.append(step)
        if step.kind == .reviewRequest {
            syncAgentSnapshot(at: threadIndex)
        }
        Self.updateExecutionLedger(&state.threads[threadIndex], with: step)
        updateLiveActivity(from: step, for: taskID)
        state.threads[threadIndex].updatedAt = Date()
        persistThreads()

        if step.kind == .reviewRequest {
            sendReviewNotification(step: step, threadTitle: state.threads[threadIndex].title, taskID: taskID)
        }
    }

    private func sendReviewNotification(step: TaskStep, threadTitle: String, taskID: UUID) {
        NotificationManager.shared.post(
            title: "需要审查确认",
            subtitle: threadTitle,
            body: step.diffFilePath.map { "文件：\($0)" } ?? "有变更等待确认",
            threadID: taskID.uuidString
        )
        updateDockBadge()
    }

    func updateDockBadge() {
        let count = state.pendingReviewCount
        guard NSClassFromString("XCTestCase") == nil, let dockTile = NSApp?.dockTile else { return }
        dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    func appendStreamDelta(_ delta: String, to taskID: UUID) {
        guard !delta.isEmpty else { return }
        streamBuffers[taskID, default: ""] += delta
        let now = Date()
        let pending = streamBuffers[taskID] ?? ""
        let lastFlush = streamLastFlushAt[taskID] ?? .distantPast
        guard pending.count >= streamFlushCharacterThreshold || now.timeIntervalSince(lastFlush) >= streamFlushInterval else {
            return
        }
        flushStreamBuffer(for: taskID)
    }

    public static let thinkingStreamID = "__thinking_stream__"

    func appendThinkingDelta(_ delta: String, to taskID: UUID) {
        guard !delta.isEmpty else { return }
        thinkingBuffers[taskID, default: ""] += delta
        let now = Date()
        let pending = thinkingBuffers[taskID] ?? ""
        let lastFlush = thinkingLastFlushAt[taskID] ?? .distantPast
        guard pending.count >= streamFlushCharacterThreshold || now.timeIntervalSince(lastFlush) >= streamFlushInterval else {
            return
        }
        flushThinkingBuffer(for: taskID)
    }

    /// Live flushes (persist: false) keep AppState untouched: the placeholder
    /// step is created once with empty text and all live content lives in
    /// streamPresentation. Terminal flushes (persist: true) fold buffered plus
    /// already-streamed text back into the persisted placeholder so it survives
    /// after the run ends, even when the raw buffer happens to be empty.
    func flushThinkingBuffer(for taskID: UUID, persist: Bool = false) {
        var pending = thinkingBuffers[taskID] ?? ""
        if !pending.isEmpty {
            thinkingBuffers[taskID] = ""
            thinkingLastFlushAt[taskID] = Date()
        }
        // Live flushes need fresh content; terminal flushes must also run with
        // an empty raw buffer to fold already-streamed store text back in.
        guard persist || !pending.isEmpty else { return }
        if persist {
            // Store content streamed earlier, so it precedes the raw buffer.
            let liveReasoning = streamPresentation.reasoning(forThread: taskID)
            if liveReasoning.isEmpty && pending.isEmpty {
                streamPresentation.clearAll(threadID: taskID)
                return
            }
            pending = liveReasoning + pending
        }
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else {
            streamPresentation.clearAll(threadID: taskID)
            return
        }
        setLiveActivity("正在思考…", for: taskID)
        if let idx = state.threads[threadIndex].steps.lastIndex(where: { $0.kind == .aiThinking && $0.toolCallId == Self.thinkingStreamID })
        {
            if persist {
                let combined = (state.threads[threadIndex].steps[idx].reasoningContent ?? "") + pending
                if combined != state.threads[threadIndex].steps[idx].reasoningContent {
                    state.threads[threadIndex].steps[idx].reasoningContent = combined
                }
                streamPresentation.clearAll(threadID: taskID)
            } else {
                streamPresentation.append(reasoning: pending, threadID: taskID)
            }
        } else {
            state.threads[threadIndex].steps.append(
                TaskStep(
                    kind: .aiThinking,
                    text: "思考中…",
                    toolCallId: Self.thinkingStreamID,
                    isCollapsible: true,
                    isCollapsed: false,
                    reasoningContent: persist ? pending : ""))
            if !persist {
                streamPresentation.append(reasoning: pending, threadID: taskID)
            }
        }
    }

    /// See flushThinkingBuffer for the live vs. terminal flush contract.
    func flushStreamBuffer(for taskID: UUID, persist: Bool = false) {
        var pending = streamBuffers[taskID] ?? ""
        if !pending.isEmpty {
            streamBuffers[taskID] = ""
            streamLastFlushAt[taskID] = Date()
        }
        guard persist || !pending.isEmpty else { return }
        if persist {
            // Store content streamed earlier, so it precedes the raw buffer.
            let liveText = streamPresentation.text(forThread: taskID)
            if liveText.isEmpty && pending.isEmpty {
                streamPresentation.clearAll(threadID: taskID)
                return
            }
            pending = liveText + pending
        }
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else {
            streamPresentation.clearAll(threadID: taskID)
            return
        }
        setLiveActivity("正在生成回复…", for: taskID)
        if let streamIndex = state.threads[threadIndex].steps.lastIndex(where: {
            $0.kind == .textOutput && $0.toolCallId == Self.streamingOutputID
        }) {
            if persist {
                let combined = state.threads[threadIndex].steps[streamIndex].text + pending
                if combined != state.threads[threadIndex].steps[streamIndex].text {
                    state.threads[threadIndex].steps[streamIndex].text = combined
                }
                streamPresentation.clearAll(threadID: taskID)
            } else {
                streamPresentation.append(text: pending, threadID: taskID)
            }
        } else {
            state.threads[threadIndex].steps.append(
                TaskStep(
                    kind: .textOutput,
                    text: persist ? pending : "",
                    toolCallId: Self.streamingOutputID,
                    isCollapsible: false,
                    isCollapsed: false))
            if !persist {
                streamPresentation.append(text: pending, threadID: taskID)
            }
        }
    }

    func mergeCompletedTask(_ completedTask: AgentTask, into taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        for step in completedTask.steps {
            let existingSteps = state.threads[threadIndex].steps
            let temporaryID: String? = {
                switch step.kind {
                case .textOutput: return Self.streamingOutputID
                case .aiThinking: return Self.thinkingStreamID
                default: return nil
                }
            }()
            if let temporaryID,
                let temporaryIndex = existingSteps.lastIndex(where: { $0.kind == step.kind && $0.toolCallId == temporaryID })
            {
                var finalStep = step
                finalStep.toolCallId = nil
                state.threads[threadIndex].steps[temporaryIndex] = finalStep
                updateLiveActivity(from: finalStep, for: taskID)
                continue
            }
            if shouldCollapseDuplicateStep(step, in: existingSteps) { continue }
            let alreadyExists = existingSteps.contains {
                $0.id == step.id || ($0.kind == step.kind && $0.text == step.text && $0.reasoningContent == step.reasoningContent)
            }
            if !alreadyExists {
                state.threads[threadIndex].steps.append(step)
                updateLiveActivity(from: step, for: taskID)
            }
        }
        state.threads[threadIndex].status = completedTask.status
        setLiveActivity("", for: taskID)
        state.threads[threadIndex].context = completedTask.context
        state.threads[threadIndex].taskProtocol = completedTask.taskProtocol ?? state.threads[threadIndex].taskProtocol
        state.threads[threadIndex].executionLedger = completedTask.executionLedger ?? state.threads[threadIndex].executionLedger
        Self.ensureAgentRuntimeContract(&state.threads[threadIndex])
        state.threads[threadIndex].context.memory = Self.taskMemory(from: state.threads[threadIndex])
        if let plan = completedTask.multiAgentPlan {
            state.threads[threadIndex].multiAgentPlan = plan
        }
        syncAgentSnapshot(at: threadIndex)
        // Phase-based routing may temporarily switch connectors during execution.
        // Do NOT persist the task's connector back to the thread or global state —
        // the thread keeps the connector the user originally selected.
        // Completion is the latest activity, so keep the conversation at the top
        // of the recency-sorted sidebar instead of reusing a stale task timestamp.
        state.threads[threadIndex].updatedAt = .now
        Self.ensureCheckpointIfNeeded(&state.threads[threadIndex])
        if !Self.isPureChatLikeThread(state.threads[threadIndex]) {
            Self.rebuildExecutionLedger(&state.threads[threadIndex])
        }
        // Completion from a background task must not change the conversation
        // currently shown by the user.
        // Final steps replaced the placeholders; drop any live stream residue.
        streamPresentation.clearAll(threadID: taskID)
        notifyCompletedTaskIfNeeded(completedTask, threadIndex: threadIndex, taskID: taskID)
    }

    private func notifyCompletedTaskIfNeeded(_ completedTask: AgentTask, threadIndex: Int, taskID: UUID) {
        guard !NSApplication.shared.isActive else { return }
        NotificationManager.shared.post(
            title: notificationTitle(for: completedTask.status),
            body: state.threads[threadIndex].title,
            threadID: taskID.uuidString
        )
    }

    private func notificationTitle(for status: TaskStatus) -> String {
        switch status {
        case .completed: return "会话 完成"
        case .failed: return "会话 失败"
        default: return "会话状态更新"
        }
    }

    func shouldCollapseDuplicateStep(_ step: TaskStep, in steps: [TaskStep]) -> Bool {
        switch step.kind {
        case .userInput:
            return steps.contains { $0.kind == step.kind && $0.text == step.text }
        case .aiThinking:
            return steps.contains {
                $0.kind == .aiThinking
                    && $0.text == step.text
                    && $0.reasoningContent == step.reasoningContent
                    && $0.toolCallId == step.toolCallId
            }
        default:
            return false
        }
    }

    nonisolated static func ensureAgentRuntimeContract(_ thread: inout Thread) {
        let goal =
            (thread.goal?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? thread.steps.first(where: { $0.kind == .userInput })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? thread.title
        if !thread.steps.contains(where: { $0.kind == .aiThinking && $0.text == "正在理解会话目标并准备执行。" }) {
            let insertIndex = thread.steps.firstIndex { $0.kind != .userInput } ?? thread.steps.count
            thread.steps.insert(
                TaskStep(kind: .aiThinking, text: "正在理解会话目标并准备执行。", isCollapsible: true, isCollapsed: true), at: insertIndex)
        }
        guard !isPureChatLikeThread(thread) else {
            thread.taskProtocol = nil
            thread.executionLedger = nil
            return
        }
        if thread.goal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            thread.goal = goal
        }
        if thread.currentPlan.isEmpty {
            thread.currentPlan = fallbackAgentPlan(for: thread)
        }
        if thread.taskProtocol == nil || thread.taskProtocol?.threadID != thread.id {
            thread.taskProtocol = AgentTaskProtocol(
                taskGoal: goal,
                workspaceRoot: thread.context.workspaceRoot,
                threadID: thread.id,
                expectedOutcome: "完成当前会话目标并形成可验证结果。",
                completionCriteria: ["保留真实执行证据", "形成最终交付或明确阻塞"],
                riskPolicy: .act,
                continuationPolicy: .ownFollowUps
            )
        }
        if thread.executionLedger == nil {
            thread.executionLedger = AgentExecutionLedger(
                originalRequest: goal,
                goal: goal,
                state: .created,
                plan: thread.currentPlan,
                nextAction: "继续处理当前会话"
            )
        }
        thread.executionLedger?.goal = goal
        thread.executionLedger?.plan = thread.currentPlan
    }

    nonisolated static func rebuildExecutionLedger(_ thread: inout Thread) {
        guard !isPureChatLikeThread(thread) else {
            thread.executionLedger = nil
            thread.taskProtocol = nil
            return
        }
        ensureAgentRuntimeContract(&thread)
        var ledger =
            thread.executionLedger
            ?? AgentExecutionLedger(
                originalRequest: thread.steps.first(where: { $0.kind == .userInput })?.text ?? thread.title,
                goal: thread.goal ?? thread.title,
                state: .created,
                plan: thread.currentPlan,
                nextAction: "继续处理当前会话"
            )
        ledger.goal = thread.goal ?? ledger.goal
        ledger.plan = thread.currentPlan
        thread.executionLedger = ledger
        let steps = thread.steps
        for step in steps {
            updateExecutionLedger(&thread, with: step, shouldTransition: false)
        }
        ledger = thread.executionLedger ?? ledger
        switch thread.status {
        case .completed:
            ledger.transition(to: .completed, reason: "任务完成")
        case .failed:
            ledger.transition(to: .failed, reason: "任务失败")
        case .cancelled:
            ledger.transition(to: .paused, reason: "任务暂停")
        case .waitingReview:
            ledger.transition(to: .waitingUser, reason: "等待审查")
        case .running:
            if thread.steps.contains(where: { $0.toolName == "verify.build" }) {
                ledger.transition(to: .verifying, reason: "正在验证")
            } else if thread.steps.contains(where: { $0.kind == .toolCall }) {
                ledger.transition(to: .executing, reason: "正在执行工具")
            } else {
                ledger.transition(to: .gatheringEvidence, reason: "正在采集证据")
            }
        case .queued:
            ledger.transition(to: .planning, reason: "等待执行")
        }
        ledger.unfinishedWork = unfinishedWork(for: thread, ledger: ledger)
        ledger.nextAction = nextAction(for: thread, ledger: ledger)
        ledger.updatedAt = .now
        thread.executionLedger = ledger
    }

    nonisolated static func isPureChatLikeThread(_ thread: Thread) -> Bool {
        let intent = thread.context.metadata["intent"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasExecutionEvidence = thread.steps.contains { step in
            step.kind == .toolCall
                || step.kind == .toolResult
                || step.kind == .reviewRequest
                || step.kind == .reviewResult
        }
        let explicitlyChat = intent == "chat"
        let legacyChatWithoutEvidence =
            intent == nil
            && thread.workflowName == nil
            && thread.multiAgentPlan == nil
        return !hasExecutionEvidence && (explicitlyChat || legacyChatWithoutEvidence)
    }

    // swiftlint:disable:next cyclomatic_complexity
    nonisolated static func updateExecutionLedger(
        _ thread: inout Thread,
        with step: TaskStep,
        shouldTransition: Bool = true
    ) {
        if thread.executionLedger == nil {
            thread.executionLedger = AgentExecutionLedger(
                originalRequest: thread.steps.first(where: { $0.kind == .userInput })?.text ?? thread.title,
                goal: thread.goal ?? thread.title,
                state: .created,
                plan: thread.currentPlan,
                nextAction: "继续处理当前会话"
            )
        }
        guard var ledger = thread.executionLedger else { return }
        let toolName = step.toolName ?? ""
        let canonicalTool = ToolNameCodec.canonicalName(toolName)
        switch step.kind {
        case .toolCall:
            if shouldTransition {
                let targetState: AgentRuntimeState = canonicalTool == "verify.build" ? .verifying : .executing
                ledger.transition(to: targetState, reason: "调用 \(canonicalTool.isEmpty ? "工具" : canonicalTool)")
            }
            if let command = step.toolParams?["command"] {
                ledger.appendUnique(command, to: \.commands)
            }
            if let query = step.toolParams?["query"] {
                ledger.appendUnique(query, to: \.searches)
            }
            if let url = step.toolParams?["url"] {
                ledger.appendUnique(url, to: \.pages)
            }
        case .toolResult:
            if step.isFailure {
                ledger.appendUnique(canonicalTool.isEmpty ? "unknown" : canonicalTool, to: \.failedTools)
                ledger.appendUnique(String(step.text.prefix(500)), to: \.errorReasons)
                if let recovery = Self.recoveryPath(for: canonicalTool, step: step) {
                    ledger.appendUnique(recovery, to: \.alternativePaths)
                }
                if shouldTransition {
                    ledger.transition(to: .failed, reason: "\(canonicalTool.isEmpty ? "tool" : canonicalTool) 失败")
                }
            } else {
                if canonicalTool == "file.read" || canonicalTool == "file.extract" {
                    if let path = step.toolParams?["path"] ?? step.toolParams?["sourcePath"] {
                        ledger.appendUnique(path, to: \.readFiles)
                    }
                    if shouldTransition {
                        ledger.transition(to: .gatheringEvidence, reason: "\(canonicalTool) 成功")
                    }
                } else if canonicalTool == "code.search" || canonicalTool == "web.search" {
                    if let query = step.toolParams?["query"] {
                        ledger.appendUnique(query, to: \.searches)
                    }
                    if shouldTransition {
                        ledger.transition(to: .gatheringEvidence, reason: "\(canonicalTool) 成功")
                    }
                } else if canonicalTool == "web.fetch" {
                    if let url = step.toolParams?["url"] {
                        ledger.appendUnique(url, to: \.pages)
                    }
                    if shouldTransition {
                        ledger.transition(to: .gatheringEvidence, reason: "读取网页成功")
                    }
                } else if ["browser", "browser.real"].contains(canonicalTool) {
                    if let url = step.toolParams?["url"] {
                        ledger.appendUnique(url, to: \.pages)
                    }
                    if let path = step.toolParams?["path"] ?? Self.pathFromText(step.text) {
                        ledger.appendUnique(path, to: \.pages)
                    }
                    if let action = step.toolParams?["action"], ["screenshot", "extract", "open", "navigate", "tabs"].contains(action) {
                        ledger.appendUnique("\(canonicalTool):\(action)", to: \.verification)
                    }
                    if shouldTransition {
                        ledger.transition(to: .gatheringEvidence, reason: "页面检查成功")
                    }
                } else if canonicalTool == "computer" {
                    if let action = step.toolParams?["action"], ["screenshot", "windows", "frontmost"].contains(action) {
                        ledger.appendUnique("\(canonicalTool):\(action)", to: \.verification)
                        if let path = step.toolParams?["path"] ?? Self.pathFromText(step.text) {
                            ledger.appendUnique(path, to: \.pages)
                        }
                    }
                    if shouldTransition {
                        ledger.transition(to: .gatheringEvidence, reason: "电脑界面检查成功")
                    }
                } else if ["file.write", "file.edit", "diff.apply"].contains(canonicalTool) {
                    if let path = step.toolParams?["path"] ?? step.toolParams?["outputPath"] {
                        ledger.appendUnique(path, to: \.modifiedFiles)
                    }
                    if shouldTransition {
                        ledger.transition(to: .executing, reason: "\(canonicalTool) 成功")
                    }
                } else if canonicalTool == "document.transform" {
                    if let path = step.toolParams?["outputPath"] ?? step.toolParams?["pdfPath"] ?? step.toolParams?["sourcePath"] {
                        ledger.appendUnique(path, to: \.artifacts)
                    }
                    if shouldTransition {
                        ledger.transition(to: .executing, reason: "文档工具成功")
                    }
                } else if canonicalTool == "verify.build" || canonicalTool == "shell.exec" {
                    ledger.appendUnique(String(step.text.prefix(500)), to: \.verification)
                    if let command = step.toolParams?["command"] {
                        ledger.appendUnique(command, to: \.commands)
                    }
                    if shouldTransition {
                        ledger.transition(to: canonicalTool == "verify.build" ? .verifying : .executing, reason: "\(canonicalTool) 成功")
                    }
                }
            }
        case .reviewRequest:
            if let path = step.diffFilePath {
                ledger.appendUnique(path, to: step.approved == true ? \.modifiedFiles : \.artifacts)
            }
            if shouldTransition {
                ledger.transition(to: step.approved == nil ? .waitingUser : .executing, reason: "变更审查")
            }
        case .reviewResult:
            if shouldTransition {
                ledger.transition(to: step.approved == false ? .failed : .executing, reason: "审查结果")
            }
        case .error:
            if step.isFailure {
                ledger.appendUnique(String(step.text.prefix(500)), to: \.errorReasons)
                if shouldTransition {
                    ledger.transition(to: step.recoverable ? .waitingUser : .failed, reason: "错误步骤")
                }
            } else if step.recoverable, shouldTransition {
                ledger.transition(to: .paused, reason: "可恢复暂停")
            }
        case .aiThinking, .textOutput, .userInput:
            break
        }
        if step.recoverable, let retryAction = step.retryAction {
            ledger.nextAction = retryAction
        }
        ledger.unfinishedWork = unfinishedWork(for: thread, ledger: ledger)
        thread.executionLedger = ledger
    }

    private nonisolated static func nextAction(for thread: Thread, ledger: AgentExecutionLedger? = nil) -> String? {
        let currentLedger = ledger ?? thread.executionLedger
        if let pending = currentLedger?.pendingFollowUp, !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "处理用户补充：\(pending)"
        }
        if thread.status == .failed {
            return "从最近失败点恢复，优先换工具或参数"
        }
        if thread.status == .cancelled {
            return "从检查点继续"
        }
        if thread.status == .waitingReview {
            return "等待用户审查变更"
        }
        if thread.status == .completed {
            return nil
        }
        return thread.currentPlan.last
    }

    private nonisolated static func unfinishedWork(for thread: Thread, ledger: AgentExecutionLedger? = nil) -> [String] {
        let currentLedger = ledger ?? thread.executionLedger
        var items: [String] = []
        if thread.isExecution && currentLedger?.hasToolEvidence != true {
            items.append("缺少真实工具证据")
        }
        if thread.steps.contains(where: { $0.kind == .toolResult && $0.isFailure }) {
            items.append("存在失败工具，需要恢复或说明阻塞")
        }
        if thread.steps.contains(where: { $0.kind == .reviewRequest && $0.approved == nil }) {
            items.append("存在待审查变更")
        }
        let request = [
            thread.executionLedger?.originalRequest,
            thread.goal,
            thread.taskProtocol?.completionCriteria.joined(separator: " "),
        ].compactMap { $0 }.joined(separator: " ")
        if AgentLoop.expectsUIEvidence(message: request, protocolCriteria: thread.taskProtocol?.completionCriteria ?? []),
            AgentLoop.hasUIEvidence(in: AgentTask(thread: thread)) == false
        {
            items.append("UI 任务缺少页面、截图或交互验证")
        }
        if thread.status == .running {
            items.append("任务仍在运行")
        }
        return items
    }

    private nonisolated static func recoveryPath(for canonicalTool: String, step: TaskStep) -> String? {
        switch canonicalTool {
        case "file.edit":
            return "file.edit 失败后改走 file.read + file.write，并基于最新磁盘内容生成 diff"
        case "code.search":
            return "code.search 失败或无结果后改走 workspace.index 或 shell.exec rg 精确搜索"
        case "file.read":
            return "file.read 失败后确认路径/类型；Office 或 PDF 改用 file.extract/document.transform"
        case "web.fetch":
            return "web.fetch 失败后换来源或先 web.search 找替代页面"
        case "browser", "browser.real":
            return "页面检查失败后改用 browser.extract/browser.screenshot 或 computer.screenshot 留证"
        case "computer":
            return "界面自动化失败后改用截图、窗口列表或让用户确认权限"
        case "verify.build":
            return "构建验证失败后读取关键错误文件，修复后再次 verify.build；环境问题需记录阻塞"
        case "shell.exec":
            if step.text.lowercased().contains("危险") || step.text.lowercased().contains("dangerous") {
                return "危险 shell 操作被拦截；需要用户明确授权或选择非破坏性替代路径"
            }
            return "shell.exec 失败后缩小命令范围、改用结构化工具或记录环境阻塞"
        default:
            return nil
        }
    }

    private nonisolated static func pathFromText(_ text: String) -> String? {
        let patterns = [
            #"/[^\s]+\.png"#,
            #"file://[^\s]+"#,
        ]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                return String(text[range])
            }
        }
        return nil
    }
}
