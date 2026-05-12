import Foundation
import LaicaiNativeDomain

extension AppStore {
    func sendTaskDraft(
        message: String,
        decision: PlannerDecision,
        customAgent: CustomAgentDefinition? = nil,
        matchedSkill: SkillMatchResult? = nil
    ) {
        let requestedImageGeneration = Self.looksLikeImageGenerationRequest(message)
        let selectedConnector = customAgent?.preferredConnectorID.flatMap { id in
            state.connectors.first(where: { $0.id == id })
        } ?? (requestedImageGeneration ? Self.imageGenerationConnector(from: state.connectors, activeID: state.activeConnectorID) : nil)
            ?? state.activeConnector
        guard let connector = selectedConnector else {
            notify("请先选择一个连接器", style: .error)
            return
        }
        if requestedImageGeneration,
           let imageConnector = ConnectorCapabilityProfile.isImageOnlyModel(connector.modelName)
            ? connector
            : Self.imageGenerationConnector(from: state.connectors, activeID: state.activeConnectorID) {
            let imageDecision = PlannerDecision(
                intent: .task,
                confidence: max(decision.confidence, 0.84),
                reason: decision.reason,
                routeLabel: "图片生成",
                expectedCapabilities: Array(Set(decision.expectedCapabilities + ["生成图片", "整理交付"]))
            )
            if imageConnector.id != state.activeConnectorID {
                notify("已自动使用 \(imageConnector.name) 生成图片", style: .info)
            }
            sendImageGenerationDraft(message: message, decision: imageDecision, connector: imageConnector)
            return
        }
        let allowImageOnlyConnector = decision.intent != .chat && requestedImageGeneration
        if ConnectorCapabilityProfile.isImageOnlyModel(connector.modelName), allowImageOnlyConnector {
            sendImageGenerationDraft(message: message, decision: decision, connector: connector)
            return
        }
        if ConnectorCapabilityProfile.isImageOnlyModel(connector.modelName), !allowImageOnlyConnector {
            notify(ConnectorCapabilityProfile.imageOnlyModelChatMessage(modelName: connector.modelName), style: .error)
            recordToolActivity(
                name: "chat.model_unsupported",
                summary: "图片生成模型不能用于聊天",
                statusLine: connector.modelName,
                isFailure: true
            )
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
        let imageConnector = ConnectorCapabilityProfile.isImageOnlyModel(connector.modelName)
            ? connector
            : Self.imageGenerationConnector(from: state.connectors, activeID: state.activeConnectorID)
        if let imageConnector {
            context.imageGenerationEndpoint = imageConnector.endpoint
            context.imageGenerationModelName = imageConnector.modelName
            context.imageGenerationAPIKey = imageConnector.note
        }

        let intent = decision.intent
        let workflowName: String? = { if case .workflow(let name) = intent { return name } else { return nil } }()

        let selectedThreadProjectID = projectIDForNewThreadFromSelection(allowRunningThread: true)

        if let wfName = workflowName, let workflow = WorkflowLibrary.find(named: wfName, workspaceRoot: state.settings.workspacePath) {
            executeWorkflow(
                taskTitle: message,
                workflow: workflow,
                context: context,
                message: message,
                decision: decision,
                projectID: selectedThreadProjectID
            )
            return
        }

        if customAgent == nil,
           MultiAgentOrchestrator.shouldUseMultiAgent(message: message, intent: intent),
           let plan = MultiAgentOrchestrator.createPlan(for: message, intent: intent, connectors: state.connectors, activeConnectorID: state.activeConnectorID) {
            executeMultiAgent(message: message, context: context, connector: connector, plan: plan, intent: intent, decision: decision, projectID: selectedThreadProjectID)
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
                context.memory = state.threads[threadIndex].context.memory
                if UserFrustrationDetector.isFrustrated(message) {
                    BehaviorSignalTracker.record(signal: .frustration, thread: state.threads[threadIndex])
                }
            }
            let currentTitle = state.threads[threadIndex].title
            if isEmptyPlaceholder || currentTitle.isEmpty || currentTitle == "新会话" || currentTitle == "新对话" {
                state.threads[threadIndex].title = String(message.prefix(32))
            }
            state.threads[threadIndex].status = .running
            state.threads[threadIndex].connectorID = connector.id
            state.threads[threadIndex].workflowName = workflowName
            state.threads[threadIndex].context = context
            if !isChatIntent {
                state.threads[threadIndex].source = .task
            }
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
            let thread = Thread(
                title: String(message.prefix(32)),
                status: .running,
                steps: initialSteps,
                connectorID: connector.id,
                workflowName: workflowName,
                context: context,
                source: isChatIntent ? .session : .task,
                projectID: isChatIntent ? nil : selectedThreadProjectID
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

    private static func looksLikeImageGenerationRequest(_ message: String) -> Bool {
        let text = message.lowercased()
        let actionMarkers = [
            "生成", "创建", "做一张", "做张", "做个", "画一张", "画张", "画个",
            "设计", "出一张", "出张", "出个", "来一张", "来张", "来个", "制作",
            "generate", "create", "draw", "design", "make"
        ]
        let imageMarkers = [
            "图片", "图像", "图", "配图", "插图", "海报", "封面", "主图", "介绍图",
            "宣传图", "商品图", "产品图", "详情图", "banner", "logo", "头像", "壁纸",
            "poster", "image", "illustration", "cover", "thumbnail", "visual"
        ]
        let negativeContext = [
            "代码图", "架构图", "流程图", "类图", "mermaid", "截图", "看图", "读图", "图片里"
        ]
        return actionMarkers.contains { text.contains($0) }
            && imageMarkers.contains { text.contains($0) }
            && !negativeContext.contains { text.contains($0) }
    }

    private static func imageGenerationConnector(from connectors: [ConnectorProfile], activeID: UUID?) -> ConnectorProfile? {
        let imageConnectors = connectors.filter { ConnectorCapabilityProfile.isImageOnlyModel($0.modelName) }
        if let activeID, let active = imageConnectors.first(where: { $0.id == activeID }) {
            return active
        }
        return imageConnectors.first { $0.modelName.localizedCaseInsensitiveContains("gpt-image-2") }
            ?? imageConnectors.first { $0.modelName.localizedCaseInsensitiveContains("gpt-image") }
            ?? imageConnectors.first
    }

    func projectIDForNewThreadFromSelection(allowRunningThread: Bool = false) -> UUID? {
        guard let selectedID = state.selectedThreadID,
              let thread = state.threads.first(where: { $0.id == selectedID }) else { return nil }
        if thread.status == .running && !allowRunningThread { return nil }
        return thread.projectID
    }
}
