import Foundation
import LaicaiNativeDomain

private struct PendingReviewWriteOp {
    let stepIndex: Int
    let fullPath: String
    let newContent: String
    let oldContent: String?
    let createDirectories: Bool
}

private struct PendingReviewRollbackRequest {
    let threadIndex: Int
    let pendingIndices: [Int]
    let writeOps: [PendingReviewWriteOp]
    let backups: [(fullPath: String, content: String?)]
    let applied: [Int]
    let failedWriteOp: PendingReviewWriteOp
    let error: Error
}

extension AppStore {
    public func approveAllPendingReviews(taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }

        let pendingIndices = pendingReviewIndices(threadIndex: threadIndex)
        guard !pendingIndices.isEmpty else {
            notify("没有待审查的变更")
            return
        }

        guard let writeOps = preparePendingReviewWriteOps(threadIndex: threadIndex, pendingIndices: pendingIndices) else {
            return
        }

        if applyPendingReviewWriteOps(threadIndex: threadIndex, pendingIndices: pendingIndices, writeOps: writeOps) {
            completePendingReviewBatch(threadIndex: threadIndex, writeOps: writeOps)
        }

        syncAgentSnapshot(at: threadIndex)
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
        updateDockBadge()
    }

    private func pendingReviewIndices(threadIndex: Int) -> [Int] {
        state.threads[threadIndex].steps.enumerated().compactMap { index, step -> Int? in
            step.kind == .reviewRequest && step.approved == nil && step.diffFilePath != nil && step.diffNewContent != nil ? index : nil
        }
    }

    private func preparePendingReviewWriteOps(threadIndex: Int, pendingIndices: [Int]) -> [PendingReviewWriteOp]? {
        var writeOps: [PendingReviewWriteOp] = []
        for stepIndex in pendingIndices {
            guard let writeOp = pendingReviewWriteOp(threadIndex: threadIndex, stepIndex: stepIndex) else { continue }
            if !validatePendingReviewWriteOp(writeOp, threadIndex: threadIndex) {
                return nil
            }
            writeOps.append(writeOp)
        }
        return writeOps
    }

    private func pendingReviewWriteOp(threadIndex: Int, stepIndex: Int) -> PendingReviewWriteOp? {
        let step = state.threads[threadIndex].steps[stepIndex]
        guard let filePath = step.diffFilePath, let newContent = step.diffNewContent else { return nil }
        let fullPath = step.toolParams?["fullPath"]
            ?? absolutePath(for: filePath, workspaceRoot: state.threads[threadIndex].context.workspaceRoot)
        return PendingReviewWriteOp(
            stepIndex: stepIndex,
            fullPath: fullPath,
            newContent: newContent,
            oldContent: step.diffOldContent,
            createDirectories: step.toolParams?["createDirectories"] != "false"
        )
    }

    private func validatePendingReviewWriteOp(_ writeOp: PendingReviewWriteOp, threadIndex: Int) -> Bool {
        let filePath = state.threads[threadIndex].steps[writeOp.stepIndex].diffFilePath ?? writeOp.fullPath
        if let securityError = SecurityManager.shared.checkWrite(path: writeOp.fullPath) {
            rejectPendingReviewBatch(
                threadIndex: threadIndex,
                stepIndex: writeOp.stepIndex,
                text: "批量写入被拦截（\(filePath)）：\(securityError)"
            )
            return false
        }
        if pendingReviewWasExternallyModified(writeOp) {
            rejectPendingReviewBatch(
                threadIndex: threadIndex,
                stepIndex: writeOp.stepIndex,
                text: "批量写入取消：\(filePath) 在审查期间被外部修改"
            )
            return false
        }
        return true
    }

    private func pendingReviewWasExternallyModified(_ writeOp: PendingReviewWriteOp) -> Bool {
        guard let oldContent = writeOp.oldContent,
              FileManager.default.fileExists(atPath: writeOp.fullPath),
              let currentContent = try? String(contentsOfFile: writeOp.fullPath, encoding: .utf8) else { return false }
        return currentContent != oldContent
    }

    private func rejectPendingReviewBatch(threadIndex: Int, stepIndex: Int, text: String) {
        state.threads[threadIndex].steps[stepIndex].approved = false
        appendReviewResult(to: threadIndex, approved: false, text: text)
        syncAgentSnapshot(at: threadIndex)
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
    }

    private func applyPendingReviewWriteOps(
        threadIndex: Int,
        pendingIndices: [Int],
        writeOps: [PendingReviewWriteOp]
    ) -> Bool {
        let backups = reviewBackups(for: writeOps)
        var applied: [Int] = []
        for writeOp in writeOps {
            do {
                try WriteFileTool().performWrite(
                    fullPath: writeOp.fullPath,
                    content: writeOp.newContent,
                    createDirectories: writeOp.createDirectories
                )
                state.threads[threadIndex].steps[writeOp.stepIndex].approved = true
                applied.append(writeOp.stepIndex)
            } catch {
                rollbackPendingReviewWrites(PendingReviewRollbackRequest(
                    threadIndex: threadIndex,
                    pendingIndices: pendingIndices,
                    writeOps: writeOps,
                    backups: backups,
                    applied: applied,
                    failedWriteOp: writeOp,
                    error: error
                ))
                return false
            }
        }
        return true
    }

    private func reviewBackups(for writeOps: [PendingReviewWriteOp]) -> [(fullPath: String, content: String?)] {
        writeOps.map { writeOp in
            (writeOp.fullPath, try? String(contentsOfFile: writeOp.fullPath, encoding: .utf8))
        }
    }

    private func rollbackPendingReviewWrites(_ request: PendingReviewRollbackRequest) {
        for index in (0..<request.applied.count).reversed() {
            restorePendingReviewBackup(request.backups[index])
            state.threads[request.threadIndex].steps[request.applied[index]].approved = nil
        }
        for stepIndex in request.pendingIndices {
            state.threads[request.threadIndex].steps[stepIndex].approved = false
        }
        let filePath = state.threads[request.threadIndex].steps[request.failedWriteOp.stepIndex].diffFilePath ?? "未知文件"
        appendReviewResult(
            to: request.threadIndex,
            approved: false,
            text: "批量写入失败并已回滚（\(request.applied.count) 个已恢复）：\(filePath) - \(request.error.localizedDescription)"
        )
        AuditLog.shared.record(
            tool: "batch.apply",
            input: "\(request.writeOps.count) files",
            output: "事务回滚：\(request.error.localizedDescription)",
            success: false
        )
        recordToolActivity(
            name: "batch.apply",
            summary: "批量写入失败已回滚",
            statusLine: "\(request.applied.count) 个文件已恢复",
            isFailure: true
        )
    }

    private func restorePendingReviewBackup(_ backup: (fullPath: String, content: String?)) {
        if let originalContent = backup.content {
            try? WriteFileTool().performWrite(fullPath: backup.fullPath, content: originalContent, createDirectories: false)
        } else {
            try? FileManager.default.removeItem(atPath: backup.fullPath)
        }
    }

    private func completePendingReviewBatch(threadIndex: Int, writeOps: [PendingReviewWriteOp]) {
        let paths = writeOps.compactMap { state.threads[threadIndex].steps[$0.stepIndex].diffFilePath }
        appendReviewResult(to: threadIndex, approved: true, text: "批量写入成功：\(paths.count) 个文件\n" + paths.joined(separator: "\n"))
        AuditLog.shared.record(tool: "batch.apply", input: "\(paths.count) files", output: "批量写入成功", success: true)
        recordToolActivity(name: "batch.apply", summary: "批量写入 \(paths.count) 个文件", statusLine: paths.first ?? "", isFailure: false)
        paths.forEach { refreshSkillsIfNeeded(filePath: $0) }
        schedulePostWriteVerification(threadIndex: threadIndex, filePath: firstSourceFilePath(in: paths))
    }

    private func firstSourceFilePath(in paths: [String]) -> String? {
        paths.first { path in
            let ext = (path as NSString).pathExtension.lowercased()
            return ["swift", "py", "js", "ts", "rs", "go", "java", "rb", "c", "cpp", "h", "m"].contains(ext)
        }
    }
}
