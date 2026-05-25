import Foundation
import LaicaiNativeDomain

extension AppStore {
    func absolutePath(for path: String, workspaceRoot: String) -> String {
        if path.hasPrefix("/") { return path }
        return (workspaceRoot as NSString).appendingPathComponent(path)
    }

    func notify(_ message: String, style: AppNoticeStyle = .info) {
        state.notice = AppNotice(message: message, style: style)
    }

    static func agentLoopConfig(settings: AppSettings, connector: ConnectorProfile? = nil) -> AgentLoop.Config {
        let profile = ConnectorCapabilityProfile.infer(for: connector, mode: settings.contextMode)
        return AgentLoop.Config(
            maxIterations: profile.maxIterations,
            maxTokensPerTurn: profile.maxTokensPerTurn,
            workspaceRoot: settings.workspacePath,
            supportsToolCalling: profile.supportsToolCalling,
            contextMode: settings.contextMode,
            contextWindow: profile.contextWindow,
            modelName: connector?.modelName ?? "",
            connectorEndpoint: connector?.endpoint ?? "",
            apiKey: connector?.note ?? "",
            emitDebugSteps: settings.showDebugPanels,
            usePipeline: settings.usePipeline,
            leanMode: settings.leanMode
        )
    }

    static func agentLoopConfig(settings: AppSettings, connector: ConnectorProfile? = nil, decision: PlannerDecision) -> AgentLoop.Config {
        var config = agentLoopConfig(settings: settings, connector: connector)
        let needsProjectDepth = decision.expectedCapabilities.contains("读取工作区")
            || decision.expectedCapabilities.contains("提出文件修改")
            || decision.expectedCapabilities.contains("形成可验证结果")
            || decision.routeLabel == "会话 执行"
            || {
                if case .workflow = decision.intent { return true }
                return false
            }()
        if needsProjectDepth {
            // Ensure at least the mode's iteration budget — profile already handles local vs remote caps
            config.maxIterations = max(config.maxIterations, settings.contextMode.maxIterations)
        }
        if decision.routeLabel == "会话 分析" {
            config.allowedTools = [
                "file.read",
                "file.extract",
                "code.search",
                "workspace.index",
                "web.search",
                "web.fetch"
            ]
        }
        let lowerReason = (decision.reason + " " + decision.routeLabel + " " + decision.expectedCapabilities.joined(separator: " ")).lowercased()
        if lowerReason.contains("ui") || lowerReason.contains("页面") || lowerReason.contains("界面") || lowerReason.contains("按钮") || lowerReason.contains("窗口") {
            if config.allowedTools == nil {
                config.allowedTools = TaskPhase.execute.allowedTools
            }
            config.allowedTools?.formUnion(["browser", "browser.real", "computer", "web.fetch"])
        }
        return config
    }

    nonisolated static func riskPolicy(for message: String, decision: PlannerDecision) -> AgentRiskPolicy {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let inspectMarkers = ["只分析", "先别改", "不要改", "不用改代码", "给我清单", "计划清单", "不用写", "别执行", "no code", "read only"]
        if inspectMarkers.contains(where: { normalized.contains($0.lowercased()) }) {
            return .inspect
        }
        let dangerousMarkers = [
            "删除", "清空", "重置", "reset --hard", "rm -rf", "覆盖", "发布", "部署", "密钥", "secret", "token",
            "sudo", "系统安装", "安装到系统", "强制推送", "push --force", "git clean", "清理工作区", "覆盖掉", "覆盖文件"
        ]
        if dangerousMarkers.contains(where: { normalized.contains($0.lowercased()) }) {
            return .dangerous
        }
        if case .chat = decision.intent {
            return .ask
        }
        if decision.routeLabel == "会话 分析" {
            return .inspect
        }
        let reviewMarkers = ["审查", "review", "看下改动", "检查 diff"]
        if reviewMarkers.contains(where: { normalized.contains($0.lowercased()) }) {
            return .review
        }
        return .act
    }

    nonisolated static func expectedOutcome(for decision: PlannerDecision, message: String) -> String {
        switch decision.intent {
        case .chat:
            return "基于当前上下文给出准确回答。"
        case .research:
            return "读取真实来源后形成可引用的调研结论。"
        case .task:
            if riskPolicy(for: message, decision: decision) == .inspect {
                return "基于真实项目证据形成分析、清单或计划，不修改文件。"
            }
            return "完成用户要求的实际业务，并留下证据、改动或产物。"
        case .workflow(let name):
            return "运行工作流 \(name)，并按用户目标交付结果。"
        }
    }

    nonisolated static func completionCriteria(for decision: PlannerDecision, message: String) -> [String] {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var criteria: [String] = ["保持当前 threadID，不因追问误建新会话"]
        switch decision.intent {
        case .chat:
            criteria.append("给出与当前会话上下文一致的回答")
        case .research:
            criteria.append(contentsOf: ["调用搜索工具", "读取关键来源", "最终结论包含来源依据"])
        case .task:
            if riskPolicy(for: message, decision: decision) == .inspect {
                criteria.append(contentsOf: ["读取真实工作区证据", "不写入文件", "列出结论、风险和下一步"])
            } else {
                criteria.append(contentsOf: ["读取真实工作区证据", "执行必要工具或文件改动", "记录验证结果或明确验证阻塞"])
            }
        case .workflow:
            criteria.append(contentsOf: ["按工作流执行步骤", "记录产物或失败原因", "形成最终交付总结"])
        }
        if normalized.contains("ui") || normalized.contains("页面") || normalized.contains("按钮") || normalized.contains("窗口") {
            criteria.append("记录页面、截图或可访问性检查证据")
        }
        if normalized.contains("性能") || normalized.contains("卡") || normalized.contains("卡顿") {
            criteria.append("定位性能瓶颈后再修复或记录测量阻塞")
        }
        if normalized.contains("markdown") {
            criteria.append("输出 Markdown 渲染/格式优化结果")
        }
        if normalized.contains("bug") || normalized.contains("修复") || normalized.contains("没反应") {
            criteria.append("记录复现路径、修复点和回归验证")
        }
        return Array(NSOrderedSet(array: criteria).compactMap { $0 as? String })
    }

    nonisolated static func makeTaskProtocol(
        threadID: UUID,
        message: String,
        context: TaskContext,
        decision: PlannerDecision
    ) -> AgentTaskProtocol {
        AgentTaskProtocol(
            taskGoal: message.trimmingCharacters(in: .whitespacesAndNewlines),
            workspaceRoot: context.workspaceRoot,
            threadID: threadID,
            expectedOutcome: expectedOutcome(for: decision, message: message),
            completionCriteria: completionCriteria(for: decision, message: message),
            riskPolicy: riskPolicy(for: message, decision: decision),
            continuationPolicy: .ownFollowUps
        )
    }

    nonisolated static func makeExecutionLedger(
        threadID: UUID,
        message: String,
        context: TaskContext,
        decision: PlannerDecision,
        plan: [String]
    ) -> AgentExecutionLedger {
        var ledger = AgentExecutionLedger(
            originalRequest: message.trimmingCharacters(in: .whitespacesAndNewlines),
            goal: message.trimmingCharacters(in: .whitespacesAndNewlines),
            state: .created,
            plan: plan,
            nextAction: "开始采集证据并执行第一步"
        )
        ledger.transition(to: decision.intent == .chat ? .planning : .gatheringEvidence, reason: "任务协议已建立")
        if !context.workspaceRoot.isEmpty {
            ledger.appendUnique(context.workspaceRoot, to: \.pages)
        }
        _ = threadID
        return ledger
    }

    static func plannerStepText(for decision: PlannerDecision) -> String {
        var lines = [
            "规划：\(decision.routeLabel) · 置信度 \(Int((decision.confidence * 100).rounded()))%",
            decision.reason
        ]
        if !decision.expectedCapabilities.isEmpty {
            lines.append("预计使用：\(decision.expectedCapabilities.joined(separator: "、"))")
        }
        return lines.joined(separator: "\n")
    }

    static func workflowCompletionCheckStep(steps: [TaskStep], hasError: Bool) -> TaskStep {
        let toolFailures = steps.filter { $0.kind == .toolResult && $0.isFailure }.count
        let text = hasError
            ? "完成检查：工作流发现 \(toolFailures) 个失败步骤，建议展开失败项后重试或调整目标。"
            : "完成检查：工作流已完成，未发现失败步骤。"
        return TaskStep(
            kind: .aiThinking,
            text: text,
            isCollapsible: true,
            isCollapsed: true,
            isFailure: hasError
        )
    }

    func syncAgentSnapshot(at threadIndex: Int) {
        Self.syncAgentSnapshot(&state.threads[threadIndex])
    }

    nonisolated static func syncAgentSnapshot(_ thread: inout Thread) {
        if thread.isArchived {
            thread.agentState = .archived
        } else if hasPendingReview(in: thread) {
            thread.agentState = .waitingForApproval
        } else {
            thread.agentState = Thread.inferAgentState(status: thread.status)
        }

        if thread.agentGoal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            thread.agentGoal = fallbackAgentGoal(for: thread)
        }
        if thread.currentPlan.isEmpty {
            thread.currentPlan = fallbackAgentPlan(for: thread)
        }
        thread.artifacts = agentArtifacts(from: thread)
    }

    nonisolated static func markAgentRunning(
        _ thread: inout Thread,
        goal: String,
        plan: [String]
    ) {
        thread.status = .running
        thread.agentState = .running
        thread.agentGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        thread.currentPlan = plan
        thread.artifacts = agentArtifacts(from: thread)
        if thread.executionLedger == nil {
            thread.executionLedger = AgentExecutionLedger(
                originalRequest: goal.trimmingCharacters(in: .whitespacesAndNewlines),
                goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
                state: .created,
                plan: plan,
                nextAction: "开始执行当前会话"
            )
        }
        thread.executionLedger?.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        thread.executionLedger?.plan = plan
        thread.executionLedger?.transition(to: .executing, reason: "会话 开始运行")
    }

    nonisolated static func hasPendingReview(in thread: Thread) -> Bool {
        thread.steps.contains { $0.kind == .reviewRequest && $0.approved == nil }
    }

    nonisolated static func fallbackAgentGoal(for thread: Thread) -> String? {
        if let firstUser = thread.steps.first(where: { $0.kind == .userInput })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstUser.isEmpty {
            return firstUser
        }
        let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Thread.isPlaceholderTitle(title) else { return nil }
        return title
    }

    nonisolated static func fallbackAgentPlan(for thread: Thread) -> [String] {
        guard !thread.steps.isEmpty else { return [] }
        if let plan = thread.multiAgentPlan {
            return agentPlanLines(for: plan, message: thread.agentGoal ?? thread.title)
        }
        switch thread.agentState {
        case .idle:
            return ["等待目标", "建立上下文", "按证据推进"]
        case .planning:
            return ["理解目标", "准备上下文", "选择合适工具"]
        case .running:
            return ["执行当前目标", "记录证据和产物", "形成可验证结果"]
        case .waitingForApproval:
            return ["等待用户确认变更", "保留可回滚记录", "确认后继续收尾"]
        case .blocked, .failed:
            return ["定位失败原因", "沿用已有证据", "从失败点继续"]
        case .paused:
            return ["保留现场", "等待继续指令", "恢复后从未完成处推进"]
        case .completed:
            return ["目标已处理", "证据已归档", "可继续追问或重试"]
        case .archived:
            return ["已归档"]
        }
    }

    nonisolated static func agentPlanLines(for plan: MultiAgentPlan, message: String) -> [String] {
        var lines = ["理解目标：\(String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))"]
        if !plan.agents.isEmpty {
            let roles = plan.agents.map(\.role.title).prefix(5).joined(separator: "、")
            lines.append("协同角色：\(roles)")
        }
        lines.append("执行多会话计划：\(plan.title.isEmpty ? "未命名计划" : plan.title)")
        lines.append("汇总各会话产出并完成交付")
        return lines
    }

    static func relevantFileLimit(settings: AppSettings, connector: ConnectorProfile) -> Int {
        ConnectorCapabilityProfile.infer(for: connector, mode: settings.contextMode).relevantFileLimit
    }

    static func directOutputLimit(for connector: ConnectorProfile) -> Int? {
        ConnectorCapabilityProfile.infer(for: connector, mode: .balanced).directOutputLimit
    }

    static func chatPrompt(context: TaskContext, message: String) -> String {
        var prompt = PromptComposer.composeChatPrompt(context: context)
        if UserFrustrationDetector.isFrustrated(message) {
            prompt += "\n\n## 用户纠错/挫败信号\n\(UserFrustrationDetector.guidance)"
        }
        return prompt
    }

    static func isLocalConnector(_ connector: ConnectorProfile) -> Bool {
        ConnectorCapabilityProfile.isLocalConnector(connector)
    }

    static func directHistory(for steps: [TaskStep], message: String) -> [TaskStep] {
        // Always carry history in chat sessions — losing context is the #1 complaint.
        // The runtime layer (compactHistory) will handle truncation if history is too long.
        return steps
            .filter { step in
                !step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && step.kind != .aiThinking
                    && step.kind != .reviewRequest
                    && step.kind != .reviewResult
            }
            .suffix(20)
    }

    nonisolated static func mergePersistedThreads(_ incoming: [Thread], into state: inout AppState) {
        guard !incoming.isEmpty else { return }

        for thread in incoming {
            if let index = state.threads.firstIndex(where: { $0.id == thread.id }) {
                if thread.updatedAt >= state.threads[index].updatedAt {
                    state.threads[index] = thread
                }
            } else {
                state.threads.append(thread)
            }
        }

        state.threads.sort { $0.updatedAt > $1.updatedAt }

        if let selectedID = state.selectedThreadID,
           !state.threads.contains(where: { $0.id == selectedID }) {
            state.selectThread(id: nil)
        }
    }

}
