import Foundation
import LaicaiNativeDomain

extension AppStore {
    // swiftlint:disable:next cyclomatic_complexity
    func sendTaskDraft(
        message: String,
        decision: PlannerDecision,
        customAgent: CustomAgentDefinition? = nil,
        matchedSkill: SkillMatchResult? = nil
    ) {
        let requestedImageGeneration = RoutingTextHeuristics.requestsImageGeneration(message)
        let selectedConnector =
            customAgent?.preferredConnectorID.flatMap { id in
                state.connectors.first(where: { $0.id == id })
            } ?? (requestedImageGeneration ? Self.imageGenerationConnector(from: state.connectors, activeID: state.activeConnectorID) : nil)
            ?? switchFromUnhealthyActiveConnectorIfNeeded()
        guard let connector = selectedConnector else {
            notify("请先选择一个连接器", style: .error)
            return
        }
        if requestedImageGeneration,
            let imageConnector = ConnectorCapabilityProfile.isImageOnlyModel(connector.modelName)
                ? connector
                : Self.imageGenerationConnector(from: state.connectors, activeID: state.activeConnectorID)
        {
            let imageDecision = PlannerDecision(
                intent: .task,
                confidence: max(decision.confidence, 0.84),
                reason: decision.reason,
                routeLabel: "会话 图片",
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
                summary: "图片生成模型不能用于通用会话",
                statusLine: connector.modelName,
                isFailure: true
            )
            return
        }
        let intent = decision.intent
        let isChatIntent = intent == .chat
        let workflowName: String? = { if case .workflow(let name) = intent { return name } else { return nil } }()

        let selectedThreadProjectID = projectIDForExistingThreadSelection(allowRunningThread: true)
        let continuationTargetID = continuationTargetThreadID(message: message, intent: intent)
        let shouldContinueSelectedThread = continuationTargetID != nil
        let selectedPlaceholderID = state.selectedThreadID.flatMap { selectedID in
            state.threads.first { thread in
                thread.id == selectedID
                    && thread.steps.isEmpty
                    && Thread.isPlaceholderTitle(thread.title)
            }?.id
        }
        let shouldPromoteSelectedPlaceholder =
            continuationTargetID == nil
            && decision.intent != .chat
            && selectedPlaceholderID != nil
        let shouldStartBesideRunningProjectThread =
            continuationTargetID == nil
            && state.selectedThread?.status == .running
            && selectedThreadProjectID != nil
        let newThreadProjectID =
            shouldContinueSelectedThread || shouldPromoteSelectedPlaceholder || shouldStartBesideRunningProjectThread
            ? selectedThreadProjectID : nil

        if decision.intent != .chat && !shouldContinueSelectedThread {
            let workspacePath = state.settings.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if workspacePath.isEmpty {
                notify("请先在设置中指定工作区目录，再执行会话。", style: .error)
                return
            }
            if !Self.isRunningTests
                && (WorkspaceSandbox.isOverlyBroadWorkspace(workspacePath)
                    || WorkspaceSandbox.isDisposableSmokeWorkspace(workspacePath))
            {
                notify("工作区不能设为 home、/tmp 或来财测试目录，请指定一个真实项目文件夹。", style: .error)
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
        context.metadata["intent"] = Self.intentMetadataValue(intent)
        let imageConnector =
            ConnectorCapabilityProfile.isImageOnlyModel(connector.modelName)
            ? connector
            : Self.imageGenerationConnector(from: state.connectors, activeID: state.activeConnectorID)
        if let imageConnector {
            context.imageGenerationEndpoint = imageConnector.endpoint
            context.imageGenerationModelName = imageConnector.modelName
            context.imageGenerationAPIKey = imageConnector.note
        }

        if let wfName = workflowName, let workflow = WorkflowLibrary.find(named: wfName, workspaceRoot: state.settings.workspacePath) {
            executeWorkflow(
                taskTitle: message,
                workflow: workflow,
                context: context,
                message: message,
                decision: decision,
                projectID: newThreadProjectID,
                reuseThreadID: selectedPlaceholderID
            )
            return
        }

        if customAgent == nil,
            MultiAgentOrchestrator.shouldUseMultiAgent(message: message, intent: intent),
            let plan = MultiAgentOrchestrator.createPlan(
                for: message,
                intent: intent,
                connectors: state.connectors,
                activeConnectorID: state.activeConnectorID
            )
        {
            createMultiAgentPlanDraft(
                message: message,
                context: context,
                connector: connector,
                plan: plan,
                decision: decision,
                projectID: newThreadProjectID,
                reuseThreadID: selectedPlaceholderID
            )
            return
        }

        let userStep = TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false)
        let initialSteps: [TaskStep]
        if isChatIntent {
            initialSteps = [userStep]
        } else {
            var steps = [userStep]
            let planStep = TaskStep(
                kind: .aiThinking,
                text: continuationTargetID == nil ? "正在理解会话目标并准备执行。" : Self.plannerStepText(for: decision),
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
        var shouldRemovePlaceholdersAfterResume = false
        if let selectedID = continuationTargetID,
            let threadIndex = state.threads.firstIndex(where: { $0.id == selectedID }),
            state.threads[threadIndex].status != .running,
            shouldContinueSelectedThread
        {
            let isEmptyPlaceholder = state.threads[threadIndex].steps.isEmpty
            shouldRemovePlaceholdersAfterResume = true
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
            if isEmptyPlaceholder || Thread.isPlaceholderTitle(currentTitle) {
                state.threads[threadIndex].title = String(message.prefix(32))
            }
            Self.markAgentRunning(
                &state.threads[threadIndex],
                goal: Self.goal(for: state.threads[threadIndex], incomingMessage: message, isContinuation: !isEmptyPlaceholder),
                plan: Self.agentPlanLines(for: decision, message: message)
            )
            if isChatIntent {
                state.threads[threadIndex].taskProtocol = nil
                state.threads[threadIndex].executionLedger = nil
            }
            let plan = state.threads[threadIndex].currentPlan
            if !isChatIntent,
                state.threads[threadIndex].taskProtocol == nil || state.threads[threadIndex].taskProtocol?.threadID != selectedID
            {
                state.threads[threadIndex].taskProtocol = Self.makeTaskProtocol(
                    threadID: selectedID,
                    message: state.threads[threadIndex].goal ?? message,
                    context: context,
                    decision: decision
                )
            }
            if !isChatIntent, state.threads[threadIndex].executionLedger == nil {
                state.threads[threadIndex].executionLedger = Self.makeExecutionLedger(
                    threadID: selectedID,
                    message: state.threads[threadIndex].goal ?? message,
                    context: context,
                    decision: decision,
                    plan: plan
                )
            }
            state.threads[threadIndex].executionLedger?.goal = state.threads[threadIndex].goal ?? message
            state.threads[threadIndex].executionLedger?.plan = plan
            state.threads[threadIndex].executionLedger?.pendingFollowUp = nil
            state.threads[threadIndex].executionLedger?.nextAction = "继续处理当前会话：\(message)"
            state.threads[threadIndex].executionLedger?.transition(to: isChatIntent ? .planning : .gatheringEvidence, reason: "用户续跑或追问")
            state.threads[threadIndex].connectorID = connector.id
            state.threads[threadIndex].workflowName = workflowName
            state.threads[threadIndex].context = context
            for step in initialSteps {
                state.threads[threadIndex].steps.append(step)
            }
            let allSteps = state.threads[threadIndex].steps
            let isHeavyThread =
                allSteps.count > 40
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
        } else if shouldPromoteSelectedPlaceholder,
            let selectedID = selectedPlaceholderID,
            let threadIndex = state.threads.firstIndex(where: { $0.id == selectedID })
        {
            let plan = Self.agentPlanLines(for: decision, message: message)
            let taskProtocol =
                isChatIntent
                ? nil
                : Self.makeTaskProtocol(
                    threadID: selectedID,
                    message: message,
                    context: context,
                    decision: decision
                )
            let ledger =
                isChatIntent
                ? nil
                : Self.makeExecutionLedger(
                    threadID: selectedID,
                    message: message,
                    context: context,
                    decision: decision,
                    plan: plan
                )
            state.threads[threadIndex].title = String(message.prefix(32))
            state.threads[threadIndex].status = .running
            state.threads[threadIndex].steps = initialSteps
            state.threads[threadIndex].connectorID = connector.id
            state.threads[threadIndex].workflowName = workflowName
            state.threads[threadIndex].context = context
            state.threads[threadIndex].projectID = newThreadProjectID
            state.threads[threadIndex].executionState = .running
            state.threads[threadIndex].goal = message
            state.threads[threadIndex].currentPlan = plan
            state.threads[threadIndex].taskProtocol = taskProtocol
            state.threads[threadIndex].executionLedger = ledger
            state.threads[threadIndex].updatedAt = .now
            targetTaskID = selectedID
            loopPriorSteps = state.threads[threadIndex].steps
        } else {
            let newThreadID = UUID()
            let plan = Self.agentPlanLines(for: decision, message: message)
            let taskProtocol =
                isChatIntent
                ? nil
                : Self.makeTaskProtocol(
                    threadID: newThreadID,
                    message: message,
                    context: context,
                    decision: decision
                )
            let ledger =
                isChatIntent
                ? nil
                : Self.makeExecutionLedger(
                    threadID: newThreadID,
                    message: message,
                    context: context,
                    decision: decision,
                    plan: plan
                )
            let thread = Thread(
                id: newThreadID,
                title: String(message.prefix(32)),
                status: .running,
                steps: initialSteps,
                connectorID: connector.id,
                workflowName: workflowName,
                context: context,
                projectID: newThreadProjectID,
                executionState: .running,
                goal: message,
                currentPlan: plan,
                taskProtocol: taskProtocol,
                executionLedger: ledger
            )
            state.threads.insert(thread, at: 0)
            targetTaskID = thread.id
            loopPriorSteps = thread.steps
        }
        if shouldRemovePlaceholdersAfterResume {
            state.threads.removeAll { thread in
                thread.id != targetTaskID
                    && thread.steps.isEmpty
                    && thread.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (Thread.isPlaceholderTitle(thread.title) || thread.title.trimmingCharacters(in: .whitespacesAndNewlines) == "新线程")
            }
        }
        state.selectThread(id: targetTaskID)
        state.modeLabel = decision.routeLabel
        persistThreads()

        let capturedImages = state.draftImages
        let generationRunID = markGenerationStarted(
            for: targetTaskID,
            activity: isChatIntent ? "思考中…" : "会话 正在分析…"
        )
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
                if AgentLoop.expectsOfficeDocumentDelivery(message) {
                    loopConfig.allowedTools?.formUnion(["file.read", "file.extract", "document.transform"])
                }
                loopConfig.allowedTools?.insert("skill.manage")
            }
        }
        if customAgent == nil, let match = matchedSkill {
            applySkillPromptHint(match, connector: connector, loopConfig: &loopConfig)
        }
        if isChatIntent {
            loopConfig.maxIterations = min(loopConfig.maxIterations, 3)
        }
        let attemptedToolCalling = loopConfig.supportsToolCalling

        if !isChatIntent, let threadIdx = state.threads.firstIndex(where: { $0.id == targetTaskID }) {
            let intentStr: String = {
                switch intent {
                case .chat:
                    return "chat"
                case .research:
                    return "research"
                case .task:
                    return "task"
                case .workflow(let workflowName):
                    return "workflow:\(workflowName)"
                }
            }()
            let avgIter = TaskOutcomeRecorder.shared.avgIterations(intent: intentStr) ?? Double(loopConfig.maxIterations)
            state.threads[threadIdx].context.metadata["expectedIterations"] = "\(Int(ceil(avgIter)))"
            if let taskProtocol = state.threads[threadIdx].taskProtocol,
                let data = try? JSONEncoder().encode(taskProtocol),
                let json = String(data: data, encoding: .utf8)
            {
                state.threads[threadIdx].context.metadata["taskProtocolJSON"] = json
            }
            if let ledger = state.threads[threadIdx].executionLedger,
                let data = try? JSONEncoder().encode(ledger),
                let json = String(data: data, encoding: .utf8)
            {
                state.threads[threadIdx].context.metadata["executionLedgerJSON"] = json
            }
            context = state.threads[threadIdx].context
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
                        guard let self, self.shouldAcceptGenerationCallback(for: targetTaskID, runID: generationRunID) else { return }
                        self.appendTaskStep(step, to: targetTaskID)
                    },
                    onStreamDelta: { [weak self] delta in
                        guard let self, self.shouldAcceptGenerationCallback(for: targetTaskID, runID: generationRunID) else { return }
                        self.appendStreamDelta(delta, to: targetTaskID)
                    },
                    onReasoningDelta: { [weak self] delta in
                        guard let self, self.shouldAcceptGenerationCallback(for: targetTaskID, runID: generationRunID) else { return }
                        self.appendThinkingDelta(delta, to: targetTaskID)
                    },
                    onCheckInterrupt: { [weak self] in
                        guard let self,
                            self.shouldAcceptGenerationCallback(for: targetTaskID, runID: generationRunID)
                        else { return nil }
                        return self.consumePendingFollowUp(for: targetTaskID)
                    }
                )

                guard self.shouldAcceptGenerationCallback(for: targetTaskID, runID: generationRunID) else { return }

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
                guard self.shouldAcceptGenerationCallback(for: targetTaskID, runID: generationRunID) else { return }
                self.flushThinkingBuffer(for: targetTaskID)
                self.flushStreamBuffer(for: targetTaskID)
                if let threadIndex = self.state.threads.firstIndex(where: { $0.id == targetTaskID }) {
                    let steps = self.state.threads[threadIndex].steps
                    let progressSummary = Self.errorProgressSummary(steps: steps)
                    let errorText =
                        progressSummary.isEmpty
                        ? error.localizedDescription
                        : "\(error.localizedDescription)\n\n已完成：\(progressSummary)"
                    self.state.threads[threadIndex].steps.append(
                        TaskStep(kind: .error, text: errorText, isFailure: true, recoverable: true, retryAction: "重试")
                    )
                    self.state.threads[threadIndex].status = .failed
                    self.syncAgentSnapshot(at: threadIndex)
                    Self.ensureCheckpointIfNeeded(&self.state.threads[threadIndex])
                    self.state.threads[threadIndex].updatedAt = Date()
                    self.persistThreadsNow()
                }
                self.recordToolActivity(name: "task.error", summary: "会话 执行失败", statusLine: error.localizedDescription, isFailure: true)
            }

            self.appendPendingFollowUp(to: targetTaskID)
            self.finishGenerationTask(targetTaskID, runID: generationRunID)
        }
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    }

    private static func imageGenerationConnector(from connectors: [ConnectorProfile], activeID: UUID?) -> ConnectorProfile? {
        let imageConnectors = connectors.filter {
            ConnectorCapabilityProfile.isImageOnlyModel($0.modelName)
                && $0.health != .offline
        }
        guard !imageConnectors.isEmpty else { return nil }
        if let activeID, let active = imageConnectors.first(where: { $0.id == activeID }) {
            return active
        }
        return imageConnectors.first { $0.modelName.localizedCaseInsensitiveContains("gpt-image-2") }
            ?? imageConnectors.first { $0.modelName.localizedCaseInsensitiveContains("gpt-image") }
            ?? imageConnectors.first
    }

    func projectIDForExistingThreadSelection(allowRunningThread: Bool = false) -> UUID? {
        guard let selectedID = state.selectedThreadID,
            let thread = state.threads.first(where: { $0.id == selectedID })
        else { return nil }
        if thread.status == .running && !allowRunningThread { return nil }
        return thread.projectID
    }

    func shouldContinueCurrentSelectedThread(message: String, intent: UserIntent) -> Bool {
        guard let selectedID = state.selectedThreadID,
            let thread = state.threads.first(where: { $0.id == selectedID })
        else { return false }
        if thread.status == .running && isThreadGenerating(selectedID) { return false }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thread.steps.isEmpty else {
            return !Self.canRecoverRecentThread(for: trimmed, intent: intent)
        }
        let selectedSourceIsExecution =
            !Self.isPureChatLikeThread(thread)
            && (thread.isExecution || thread.steps.contains { $0.kind == .toolCall })
        if !selectedSourceIsExecution {
            if intent == .chat {
                if Self.isContinuationCommand(trimmed) || Self.isContextualFollowUp(trimmed, thread: thread) {
                    return true
                }
                return !Self.isStandaloneCapabilityOrConceptQuestion(trimmed)
                    && !Self.isStandaloneInfoQuestion(trimmed)
                    && !Self.isStandaloneGeneralQuestion(trimmed)
                    && !Self.isTaskStatusQuestion(trimmed)
            }
            return true
        }
        if selectedSourceIsExecution, Self.taskHasTruncatedOutput(AgentTask(thread: thread)), Self.isTruncationContinuation(trimmed) {
            return true
        }
        if selectedSourceIsExecution, intent == .chat, Self.isStandaloneGeneralQuestion(trimmed) {
            return false
        }
        if Self.isContinuationCommand(trimmed)
            || Self.isContextualFollowUp(trimmed, thread: thread)
            || UserFrustrationDetector.shouldRecoverRecentTask(trimmed)
        {
            return true
        }
        if intent == .chat {
            return !selectedSourceIsExecution
        }
        let hasExplicitThreadReference = Self.isContextualTaskReference(trimmed)
        return selectedSourceIsExecution && (hasExplicitThreadReference || Self.isContextualFollowUp(trimmed, thread: thread))
    }

    func continuationTargetThreadID(message: String, intent: UserIntent) -> UUID? {
        if shouldContinueCurrentSelectedThread(message: message, intent: intent) {
            return state.selectedThreadID
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.canRecoverRecentThread(for: trimmed, intent: intent) else { return nil }

        let selectedID = state.selectedThreadID
        return state.threads
            .filter { thread in
                thread.id != selectedID
                    && !thread.isEmptyPlaceholder
                    && thread.status != .running
                    && thread.canContinue
            }
            .sorted { lhs, rhs in lhs.updatedAt > rhs.updatedAt }
            .first { thread in
                Self.shouldRecoverIntoRecentThread(message: trimmed, thread: thread)
            }?
            .id
    }

    static func canRecoverRecentThread(for message: String, intent: UserIntent) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if isStandaloneCapabilityOrConceptQuestion(normalized)
            || isStandaloneInfoQuestion(normalized)
            || isStandaloneGeneralQuestion(normalized)
        {
            return false
        }
        if isTinyFollowUp(normalized) && !isExplicitRecentTaskFollowUp(normalized) {
            return false
        }
        return isContinuationCommand(normalized)
            || isWikiPersistenceFollowUp(normalized)
            || isExplicitRecentTaskFollowUp(normalized)
            || isContextualTaskReference(normalized)
            || isTaskStatusQuestion(normalized)
            || UserFrustrationDetector.shouldRecoverRecentTask(normalized)
    }

    static func shouldRecoverIntoRecentThread(message: String, thread: Thread) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if isExplicitRecentTaskFollowUp(normalized)
            || isContinuationCommand(normalized)
            || isWikiPersistenceFollowUp(normalized)
            || isContextualTaskReference(normalized)
            || isTaskStatusQuestion(normalized)
            || UserFrustrationDetector.shouldRecoverRecentTask(normalized)
        {
            return true
        }
        if isContextualFollowUp(normalized, thread: thread) {
            return true
        }
        let lastUserInput = thread.steps.reversed().first { $0.kind == .userInput }?.text ?? thread.title
        let sharedKeywords = semanticOverlapKeywords(in: normalized).intersection(semanticOverlapKeywords(in: lastUserInput))
        return sharedKeywords.count >= 2 && isLikelyTaskFollowUp(normalized)
    }

    static func isExplicitRecentTaskFollowUp(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if isWikiPersistenceFollowUp(normalized) { return true }
        let explicitMarkers = [
            "在哪", "到哪", "在哪里", "预览", "打开看看", "看一下产物", "看下产物",
            "文件在哪", "产物在哪", "继续这个", "接着这个", "继续当前", "接着当前",
            "刚才那个", "上个任务", "上一轮", "这个任务", "这个会话", "这个agent",
            "沉淀到wiki", "保存到wiki", "写到wiki", "写进wiki", "生成wiki", "收进知识库",
            "没发完", "被截断", "没写完", "没说完",
        ]
        return explicitMarkers.contains { normalized.localizedCaseInsensitiveContains($0) }
    }

    static func isContextualFollowUp(_ message: String, thread: Thread) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if isWikiPersistenceFollowUp(normalized) { return true }
        if taskHasTruncatedOutput(AgentTask(thread: thread)), isTruncationContinuation(normalized) {
            return true
        }
        if isStandaloneCapabilityOrConceptQuestion(normalized) || isStandaloneInfoQuestion(normalized)
            || isStandaloneGeneralQuestion(normalized)
        {
            return false
        }
        let contextualMarkers = [
            "刚才", "上面", "前面", "这个", "那个", "这里", "它", "这些", "那些",
            "还有", "还要", "继续", "接着", "为什么", "为啥",
            "对吗", "不对", "没反应", "没生效", "还是", "又", "仍然",
            "这个逻辑", "这个页面", "这个按钮", "这个会话", "这个agent", "这个任务", "当前",
            "窗口", "页面", "按钮", "bug", "Bug", "卡顿", "历史任务", "左边", "右边", "追问", "新会话",
        ]
        if contextualMarkers.contains(where: { normalized.contains($0) }) { return true }

        let lastUserInput = thread.steps.reversed().first { $0.kind == .userInput }?.text ?? thread.title
        let sharedKeywords = semanticOverlapKeywords(in: normalized).intersection(semanticOverlapKeywords(in: lastUserInput))
        if normalized.count <= 18 {
            return sharedKeywords.count >= 1 && !isStandaloneGeneralQuestion(normalized)
        }
        return sharedKeywords.count >= 2
    }

    static func goal(for thread: Thread, incomingMessage: String, isContinuation: Bool) -> String {
        let trimmed = incomingMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if isContinuation,
            let existing = thread.goal?.trimmingCharacters(in: .whitespacesAndNewlines),
            !existing.isEmpty
        {
            return existing
        }
        if isContinuation,
            let firstUser = thread.steps.first(where: { $0.kind == .userInput })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
            !firstUser.isEmpty
        {
            return firstUser
        }
        return trimmed
    }

    static func agentPlanLines(for decision: PlannerDecision, message: String) -> [String] {
        var lines = ["理解目标：\(String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))"]
        if !decision.expectedCapabilities.isEmpty {
            lines.append("准备能力：\(decision.expectedCapabilities.prefix(4).joined(separator: "、"))")
        }
        switch decision.intent {
        case .chat:
            lines.append("直接回答或澄清，保持轻量问答姿态")
        case .research:
            lines.append("检索证据并汇总来源")
        case .task:
            lines.append("执行工具，形成可验证结果")
        case .workflow(let name):
            lines.append("运行工作流：\(name)")
        }
        return lines
    }

    static func intentMetadataValue(_ intent: UserIntent) -> String {
        switch intent {
        case .chat: return "chat"
        case .research: return "research"
        case .task: return "task"
        case .workflow(let name): return "workflow:\(name)"
        }
    }
}
