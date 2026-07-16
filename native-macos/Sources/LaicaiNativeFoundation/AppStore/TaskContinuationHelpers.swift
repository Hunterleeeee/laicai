import Foundation
import LaicaiNativeDomain

extension AppStore {
    static func prepareThreadForContinuation(_ thread: inout Thread, message: String) {
        let checkpoint = latestCheckpoint(in: thread)
        thread.steps.removeAll(where: shouldRemoveContinuationTransientStep)

        guard isContinuationCommand(message) || isLikelyTaskFollowUp(message),
            !thread.context.memory.userDecisions.contains(where: { $0.contains("[continuation]") })
        else { return }
        let checkpointText = checkpoint.map { "\n\n最近检查点：\($0)" } ?? ""
        let summary = continuationSummary(for: thread, checkpointText: checkpointText)

        thread.context.memory.appendDecision("[continuation] \(summary)")
        if !checkpointText.isEmpty {
            thread.steps.append(
                TaskStep(
                    kind: .aiThinking,
                    text: "恢复现场：最近检查点已写入本轮上下文。\(checkpointText)",
                    isCollapsible: true,
                    isCollapsed: true
                ))
        }
    }

    private static func shouldRemoveContinuationTransientStep(_ step: TaskStep) -> Bool {
        if step.kind == .textOutput,
            step.toolCallId == streamingOutputID,
            step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        guard step.kind == .error else { return false }
        let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if step.recoverable && !step.isFailure { return true }
        if text.contains("已达到最大迭代次数") { return true }
        return text.contains("上次运行被中断")
            || text.contains("已自动标记为已暂停")
            || text.contains("已自动标记为已取消")
    }

    private static func continuationSummary(for thread: Thread, checkpointText: String) -> String {
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
        var summary = "继续处理：沿用已有结果，从未完成处继续。\n\n"
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
        return summary
    }

    static func ensureCheckpointIfNeeded(_ thread: inout Thread) {
        guard thread.status == .failed || thread.status == .cancelled || thread.steps.contains(where: { $0.text.contains("已达到最大迭代次数") })
        else { return }
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
        lines.append("建议下一步：基于已读结果继续，优先补齐未读关键文件；如果是整项目会话，先使用 workspace.index 或已有索引，不要重复低效 shell 遍历。")
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
            $0.kind == .aiThinking && ($0.text.hasPrefix("会话 检查点") || $0.text.hasPrefix("任务检查点"))
        }?.text
    }

    static func retryMessage(for thread: Thread, lastUserMessage: String) -> String {
        lastUserMessage.trimmingCharacters(in: .whitespacesAndNewlines)
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

    static func markStaleRunningTasks(in state: inout AppState, now: Date = .now) {
        let timeout: TimeInterval = 20 * 60
        for index in state.threads.indices {
            let isStale = now.timeIntervalSince(state.threads[index].updatedAt) > timeout
            let shouldCancelRunning = state.threads[index].status == .running && isStale
            let shouldCancelStaleReview =
                state.threads[index].isExecution
                && state.threads[index].status == .waitingReview
                && isStale
            guard shouldCancelRunning || shouldCancelStaleReview else { continue }
            state.threads[index].status = .cancelled
            state.threads[index].executionState = .paused
            state.threads[index].updatedAt = now
            if state.threads[index].steps.contains(where: { $0.kind == .error && $0.text.contains("上次运行被中断") }) {
                continue
            }
            state.threads[index].steps.append(
                TaskStep(
                    kind: .error,
                    text: "上次运行被中断，已自动标记为已暂停。可以从这个会话继续或重新发送。",
                    isFailure: false,
                    recoverable: true,
                    retryAction: "继续"
                ))
            if state.threads[index].isExecution {
                ensureCheckpointIfNeeded(&state.threads[index])
            }
        }
    }
}
