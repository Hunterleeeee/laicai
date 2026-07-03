import Foundation
import LaicaiNativeDomain

extension AppStore {
    func schedulePostWriteVerification(threadIndex: Int, filePath: String? = nil) {
        if let lowercasedFilePath = filePath?.lowercased() {
            let skipExtensions = [".json", ".md", ".txt", ".yaml", ".yml", ".toml", ".lock", ".png", ".jpg", ".svg", ".ico"]
            let skipDirectories = ["skills/", "docs/", "assets/", ".github/", ".vscode/"]
            if skipExtensions.contains(where: { lowercasedFilePath.hasSuffix($0) })
                || skipDirectories.contains(where: { lowercasedFilePath.contains($0) }) {
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

    func refreshSkillsIfNeeded(filePath: String) {
        let lowercasedFilePath = filePath.lowercased()
        if lowercasedFilePath.contains("/skills/")
            || lowercasedFilePath.hasPrefix("skills/")
            || lowercasedFilePath.contains(".laicai/skills") {
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
                    onStep: { @MainActor _ in },
                    onStreamDelta: { _ in }
                )

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let threadIndex = self.state.threads.firstIndex(where: { $0.id == taskID }) else { return }

                    let repairSteps = repairTask.steps.map { step -> TaskStep in
                        var repairStep = step
                        repairStep.agentRole = .coder
                        return repairStep
                    }
                    self.state.threads[threadIndex].steps.append(contentsOf: repairSteps)

                    let hasNewReviews = repairSteps.contains { $0.kind == .reviewRequest && $0.approved == nil }
                    let summaryStep = TaskStep(
                        kind: .aiThinking,
                        text: hasNewReviews
                            ? "自动修复已生成变更，等待审查批准后将重新验证"
                            : "自动修复尝试完成（第 \(attempt) 次），未产生新的文件变更"
                    )
                    self.state.threads[threadIndex].steps.append(summaryStep)
                    self.state.threads[threadIndex].updatedAt = .now
                    self.persistThreadsNow()
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let threadIndex = self.state.threads.firstIndex(where: { $0.id == taskID }) else { return }
                    self.state.threads[threadIndex].steps.append(TaskStep(
                        kind: .error,
                        text: "自动修复失败：\(error.localizedDescription)",
                        isFailure: true
                    ))
                    self.state.threads[threadIndex].updatedAt = .now
                    self.persistThreadsNow()
                }
            }
        }
    }
}
