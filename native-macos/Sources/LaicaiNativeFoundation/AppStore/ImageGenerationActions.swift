import Foundation
import LaicaiNativeDomain

private struct ImageGenerationThreadRequest {
    let message: String
    let decision: PlannerDecision
    let connector: ConnectorProfile
    let initialSteps: [TaskStep]
    var context: TaskContext
}

private struct ImageGenerationThreadTarget {
    let threadID: UUID
    let context: TaskContext
}

private struct ImageGenerationThreadRouting {
    let continuationTargetID: UUID?
    let selectedPlaceholderID: UUID?
    let projectID: UUID?
}

extension AppStore {
    func sendImageGenerationDraft(message: String, decision: PlannerDecision, connector: ConnectorProfile) {
        let workspaceRoot = state.settings.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspaceRoot.isEmpty {
            notify("请先在设置中指定工作区目录，再生成图片。", style: .error)
            return
        }
        if WorkspaceSandbox.isOverlyBroadWorkspace(workspaceRoot)
            || WorkspaceSandbox.isDisposableSmokeWorkspace(workspaceRoot)
        {
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
        let target = prepareImageGenerationThread(
            ImageGenerationThreadRequest(
                message: message,
                decision: decision,
                connector: connector,
                initialSteps: initialSteps,
                context: context
            ))
        context = target.context
        let targetThreadID = target.threadID
        state.selectThread(id: targetThreadID)
        state.modeLabel = decision.routeLabel
        let generationRunID = markGenerationStarted(for: targetThreadID, activity: "正在生成图片…")
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
                guard self.shouldAcceptGenerationCallback(for: targetThreadID, runID: generationRunID) else { return }
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
                guard self.shouldAcceptGenerationCallback(for: targetThreadID, runID: generationRunID) else { return }
                let errorStep = TaskStep(
                    kind: .error, text: error.localizedDescription, isFailure: true, recoverable: true, retryAction: "重试")
                self.appendTaskStep(errorStep, to: targetThreadID)
                if let index = self.state.threads.firstIndex(where: { $0.id == targetThreadID }) {
                    self.state.threads[index].status = .failed
                    self.syncAgentSnapshot(at: index)
                    self.state.threads[index].updatedAt = Date()
                    self.persistThreadsNow()
                }
                self.recordToolActivity(name: "image.generate", summary: "图片生成失败", statusLine: error.localizedDescription, isFailure: true)
            }
            self.finishGenerationTask(targetThreadID, runID: generationRunID)
        }
    }

    private func prepareImageGenerationThread(_ request: ImageGenerationThreadRequest) -> ImageGenerationThreadTarget {
        let routing = imageGenerationThreadRouting(message: request.message, intent: request.decision.intent)
        if let target = continueImageGenerationThread(request, continuationTargetID: routing.continuationTargetID) {
            return target
        }
        if let target = promoteImageGenerationPlaceholder(
            request,
            selectedPlaceholderID: routing.selectedPlaceholderID,
            projectID: routing.projectID
        ) {
            return target
        }
        return createImageGenerationThread(request, projectID: routing.projectID)
    }

    private func imageGenerationThreadRouting(message: String, intent: UserIntent) -> ImageGenerationThreadRouting {
        let selectedThreadProjectID = projectIDForExistingThreadSelection(allowRunningThread: true)
        let continuationTargetID = continuationTargetThreadID(message: message, intent: intent)
        let selectedPlaceholderID = selectedImageGenerationPlaceholderID()
        let shouldPromotePlaceholder = continuationTargetID == nil && selectedPlaceholderID != nil
        let shouldStartBesideRunningProjectThread =
            continuationTargetID == nil
            && state.selectedThread?.status == .running
            && selectedThreadProjectID != nil
        let shouldUseProject =
            continuationTargetID != nil
            || shouldPromotePlaceholder
            || shouldStartBesideRunningProjectThread
        return ImageGenerationThreadRouting(
            continuationTargetID: continuationTargetID,
            selectedPlaceholderID: shouldPromotePlaceholder ? selectedPlaceholderID : nil,
            projectID: shouldUseProject ? selectedThreadProjectID : nil
        )
    }

    private func selectedImageGenerationPlaceholderID() -> UUID? {
        state.selectedThreadID.flatMap { selectedID in
            state.threads.first { thread in
                thread.id == selectedID
                    && thread.steps.isEmpty
                    && Thread.isPlaceholderTitle(thread.title)
            }?.id
        }
    }

    private func continueImageGenerationThread(
        _ request: ImageGenerationThreadRequest,
        continuationTargetID: UUID?
    ) -> ImageGenerationThreadTarget? {
        guard let selectedID = continuationTargetID,
            let threadIndex = state.threads.firstIndex(where: { $0.id == selectedID }),
            state.threads[threadIndex].status != .running
        else { return nil }
        var context = request.context
        let isEmptyPlaceholder = state.threads[threadIndex].steps.isEmpty
        if !isEmptyPlaceholder {
            context.memory =
                state.threads[threadIndex].context.memory.isEmpty
                ? context.memory
                : state.threads[threadIndex].context.memory
            Self.prepareThreadForContinuation(&state.threads[threadIndex], message: request.message)
            context.memory = state.threads[threadIndex].context.memory
        }
        updateContinuedImageGenerationThread(
            at: threadIndex,
            threadID: selectedID,
            request: request,
            context: context,
            isEmptyPlaceholder: isEmptyPlaceholder
        )
        return ImageGenerationThreadTarget(threadID: selectedID, context: context)
    }

    private func updateContinuedImageGenerationThread(
        at threadIndex: Int,
        threadID: UUID,
        request: ImageGenerationThreadRequest,
        context: TaskContext,
        isEmptyPlaceholder: Bool
    ) {
        let currentTitle = state.threads[threadIndex].title
        if isEmptyPlaceholder || Thread.isPlaceholderTitle(currentTitle) {
            state.threads[threadIndex].title = String(request.message.prefix(32))
        }
        Self.markAgentRunning(
            &state.threads[threadIndex],
            goal: Self.goal(
                for: state.threads[threadIndex],
                incomingMessage: request.message,
                isContinuation: !isEmptyPlaceholder
            ),
            plan: Self.agentPlanLines(for: request.decision, message: request.message)
        )
        state.threads[threadIndex].connectorID = request.connector.id
        state.threads[threadIndex].workflowName = nil
        state.threads[threadIndex].context = context
        if state.threads[threadIndex].taskProtocol == nil {
            state.threads[threadIndex].taskProtocol = Self.makeTaskProtocol(
                threadID: threadID,
                message: request.message,
                context: context,
                decision: request.decision
            )
        }
        if state.threads[threadIndex].executionLedger == nil {
            state.threads[threadIndex].executionLedger = Self.makeExecutionLedger(
                threadID: threadID,
                message: request.message,
                context: context,
                decision: request.decision,
                plan: state.threads[threadIndex].currentPlan
            )
        }
        state.threads[threadIndex].steps.append(contentsOf: request.initialSteps)
        state.threads[threadIndex].updatedAt = .now
    }

    private func promoteImageGenerationPlaceholder(
        _ request: ImageGenerationThreadRequest,
        selectedPlaceholderID: UUID?,
        projectID: UUID?
    ) -> ImageGenerationThreadTarget? {
        guard let selectedID = selectedPlaceholderID,
            let threadIndex = state.threads.firstIndex(where: { $0.id == selectedID })
        else { return nil }
        state.threads[threadIndex].title = String(request.message.prefix(32))
        state.threads[threadIndex].status = .running
        state.threads[threadIndex].steps = request.initialSteps
        state.threads[threadIndex].connectorID = request.connector.id
        state.threads[threadIndex].context = request.context
        state.threads[threadIndex].projectID = projectID
        state.threads[threadIndex].executionState = .running
        state.threads[threadIndex].goal = request.message
        state.threads[threadIndex].currentPlan = Self.agentPlanLines(for: request.decision, message: request.message)
        state.threads[threadIndex].taskProtocol = Self.makeTaskProtocol(
            threadID: selectedID,
            message: request.message,
            context: request.context,
            decision: request.decision
        )
        state.threads[threadIndex].executionLedger = Self.makeExecutionLedger(
            threadID: selectedID,
            message: request.message,
            context: request.context,
            decision: request.decision,
            plan: state.threads[threadIndex].currentPlan
        )
        state.threads[threadIndex].updatedAt = .now
        return ImageGenerationThreadTarget(threadID: selectedID, context: request.context)
    }

    private func createImageGenerationThread(
        _ request: ImageGenerationThreadRequest,
        projectID: UUID?
    ) -> ImageGenerationThreadTarget {
        let threadID = UUID()
        let plan = Self.agentPlanLines(for: request.decision, message: request.message)
        let thread = Thread(
            id: threadID,
            title: String(request.message.prefix(32)),
            status: .running,
            steps: request.initialSteps,
            connectorID: request.connector.id,
            context: request.context,
            projectID: projectID,
            executionState: .running,
            goal: request.message,
            currentPlan: plan,
            taskProtocol: Self.makeTaskProtocol(
                threadID: threadID,
                message: request.message,
                context: request.context,
                decision: request.decision
            ),
            executionLedger: Self.makeExecutionLedger(
                threadID: threadID,
                message: request.message,
                context: request.context,
                decision: request.decision,
                plan: plan
            )
        )
        state.threads.insert(thread, at: 0)
        return ImageGenerationThreadTarget(threadID: thread.id, context: request.context)
    }

    private static func imageGenerationArguments(prompt: String) -> String {
        let payload: [String: Any] = [
            "prompt": prompt,
            "width": 1024,
            "height": 1024,
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"prompt":""}"#
    }
}
