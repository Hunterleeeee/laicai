import AppKit
import Combine
import Foundation
import LaicaiNativeDomain

@MainActor
public final class AppStore: ObservableObject {
    @Published public internal(set) var state: AppState
    @Published public var isShowingTaskModeInfo = false
    let environment: AppEnvironment
    var agentLoops: [UUID: AgentLoop] = [:]
    static let streamingOutputID = "__streaming_output__"
    var streamBuffers: [UUID: String] = [:]
    var streamLastFlushAt: [UUID: Date] = [:]
    var thinkingBuffers: [UUID: String] = [:]
    var thinkingLastFlushAt: [UUID: Date] = [:]
    var chatStreamBuffers: [UUID: String] = [:]
    var chatStreamLastFlushAt: [UUID: Date] = [:]
    var healthChecksInFlight: Set<UUID> = []
    private var _cachedThreadSummaries: [ThreadRecord]?
    private var _cachedSummaryGen: UInt64 = 0

    public var cachedThreadRecordSummaries: [ThreadRecord] {
        if let cached = _cachedThreadSummaries, _cachedSummaryGen == state.threadSummaryGeneration {
            return cached
        }
        let result = state.threadRecordSummaries
        _cachedThreadSummaries = result
        _cachedSummaryGen = state.threadSummaryGeneration
        return result
    }

    let streamFlushCharacterThreshold = 900
    let streamFlushInterval: TimeInterval = 0.8
    let chatStreamFlushCharacterThreshold = 1_200
    let chatStreamFlushInterval: TimeInterval = 0.9
    private var shellStreamObserver: NSObjectProtocol?

    // H1: Debounced persistence — collapse rapid persist calls into one
    var persistDebounceTask: Task<Void, Never>?
    var lastPersistedAt: Date = .distantPast
    let persistDebounceInterval: TimeInterval = 1.0

    public init(state: AppState, environment: AppEnvironment = .preview) {
        var initialState = state
        Self.markStaleRunningTasks(in: &initialState)
        self.state = initialState
        self.environment = environment
        if initialState.threads != state.threads {
            persistThreads()
        }
        // Self-evolution: auto-promote winning prompt variants on startup
        PromptRegistry.shared.autoPromote()
        // Auto-resume: select the most recently interrupted task on launch
        autoResumeInterruptedTask()
        shellStreamObserver = NotificationCenter.default.addObserver(
            forName: .shellStreamUpdate,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let info = notification.userInfo
            Task { @MainActor [weak self] in
                guard let self = self, let info = info else { return }
                self.handleShellStreamNotification(info)
            }
        }
    }

    public static func preview() -> AppStore {
        AppStore(state: .preview, environment: .preview)
    }

    public static func live() -> AppStore {
        let environment = AppEnvironment.live
        return AppStore(state: .bootstrap(environment: environment), environment: environment)
    }

    // MARK: - Message Sending

    var generationTasks: [UUID: Task<Void, Never>] = [:]

    /// Codex-style steer: inject a correction into a running agent loop.
    /// Unlike stop, this does NOT cancel the task — it redirects it.
    public func steerRunningTask(_ message: String) {
        guard let threadID = state.selectedThreadID,
              let loop = agentLoops[threadID] else { return }
        loop.steer(message)
        ToastCenter.shared.show("🔀 已发送方向修正")
    }

    public func stopGenerating() {
        // Cancel only the selected thread's generation task
        if let threadID = state.selectedThreadID {
            generationTasks[threadID]?.cancel()
            generationTasks.removeValue(forKey: threadID)
            agentLoops.removeValue(forKey: threadID)
        }
        // Always reset UI generating state — the user stopped the visible thread.
        // Background tasks continue silently and clean up on their own.
        state.isGenerating = false
        state.generationStartedAt = nil
        state.liveActivity = ""
        if let threadID = state.selectedThreadID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == threadID }),
           state.threads[threadIndex].source == .task,
           state.threads[threadIndex].status == .running {
            flushStreamBuffer(for: threadID)
            state.threads[threadIndex].steps.append(TaskStep(kind: .error, text: "已中断", isFailure: false, recoverable: true, retryAction: "重试"))
            state.threads[threadIndex].status = .cancelled
            state.threads[threadIndex].updatedAt = .now
            BehaviorSignalTracker.record(signal: .cancel, thread: state.threads[threadIndex])
            persistThreads()
            streamBuffers.removeValue(forKey: threadID)
            streamLastFlushAt.removeValue(forKey: threadID)
        }
        // Clean up incomplete assistant step
        if let threadID = state.selectedThreadID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == threadID }),
           state.threads[threadIndex].source == .session {
            var steps = state.threads[threadIndex].steps
            if let lastStep = steps.last, lastStep.kind == .textOutput {
                if lastStep.text.isEmpty {
                    steps.removeLast()
                } else {
                    steps[steps.count - 1] = TaskStep(
                        id: lastStep.id, kind: .textOutput,
                        text: lastStep.text + "\n\n（已中断）",
                        isCollapsible: false, isCollapsed: false,
                        metrics: lastStep.metrics, createdAt: lastStep.createdAt
                    )
                }
                state.threads[threadIndex].steps = steps
                state.threads[threadIndex].preview = normalizedSessionPreview(steps.last?.text ?? "")
                state.threads[threadIndex].updatedAt = .now
            }
        }
        chatStreamBuffers.removeAll()
        chatStreamLastFlushAt.removeAll()
        persistThreads()
    }

    public func sendDraft() {
        let message = composedDraftMessage()
        // Allow concurrent tasks: only block if the selected thread is already running
        let selectedThreadRunning: Bool = {
            guard let tid = state.selectedThreadID else { return false }
            return generationTasks[tid] != nil
        }()
        guard !message.isEmpty, !selectedThreadRunning else { return }

        // Slash commands: /goal, /background, /schedule, /gateway
        if handleSlashCommand(message) { return }

        let agentInvocation = customAgentInvocation(from: message)
        var effectiveMessage = agentInvocation?.message ?? message

        // Intent enrichment: expand ultra-short/vague messages using thread context
        effectiveMessage = Self.enrichVagueMessage(effectiveMessage, thread: state.selectedThread)

        reconcileSelectedRunningTaskIfIdle()
        if answerSelectedTaskStatusQuestion(effectiveMessage) {
            return
        }
        var decision = IntentRouter.plan(effectiveMessage)

        // Context-aware intent upgrade: if the selected thread already has tool calls,
        // the user is continuing an action-oriented conversation — keep tools available.
        if decision.intent == .chat,
           let tid = state.selectedThreadID,
           let thread = state.threads.first(where: { $0.id == tid }),
           thread.steps.contains(where: { $0.kind == .toolCall }) {
            decision = PlannerDecision(
                intent: .task,
                confidence: max(decision.confidence, 0.75),
                reason: decision.reason + " [线程已有工具调用历史，自动升级为任务模式]",
                routeLabel: "任务",
                expectedCapabilities: decision.expectedCapabilities + ["运行命令", "提出文件修改"]
            )
        }

        // Auto-match skill from registry
        let matchedSkill = SkillMatcher.match(input: effectiveMessage, intent: decision.intent)

        // Single path: always give full tools, LLM decides what to use.
        // Safety: file writes go through approval flow, dangerous commands need confirmation.
        sendTaskDraft(message: effectiveMessage, decision: decision, customAgent: agentInvocation?.agent, matchedSkill: matchedSkill)
    }

    private struct CustomAgentInvocation {
        let agent: CustomAgentDefinition
        let message: String
    }

    private func customAgentInvocation(from message: String) -> CustomAgentInvocation? {
        let prefix = "[Agent:"
        guard message.hasPrefix(prefix),
              let endIndex = message.firstIndex(of: "]") else {
            return nil
        }
        let nameStart = message.index(message.startIndex, offsetBy: prefix.count)
        let name = String(message[nameStart..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        AgentRegistry.shared.refresh(workspaceRoot: state.settings.workspacePath)
        guard let agent = AgentRegistry.shared.agents.first(where: { $0.name == name }) else {
            notify("未找到 Agent「\(name)」", style: .error)
            return nil
        }
        let contentStart = message.index(after: endIndex)
        let content = String(message[contentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return CustomAgentInvocation(agent: agent, message: content.isEmpty ? "请按你的 Agent 职责继续处理当前任务。" : content)
    }

    /// Send a task draft through the local task engine.
    private func sendTaskDraft(
        message: String,
        decision: PlannerDecision,
        customAgent: CustomAgentDefinition? = nil,
        matchedSkill: SkillMatchResult? = nil
    ) {
        let selectedConnector = customAgent?.preferredConnectorID.flatMap { id in
            state.connectors.first(where: { $0.id == id })
        } ?? state.activeConnector
        guard let connector = selectedConnector else {
            notify("请先选择一个连接器", style: .error)
            return
        }
        // Safety: block tool-using tasks when workspace is not set or is overly broad
        if decision.intent != .chat {
            let wp = state.settings.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if wp.isEmpty {
                notify("请先在设置中指定工作区目录，再执行任务。", style: .error)
                return
            }
            if WorkspaceSandbox.isOverlyBroadWorkspace(wp) {
                notify("工作区不能设为 home 目录或根目录，请指定一个具体的项目文件夹。", style: .error)
                return
            }
        }
        // Don't discard empty placeholder — we'll reuse it as the new task thread
        var context = AutoContextEngine.buildContext(
            workspaceRoot: state.settings.workspacePath,
            vaultRoot: state.settings.vaultPath,
            userInput: message,
            fileLimit: Self.relevantFileLimit(settings: state.settings, connector: connector),
            comfyUIServerURL: state.settings.comfyUIServerURL,
            comfyUIModelName: state.settings.comfyUIModelName
        )

        let intent = decision.intent
        let workflowName: String? = { if case .workflow(let name) = intent { return name } else { return nil } }()

        // If matching workflow, execute it directly
        if let wfName = workflowName, let workflow = WorkflowLibrary.find(named: wfName, workspaceRoot: state.settings.workspacePath) {
            executeWorkflow(taskTitle: message, workflow: workflow, context: context, message: message, decision: decision)
            return
        }

        // Check if multi-agent collaboration is warranted
        if customAgent == nil,
           MultiAgentOrchestrator.shouldUseMultiAgent(message: message, intent: intent),
           let plan = MultiAgentOrchestrator.createPlan(for: message, intent: intent, connectors: state.connectors, activeConnectorID: state.activeConnectorID) {
            executeMultiAgent(message: message, context: context, connector: connector, plan: plan, intent: intent, decision: decision)
            return
        }

        let isChatIntent = intent == .chat
        let userStep = TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false)
        // Chat intent: skip verbose planning step to keep UI clean
        let initialSteps: [TaskStep]
        if isChatIntent {
            initialSteps = [userStep]
        } else {
            var steps = [userStep]
            let planStep = TaskStep(
                kind: .aiThinking,
                text: Self.plannerStepText(for: decision),
                isCollapsible: true,
                isCollapsed: true
            )
            steps.append(planStep)
            if let match = matchedSkill {
                let skillStep = TaskStep(
                    kind: .aiThinking,
                    text: "🎯 \(match.reason)",
                    isCollapsible: true,
                    isCollapsed: true
                )
                steps.append(skillStep)
            }
            initialSteps = steps
        }
        let targetTaskID: UUID
        let loopPriorSteps: [TaskStep]
        if let selectedID = state.selectedThreadID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == selectedID }),
           state.threads[threadIndex].status != .running {
            let isEmptyPlaceholder = state.threads[threadIndex].steps.isEmpty
            if !isEmptyPlaceholder {
                // Continuing an existing thread with history
                if !state.threads[threadIndex].context.memory.isEmpty {
                    context.memory = state.threads[threadIndex].context.memory
                }
                Self.prepareThreadForContinuation(&state.threads[threadIndex], message: message)
                if UserFrustrationDetector.isFrustrated(message) {
                    BehaviorSignalTracker.record(signal: .frustration, thread: state.threads[threadIndex])
                }
            }
            // Update thread title if placeholder or generic
            let currentTitle = state.threads[threadIndex].title
            if isEmptyPlaceholder || currentTitle.isEmpty || currentTitle == "新会话" || currentTitle == "新对话" {
                state.threads[threadIndex].title = String(message.prefix(32))
            }
            state.threads[threadIndex].status = .running
            state.threads[threadIndex].connectorID = state.activeConnectorID
            state.threads[threadIndex].workflowName = workflowName
            state.threads[threadIndex].context = context
            for step in initialSteps {
                state.threads[threadIndex].steps.append(step)
            }
            // Lightweight follow-up path: long thread + small clarification question →
            // strip heavy tool history and memory so the model isn't dragged into
            // re-doing failed file edits or claiming non-existent tools.
            let allSteps = state.threads[threadIndex].steps
            let isHeavyThread = allSteps.count > 40
                || allSteps.reduce(0) { $0 + $1.text.count } > 40_000
            let isLightweightFollowUp = Self.isLightweightStatusQuery(message)
            if isHeavyThread && isLightweightFollowUp {
                let trimmedTail = Array(allSteps.suffix(8))
                loopPriorSteps = trimmedTail
                context.memory = TaskMemory()  // clear injected userDecisions / read files etc.
            } else {
                loopPriorSteps = isEmptyPlaceholder ? initialSteps : allSteps
            }
            state.threads[threadIndex].updatedAt = .now
            targetTaskID = selectedID
        } else {
            // Bind new thread to active project (Codex-style)
            let activeProjectID = ProjectManager.shared.activeProjectID
            let thread = Thread(
                title: String(message.prefix(32)),
                status: .running,
                steps: initialSteps,
                connectorID: state.activeConnectorID,
                workflowName: workflowName,
                context: context,
                source: isChatIntent ? .session : nil,
                projectID: activeProjectID
            )
            state.threads.insert(thread, at: 0)
            targetTaskID = thread.id
            loopPriorSteps = thread.steps
        }
        state.selectThread(id: targetTaskID)
        state.modeLabel = decision.routeLabel
        persistThreads()

        let capturedImages = state.draftImages
        state.isGenerating = true
        state.generationStartedAt = Date()
        state.liveActivity = isChatIntent ? "思考中…" : "正在分析任务…"
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        var loopConfig = Self.agentLoopConfig(settings: state.settings, connector: connector, decision: decision)
        if let customAgent {
            loopConfig.customSystemPrompt = customAgent.systemPrompt
            let agentTools = Set(customAgent.tools.map { ToolNameCodec.canonicalName($0) })
            if !agentTools.isEmpty {
                loopConfig.allowedTools = agentTools
                if AgentLoop.expectsWikiOutput(message) {
                    loopConfig.allowedTools?.formUnion(["file.read", "file.extract", "wiki.build"])
                }
            }
        }
        // Inject matched skill hint into system prompt
        if customAgent == nil, let match = matchedSkill {
            let skill = match.skill
            var hint = "\n\n## 已激活技能：\(skill.name)\n\(skill.description)"
            if let systemHint = skill.systemHint, !systemHint.isEmpty {
                hint += "\n\n\(systemHint)"
            }
            if !skill.tools.isEmpty {
                hint += "\n推荐工具：\(skill.tools.joined(separator: "、"))"
            }
            hint += """

执行要求：
- 先按技能指南确认输入边界，再调用所需工具；不要只复述技能说明。
- 输出必须符合该技能的格式要求；保存类技能只有在 save_note/wiki_build/file_write 成功后才能说已保存。
- 如果技能请求与用户当前目标冲突，以用户当前目标为准，并说明取舍。
"""
            loopConfig.customSystemPrompt = (loopConfig.customSystemPrompt ?? "") + hint
            state.liveActivity = "已激活技能：\(skill.name)"
            // Switch to preferred model if needed
            if let preferred = ModelRouter.selectModel(for: skill, connectors: state.connectors, activeConnectorID: state.activeConnectorID),
               preferred.id != connector.id {
                loopConfig.modelName = preferred.modelName
            }
        }
        // Chat intent: cap iterations — LLM decides if tools needed, but don't run away
        if isChatIntent {
            loopConfig.maxIterations = min(loopConfig.maxIterations, 3)
        }
        let attemptedToolCalling = loopConfig.supportsToolCalling && !isChatIntent

        // Seed expected iterations from historical data for progress estimation
        if !isChatIntent, let threadIdx = state.threads.firstIndex(where: { $0.id == targetTaskID }) {
            let intentStr: String = { switch intent { case .chat: return "chat"; case .research: return "research"; case .task: return "task"; case .workflow(let n): return "workflow:\(n)" } }()
            let avgIter = TaskOutcomeRecorder.shared.avgIterations(intent: intentStr) ?? Double(loopConfig.maxIterations)
            state.threads[threadIdx].context.metadata["expectedIterations"] = "\(Int(ceil(avgIter)))"
        }

        let loop = AgentLoop(
            config: loopConfig,
            runtime: environment.runtimeClient
        )
        agentLoops[targetTaskID] = loop

        generationTasks[targetTaskID] = Task { [weak self] in
            guard let self else { return }
            do {
                let completedTask = try await loop.run(
                    taskID: targetTaskID,
                    message: message,
                    intent: intent,
                    connector: connector,
                    allConnectors: state.connectors,
                    context: context,
                    priorSteps: loopPriorSteps,
                    summaryCache: state.threads.first(where: { $0.id == targetTaskID })?.summaryCache,
                    imageAttachments: capturedImages,
                    onStep: { [weak self] step in
                        guard let self else { return }
                        self.appendTaskStep(step, to: targetTaskID)
                    },
                    onStreamDelta: { [weak self] delta in
                        guard let self else { return }
                        self.appendStreamDelta(delta, to: targetTaskID)
                    },
                    onReasoningDelta: { [weak self] delta in
                        guard let self else { return }
                        self.appendThinkingDelta(delta, to: targetTaskID)
                    },
                    onCheckInterrupt: { [weak self] in
                        guard let self else { return nil }
                        guard let followUp = self.state.pendingFollowUp, !followUp.isEmpty else { return nil }
                        self.state.pendingFollowUp = nil
                        self.state.draftMessage = ""
                        return followUp
                    }
                )

                guard !Task.isCancelled else { return }

                // Update task with completed state
                self.flushThinkingBuffer(for: targetTaskID)
                self.flushStreamBuffer(for: targetTaskID)
                self.mergeCompletedTask(completedTask, into: targetTaskID)
                self.recordConnectorOutcome(completedTask, connectorID: connector.id, attemptedToolCalling: attemptedToolCalling)
                MemoryEngine.shared.extractFromTask(completedTask)
                self.persistThreadsNow()

                // Record tool activities
                for step in completedTask.steps where step.kind == .toolCall {
                    self.recordToolActivity(name: step.toolName ?? "tool", summary: step.text, statusLine: "", isFailure: false)
                }

                // Post-mortem: scan completed session for known failure patterns
                if completedTask.context.metadata["selfImproveTask"] == nil,
                   let threadIndex = self.state.threads.firstIndex(where: { $0.id == targetTaskID }) {
                    let thread = self.state.threads[threadIndex]
                    let report = SessionPostMortem.shared.analyze(thread: thread)
                    if report.hasCritical {
                        AuditLog.shared.record(
                            tool: "postmortem",
                            input: "thread:\(thread.id)",
                            output: report.summary,
                            success: false
                        )
                        // Feed precise diagnosis to SelfImprovementEngine with session replay + source context
                        let precisePrompt = SelfImprovementEngine.shared.generatePreciseFixPrompt(
                            from: report,
                            steps: thread.steps
                        )
                        self.triggerPreciseSelfImprovement(prompt: precisePrompt, report: report)
                    }
                }

                // Self-improvement: check if metrics warrant auto-improving harness code
                if completedTask.context.metadata["selfImproveTask"] == nil {
                    self.checkAndTriggerSelfImprovement()
                } else {
                    // This WAS a self-improvement task — record result
                    let succeeded = completedTask.status == .completed
                    if succeeded {
                        SelfImprovementEngine.shared.onImprovementSuccess()
                    } else {
                        SelfImprovementEngine.shared.onImprovementFailure()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.flushThinkingBuffer(for: targetTaskID)
                self.flushStreamBuffer(for: targetTaskID)
                if let threadIndex = self.state.threads.firstIndex(where: { $0.id == targetTaskID }) {
                    let steps = self.state.threads[threadIndex].steps
                    let progressSummary = Self.errorProgressSummary(steps: steps)
                    let errorText = progressSummary.isEmpty
                        ? error.localizedDescription
                        : "\(error.localizedDescription)\n\n已完成：\(progressSummary)"
                    self.state.threads[threadIndex].steps.append(
                        TaskStep(kind: .error, text: errorText, isFailure: true, recoverable: true, retryAction: "重试")
                    )
                    self.state.threads[threadIndex].status = .failed
                    self.state.threads[threadIndex].updatedAt = Date()
                    self.persistThreadsNow()
                }
                self.recordToolActivity(name: "task.error", summary: "任务执行失败", statusLine: error.localizedDescription, isFailure: true)
            }

            // Append pending follow-up if exists
            if let followUp = self.state.pendingFollowUp, !followUp.isEmpty {
                if let threadIndex = self.state.threads.firstIndex(where: { $0.id == targetTaskID }) {
                    let step = TaskStep(kind: .userInput, text: followUp, isCollapsible: false, isCollapsed: false)
                    self.state.threads[threadIndex].steps.append(step)
                    self.state.threads[threadIndex].updatedAt = .now
                    self.persistThreadsNow()
                }
                self.state.pendingFollowUp = nil
            }

            self.generationTasks.removeValue(forKey: targetTaskID)
            self.agentLoops.removeValue(forKey: targetTaskID)
            self.streamBuffers.removeValue(forKey: targetTaskID)
            self.streamLastFlushAt.removeValue(forKey: targetTaskID)
            if self.generationTasks.isEmpty {
                self.state.isGenerating = false
                self.state.generationStartedAt = nil
                self.state.liveActivity = ""
            }
        }
    }

    /// Check outcome metrics and trigger a self-improvement task if needed.
    private func checkAndTriggerSelfImprovement() {
        guard let diagnosis = SelfImprovementEngine.shared.shouldTrigger() else { return }
        guard let connector = state.activeConnector else { return }
        guard !state.isGenerating else { return }

        let message = SelfImprovementEngine.shared.generateImprovementTask(diagnosis: diagnosis)

        // Build context pointing to the harness source directory
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

            self.generationTasks.removeValue(forKey: targetID)
            self.agentLoops.removeValue(forKey: targetID)
            self.streamBuffers.removeValue(forKey: targetID)
            self.streamLastFlushAt.removeValue(forKey: targetID)
            if self.generationTasks.isEmpty {
                self.state.isGenerating = false
                self.state.generationStartedAt = nil
                self.state.liveActivity = ""
            }
        }
    }

    // MARK: - Precise Self-Improvement (PostMortem-driven)

    /// Trigger a self-improvement task based on a precise PostMortem diagnosis.
    /// Unlike the stats-based approach, this provides exact source locations and fix descriptions.
    private func triggerPreciseSelfImprovement(prompt: String, report: SessionPostMortem.Report) {
        // Respect cooldown and guard conditions
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

            self.generationTasks.removeValue(forKey: targetTaskID)
            self.agentLoops.removeValue(forKey: targetTaskID)
            if self.generationTasks.isEmpty {
                self.state.isGenerating = false
                self.state.generationStartedAt = nil
                self.state.liveActivity = ""
            }
        }
    }

}
