import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func rollbackLastApprovedWrite(taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        guard let step = state.threads[threadIndex].steps.reversed().first(where: {
            $0.kind == .reviewRequest && $0.approved == true && $0.diffFilePath != nil && $0.diffOldContent != nil
        }) else {
            state.threads[threadIndex].steps.append(TaskStep(
                kind: .error,
                text: "没有可回滚的已批准文件变更。",
                isCollapsible: true,
                isCollapsed: true,
                isFailure: false,
                recoverable: false
            ))
            state.threads[threadIndex].updatedAt = .now
            persistThreads()
            return
        }
        performRollback(threadIndex: threadIndex, step: step)
    }

    public func rollbackBatch(taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        let approvedSteps = state.threads[threadIndex].steps.enumerated().compactMap { index, step -> (Int, TaskStep)? in
            step.kind == .reviewRequest && step.approved == true && step.diffFilePath != nil && step.diffOldContent != nil ? (index, step) : nil
        }
        guard !approvedSteps.isEmpty else {
            ToastCenter.shared.show("没有可回滚的已批准变更")
            return
        }
        var rolledBack = 0
        for (_, step) in approvedSteps.reversed() {
            let filePath = step.diffFilePath ?? ""
            let fullPath = step.toolParams?["fullPath"]
                ?? absolutePath(for: filePath, workspaceRoot: state.threads[threadIndex].context.workspaceRoot)
            if SecurityManager.shared.checkWrite(path: fullPath) != nil { continue }
            do {
                try WriteFileTool().performWrite(fullPath: fullPath, content: step.diffOldContent ?? "", createDirectories: true)
                rolledBack += 1
            } catch {
                // Continue best-effort rollback for the remaining files.
            }
        }
        for (si, _) in approvedSteps {
            state.threads[threadIndex].steps[si].approved = nil
        }
        appendReviewResult(to: threadIndex, approved: false, text: "批量回滚完成：\(rolledBack)/\(approvedSteps.count) 个文件已恢复")
        AuditLog.shared.record(tool: "batch.rollback", input: "\(approvedSteps.count) files", output: "回滚 \(rolledBack) 个文件", success: true)
        recordToolActivity(name: "batch.rollback", summary: "批量回滚 \(rolledBack) 个文件", statusLine: "", isFailure: false)
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
    }

    public func rollbackApprovedWrite(taskID: UUID, stepID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        guard let step = state.threads[threadIndex].steps.first(where: {
            $0.id == stepID && $0.kind == .reviewRequest && $0.approved == true && $0.diffFilePath != nil && $0.diffOldContent != nil
        }) else {
            ToastCenter.shared.warn("该步骤不可回滚")
            return
        }
        performRollback(threadIndex: threadIndex, step: step)
    }

    private func performRollback(threadIndex: Int, step: TaskStep) {
        let filePath = step.diffFilePath ?? "文件变更"
        let fullPath = step.toolParams?["fullPath"]
            ?? absolutePath(for: filePath, workspaceRoot: state.threads[threadIndex].context.workspaceRoot)
        if let securityError = SecurityManager.shared.checkWrite(path: fullPath) {
            appendReviewResult(to: threadIndex, approved: false, text: "回滚被安全策略拦截：\(securityError)")
            recordToolActivity(name: "file.rollback", summary: "回滚被拦截", statusLine: filePath, isFailure: true)
            state.threads[threadIndex].updatedAt = .now
            persistThreads()
            return
        }

        do {
            try WriteFileTool().performWrite(fullPath: fullPath, content: step.diffOldContent ?? "", createDirectories: true)
            appendReviewResult(to: threadIndex, approved: true, text: "已回滚 \(filePath)")
            AuditLog.shared.record(tool: "file.rollback", input: filePath, output: "已恢复旧内容", success: true)
            recordToolActivity(name: "file.rollback", summary: "已回滚文件", statusLine: filePath, isFailure: false)
        } catch {
            appendReviewResult(to: threadIndex, approved: false, text: "回滚失败：\(error.localizedDescription)")
            AuditLog.shared.record(tool: "file.rollback", input: filePath, output: error.localizedDescription, success: false)
            recordToolActivity(name: "file.rollback", summary: "回滚失败", statusLine: error.localizedDescription, isFailure: true)
        }
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
    }
}
