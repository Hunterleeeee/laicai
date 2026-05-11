import Foundation
import LaicaiNativeDomain

extension AppStore {
    /// Handle /goal, /background, /schedule, /gateway commands. Returns true if handled.
    func handleSlashCommand(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("/goal ") {
            let body = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else {
                notify("用法：/goal <目标描述>", style: .error)
                return true
            }
            state.draftMessage = ""
            createGoal(title: body, message: body)
            return true
        }

        if trimmed == "/goal list" {
            let goals = GoalEngine.shared.activeGoals
            let text = goals.isEmpty ? "暂无活跃目标" : goals.map { "- [\($0.status.displayText)] \($0.title)" }.joined(separator: "\n")
            notify(text, style: .info)
            state.draftMessage = ""
            return true
        }
        if trimmed.hasPrefix("/goal pause") {
            if let goal = GoalEngine.shared.activeGoals.first(where: { $0.status == .running }) {
                pauseGoal(id: goal.id)
            }
            state.draftMessage = ""
            return true
        }
        if trimmed.hasPrefix("/goal resume") {
            if let goal = GoalEngine.shared.activeGoals.first(where: { $0.status == .paused }) {
                resumeGoal(id: goal.id)
            }
            state.draftMessage = ""
            return true
        }

        if trimmed == "/background" || trimmed == "/bg" {
            if let threadID = state.selectedThreadID {
                sendToBackground(threadID: threadID)
            } else {
                notify("没有选中的任务可以转到后台", style: .error)
            }
            state.draftMessage = ""
            return true
        }

        if trimmed.hasPrefix("/schedule ") {
            let body = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            let parts = body.components(separatedBy: " ")
            guard parts.count >= 2 else {
                notify("用法：/schedule <间隔分钟数> <任务消息>", style: .error)
                return true
            }
            if let minutes = Int(parts[0]) {
                let taskMessage = parts.dropFirst().joined(separator: " ")
                let task = ScheduledTask(
                    name: String(taskMessage.prefix(30)),
                    message: taskMessage,
                    schedule: .interval(seconds: minutes * 60)
                )
                SchedulerEngine.shared.addTask(task)
                notify("定时任务已创建：每 \(minutes) 分钟执行「\(taskMessage)」", style: .success)
            }
            state.draftMessage = ""
            return true
        }

        if trimmed == "/gateway start" {
            startGateway()
            state.draftMessage = ""
            return true
        }
        if trimmed == "/gateway stop" {
            stopGateway()
            state.draftMessage = ""
            return true
        }

        if trimmed.hasPrefix("/pipe ") {
            let body = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if let pipeline = PipelineParser.parse(body) {
                state.draftMessage = ""
                Task { await SkillCompositionEngine.shared.execute(pipeline, workspaceRoot: state.settings.workspacePath) }
                notify("管道已启动：\(pipeline.name)", style: .success)
            } else {
                notify("用法：/pipe 技能1 | 技能2 | 技能3", style: .error)
            }
            return true
        }

        if trimmed.hasPrefix("/foreach ") {
            let body = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            if let pipeline = PipelineParser.parseBatch("/foreach " + body) {
                state.draftMessage = ""
                Task { await SkillCompositionEngine.shared.execute(pipeline, workspaceRoot: state.settings.workspacePath) }
                notify("批量任务已启动：\(pipeline.name)", style: .success)
            } else {
                notify("用法：/foreach file in *.swift: 审查代码", style: .error)
            }
            return true
        }

        if trimmed == "/export" {
            let url = SessionTeleport.suggestedExportURL(workspaceName: state.workspaceName)
            do {
                try SessionTeleport.shared.exportBundle(
                    threads: state.threads,
                    connectors: state.connectors,
                    settings: state.settings,
                    to: url
                )
                notify("已导出到 \(url.lastPathComponent)", style: .success)
            } catch {
                notify("导出失败：\(error.localizedDescription)", style: .error)
            }
            state.draftMessage = ""
            return true
        }

        if trimmed == "/regression" {
            state.draftMessage = ""
            Task { await ModelRegressionRunner.shared.runAll() }
            notify("模型回归测试已启动", style: .info)
            return true
        }

        return false
    }
}
