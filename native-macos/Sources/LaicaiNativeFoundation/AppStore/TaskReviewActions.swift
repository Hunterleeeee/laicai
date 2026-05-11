import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func approveReview(taskID: UUID, stepID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        guard let stepIndex = state.threads[threadIndex].steps.firstIndex(where: { $0.id == stepID }) else { return }

        let step = state.threads[threadIndex].steps[stepIndex]
        guard step.approved == nil else { return }
        guard let filePath = step.diffFilePath,
              let newContent = step.diffNewContent else {
            state.threads[threadIndex].steps[stepIndex].approved = false
            appendReviewResult(to: threadIndex, approved: false, text: "缺少文件变更内容，无法写入。")
            state.threads[threadIndex].updatedAt = .now
            persistThreads()
            return
        }

        let fullPath = step.toolParams?["fullPath"]
            ?? absolutePath(for: filePath, workspaceRoot: state.threads[threadIndex].context.workspaceRoot)
        let createDirectories = step.toolParams?["createDirectories"] != "false"

        if let securityError = SecurityManager.shared.checkWrite(path: fullPath) {
            state.threads[threadIndex].steps[stepIndex].approved = false
            appendReviewResult(to: threadIndex, approved: false, text: "写入被安全策略拦截：\(securityError)")
            let toolName = step.toolName ?? "file.write"
            AuditLog.shared.record(tool: toolName, input: filePath, output: securityError, success: false)
            recordToolActivity(name: toolName, summary: "写入被拦截", statusLine: filePath, isFailure: true)
            persistThreads()
            return
        }

        // Verify file hasn't been modified externally since review was created.
        if let oldContent = step.diffOldContent,
           FileManager.default.fileExists(atPath: fullPath) {
            if let currentContent = try? String(contentsOfFile: fullPath, encoding: .utf8),
               currentContent != oldContent {
                state.threads[threadIndex].steps[stepIndex].approved = false
                appendReviewResult(to: threadIndex, approved: false, text: "文件在审查期间被外部修改，写入已取消。请重新读取文件并提交新变更。")
                let toolName = step.toolName ?? "file.write"
                AuditLog.shared.record(tool: toolName, input: filePath, output: "文件被外部修改", success: false)
                recordToolActivity(name: toolName, summary: "写入取消：文件被外部修改", statusLine: filePath, isFailure: true)
                persistThreads()
                return
            }
        }

        do {
            try WriteFileTool().performWrite(fullPath: fullPath, content: newContent, createDirectories: createDirectories)
            state.threads[threadIndex].steps[stepIndex].approved = true
            appendReviewResult(to: threadIndex, approved: true, text: "已写入 \(filePath)")
            let toolName = step.toolName ?? "file.write"
            AuditLog.shared.record(tool: toolName, input: filePath, output: "已写入 \(newContent.count) 字符", success: true)
            recordToolActivity(name: toolName, summary: "已写入文件", statusLine: filePath, isFailure: false)
            refreshSkillsIfNeeded(filePath: filePath)
            schedulePostWriteVerification(threadIndex: threadIndex, filePath: filePath)
        } catch {
            state.threads[threadIndex].steps[stepIndex].approved = false
            appendReviewResult(to: threadIndex, approved: false, text: "写入失败：\(error.localizedDescription)")
            let toolName = step.toolName ?? "file.write"
            AuditLog.shared.record(tool: toolName, input: filePath, output: error.localizedDescription, success: false)
            recordToolActivity(name: toolName, summary: "写入失败", statusLine: error.localizedDescription, isFailure: true)
        }
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
        updateDockBadge()
    }

    public func approveHunk(taskID: UUID, stepID: UUID, hunkID: UUID) {
        guard let ti = state.threads.firstIndex(where: { $0.id == taskID }),
              let si = state.threads[ti].steps.firstIndex(where: { $0.id == stepID }),
              var hunks = state.threads[ti].steps[si].diffHunks,
              let hi = hunks.firstIndex(where: { $0.id == hunkID }) else { return }
        hunks[hi].approved = true
        state.threads[ti].steps[si].diffHunks = hunks
        checkAllHunksDecided(threadIndex: ti, stepIndex: si)
        state.threads[ti].updatedAt = .now
        persistThreads()
    }

    public func rejectHunk(taskID: UUID, stepID: UUID, hunkID: UUID) {
        guard let ti = state.threads.firstIndex(where: { $0.id == taskID }),
              let si = state.threads[ti].steps.firstIndex(where: { $0.id == stepID }),
              var hunks = state.threads[ti].steps[si].diffHunks,
              let hi = hunks.firstIndex(where: { $0.id == hunkID }) else { return }
        hunks[hi].approved = false
        state.threads[ti].steps[si].diffHunks = hunks
        checkAllHunksDecided(threadIndex: ti, stepIndex: si)
        state.threads[ti].updatedAt = .now
        persistThreads()
    }

    private func checkAllHunksDecided(threadIndex ti: Int, stepIndex si: Int) {
        guard let hunks = state.threads[ti].steps[si].diffHunks,
              hunks.allSatisfy({ $0.approved != nil }) else { return }
        let approvedHunks = hunks.filter { $0.approved == true }
        if approvedHunks.isEmpty {
            state.threads[ti].steps[si].approved = false
            appendReviewResult(to: ti, approved: false, text: "所有 hunk 均已拒绝")
            return
        }
        guard let filePath = state.threads[ti].steps[si].diffFilePath,
              let oldContent = state.threads[ti].steps[si].diffOldContent else {
            state.threads[ti].steps[si].approved = false
            appendReviewResult(to: ti, approved: false, text: "缺少文件信息")
            return
        }
        var result = oldContent
        for hunk in approvedHunks.sorted(by: { $0.index < $1.index }) {
            result = result.replacingOccurrences(of: hunk.oldText, with: hunk.newText)
        }
        let fullPath = state.threads[ti].steps[si].toolParams?["fullPath"]
            ?? absolutePath(for: filePath, workspaceRoot: state.threads[ti].context.workspaceRoot)
        let createDirectories = state.threads[ti].steps[si].toolParams?["createDirectories"] != "false"
        if let securityError = SecurityManager.shared.checkWrite(path: fullPath) {
            state.threads[ti].steps[si].approved = false
            appendReviewResult(to: ti, approved: false, text: "安全策略拦截：\(securityError)")
            return
        }
        do {
            try WriteFileTool().performWrite(fullPath: fullPath, content: result, createDirectories: createDirectories)
            state.threads[ti].steps[si].approved = true
            let accepted = approvedHunks.count
            let rejected = hunks.count - accepted
            appendReviewResult(to: ti, approved: true, text: "已写入 \(filePath)（接受 \(accepted) / 拒绝 \(rejected) 个 hunk）")
            refreshSkillsIfNeeded(filePath: filePath)
            schedulePostWriteVerification(threadIndex: ti, filePath: filePath)
        } catch {
            state.threads[ti].steps[si].approved = false
            appendReviewResult(to: ti, approved: false, text: "写入失败：\(error.localizedDescription)")
        }
    }

    public func rejectReview(taskID: UUID, stepID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        guard let stepIndex = state.threads[threadIndex].steps.firstIndex(where: { $0.id == stepID }) else { return }
        guard state.threads[threadIndex].steps[stepIndex].approved == nil else { return }
        let filePath = state.threads[threadIndex].steps[stepIndex].diffFilePath ?? "文件变更"
        state.threads[threadIndex].steps[stepIndex].approved = false
        appendReviewResult(to: threadIndex, approved: false, text: "已拒绝，未写入 \(filePath)。")
        let toolName = state.threads[threadIndex].steps[stepIndex].toolName ?? "file.write"
        AuditLog.shared.record(tool: toolName, input: filePath, output: "用户拒绝", success: false)
        recordToolActivity(name: toolName, summary: "已拒绝写入", statusLine: filePath, isFailure: true)
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
    }
}
