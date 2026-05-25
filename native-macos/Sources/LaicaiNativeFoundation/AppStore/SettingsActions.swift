import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func updateDraft(_ value: String) { state.draftMessage = value }

    private func isInvalidWorkspacePath(_ value: String) -> Bool {
        WorkspaceSandbox.isOverlyBroadWorkspace(value)
            || WorkspaceSandbox.isDisposableSmokeWorkspace(value)
    }

    public func updateWorkspacePath(_ value: String) {
        if isInvalidWorkspacePath(value) {
            notify("工作区不能设为 home、/tmp 或来财测试目录，请选择一个真实项目文件夹。", style: .error)
            return
        }
        state.settings.workspacePath = value
        state.workspaceName = URL(fileURLWithPath: value).lastPathComponent
        WorkspaceSandbox.shared.workspaceRoot = value
        initializeEngines(workspaceRoot: value)
        persistSettings()
    }

    public func switchWorkspace(to path: String) {
        if isInvalidWorkspacePath(path) {
            notify("这个目录是系统/测试目录，不能作为来财工作区。", style: .error)
            return
        }
        state.settings.switchWorkspace(to: path)
        state.workspaceName = URL(fileURLWithPath: path).lastPathComponent
        WorkspaceSandbox.shared.workspaceRoot = path
        initializeEngines(workspaceRoot: path)
        persistSettings()
    }

    public func updateVaultPath(_ value: String) {
        state.settings.vaultPath = value
        persistSettings()
    }

    public func toggleCompactComposer(_ enabled: Bool) {
        state.settings.compactComposer = enabled
        persistSettings()
    }

    public func updateComfyUIServerURL(_ value: String) {
        state.settings.comfyUIServerURL = value
        persistSettings()
    }

    public func updateComfyUIModelName(_ value: String) {
        state.settings.comfyUIModelName = value
        persistSettings()
    }

    public func startGeminiOAuthBridge() {
        do {
            try GeminiOAuthBridgeManager.shared.startInTerminal()
            notify("Gemini / Antigravity 桥已在后台启动。", style: .info)
            recordToolActivity(
                name: "gemini.oauth_bridge",
                summary: "启动 Gemini / Antigravity 桥",
                statusLine: "后台 · 127.0.0.1:\(GeminiOAuthBridgeManager.listenPort)",
                isFailure: false
            )
        } catch {
            notify("启动 Gemini / Antigravity 桥失败：\(error.localizedDescription)", style: .error)
            recordToolActivity(
                name: "gemini.oauth_bridge",
                summary: "启动 Gemini / Antigravity 桥失败",
                statusLine: error.localizedDescription,
                isFailure: true
            )
        }
    }

    public func stopGeminiOAuthBridge() {
        do {
            try GeminiOAuthBridgeManager.shared.stopInTerminal()
            notify("已停止 Gemini / Antigravity 桥并清理 hosts。", style: .info)
            recordToolActivity(
                name: "gemini.oauth_bridge",
                summary: "停止 Gemini / Antigravity 桥",
                statusLine: "清理 /etc/hosts 临时条目",
                isFailure: false
            )
        } catch {
            notify("停止 Gemini / Antigravity 桥失败：\(error.localizedDescription)", style: .error)
            recordToolActivity(
                name: "gemini.oauth_bridge",
                summary: "停止 Gemini / Antigravity 桥失败",
                statusLine: error.localizedDescription,
                isFailure: true
            )
        }
    }

    public func toggleDebugPanels(_ enabled: Bool) {
        state.settings.showDebugPanels = enabled
        persistSettings()
    }

    public func toggleLeanMode(_ enabled: Bool) {
        state.settings.leanMode = enabled
        persistSettings()
    }

    public func updateContextMode(_ mode: ContextMode) {
        state.settings.contextMode = mode
        persistSettings()
    }

    static func enrichVagueMessage(_ message: String, thread: Thread?) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 8 else { return message }

        let hasContext = thread != nil && !(thread?.steps.isEmpty ?? true)
        let lastUserInput = thread?.steps.last(where: { $0.kind == .userInput })?.text ?? ""
        let threadTitle = thread?.title ?? ""

        let continuationPhrases = ["继续", "接着", "接着做", "go on", "continue", "好的继续", "ok继续"]
        let executionPhrases = ["做", "开始", "开始做", "做吧", "干", "go", "start", "执行"]
        let allDonePhrases = ["全做", "都做", "全部", "一起做", "all"]
        let retryPhrases = ["重试", "再试", "retry", "again", "再来"]

        let lower = trimmed.lowercased()

        if continuationPhrases.contains(where: { lower == $0 }) {
            if hasContext {
                return "继续处理当前会话，优先基于已有证据形成结论；不要重复已完成的读取、搜索或执行步骤。"
            }
        }

        if executionPhrases.contains(where: { lower == $0 }) {
            if hasContext {
                return "执行上面讨论的方案。\(!lastUserInput.isEmpty ? "原始需求：\(lastUserInput.prefix(200))" : "")"
            }
        }

        if allDonePhrases.contains(where: { lower == $0 || lower.contains($0) }) {
            if hasContext {
                return "按上面讨论的方案，全部执行。按优先级顺序逐一完成，每完成一项汇报进度。\(!threadTitle.isEmpty ? "Agent：\(threadTitle)" : "")"
            }
        }

        if retryPhrases.contains(where: { lower == $0 }) {
            if hasContext && !lastUserInput.isEmpty {
                return "重试上一次操作。原始需求：\(lastUserInput.prefix(300))\n注意避免之前的失败原因。"
            }
        }

        let affirmations = ["好", "行", "ok", "可以", "好的", "行吧", "嗯"]
        if affirmations.contains(where: { lower == $0 }) && hasContext {
            return "确认，请执行你建议的方案。"
        }

        return message
    }
}
