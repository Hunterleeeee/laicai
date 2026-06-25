import Foundation
import LaicaiNativeDomain

extension AppStore {
    func sendImageGenerationDraft(message: String, decision: PlannerDecision, connector: ConnectorProfile) {
        let workspaceRoot = state.settings.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspaceRoot.isEmpty {
            notify("请先在设置中指定工作区目录，再生成图片。", style: .error)
            return
        }
        if WorkspaceSandbox.isOverlyBroadWorkspace(workspaceRoot)
            || WorkspaceSandbox.isDisposableSmokeWorkspace(workspaceRoot) {
            notify("工作区不能设为 home、/tmp 或来财测试目录，请指定一个真实项目文件夹。", style: .error)
            return
        }

        var context = TaskContext(
            workspaceRoot: workspaceRoot,
            vaultRoot: state.settings.vaultPath,
            contextMode: state.settings.contextMode,
            comfyUIServerURL: state.settings.comfyUIServerURL,
            comfyUIModelName: state.settings.comfyUIModelName,
            imageGenerationEndpoint: connector.endpoint,
            imageGenerationModelName: connector.modelName,
            imageGenerationAPIKey: connector.note
        )

        let userStep = TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false)
        let planStep = TaskStep(
            kind: .aiThinking,
            text: "正在调用 \(connector.modelName) 生成图片。",
            isCollapsible: true,
            isCollapsed: true
        )
        let initialSteps = [userStep, planStep]
        let selectedThreadProjectID = projectIDForExistingThreadSelection(allowRunningThread: true)
        let continuationTargetID = continuationTargetThreadID(message: message, intent: decision.intent)
        let shouldContinueSelectedThread = continuationTargetID != nil
        let selectedPlaceholderID = state.selectedThreadID.flatMap { selectedID in
            state.threads.first { thread in
                thread.id == selectedID
                    && thread.steps.isEmpty
                    && Thread.isPlaceholderTitle(thread.title)
            }?.id
        }
        let shouldPromoteSelectedPlaceholder = continuationTargetID == nil
            && selectedPlaceholderID != nil
        let shouldStartBesideRunningProjectThread = continuationTargetID == nil
            && state.selectedThread?.status == .running
            && selectedThreadProjectID != nil
        let projectID = shouldContinueSelectedThread || shouldPromoteSelectedPlaceholder || shouldStartBesideRunningProjectThread ? selectedThreadProjectID : nil
        let targetThreadID: UUID
        if let selectedID = continuationTargetID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == selectedID }),
           state.threads[threadIndex].status != .running,
           shouldContinueSelectedThread {
            let isEmptyPlaceholder = state.threads[threadIndex].steps.isEmpty
            if !isEmptyPlaceholder {
                if !state.threads[threadIndex].context.memory.isEmpty {
                    context.memory = state.threads[threadIndex].context.memory
                }
                Self.prepareThreadForContinuation(&state.threads[threadIndex], message: message)
                context.memory = state.threads[threadIndex].context.memory
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
            state.threads[threadIndex].connectorID = connector.id
            state.threads[threadIndex].workflowName = nil
            state.threads[threadIndex].context = context
            if state.threads[threadIndex].taskProtocol == nil {
                state.threads[threadIndex].taskProtocol = Self.makeTaskProtocol(threadID: selectedID, message: message, context: context, decision: decision)
            }
            if state.threads[threadIndex].executionLedger == nil {
                state.threads[threadIndex].executionLedger = Self.makeExecutionLedger(threadID: selectedID, message: message, context: context, decision: decision, plan: state.threads[threadIndex].currentPlan)
            }
            state.threads[threadIndex].steps.append(contentsOf: initialSteps)
            state.threads[threadIndex].updatedAt = .now
            targetThreadID = selectedID
        } else if shouldPromoteSelectedPlaceholder,
                  let selectedID = selectedPlaceholderID,
                  let threadIndex = state.threads.firstIndex(where: { $0.id == selectedID }) {
            state.threads[threadIndex].title = String(message.prefix(32))
            state.threads[threadIndex].status = .running
            state.threads[threadIndex].steps = initialSteps
            state.threads[threadIndex].connectorID = connector.id
            state.threads[threadIndex].context = context
            state.threads[threadIndex].projectID = projectID
            state.threads[threadIndex].executionState = .running
            state.threads[threadIndex].goal = message
            state.threads[threadIndex].currentPlan = Self.agentPlanLines(for: decision, message: message)
            state.threads[threadIndex].taskProtocol = Self.makeTaskProtocol(threadID: selectedID, message: message, context: context, decision: decision)
            state.threads[threadIndex].executionLedger = Self.makeExecutionLedger(threadID: selectedID, message: message, context: context, decision: decision, plan: state.threads[threadIndex].currentPlan)
            state.threads[threadIndex].updatedAt = .now
            targetThreadID = selectedID
        } else {
            let threadID = UUID()
            let plan = Self.agentPlanLines(for: decision, message: message)
            let thread = Thread(
                id: threadID,
                title: String(message.prefix(32)),
                status: .running,
                steps: initialSteps,
                connectorID: connector.id,
                context: context,
                projectID: projectID,
                executionState: .running,
                goal: message,
                currentPlan: plan,
                taskProtocol: Self.makeTaskProtocol(threadID: threadID, message: message, context: context, decision: decision),
                executionLedger: Self.makeExecutionLedger(threadID: threadID, message: message, context: context, decision: decision, plan: plan)
            )
            state.threads.insert(thread, at: 0)
            targetThreadID = thread.id
        }
        state.selectThread(id: targetThreadID)
        state.modeLabel = decision.routeLabel
        markGenerationStarted(for: targetThreadID, activity: "正在生成图片…")
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        persistThreads()

        generationTasks[targetThreadID] = Task { [weak self] in
            guard let self else { return }
            let tool = ComfyUITool()
            let arguments = Self.imageGenerationArguments(prompt: message)
            do {
                let result = try await tool.execute(argumentsJSON: arguments, context: context)
                guard self.shouldAcceptGenerationCallback(for: targetThreadID) else { return }
                let resultStep = TaskStep(
                    kind: .toolResult,
                    text: result.output,
                    toolName: "image.generate",
                    toolParams: result.data,
                    isCollapsible: false,
                    isCollapsed: false,
                    isFailure: !result.success
                )
                self.appendTaskStep(resultStep, to: targetThreadID)
                if let index = self.state.threads.firstIndex(where: { $0.id == targetThreadID }) {
                    self.state.threads[index].status = result.success ? .completed : .failed
                    self.state.threads[index].context = context
                    self.syncAgentSnapshot(at: index)
                    self.state.threads[index].updatedAt = Date()
                    self.persistThreadsNow()
                }
                self.recordToolActivity(
                    name: "image.generate",
                    summary: result.success ? "图片生成完成" : "图片生成失败",
                    statusLine: result.data?["imagePath"] ?? result.error ?? "",
                    isFailure: !result.success
                )
            } catch {
                guard self.shouldAcceptGenerationCallback(for: targetThreadID) else { return }
                let errorStep = TaskStep(kind: .error, text: error.localizedDescription, isFailure: true, recoverable: true, retryAction: "重试")
                self.appendTaskStep(errorStep, to: targetThreadID)
                if let index = self.state.threads.firstIndex(where: { $0.id == targetThreadID }) {
                    self.state.threads[index].status = .failed
                    self.syncAgentSnapshot(at: index)
                    self.state.threads[index].updatedAt = Date()
                    self.persistThreadsNow()
                }
                self.recordToolActivity(name: "image.generate", summary: "图片生成失败", statusLine: error.localizedDescription, isFailure: true)
            }
            self.finishGenerationTask(targetThreadID)
        }
    }

    private static func imageGenerationArguments(prompt: String) -> String {
        let payload: [String: Any] = [
            "prompt": prompt,
            "width": 1024,
            "height": 1024
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"prompt":""}"#
    }
}
