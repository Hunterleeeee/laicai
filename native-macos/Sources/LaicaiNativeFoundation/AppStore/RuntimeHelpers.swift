import AppKit
import Foundation
import LaicaiNativeDomain

@MainActor
extension AppStore {
    func handleShellStreamNotification(_ info: [AnyHashable: Any]) {
        guard let stepID = info["stepID"] as? UUID,
              let callID = info["callID"] as? String,
              let command = info["command"] as? String,
              let text = info["text"] as? String,
              let isFailure = info["isFailure"] as? Bool else { return }
        let isFinal = info["isFinal"] as? Bool ?? false

        let step = TaskStep(
            id: stepID,
            kind: .toolResult,
            text: text,
            toolName: "shell.exec",
            toolParams: ["command": command],
            toolCallId: callID,
            isCollapsible: true,
            isCollapsed: false,
            isFailure: isFailure,
            recoverable: isFinal && isFailure,
            retryAction: isFinal && isFailure ? "根据终端输出修复后重试" : nil
        )

        if let threadIndex = state.threads.firstIndex(where: { $0.status == .running }) {
            if let existingIndex = state.threads[threadIndex].steps.firstIndex(where: { $0.id == stepID }) {
                state.threads[threadIndex].steps[existingIndex] = step
            } else {
                state.threads[threadIndex].steps.append(step)
            }
            updateLiveActivity(from: step)
            state.threads[threadIndex].updatedAt = Date()
            if isFinal {
                persistThreads()
            }
        }
    }

    func composedDraftMessage() -> String {
        let text = state.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        // G8: Expand @-mention file references (e.g. @src/main.swift or @/absolute/path)
        var mentionedPaths: [String] = []
        let mentionPattern = #"@((?:/[\w./-]+)|(?:[\w./-]+\.[\w]+))"#
        if let regex = try? NSRegularExpression(pattern: mentionPattern) {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let pathRange = match.range(at: 1)
                var path = ns.substring(with: pathRange)
                if !path.hasPrefix("/") {
                    let fullPath = (state.settings.workspacePath as NSString).appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: fullPath) {
                        path = fullPath
                    }
                }
                if FileManager.default.fileExists(atPath: path) {
                    mentionedPaths.append(path)
                }
            }
        }

        // Add mentioned files to attachments
        var allAttachments = state.draftAttachments + mentionedPaths
        allAttachments = Array(Set(allAttachments))

        guard !allAttachments.isEmpty else { return text }
        let attachmentText: String
        if allAttachments.count == 1, let path = allAttachments.first {
            attachmentText = "请读取这个附件：\(path)"
        } else {
            attachmentText = "请读取这些附件：\n" + allAttachments.joined(separator: "\n")
        }
        return text.isEmpty ? attachmentText : "\(text)\n\(attachmentText)"
    }

    func promoteSelectedSessionToTaskIfNeeded() {
        guard let sessionID = state.selectedSessionID,
              let threadIndex = state.threads.firstIndex(where: { $0.id == sessionID }) else { return }
        let thread = state.threads[threadIndex]
        guard thread.source == .session && !thread.steps.isEmpty else { return }
        // Session already has steps as TaskStep; just add context to promote to task
        state.threads[threadIndex].context = TaskContext(workspaceRoot: state.settings.workspacePath, vaultRoot: cleanVaultPath())
        state.threads[threadIndex].connectorID = state.activeConnectorID
        // Source will automatically become .task now that context is non-empty
        persistThreads()
    }

    func taskStepKind(for role: ChatRole) -> TaskStepKind {
        switch role {
        case .user: return .userInput
        case .assistant: return .textOutput
        case .tool: return .toolResult
        case .system: return .aiThinking
        }
    }

    func cleanVaultPath() -> String? {
        let trimmed = state.settings.vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizedConnector(_ connector: ConnectorProfile, previous: ConnectorProfile? = nil) -> ConnectorProfile {
        var normalized = connector
        normalized.name = connector.name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.kind = connector.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.endpoint = connector.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.modelName = connector.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.note = connector.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let previous,
           Self.toolCallingIdentityChanged(from: previous, to: normalized) {
            normalized.toolCallingCapability = nil
            normalized.toolCallingCapabilitySource = nil
            normalized.toolCallingCapabilityLearnedAt = nil
        }
        if let previous, Self.connectorConfigurationChanged(from: previous, to: normalized) {
            normalized.health = .attention
        }
        return normalized
    }

    func scheduleConnectorHealthRefreshIfNeeded(for connector: ConnectorProfile, force: Bool = false) {
        guard canAutoCheckConnectorHealth(connector) else { return }
        guard force || connector.health != .ready else { return }
        checkConnectorHealth(id: connector.id, showsToast: false, probeToolCalling: false)
    }

    func canAutoCheckConnectorHealth(_ connector: ConnectorProfile) -> Bool {
        !connector.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !connector.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func recordToolActivity(name: String, summary: String, statusLine: String, isFailure: Bool) {
        recordToolActivity(ToolActivity(name: name, summary: summary, statusLine: statusLine, isFailure: isFailure))
    }

    func recordToolActivity(_ activity: ToolActivity) {
        if let first = state.toolActivities.first,
           first.name == activity.name,
           first.summary == activity.summary,
           first.statusLine == activity.statusLine,
           first.isFailure == activity.isFailure {
            return
        }
        state.toolActivities.removeAll {
            $0.name == activity.name
                && $0.summary == activity.summary
                && $0.statusLine == activity.statusLine
                && $0.isFailure == activity.isFailure
        }
        state.toolActivities.insert(activity, at: 0)
        if state.toolActivities.count > 12 { state.toolActivities = Array(state.toolActivities.prefix(12)) }
    }

    func appendTaskStep(_ step: TaskStep, to taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        let steps = state.threads[threadIndex].steps

        // H2: ID dedup — search only the last 20 steps (new steps almost always
        // match recent ones; full scan on 100+ steps was a hot path).
        let searchSlice = steps.suffix(20)
        if let existingIndex = searchSlice.lastIndex(where: { $0.id == step.id }) {
            if step.kind == .toolResult {
                state.threads[threadIndex].steps[existingIndex] = step
                state.threads[threadIndex].updatedAt = Date()
                persistThreads()
            }
            return
        }

        // Replace streaming placeholder with final text
        if step.kind == .textOutput,
           let streamingIndex = steps.lastIndex(where: { $0.kind == .textOutput && $0.toolCallId == Self.streamingOutputID }) {
            streamBuffers.removeValue(forKey: taskID)
            streamLastFlushAt.removeValue(forKey: taskID)
            var finalStep = step
            finalStep.toolCallId = nil
            state.threads[threadIndex].steps[streamingIndex] = finalStep
            state.threads[threadIndex].updatedAt = Date()
            persistThreads()
            return
        }

        // H2: During generation, skip expensive full-text dedup — AgentLoop
        // already ensures no duplicate steps are emitted. Only do cheap dedup
        // for user-initiated appends.
        if !state.isGenerating {
            if shouldCollapseDuplicateStep(step, in: steps) { return }
            if steps.contains(where: { $0.kind == step.kind && $0.text == step.text }) { return }
        }

        state.threads[threadIndex].steps.append(step)
        state.threads[threadIndex].updatedAt = Date()
        persistThreads()
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

    func flushStreamBuffer(for taskID: UUID) {
        guard let pending = streamBuffers[taskID], !pending.isEmpty else { return }
        streamBuffers[taskID] = ""
        streamLastFlushAt[taskID] = Date()
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        state.liveActivity = "正在生成回复…"
        if let streamIndex = state.threads[threadIndex].steps.lastIndex(where: { $0.kind == .textOutput && $0.toolCallId == Self.streamingOutputID }) {
            state.threads[threadIndex].steps[streamIndex].text += pending
        } else {
            state.threads[threadIndex].steps.append(TaskStep(
                kind: .textOutput,
                text: pending,
                toolCallId: Self.streamingOutputID,
                isCollapsible: false,
                isCollapsed: false
            ))
        }
        state.threads[threadIndex].updatedAt = Date()
    }

    func mergeCompletedTask(_ completedTask: AgentTask, into taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        for step in completedTask.steps {
            if shouldCollapseDuplicateStep(step, in: state.threads[threadIndex].steps) { continue }
            let alreadyExists = state.threads[threadIndex].steps.contains {
                $0.id == step.id || ($0.kind == step.kind && $0.text == step.text)
            }
            if !alreadyExists {
                state.threads[threadIndex].steps.append(step)
                updateLiveActivity(from: step)
            }
        }
        state.threads[threadIndex].status = completedTask.status
        state.liveActivity = ""
        state.threads[threadIndex].context = completedTask.context
        state.threads[threadIndex].context.memory = Self.taskMemory(from: state.threads[threadIndex])
        if let plan = completedTask.multiAgentPlan {
            state.threads[threadIndex].multiAgentPlan = plan
        }
        state.threads[threadIndex].updatedAt = completedTask.updatedAt
        Self.ensureCheckpointIfNeeded(&state.threads[threadIndex])
        state.selectThread(id: taskID)

        // System notification when app is in background
        let appIsActive = NSApplication.shared.isActive
        if !appIsActive {
            let threadTitle = state.threads[threadIndex].title
            let noteTitle: String
            switch completedTask.status {
            case .completed: noteTitle = "任务完成"
            case .failed: noteTitle = "任务失败"
            default: noteTitle = "任务状态更新"
            }
            NotificationManager.shared.post(
                title: noteTitle,
                body: threadTitle,
                threadID: taskID.uuidString
            )
        }
    }

    func shouldCollapseDuplicateStep(_ step: TaskStep, in steps: [TaskStep]) -> Bool {
        switch step.kind {
        case .userInput, .aiThinking:
            return steps.contains { $0.kind == step.kind && $0.text == step.text }
        default:
            return false
        }
    }

    func appendAssistantStep(_ text: String, to sessionID: UUID, connectorName: String, metrics: ResponseMetrics? = nil) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == sessionID }) else { return }
        let assistantText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        state.threads[threadIndex].steps.append(TaskStep(kind: .textOutput, text: assistantText, isCollapsible: false, isCollapsed: false, metrics: metrics))
        state.threads[threadIndex].preview = normalizedSessionPreview(assistantText)
        state.threads[threadIndex].modelName = connectorName
        state.threads[threadIndex].updatedAt = .now
        state.selectThread(id: sessionID)
        persistThreads()
    }

    func appendAssistantDelta(_ delta: String, stepID: UUID, in sessionID: UUID, connectorName: String) {
        guard !delta.isEmpty else { return }
        chatStreamBuffers[stepID, default: ""] += delta
        let now = Date()
        let pending = chatStreamBuffers[stepID] ?? ""
        let lastFlush = chatStreamLastFlushAt[stepID] ?? .distantPast
        guard pending.count >= chatStreamFlushCharacterThreshold || now.timeIntervalSince(lastFlush) >= chatStreamFlushInterval else {
            return
        }
        flushAssistantBuffer(stepID: stepID, in: sessionID, connectorName: connectorName)
    }

    func flushAssistantBuffer(stepID: UUID, in sessionID: UUID, connectorName: String) {
        guard let pending = chatStreamBuffers[stepID], !pending.isEmpty else { return }
        chatStreamBuffers[stepID] = ""
        chatStreamLastFlushAt[stepID] = Date()
        updateAssistantStep(stepID, in: sessionID, delta: pending, connectorName: connectorName, persist: false)
    }

    func updateAssistantStep(
        _ stepID: UUID,
        in sessionID: UUID,
        delta: String? = nil,
        finalText: String? = nil,
        metrics: ResponseMetrics? = nil,
        connectorName: String,
        persist shouldPersist: Bool = true
    ) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == sessionID }) else { return }
        guard let stepIndex = state.threads[threadIndex].steps.firstIndex(where: { $0.id == stepID }) else {
            appendAssistantStep(finalText ?? delta ?? "", to: sessionID, connectorName: connectorName, metrics: metrics)
            return
        }

        if let finalText {
            state.threads[threadIndex].steps[stepIndex].text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let delta, !delta.isEmpty {
            state.threads[threadIndex].steps[stepIndex].text += delta
        }
        if let metrics {
            state.threads[threadIndex].steps[stepIndex].metrics = metrics
        }

        let text = state.threads[threadIndex].steps[stepIndex].text
        state.threads[threadIndex].preview = normalizedSessionPreview(text)
        state.threads[threadIndex].modelName = connectorName
        state.threads[threadIndex].updatedAt = .now
        state.selectThread(id: sessionID)
        if shouldPersist {
            chatStreamBuffers.removeValue(forKey: stepID)
            chatStreamLastFlushAt.removeValue(forKey: stepID)
            persistThreads()
        }
    }

    func directSessionTitle(for message: String) -> String {
        let normalized = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "新会话" }
        if Self.isTinyFollowUp(normalized), let title = state.selectedThread?.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return String(normalized.prefix(32))
    }

    func reconcileSelectedRunningTaskIfIdle() {
        guard !state.isGenerating,
              let taskID = state.selectedThreadID,
              let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }),
              state.threads[threadIndex].status == .running else { return }

        state.threads[threadIndex].status = .cancelled
        state.threads[threadIndex].updatedAt = .now
        state.threads[threadIndex].steps.append(TaskStep(
            kind: .error,
            text: "上次执行没有正常结束，已转为可继续状态。本轮会沿着这条任务继续。",
            isCollapsible: true,
            isCollapsed: true,
            isFailure: false,
            recoverable: true,
            retryAction: "继续"
        ))
        persistThreads()
    }

    func answerSelectedTaskStatusQuestion(_ message: String) -> Bool {
        guard let taskID = state.selectedTaskID,
              let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }),
              state.threads[threadIndex].status != .running,
              Self.isTaskStatusQuestion(message) else { return false }

        let answer = Self.taskStatusAnswer(for: AgentTask(thread: state.threads[threadIndex]), question: message)
        state.threads[threadIndex].steps.append(TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false))
        state.threads[threadIndex].steps.append(TaskStep(kind: .textOutput, text: answer, isCollapsible: false, isCollapsed: false))
        state.threads[threadIndex].updatedAt = .now
        state.selectThread(id: taskID)
        state.modeLabel = state.threads[threadIndex].workflowName == nil ? "任务" : "工作流"
        state.draftMessage = ""
        persistThreads()
        return true
    }

    func appendReviewResult(to threadIndex: Int, approved: Bool, text: String) {
        let result = TaskStep(
            kind: .reviewResult,
            text: text,
            isCollapsible: false,
            isCollapsed: false,
            isFailure: !approved,
            approved: approved
        )
        state.threads[threadIndex].steps.append(result)
    }

    func markConnectorReady(_ id: UUID) {
        updateConnectorHealth(id, to: .ready)
    }

    func updateConnectorHealth(_ id: UUID, to health: ConnectorHealth) {
        guard let index = state.connectors.firstIndex(where: { $0.id == id }) else { return }
        state.connectors[index].health = health
        state.connectors[index].lastCheckedAt = .now
        persistConnectors()
    }

    func recordConnectorOutcome(_ response: SendMessageResponse, connectorID: UUID) {
        if let health = Self.connectorFailureHealth(from: response) {
            updateConnectorHealth(connectorID, to: health)
            return
        }
        markConnectorReady(connectorID)
    }

    func recordConnectorOutcome(_ task: AgentTask, connectorID: UUID, attemptedToolCalling: Bool) {
        rememberToolCallingCapabilityIfNeeded(from: task, connectorID: connectorID, attemptedToolCalling: attemptedToolCalling)
        if let health = Self.connectorFailureHealth(from: task) {
            updateConnectorHealth(connectorID, to: health)
            return
        }
        markConnectorReady(connectorID)
    }

    static func connectorConfigurationChanged(from previous: ConnectorProfile, to next: ConnectorProfile) -> Bool {
        previous.kind.trimmingCharacters(in: .whitespacesAndNewlines) != next.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) != next.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.modelName.trimmingCharacters(in: .whitespacesAndNewlines) != next.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.note.trimmingCharacters(in: .whitespacesAndNewlines) != next.note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func toolCallingIdentityChanged(from previous: ConnectorProfile, to next: ConnectorProfile) -> Bool {
        previous.kind.trimmingCharacters(in: .whitespacesAndNewlines) != next.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) != next.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.modelName.trimmingCharacters(in: .whitespacesAndNewlines) != next.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func rememberToolCallingCapabilityIfNeeded(from task: AgentTask, connectorID: UUID, attemptedToolCalling: Bool) {
        guard attemptedToolCalling else { return }
        let fallbackDetected = task.steps.contains(where: { $0.retryAction == AgentLoop.toolCompatibilityFallbackAction })
        let producedAgentContent = task.steps.contains {
            $0.kind == .textOutput || $0.kind == .toolCall || $0.kind == .toolResult || $0.kind == .reviewResult
        }
        let nextCapability: ConnectorToolCallingCapability?
        if fallbackDetected {
            nextCapability = .unsupported
        } else if producedAgentContent {
            nextCapability = .supported
        } else {
            nextCapability = nil
        }
        if rememberToolCallingCapability(nextCapability, connectorID: connectorID, activitySource: .taskRun) {
            persistConnectors()
        }
    }

    @discardableResult
    func rememberToolCallingCapability(
        _ capability: ConnectorToolCallingCapability?,
        connectorID: UUID,
        activitySource: ConnectorToolCallingCapabilityObservationSource?
    ) -> Bool {
        guard let capability,
              let index = state.connectors.firstIndex(where: { $0.id == connectorID }) else { return false }
        let previousCapability = state.connectors[index].toolCallingCapability
        let previousSource = state.connectors[index].toolCallingCapabilitySource
        let capabilityChanged = previousCapability != capability
        let sourceChanged = activitySource != nil && previousSource != activitySource
        let observedAgain = activitySource != nil
        guard capabilityChanged || observedAgain else { return false }
        state.connectors[index].toolCallingCapability = capability
        if capabilityChanged {
            refreshActiveAgentLoopIfNeeded(for: connectorID)
        }
        if let activitySource {
            state.connectors[index].toolCallingCapabilitySource = activitySource
            state.connectors[index].toolCallingCapabilityLearnedAt = .now
        } else if capabilityChanged {
            state.connectors[index].toolCallingCapabilitySource = nil
            state.connectors[index].toolCallingCapabilityLearnedAt = nil
        }
        guard let activitySource,
              capabilityChanged || sourceChanged else { return true }
        let statusLine: String
        switch (activitySource, capability) {
        case (.connectorProbe, .supported):
            statusLine = "已通过连接测试验证 tools 请求兼容，automatic 模式会继续保留工具调用。"
        case (.connectorProbe, .unsupported):
            statusLine = "已通过连接测试验证 tools 请求不兼容，automatic 模式后续将默认不再发送 tools。"
        case (.taskRun, .supported):
            statusLine = "本次任务已成功携带 tools 请求，automatic 模式后续会继续保留工具调用。"
        case (.taskRun, .unsupported):
            statusLine = "检测到请求格式不兼容，automatic 模式后续将默认不再发送 tools。"
        }
        recordToolActivity(
            name: "connector.capability",
            summary: capability == .supported
                ? "已验证 \(state.connectors[index].name) 支持工具调用"
                : "已验证 \(state.connectors[index].name) 不兼容工具调用",
            statusLine: statusLine,
            isFailure: false
        )
        return true
    }

    func refreshActiveAgentLoopIfNeeded(for connectorID: UUID) {
        // No-op: per-thread loops are created on demand in sendTaskDraft
    }

    static func connectorFailureHealth(from response: SendMessageResponse) -> ConnectorHealth? {
        let text = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("无法连接") || text.hasPrefix("请求失败：") || text.hasPrefix("模型请求失败：") {
            return .offline
        }
        if response.toolActivities.contains(where: { $0.isFailure }) || looksLikeConnectorFailure(text) {
            return .attention
        }
        return nil
    }

    static func connectorFailureHealth(from task: AgentTask) -> ConnectorHealth? {
        guard let errorStep = task.steps.reversed().first(where: { $0.kind == .error && $0.isFailure }) else { return nil }
        if errorStep.retryAction == "检查端点、模型名和请求兼容性后重试" {
            return .attention
        }
        let text = errorStep.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("模型请求失败：") || text.hasPrefix("请求失败：") || text.hasPrefix("无法连接") {
            return .offline
        }
        return nil
    }

    static func looksLikeConnectorFailure(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let preview = normalizedSessionPreview(text)
        return preview == "未找到接口，请检查端点地址是否正确。"
            || preview == "鉴权失败，请检查 API 密钥是否正确。"
            || preview == "请求失败，请检查连接器配置。"
            || text.contains("HTTP 400")
            || text.contains("HTTP 401")
            || text.contains("HTTP 404")
    }

    /// H1: Debounced persistence — during streaming/generation, collapse
    /// rapid calls into one write per `persistDebounceInterval`.
    func persistThreads() {
        // If we're not generating, persist immediately (user actions, startup, etc.)
        guard state.isGenerating else {
            persistThreadsNow()
            return
        }
        // During generation: debounce to avoid 50-100 writes per task
        persistDebounceTask?.cancel()
        persistDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.persistDebounceInterval ?? 1.0))
            guard !Task.isCancelled else { return }
            self?.persistThreadsNow()
        }
    }

    /// Immediately persist — used at critical moments (task complete, cancel, explicit save)
    func persistThreadsNow() {
        lastPersistedAt = Date()
        updateSummaryCaches()
        do { try environment.threadRepository.saveThreads(state.threads) }
        catch { recordToolActivity(name: "threads.save", summary: "会话持久化失败", statusLine: error.localizedDescription, isFailure: true) }
    }

    /// For threads with >20 steps, generate a summary cache of early steps
    /// so that continuation runs don't need to re-compress the full history.
    /// H2: During generation, only update the active thread to avoid scanning all threads.
    func updateSummaryCaches() {
        let summaryThreshold = 20
        let indicesToCheck: Range<Int>
        if state.isGenerating, let selectedID = state.selectedThreadID,
           let idx = state.threads.firstIndex(where: { $0.id == selectedID }) {
            indicesToCheck = idx..<(idx + 1)
        } else {
            indicesToCheck = state.threads.startIndex..<state.threads.endIndex
        }
        for index in indicesToCheck {
            let thread = state.threads[index]
            guard thread.steps.count > summaryThreshold else { continue }
            let recentStepCount = min(14, thread.steps.count)
            let earlyStepsCount = thread.steps.count - recentStepCount
            let needsUpdate: Bool
            if let cache = thread.summaryCache {
                needsUpdate = !cache.contains("\(earlyStepsCount) 条早期步骤")
            } else {
                needsUpdate = true
            }
            guard needsUpdate else { continue }
            state.threads[index].summaryCache = Self.generateSummaryCache(for: thread)
        }
    }

    func persistConnectors() {
        do { try environment.connectorRepository.saveConnectors(state.connectors, activeConnectorID: state.activeConnectorID) }
        catch { recordToolActivity(name: "connectors.save", summary: "连接器持久化失败", statusLine: error.localizedDescription, isFailure: true) }
    }

    func persistSettings() {
        AppSettingsStorage.save(state.settings)
    }

    // MARK: - Engine Initialization (Hooks, Scheduler, Goals, Gateway)

    func initializeEngines(workspaceRoot: String) {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }

        HookEngine.shared.loadHooks(workspaceRoot: root)

        // Persistent memory engine
        MemoryEngine.shared.open()

        SchedulerEngine.shared.onExecuteTask = { [weak self] message, workflowName in
            guard let self else { return "未初始化" }
            if let wfName = workflowName {
                self.startWorkflow(named: wfName, goal: message)
            } else {
                self.state.draftMessage = message
                self.sendDraft()
            }
            return "已触发"
        }
        SchedulerEngine.shared.start(workspaceRoot: root)

        GoalEngine.shared.onExecuteStep = { [weak self] message, threadID in
            guard let self else { return (false, "未初始化") }
            self.state.draftMessage = message
            self.sendDraft()
            return (true, "已发送")
        }

        MessagingGateway.shared.onProcessMessage = { [weak self] message in
            guard let self else { return "来财未初始化" }
            self.state.draftMessage = message.text
            self.sendDraft()
            return "已处理"
        }

        // Skill composition callbacks
        SkillCompositionEngine.shared.onExecuteStep = { [weak self] message, skillName in
            guard let self else { return ("", false) }
            await MainActor.run {
                self.state.draftMessage = message
                self.sendDraft()
            }
            return (message, true)
        }
        SkillCompositionEngine.shared.onExpandGlob = { glob, wsRoot in
            let dir = URL(fileURLWithPath: wsRoot)
            guard let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }
            let ext = glob.replacingOccurrences(of: "*.", with: "")
            var files: [String] = []
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension == ext { files.append(url.path) }
                if files.count >= 100 { break }
            }
            return files
        }

        // Load workflow chains
        WorkflowChainRegistry.shared.load(workspaceRoot: root)
    }

    // MARK: - Background Agent Support

    public func sendToBackground(threadID: UUID) {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }),
              state.threads[index].status == .running else { return }
        let title = state.threads[index].title
        let bgTaskID = BackgroundTaskManager.shared.startTask(title: title)
        state.threads[index].context.metadata["backgroundTaskID"] = bgTaskID.uuidString
        state.threads[index].context.metadata["isBackground"] = "true"
        notify("任务已转入后台：\(title)", style: .info)
    }

    public func isBackgroundThread(_ threadID: UUID) -> Bool {
        guard let thread = state.threads.first(where: { $0.id == threadID }) else { return false }
        return thread.context.metadata["isBackground"] == "true"
    }

    // MARK: - Goal Management Shortcuts

    public func createGoal(title: String, message: String, steps: [GoalStep] = []) {
        let goal = GoalEngine.shared.createGoal(title: title, message: message, steps: steps)
        notify("目标已创建：\(goal.title)", style: .success)
    }

    public func pauseGoal(id: UUID) { GoalEngine.shared.pauseGoal(id: id) }
    public func resumeGoal(id: UUID) { GoalEngine.shared.resumeGoal(id: id) }
    public func cancelGoal(id: UUID) { GoalEngine.shared.cancelGoal(id: id) }

    // MARK: - Messaging Gateway Shortcuts

    public func startGateway(port: Int = 18789) {
        MessagingGateway.shared.start(workspaceRoot: state.settings.workspacePath, port: port)
        notify("消息网关已启动（端口 \(port)）", style: .success)
    }

    public func stopGateway() {
        MessagingGateway.shared.stop()
        notify("消息网关已停止", style: .info)
    }
}
