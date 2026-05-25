import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func approveAllPendingReviews(taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }

        let pendingIndices = state.threads[threadIndex].steps.enumerated().compactMap { index, step -> Int? in
            step.kind == .reviewRequest && step.approved == nil && step.diffFilePath != nil && step.diffNewContent != nil ? index : nil
        }
        guard !pendingIndices.isEmpty else {
            notify("没有待审查的变更")
            return
        }

        var writeOps: [(stepIndex: Int, fullPath: String, newContent: String, oldContent: String?, createDirs: Bool)] = []
        for si in pendingIndices {
            let step = state.threads[threadIndex].steps[si]
            guard let filePath = step.diffFilePath, let newContent = step.diffNewContent else { continue }
            let fullPath = step.toolParams?["fullPath"]
                ?? absolutePath(for: filePath, workspaceRoot: state.threads[threadIndex].context.workspaceRoot)
            let createDirs = step.toolParams?["createDirectories"] != "false"
            if let securityError = SecurityManager.shared.checkWrite(path: fullPath) {
                state.threads[threadIndex].steps[si].approved = false
                appendReviewResult(to: threadIndex, approved: false, text: "批量写入被拦截（\(filePath)）：\(securityError)")
                syncAgentSnapshot(at: threadIndex)
                state.threads[threadIndex].updatedAt = .now
                persistThreads()
                return
            }
            if let oldContent = step.diffOldContent, FileManager.default.fileExists(atPath: fullPath) {
                if let currentContent = try? String(contentsOfFile: fullPath, encoding: .utf8), currentContent != oldContent {
                    state.threads[threadIndex].steps[si].approved = false
                    appendReviewResult(to: threadIndex, approved: false, text: "批量写入取消：\(filePath) 在审查期间被外部修改")
                    syncAgentSnapshot(at: threadIndex)
                    state.threads[threadIndex].updatedAt = .now
                    persistThreads()
                    return
                }
            }
            writeOps.append((si, fullPath, newContent, step.diffOldContent, createDirs))
        }

        var backups: [(fullPath: String, content: String?)] = []
        for op in writeOps {
            let existing = try? String(contentsOfFile: op.fullPath, encoding: .utf8)
            backups.append((op.fullPath, existing))
        }

        var applied: [Int] = []
        var failed = false
        for op in writeOps {
            do {
                try WriteFileTool().performWrite(fullPath: op.fullPath, content: op.newContent, createDirectories: op.createDirs)
                state.threads[threadIndex].steps[op.stepIndex].approved = true
                applied.append(op.stepIndex)
            } catch {
                failed = true
                for i in (0..<applied.count).reversed() {
                    let backup = backups[i]
                    if let originalContent = backup.content {
                        try? WriteFileTool().performWrite(fullPath: backup.fullPath, content: originalContent, createDirectories: false)
                    } else {
                        try? FileManager.default.removeItem(atPath: backup.fullPath)
                    }
                    state.threads[threadIndex].steps[applied[i]].approved = nil
                }
                for si in pendingIndices {
                    state.threads[threadIndex].steps[si].approved = false
                }
                let filePath = state.threads[threadIndex].steps[op.stepIndex].diffFilePath ?? "未知文件"
                appendReviewResult(to: threadIndex, approved: false, text: "批量写入失败并已回滚（\(applied.count) 个已恢复）：\(filePath) - \(error.localizedDescription)")
                AuditLog.shared.record(tool: "batch.apply", input: "\(writeOps.count) files", output: "事务回滚：\(error.localizedDescription)", success: false)
                recordToolActivity(name: "batch.apply", summary: "批量写入失败已回滚", statusLine: "\(applied.count) 个文件已恢复", isFailure: true)
                break
            }
        }

        if !failed {
            let paths = writeOps.compactMap { state.threads[threadIndex].steps[$0.stepIndex].diffFilePath }
            appendReviewResult(to: threadIndex, approved: true, text: "批量写入成功：\(paths.count) 个文件\n" + paths.joined(separator: "\n"))
            AuditLog.shared.record(tool: "batch.apply", input: "\(paths.count) files", output: "批量写入成功", success: true)
            recordToolActivity(name: "batch.apply", summary: "批量写入 \(paths.count) 个文件", statusLine: paths.first ?? "", isFailure: false)
            paths.forEach { refreshSkillsIfNeeded(filePath: $0) }
            let sourceFilePath = paths.first(where: { p in
                let ext = (p as NSString).pathExtension.lowercased()
                return ["swift", "py", "js", "ts", "rs", "go", "java", "rb", "c", "cpp", "h", "m"].contains(ext)
            })
            schedulePostWriteVerification(threadIndex: threadIndex, filePath: sourceFilePath)
        }

        syncAgentSnapshot(at: threadIndex)
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
        updateDockBadge()
    }
}
