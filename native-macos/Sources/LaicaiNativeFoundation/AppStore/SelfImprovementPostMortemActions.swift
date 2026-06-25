import Foundation
import LaicaiNativeDomain

extension AppStore {
    func triggerPreciseSelfImprovement(prompt: String, report: SessionPostMortem.Report) {
        guard SelfImprovementEngine.shared.shouldTrigger() != nil || report.hasCritical else { return }
        guard let connector = state.activeConnector else { return }
        guard !state.isGenerating else { return }

        let message = """
        # 自我改进任务（会话后检触发）

        \(prompt)

        ## 执行步骤
        1. 先读取上述建议修复文件中指定行号附近的代码
        2. 理解当前实现和问题根因
        3. 用 file_edit 修改代码（最小化修改）
        4. 运行 `bash \(SelfImprovementEngine.shared.buildScript)` 验证编译
        5. 编译通过后提交：先运行 `git status --short`，只 `git add -- <本轮修改文件>`，再 `git commit -m "self-fix: \(report.findings.first?.pattern.rawValue ?? "postmortem")"`
        6. 重启应用

        ## 限制
        - 只修改 LaicaiNativeFoundation 目录下的 .swift 文件
        - 不要修改 Models.swift 的 struct 定义
        - 每次最多修改 3 个文件
        - 必须编译通过
        """

        var context = AutoContextEngine.buildContext(
            workspaceRoot: SelfImprovementEngine.shared.harnessRoot,
            userInput: message
        )
        context.metadata["selfImproveTask"] = "true"
        context.metadata["postmortemThreadID"] = report.threadID.uuidString

        let targetID = UUID()
        let thread = Thread(
            id: targetID,
            title: "🔧 自动修复：\(report.findings.first?.pattern.rawValue ?? "postmortem")",
            status: .running,
            connectorID: connector.id,
            context: context,
            modelName: connector.modelName,
            category: .engineering,
            executionState: .running,
            goal: message,
            currentPlan: [
                "读取后检建议定位根因",
                "修改最小必要代码",
                "构建验证并准备提交"
            ]
        )
        state.threads.insert(thread, at: 0)
        persistThreadsNow()

        var loopConfig = AgentLoop.Config(
            maxIterations: 20,
            maxTokensPerTurn: 16384,
            workspaceRoot: SelfImprovementEngine.shared.harnessRoot,
            supportsToolCalling: true,
            contextMode: .deep,
            modelName: connector.modelName
        )
        loopConfig.allowedTools = ["file.read", "file.edit", "diff.apply", "code.search", "workspace.index", "shell.exec", "verify.build", "skill.manage", "git"]

        let loop = AgentLoop(config: loopConfig, runtime: environment.runtimeClient)
        agentLoops[targetID] = loop

        let targetTaskID = targetID
        markGenerationStarted(for: targetTaskID, activity: "正在执行自我改进复盘…")

        generationTasks[targetTaskID] = Task { [weak self] in
            guard let self else { return }
            do {
                let completedTask: AgentTask = try await loop.run(
                    taskID: targetID,
                    message: message,
                    intent: UserIntent.task,
                    connector: connector,
                    context: context,
                    priorSteps: [],
                    onStep: { @MainActor [weak self] (step: TaskStep) in
                        guard let self, self.shouldAcceptGenerationCallback(for: targetTaskID) else { return }
                        self.appendTaskStep(step, to: targetTaskID)
                    },
                    onStreamDelta: { @Sendable @MainActor [weak self] (delta: String) in
                        guard let self, self.shouldAcceptGenerationCallback(for: targetTaskID) else { return }
                        self.appendStreamDelta(delta, to: targetTaskID)
                    }
                )
                guard self.shouldAcceptGenerationCallback(for: targetTaskID) else { return }
                self.mergeCompletedTask(completedTask, into: targetTaskID)
                self.persistThreadsNow()

                let succeeded = completedTask.status == .completed
                SelfImprovementEngine.shared.recordAttempt(
                    category: report.findings.first?.pattern.rawValue ?? "postmortem",
                    description: report.summary,
                    filesChanged: completedTask.steps
                        .filter { $0.kind == .reviewRequest }
                        .compactMap(\.diffFilePath),
                    buildSuccess: succeeded,
                    commitHash: nil
                )
                if succeeded {
                    SelfImprovementEngine.shared.onImprovementSuccess()
                } else {
                    SelfImprovementEngine.shared.onImprovementFailure()
                }
            } catch {
                guard self.shouldAcceptGenerationCallback(for: targetTaskID) else { return }
                if let ti = self.state.threads.firstIndex(where: { $0.id == targetTaskID }) {
                    self.state.threads[ti].steps.append(
                        TaskStep(kind: .error, text: "自动修复失败：\(error.localizedDescription)", isFailure: true, recoverable: false)
                    )
                    self.state.threads[ti].status = .failed
                    self.syncAgentSnapshot(at: ti)
                    self.state.threads[ti].updatedAt = Date()
                    self.persistThreadsNow()
                }
                SelfImprovementEngine.shared.onImprovementFailure()
            }

            self.finishGenerationTask(targetTaskID)
        }
    }
}
