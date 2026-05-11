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

    private func schedulePostWriteVerification(threadIndex: Int, filePath: String? = nil) {
        if let fp = filePath?.lowercased() {
            let skipExtensions = [".json", ".md", ".txt", ".yaml", ".yml", ".toml", ".lock", ".png", ".jpg", ".svg", ".ico"]
            let skipDirectories = ["skills/", "docs/", "assets/", ".github/", ".vscode/"]
            if skipExtensions.contains(where: { fp.hasSuffix($0) })
                || skipDirectories.contains(where: { fp.contains($0) }) {
                return
            }
        }

        let taskID = state.threads[threadIndex].id
        let context = state.threads[threadIndex].context
        let command = ValidationEngine.suggestVerificationCommand(workspaceRoot: context.workspaceRoot)
        let callID = "call_verify_build_\(UUID().uuidString.prefix(8))"
        var params: [String: String] = [:]
        if let command { params["command"] = command }
        let callStep = TaskStep(
            kind: .toolCall,
            text: command.map { "正在自动验证：\($0)" } ?? "正在自动验证构建/测试",
            toolName: "verify.build",
            toolParams: params,
            toolCallId: callID,
            isCollapsible: true,
            isCollapsed: false
        )
        state.threads[threadIndex].steps.append(callStep)
        state.threads[threadIndex].updatedAt = .now
        persistThreads()

        Task { [weak self] in
            guard let self else { return }
            var jsonObject: [String: Any] = ["fix": true]
            if let command { jsonObject["command"] = command }
            let jsonData = (try? JSONSerialization.data(withJSONObject: jsonObject)) ?? Data("{}".utf8)
            let json = String(data: jsonData, encoding: .utf8) ?? "{}"
            let result: ToolResult
            do {
                result = try await VerifyBuildTool().execute(argumentsJSON: json, context: context)
            } catch {
                result = ToolResult(output: "自动验证失败：\(error.localizedDescription)", success: false, error: "verify_failed")
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendPostWriteVerificationResult(
                    taskID: taskID,
                    callID: callID,
                    params: params,
                    command: command,
                    result: result
                )
            }
        }
    }

    private func refreshSkillsIfNeeded(filePath: String) {
        let fp = filePath.lowercased()
        if fp.contains("/skills/") || fp.hasPrefix("skills/") || fp.contains(".laicai/skills") {
            SkillRegistry.shared.refresh(workspaceRoot: state.settings.workspacePath)
        }
    }

    private static let maxAutoRepairAttempts = 1

    private func appendPostWriteVerificationResult(
        taskID: UUID,
        callID: String,
        params: [String: String],
        command: String?,
        result: ToolResult
    ) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }

        let repairCount = state.threads[threadIndex].steps.filter {
            $0.toolName == "verify.build" && $0.kind == .toolResult && $0.isFailure
        }.count

        let canAutoRepair = !result.success && repairCount < Self.maxAutoRepairAttempts

        let resultStep = TaskStep(
            kind: .toolResult,
            text: result.output,
            toolName: "verify.build",
            toolParams: params,
            toolCallId: callID,
            isCollapsible: true,
            isCollapsed: false,
            isFailure: !result.success,
            recoverable: !result.success,
            retryAction: result.success ? nil : (canAutoRepair ? "正在自动修复…" : "已达最大重试次数，请手动修复")
        )
        state.threads[threadIndex].steps.append(resultStep)
        state.threads[threadIndex].updatedAt = Date()
        recordToolActivity(
            name: "verify.build",
            summary: result.success ? "自动验证通过" : "自动验证失败（\(repairCount + 1)/\(Self.maxAutoRepairAttempts)）",
            statusLine: result.data?["command"] ?? command ?? "自动检测",
            isFailure: !result.success
        )
        persistThreads()

        if canAutoRepair {
            scheduleAutoRepair(threadIndex: threadIndex, errorOutput: result.output, attempt: repairCount + 1)
        }
    }

    private func scheduleAutoRepair(threadIndex: Int, errorOutput: String, attempt: Int) {
        let taskID = state.threads[threadIndex].id
        let context = state.threads[threadIndex].context

        let thinkingStep = TaskStep(
            kind: .aiThinking,
            text: "自动修复循环（第 \(attempt)/\(Self.maxAutoRepairAttempts) 次）：分析构建错误并生成修复…"
        )
        state.threads[threadIndex].steps.append(thinkingStep)
        state.threads[threadIndex].updatedAt = .now
        persistThreads()

        let truncatedError = errorOutput.count > 2000 ? String(errorOutput.suffix(2000)) : errorOutput

        Task { [weak self] in
            guard let self else { return }
            let repairPrompt = """
            构建/测试验证失败（第 \(attempt) 次尝试），请分析以下错误并用 file.edit 工具修复：

            ```
            \(truncatedError)
            ```

            请：
            1. 分析错误原因
            2. 用 file.edit 提交精准修复
            3. 修复后自动触发 verify.build 重新验证
            """

            let connector = await MainActor.run { self.state.activeConnector }
            guard let connector else { return }
            var loopConfig = Self.agentLoopConfig(settings: self.state.settings, connector: connector)
            loopConfig.maxIterations = min(loopConfig.maxIterations, 6)
            let repairLoop = AgentLoop(config: loopConfig, runtime: self.environment.runtimeClient)

            do {
                let repairTask = try await repairLoop.run(
                    message: repairPrompt,
                    intent: .task,
                    connector: connector,
                    context: context,
                    onStep: { @MainActor step in },
                    onStreamDelta: { _ in }
                )

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let ti = self.state.threads.firstIndex(where: { $0.id == taskID }) else { return }

                    let repairSteps = repairTask.steps.map { step -> TaskStep in
                        var s = step
                        s.agentRole = .coder
                        return s
                    }
                    self.state.threads[ti].steps.append(contentsOf: repairSteps)

                    let hasNewReviews = repairSteps.contains { $0.kind == .reviewRequest && $0.approved == nil }
                    let summaryStep = TaskStep(
                        kind: .aiThinking,
                        text: hasNewReviews
                            ? "自动修复已生成变更，等待审查批准后将重新验证"
                            : "自动修复尝试完成（第 \(attempt) 次），未产生新的文件变更"
                    )
                    self.state.threads[ti].steps.append(summaryStep)
                    self.state.threads[ti].updatedAt = .now
                    self.persistThreadsNow()
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let ti = self.state.threads.firstIndex(where: { $0.id == taskID }) else { return }
                    self.state.threads[ti].steps.append(TaskStep(
                        kind: .error,
                        text: "自动修复失败：\(error.localizedDescription)",
                        isFailure: true
                    ))
                    self.state.threads[ti].updatedAt = .now
                    self.persistThreadsNow()
                }
            }
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

    public func approveAllPendingReviews(taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }

        let pendingIndices = state.threads[threadIndex].steps.enumerated().compactMap { index, step -> Int? in
            step.kind == .reviewRequest && step.approved == nil && step.diffFilePath != nil && step.diffNewContent != nil ? index : nil
        }
        guard !pendingIndices.isEmpty else {
            ToastCenter.shared.show("没有待审查的变更")
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
                state.threads[threadIndex].updatedAt = .now
                persistThreads()
                return
            }
            if let oldContent = step.diffOldContent, FileManager.default.fileExists(atPath: fullPath) {
                if let currentContent = try? String(contentsOfFile: fullPath, encoding: .utf8), currentContent != oldContent {
                    state.threads[threadIndex].steps[si].approved = false
                    appendReviewResult(to: threadIndex, approved: false, text: "批量写入取消：\(filePath) 在审查期间被外部修改")
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

        state.threads[threadIndex].updatedAt = .now
        persistThreads()
        updateDockBadge()
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
                // continue best-effort
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

    /// Undo the last auto-checkpoint by running `git reset HEAD~1`.
    /// This reverts all file changes made since the last checkpoint while keeping them staged.
    public func undoLastCheckpoint() {
        let root = state.settings.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            ToastCenter.shared.warn("未设置工作区，无法回滚")
            return
        }
        guard FileManager.default.fileExists(atPath: root + "/.git") else {
            ToastCenter.shared.warn("工作区不是 Git 仓库，无法回滚")
            return
        }

        let logProcess = Process()
        logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        logProcess.currentDirectoryURL = URL(fileURLWithPath: root)
        logProcess.arguments = ["git", "log", "-1", "--format=%s"]
        let logPipe = Pipe()
        logProcess.standardOutput = logPipe
        logProcess.standardError = Pipe()
        try? logProcess.run()
        logProcess.waitUntilExit()
        let logData = logPipe.fileHandleForReading.readDataToEndOfFile()
        let lastMessage = String(data: logData, encoding: .utf8) ?? ""

        guard lastMessage.contains("来财自动检查点") else {
            ToastCenter.shared.warn("最近一次提交不是来财检查点")
            return
        }

        let resetProcess = Process()
        resetProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        resetProcess.currentDirectoryURL = URL(fileURLWithPath: root)
        resetProcess.arguments = ["git", "reset", "HEAD~1"]
        let resetPipe = Pipe()
        resetProcess.standardOutput = resetPipe
        resetProcess.standardError = resetPipe
        try? resetProcess.run()
        resetProcess.waitUntilExit()
        let resetData = resetPipe.fileHandleForReading.readDataToEndOfFile()
        let resetOutput = String(data: resetData, encoding: .utf8) ?? ""

        if resetProcess.terminationStatus == 0 {
            ToastCenter.shared.success("已回滚到最近检查点（变更保留在工作区）")
            AuditLog.shared.record(tool: "git.reset", input: "undo checkpoint", output: resetOutput.prefix(200).description, success: true)
        } else {
            ToastCenter.shared.warn("回滚失败：\(resetOutput.prefix(100))")
            AuditLog.shared.record(tool: "git.reset", input: "undo checkpoint", output: resetOutput.prefix(200).description, success: false)
        }
    }
}
