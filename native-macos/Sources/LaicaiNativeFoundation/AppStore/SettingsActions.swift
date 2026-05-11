import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func updateDraft(_ value: String) { state.draftMessage = value }

    public func queueFollowUp(_ message: String) {
        state.pendingFollowUp = message
    }

    public func submitFollowUp() {
        guard let followUp = state.pendingFollowUp, !followUp.isEmpty else { return }
        state.pendingFollowUp = nil
        state.draftMessage = ""
        if let taskID = state.selectedTaskID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) {
            let step = TaskStep(kind: .userInput, text: followUp, isCollapsible: false, isCollapsed: false)
            state.threads[threadIndex].steps.append(step)
            persistThreads()
        }
    }

    public func clearPendingFollowUp() {
        state.pendingFollowUp = nil
    }

    public func addDraftAttachments(_ paths: [String]) {
        let cleaned = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        var existing = state.draftAttachments
        for path in cleaned where !existing.contains(path) {
            existing.append(path)
        }
        state.draftAttachments = existing
    }

    public func removeDraftAttachment(_ path: String) {
        state.draftAttachments.removeAll { $0 == path }
    }

    public func addDraftImage(_ attachment: ImageAttachment) {
        state.draftImages.append(attachment)
    }

    public func removeDraftImage(id: UUID) {
        state.draftImages.removeAll { $0.id == id }
    }

    public func clearDraftImages() {
        state.draftImages.removeAll()
    }

    public func updateWorkspacePath(_ value: String) {
        if WorkspaceSandbox.isOverlyBroadWorkspace(value) {
            notify("工作区不能设为 home 目录或根目录，请选择一个具体的项目文件夹。", style: .error)
            return
        }
        state.settings.workspacePath = value
        state.workspaceName = URL(fileURLWithPath: value).lastPathComponent
        WorkspaceSandbox.shared.workspaceRoot = value
        initializeEngines(workspaceRoot: value)
        persistSettings()
    }

    public func switchWorkspace(to path: String) {
        state.settings.switchWorkspace(to: path)
        state.workspaceName = URL(fileURLWithPath: path).lastPathComponent
        WorkspaceSandbox.shared.workspaceRoot = path
        initializeEngines(workspaceRoot: path)
        persistSettings()
    }

    public func updateVaultPath(_ value: String) {
        state.settings.vaultPath = value
        persistSettings()
    }

    public func toggleCompactComposer(_ enabled: Bool) {
        state.settings.compactComposer = enabled
        persistSettings()
    }

    public func updateComfyUIServerURL(_ value: String) {
        state.settings.comfyUIServerURL = value
        persistSettings()
    }

    public func updateComfyUIModelName(_ value: String) {
        state.settings.comfyUIModelName = value
        persistSettings()
    }

    public func toggleDebugPanels(_ enabled: Bool) {
        state.settings.showDebugPanels = enabled
        persistSettings()
    }

    public func updateContextMode(_ mode: ContextMode) {
        state.settings.contextMode = mode
        persistSettings()
    }

    public func retryLastMessage() {
        guard !state.isGenerating else { return }

        if let thread = state.selectedThread, thread.source == .task {
            guard thread.status != .running else { return }
            guard let lastUserStep = thread.steps.last(where: { $0.kind == .userInput }) else { return }
            BehaviorSignalTracker.record(signal: .retry, thread: thread)
            state.draftMessage = Self.retryMessage(for: thread, lastUserMessage: lastUserStep.text)
            sendDraft()
            return
        }

        guard let thread = state.selectedThread, thread.source == .session else { return }
        guard let lastUserIndex = thread.steps.lastIndex(where: { $0.kind == .userInput }) else { return }
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == thread.id }) else { return }
        let lastUserStep = thread.steps[lastUserIndex]
        state.threads[threadIndex].steps = Array(thread.steps.prefix(lastUserIndex))
        state.threads[threadIndex].preview = thread.steps.prefix(lastUserIndex).last?.text ?? ""
        state.draftMessage = lastUserStep.text
        persistThreads()
        sendDraft()
    }

    public func continueTask() {
        guard !state.isGenerating else { return }
        guard let thread = state.selectedThread, thread.source == .task else { return }
        guard thread.status == .failed || thread.status == .completed else { return }

        if let threadIndex = state.threads.firstIndex(where: { $0.id == thread.id }) {
            state.threads[threadIndex].status = .queued
            state.threads[threadIndex].updatedAt = .now
            persistThreads()
        }

        state.draftMessage = "继续处理，并优先基于当前证据形成结论；不要重复已经完成的读取、搜索或执行步骤。"
        sendDraft()
    }

    public func clearSelectedThread() {
        guard let threadID = state.selectedThreadID,
              let threadIndex = state.threads.firstIndex(where: { $0.id == threadID }) else { return }
        state.threads[threadIndex].steps = []
        state.threads[threadIndex].status = .queued
        state.threads[threadIndex].preview = ""
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
    }

    static func enrichVagueMessage(_ message: String, thread: Thread?) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 8 else { return message }

        let hasContext = thread != nil && !(thread?.steps.isEmpty ?? true)
        let lastUserInput = thread?.steps.last(where: { $0.kind == .userInput })?.text ?? ""
        let threadTitle = thread?.title ?? ""

        let continuationPhrases = ["继续", "接着", "接着做", "go on", "continue", "好的继续", "ok继续"]
        let executionPhrases = ["做", "开始", "开始做", "做吧", "干", "go", "start", "执行"]
        let allDonePhrases = ["全做", "都做", "全部", "一起做", "all"]
        let retryPhrases = ["重试", "再试", "retry", "again", "再来"]

        let lower = trimmed.lowercased()

        if continuationPhrases.contains(where: { lower == $0 }) {
            if hasContext {
                return "继续处理当前任务，优先基于已有证据形成结论；不要重复已完成的读取、搜索或执行步骤。"
            }
        }

        if executionPhrases.contains(where: { lower == $0 }) {
            if hasContext {
                return "执行上面讨论的方案。\(!lastUserInput.isEmpty ? "原始需求：\(lastUserInput.prefix(200))" : "")"
            }
        }

        if allDonePhrases.contains(where: { lower == $0 || lower.contains($0) }) {
            if hasContext {
                return "按上面讨论的方案，全部执行。按优先级顺序逐一完成，每完成一项汇报进度。\(!threadTitle.isEmpty ? "任务：\(threadTitle)" : "")"
            }
        }

        if retryPhrases.contains(where: { lower == $0 }) {
            if hasContext && !lastUserInput.isEmpty {
                return "重试上一次操作。原始需求：\(lastUserInput.prefix(300))\n注意避免之前的失败原因。"
            }
        }

        let affirmations = ["好", "行", "ok", "可以", "好的", "行吧", "嗯"]
        if affirmations.contains(where: { lower == $0 }) && hasContext {
            return "确认，请执行你建议的方案。"
        }

        return message
    }

    public func autoResumeInterruptedTask() {
        let interrupted = state.threads
            .filter { $0.source == .task && $0.status == .cancelled }
            .filter { $0.steps.contains(where: { $0.kind == .error && $0.text.contains("上次运行被中断") }) }
            .sorted { $0.updatedAt > $1.updatedAt }

        guard let latest = interrupted.first else { return }
        state.selectedThreadID = latest.id

        let timeSinceInterruption = Date.now.timeIntervalSince(latest.updatedAt)
        if timeSinceInterruption < 30 * 60 {
            if let idx = state.threads.firstIndex(where: { $0.id == latest.id }) {
                let hasResumeHint = state.threads[idx].steps.contains(where: {
                    $0.kind == .error && $0.text.contains("自动恢复")
                })
                if !hasResumeHint {
                    state.threads[idx].steps.append(TaskStep(
                        kind: .error,
                        text: "检测到上次任务被中断（\(Self.relativeTimeString(latest.updatedAt))）。点击「继续任务」自动恢复，或发送新消息开始新的对话。",
                        isFailure: false,
                        recoverable: true,
                        retryAction: "继续执行"
                    ))
                    persistThreads()
                }
            }
        }
    }

    private static func relativeTimeString(_ date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "\(Int(interval))秒前" }
        if interval < 3600 { return "\(Int(interval / 60))分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600))小时前" }
        return "\(Int(interval / 86400))天前"
    }
}
