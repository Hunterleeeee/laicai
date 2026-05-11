import Foundation
import LaicaiNativeDomain

extension AppStore {
    func sendImageGenerationDraft(message: String, decision: PlannerDecision, connector: ConnectorProfile) {
        let workspaceRoot = state.settings.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspaceRoot.isEmpty {
            notify("请先在设置中指定工作区目录，再生成图片。", style: .error)
            return
        }
        if WorkspaceSandbox.isOverlyBroadWorkspace(workspaceRoot) {
            notify("工作区不能设为 home 目录或根目录，请指定一个具体的项目文件夹。", style: .error)
            return
        }

        let context = TaskContext(
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
        let thread = Thread(
            title: String(message.prefix(32)),
            status: .running,
            steps: [userStep, planStep],
            connectorID: connector.id,
            context: context,
            projectID: ProjectManager.shared.activeProjectID
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
        state.modeLabel = decision.routeLabel
        state.isGenerating = true
        state.generationStartedAt = Date()
        state.liveActivity = "正在生成图片…"
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        persistThreads()

        generationTasks[thread.id] = Task { [weak self] in
            guard let self else { return }
            let tool = ComfyUITool()
            let arguments = Self.imageGenerationArguments(prompt: message)
            do {
                let result = try await tool.execute(argumentsJSON: arguments, context: context)
                guard !Task.isCancelled else { return }
                let resultStep = TaskStep(
                    kind: .toolResult,
                    text: result.output,
                    toolName: "image.generate",
                    isCollapsible: false,
                    isCollapsed: false,
                    isFailure: !result.success
                )
                self.appendTaskStep(resultStep, to: thread.id)
                if let index = self.state.threads.firstIndex(where: { $0.id == thread.id }) {
                    self.state.threads[index].status = result.success ? .completed : .failed
                    self.state.threads[index].context = context
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
                guard !Task.isCancelled else { return }
                let errorStep = TaskStep(kind: .error, text: error.localizedDescription, isFailure: true, recoverable: true, retryAction: "重试")
                self.appendTaskStep(errorStep, to: thread.id)
                if let index = self.state.threads.firstIndex(where: { $0.id == thread.id }) {
                    self.state.threads[index].status = .failed
                    self.state.threads[index].updatedAt = Date()
                    self.persistThreadsNow()
                }
                self.recordToolActivity(name: "image.generate", summary: "图片生成失败", statusLine: error.localizedDescription, isFailure: true)
            }
            self.finishGenerationTask(thread.id)
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
