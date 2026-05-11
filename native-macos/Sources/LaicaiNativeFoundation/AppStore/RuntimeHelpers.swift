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

}
