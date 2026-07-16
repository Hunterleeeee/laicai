import Foundation
import LaicaiNativeDomain

@MainActor
extension AppStore {
    func initializeEngines(workspaceRoot: String) {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }

        HookEngine.shared.loadHooks(workspaceRoot: root)
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

        GoalEngine.shared.onExecuteStep = { [weak self] message, _ in
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

        SkillCompositionEngine.shared.onExecuteStep = { [weak self] message, _ in
            guard let self else { return ("", false) }
            await MainActor.run {
                self.state.draftMessage = message
                self.sendDraft()
            }
            return (message, true)
        }
        SkillCompositionEngine.shared.onExpandGlob = { glob, wsRoot in
            let dir = URL(fileURLWithPath: wsRoot)
            guard
                let enumerator = FileManager.default.enumerator(
                    at: dir, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            else { return [] }
            let ext = glob.replacingOccurrences(of: "*.", with: "")
            var files: [String] = []
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension == ext { files.append(url.path) }
                if files.count >= 100 { break }
            }
            return files
        }

        WorkflowChainRegistry.shared.load(workspaceRoot: root)
    }

    public func sendToBackground(threadID: UUID) {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }),
            state.threads[index].status == .running
        else { return }
        let title = state.threads[index].title
        let bgTaskID = BackgroundTaskManager.shared.startTask(title: title)
        state.threads[index].context.metadata["backgroundTaskID"] = bgTaskID.uuidString
        state.threads[index].context.metadata["isBackground"] = "true"
        notify("会话 已转入后台：\(title)", style: .info)
    }

    public func isBackgroundThread(_ threadID: UUID) -> Bool {
        guard let thread = state.threads.first(where: { $0.id == threadID }) else { return false }
        return thread.context.metadata["isBackground"] == "true"
    }

    public func createGoal(title: String, message: String, steps: [GoalStep] = []) {
        let goal = GoalEngine.shared.createGoal(title: title, message: message, steps: steps)
        notify("目标已创建：\(goal.title)", style: .success)
    }

    public func pauseGoal(id: UUID) { GoalEngine.shared.pauseGoal(id: id) }

    public func resumeGoal(id: UUID) { GoalEngine.shared.resumeGoal(id: id) }

    public func cancelGoal(id: UUID) { GoalEngine.shared.cancelGoal(id: id) }

    public func startGateway(port: Int = 18789) {
        if MessagingGateway.shared.start(workspaceRoot: state.settings.workspacePath, port: port) {
            notify("消息网关已启动（端口 \(port)）", style: .success)
        } else {
            notify(
                MessagingGateway.shared.gatewayError ?? "消息网关启动失败",
                style: .error
            )
        }
    }

    public func stopGateway() {
        MessagingGateway.shared.stop()
        notify("消息网关已停止", style: .info)
    }
}
