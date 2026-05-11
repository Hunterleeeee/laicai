import Foundation
import LaicaiNativeDomain

extension AppStore {
    func handlePostRunSelfImprovement(completedTask: AgentTask, targetTaskID: UUID) {
        if completedTask.context.metadata["selfImproveTask"] == nil,
           let threadIndex = state.threads.firstIndex(where: { $0.id == targetTaskID }) {
            let thread = state.threads[threadIndex]
            let report = SessionPostMortem.shared.analyze(thread: thread)
            if report.hasCritical {
                AuditLog.shared.record(
                    tool: "postmortem",
                    input: "thread:\(thread.id)",
                    output: report.summary,
                    success: false
                )
                let precisePrompt = SelfImprovementEngine.shared.generatePreciseFixPrompt(
                    from: report,
                    steps: thread.steps
                )
                triggerPreciseSelfImprovement(prompt: precisePrompt, report: report)
            }
        }

        if completedTask.context.metadata["selfImproveTask"] == nil {
            checkAndTriggerSelfImprovement()
        } else {
            let succeeded = completedTask.status == .completed
            if succeeded {
                SelfImprovementEngine.shared.onImprovementSuccess()
            } else {
                SelfImprovementEngine.shared.onImprovementFailure()
            }
        }
    }

    private func checkAndTriggerSelfImprovement() {
        guard let diagnosis = SelfImprovementEngine.shared.shouldTrigger() else { return }
        guard let connector = state.activeConnector else { return }
        guard !state.isGenerating else { return }

        let message = SelfImprovementEngine.shared.generateImprovementTask(diagnosis: diagnosis)

        var context = AutoContextEngine.buildContext(
            workspaceRoot: SelfImprovementEngine.shared.harnessRoot,
            userInput: message
        )
        context.metadata["selfImproveTask"] = "true"
        context.metadata["diagnosisCategory"] = diagnosis.category.rawValue

        let userStep = TaskStep(kind: .userInput, text: "🔧 自我改进：\(diagnosis.description)", isCollapsible: false, isCollapsed: false)
        let planStep = TaskStep(
            kind: .aiThinking,
            text: "检测到性能问题，启动自我改进流程。类别：\(diagnosis.category.rawValue)，严重程度：\(diagnosis.severity.rawValue)",
            isCollapsible: true,
            isCollapsed: false
        )
        let thread = Thread(
            title: "自我改进：\(diagnosis.category.rawValue)",
            status: .running,
            steps: [userStep, planStep],
            connectorID: state.activeConnectorID,
            context: context,
            source: .task
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
        persistThreads()

        state.isGenerating = true
        state.generationStartedAt = Date()
        var loopConfig = AgentLoop.Config(
            maxIterations: 20,
            maxTokensPerTurn: 16384,
            workspaceRoot: SelfImprovementEngine.shared.harnessRoot,
            supportsToolCalling: true,
            contextMode: .deep,
            modelName: connector.modelName
        )
        loopConfig.allowedTools = ["file.read", "file.edit", "diff.apply", "code.search", "workspace.index", "shell.exec", "verify.build", "git"]

        let loop = AgentLoop(config: loopConfig, runtime: environment.runtimeClient)
        let targetID = thread.id
        agentLoops[targetID] = loop

        generationTasks[targetID] = Task { [weak self] in
            guard let self else { return }
            do {
                let completedTask: AgentTask = try await loop.run(
                    taskID: targetID,
                    message: message,
                    intent: UserIntent.task,
                    connector: connector,
                    context: context,
                    priorSteps: thread.steps,
                    onStep: { @MainActor [weak self] (step: TaskStep) in
                        guard let self else { return }
                        self.appendTaskStep(step, to: targetID)
                    },
                    onStreamDelta: { @Sendable @MainActor [weak self] (delta: String) in
                        guard let self else { return }
                        self.appendStreamDelta(delta, to: targetID)
                    }
                )
                guard !Task.isCancelled else { return }

                self.flushStreamBuffer(for: targetID)
                self.mergeCompletedTask(completedTask, into: targetID)
                self.persistThreadsNow()

                let succeeded = completedTask.status == .completed
                SelfImprovementEngine.shared.recordAttempt(
                    category: diagnosis.category.rawValue,
                    description: diagnosis.description,
                    filesChanged: completedTask.steps
                        .filter { $0.kind == .toolCall && AgentLoop.isFileChangeTool($0.toolName ?? "") }
                        .map { AgentLoop.pathForFileChange(callStep: $0) }
                        .filter { !$0.isEmpty },
                    buildSuccess: succeeded,
                    commitHash: nil
                )
                if succeeded {
                    SelfImprovementEngine.shared.onImprovementSuccess()
                } else {
                    SelfImprovementEngine.shared.onImprovementFailure()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: targetID)
                if let threadIndex = self.state.threads.firstIndex(where: { $0.id == targetID }) {
                    self.state.threads[threadIndex].steps.append(
                        TaskStep(kind: .error, text: "自我改进失败：\(error.localizedDescription)", isFailure: true, recoverable: false)
                    )
                    self.state.threads[threadIndex].status = .failed
                    self.state.threads[threadIndex].updatedAt = Date()
                    self.persistThreadsNow()
                }
                SelfImprovementEngine.shared.onImprovementFailure()
            }

            self.finishGenerationTask(targetID)
        }
    }

    private func triggerPreciseSelfImprovement(prompt: String, report: SessionPostMortem.Report) {
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
            source: .task
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
        loopConfig.allowedTools = ["file.read", "file.edit", "diff.apply", "code.search", "workspace.index", "shell.exec", "verify.build", "git"]

        let loop = AgentLoop(config: loopConfig, runtime: environment.runtimeClient)
        agentLoops[targetID] = loop

        state.isGenerating = true
        state.generationStartedAt = Date()
        let targetTaskID = targetID

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
                        guard let self else { return }
                        self.appendTaskStep(step, to: targetTaskID)
                    },
                    onStreamDelta: { @Sendable @MainActor [weak self] (delta: String) in
                        guard let self else { return }
                        self.appendStreamDelta(delta, to: targetTaskID)
                    }
                )
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
                guard !Task.isCancelled else { return }
                if let ti = self.state.threads.firstIndex(where: { $0.id == targetTaskID }) {
                    self.state.threads[ti].steps.append(
                        TaskStep(kind: .error, text: "自动修复失败：\(error.localizedDescription)", isFailure: true, recoverable: false)
                    )
                    self.state.threads[ti].status = .failed
                    self.state.threads[ti].updatedAt = Date()
                    self.persistThreadsNow()
                }
                SelfImprovementEngine.shared.onImprovementFailure()
            }

            self.finishGenerationTask(targetTaskID)
        }
    }
}
