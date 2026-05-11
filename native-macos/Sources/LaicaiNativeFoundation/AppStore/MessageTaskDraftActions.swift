import Foundation
import LaicaiNativeDomain

extension AppStore {
    func sendTaskDraft(
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

        if let wfName = workflowName, let workflow = WorkflowLibrary.find(named: wfName, workspaceRoot: state.settings.workspacePath) {
            executeWorkflow(taskTitle: message, workflow: workflow, context: context, message: message, decision: decision)
            return
        }

        if customAgent == nil,
           MultiAgentOrchestrator.shouldUseMultiAgent(message: message, intent: intent),
           let plan = MultiAgentOrchestrator.createPlan(for: message, intent: intent, connectors: state.connectors, activeConnectorID: state.activeConnectorID) {
            executeMultiAgent(message: message, context: context, connector: connector, plan: plan, intent: intent, decision: decision)
            return
        }

        let isChatIntent = intent == .chat
        let userStep = TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false)
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
                if !state.threads[threadIndex].context.memory.isEmpty {
                    context.memory = state.threads[threadIndex].context.memory
                }
                Self.prepareThreadForContinuation(&state.threads[threadIndex], message: message)
                if UserFrustrationDetector.isFrustrated(message) {
                    BehaviorSignalTracker.record(signal: .frustration, thread: state.threads[threadIndex])
                }
            }
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
            let allSteps = state.threads[threadIndex].steps
            let isHeavyThread = allSteps.count > 40
                || allSteps.reduce(0) { $0 + $1.text.count } > 40_000
            let isLightweightFollowUp = Self.isLightweightStatusQuery(message)
            if isHeavyThread && isLightweightFollowUp {
                loopPriorSteps = Array(allSteps.suffix(8))
                context.memory = TaskMemory()
            } else {
                loopPriorSteps = isEmptyPlaceholder ? initialSteps : allSteps
            }
            state.threads[threadIndex].updatedAt = .now
            targetTaskID = selectedID
        } else {
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
        if customAgent == nil, let match = matchedSkill {
            applySkillPromptHint(match, connector: connector, loopConfig: &loopConfig)
        }
        if isChatIntent {
            loopConfig.maxIterations = min(loopConfig.maxIterations, 3)
        }
        let attemptedToolCalling = loopConfig.supportsToolCalling && !isChatIntent

        if !isChatIntent, let threadIdx = state.threads.firstIndex(where: { $0.id == targetTaskID }) {
            let intentStr: String = { switch intent { case .chat: return "chat"; case .research: return "research"; case .task: return "task"; case .workflow(let n): return "workflow:\(n)" } }()
            let avgIter = TaskOutcomeRecorder.shared.avgIterations(intent: intentStr) ?? Double(loopConfig.maxIterations)
            state.threads[threadIdx].context.metadata["expectedIterations"] = "\(Int(ceil(avgIter)))"
        }

        let loop = AgentLoop(config: loopConfig, runtime: environment.runtimeClient)
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

                self.flushThinkingBuffer(for: targetTaskID)
                self.flushStreamBuffer(for: targetTaskID)
                self.mergeCompletedTask(completedTask, into: targetTaskID)
                self.recordConnectorOutcome(completedTask, connectorID: connector.id, attemptedToolCalling: attemptedToolCalling)
                MemoryEngine.shared.extractFromTask(completedTask)
                self.persistThreadsNow()

                for step in completedTask.steps where step.kind == .toolCall {
                    self.recordToolActivity(name: step.toolName ?? "tool", summary: step.text, statusLine: "", isFailure: false)
                }

                self.handlePostRunSelfImprovement(completedTask: completedTask, targetTaskID: targetTaskID)
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

            self.appendPendingFollowUp(to: targetTaskID)
            self.finishGenerationTask(targetTaskID)
        }
    }
}
