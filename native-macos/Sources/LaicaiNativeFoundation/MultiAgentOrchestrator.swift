import Foundation
import LaicaiNativeDomain

// MARK: - Multi-Agent Orchestrator

/// Coordinates multiple specialized agents to collaboratively complete complex tasks.
/// Each agent is an AgentLoop with role-specific system prompts, tools, and model preferences.
@MainActor
public final class MultiAgentOrchestrator: ObservableObject {

    public struct Config: Sendable {
        public var workspaceRoot: String
        public var contextMode: ContextMode

        public init(
            workspaceRoot: String = "",
            contextMode: ContextMode = .balanced
        ) {
            self.workspaceRoot = workspaceRoot
            self.contextMode = contextMode
        }
    }

    public struct ConnectorSelection: Sendable {
        public let connector: ConnectorProfile
        public let allConnectors: [ConnectorProfile]

        public init(connector: ConnectorProfile, allConnectors: [ConnectorProfile]) {
            self.connector = connector
            self.allConnectors = allConnectors
        }
    }

    public struct RunRequest: Sendable {
        public let taskID: UUID
        public let message: String
        public let intent: UserIntent
        public let connectorSelection: ConnectorSelection
        public let context: TaskContext?
        public let plan: MultiAgentPlan

        public init(
            taskID: UUID,
            message: String,
            intent: UserIntent,
            connectorSelection: ConnectorSelection,
            plan: MultiAgentPlan,
            context: TaskContext? = nil
        ) {
            self.taskID = taskID
            self.message = message
            self.intent = intent
            self.connectorSelection = connectorSelection
            self.plan = plan
            self.context = context
        }
    }

    let config: Config
    private let runtime: any ChatRuntimeClient
    private let toolRegistry: ToolRegistry

    private struct AgentRunCallbacks {
        let onStep: @MainActor (TaskStep) -> Void
        let onStreamDelta: @Sendable @MainActor (String) -> Void
        let onPlanUpdate: @MainActor (MultiAgentPlan) -> Void
    }

    private struct AgentExecutionContext {
        let message: String
        let intent: UserIntent
        let connector: ConnectorProfile
        let allConnectors: [ConnectorProfile]
        let callbacks: AgentRunCallbacks
    }

    private struct AgentExecutionSnapshot {
        let message: String
        let intent: UserIntent
        let connector: ConnectorProfile
        let allConnectors: [ConnectorProfile]
        let plan: MultiAgentPlan
        let context: TaskContext
        let artifacts: [UUID: String]
    }

    private struct AgentExecutionResult {
        let agentID: UUID
        let output: String?
        let status: TaskStatus
        let steps: [TaskStep]
    }

    private struct AgentRetryRequest {
        let node: AgentNode
        let index: Int
        let agentInput: String
        let execution: AgentExecutionContext
        let context: TaskContext
        let callbacks: AgentRunCallbacks
    }

    private struct AgentRetryResult {
        let output: String?
        let status: TaskStatus
        let steps: [TaskStep]
    }

    private struct SingleAgentLoopRequest {
        let node: AgentNode
        let agentInput: String
        let intent: UserIntent
        let connector: ConnectorProfile
        let allConnectors: [ConnectorProfile]
        let context: TaskContext
    }

    public init(
        config: Config,
        runtime: any ChatRuntimeClient,
        toolRegistry: ToolRegistry? = nil
    ) {
        self.config = config
        self.runtime = runtime
        self.toolRegistry = toolRegistry ?? .shared
    }

    // MARK: - Plan Creation

    /// Create a multi-agent plan based on user intent analysis.
    public static func createPlan(
        for message: String,
        intent: UserIntent,
        connectors: [ConnectorProfile],
        activeConnectorID: UUID?
    ) -> MultiAgentPlan? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }

        let needsCodeMutation = needsCodeMutation(text)
        let roles = inferRoles(for: text, intent: intent)
        guard roles.count >= 2 else { return nil }

        var agents: [AgentNode] = []

        for role in roles {
            let connector = ModelRouter.selectModel(forRole: role, connectors: connectors, activeConnectorID: activeConnectorID)
            let node = AgentNode(
                role: role,
                connectorID: connector?.id
            )
            agents.append(node)
        }
        var handoffs: [AgentHandoff] = []

        // Coding plans are staged as a real engineering loop:
        // planner/research → coder → tester → reviewer.
        if needsCodeMutation {
            applyCodingDependencies(to: &agents)
            handoffs = handoffsForDependencies(agents)
        } else {
            for index in 1..<agents.count {
                agents[index].dependsOn = [agents[index - 1].id]
            }
            handoffs = handoffsForDependencies(agents)
        }

        let planTitle = roles.map { $0.title }.joined(separator: " → ")
        return MultiAgentPlan(
            title: planTitle,
            agents: agents,
            handoffs: handoffs,
            status: .queued
        )
    }

    private static func applyCodingDependencies(to agents: inout [AgentNode]) {
        let plannerID = agents.first(where: { $0.role == .planner })?.id
        let researcherID = agents.first(where: { $0.role == .researcher })?.id
        let coderID = agents.first(where: { $0.role == .coder })?.id
        let testerID = agents.first(where: { $0.role == .tester })?.id

        for index in agents.indices {
            switch agents[index].role {
            case .planner:
                agents[index].dependsOn = []
            case .researcher:
                agents[index].dependsOn = plannerID.map { [$0] } ?? []
            case .coder:
                agents[index].dependsOn = [plannerID, researcherID].compactMap { $0 }
            case .tester:
                agents[index].dependsOn = coderID.map { [$0] } ?? []
            case .reviewer:
                agents[index].dependsOn = testerID.map { [$0] } ?? (coderID.map { [$0] } ?? [])
            }
        }
    }

    private static func handoffsForDependencies(_ agents: [AgentNode]) -> [AgentHandoff] {
        var handoffs: [AgentHandoff] = []
        for agent in agents {
            for depID in agent.dependsOn {
                handoffs.append(AgentHandoff(fromAgentID: depID, toAgentID: agent.id, artifact: ""))
            }
        }
        return handoffs
    }

    /// Infer which agent roles are needed for the given message.
    static func inferRoles(for message: String, intent: UserIntent) -> [AgentRole] {
        let needsCodeMutation = needsCodeMutation(message)

        // Explicit multi-agent patterns
        if containsAny(["协同", "多agent", "multi-agent"], in: message) {
            return needsCodeMutation ? [.planner, .coder, .tester, .reviewer] : [.planner, .coder, .reviewer]
        }

        // Sequential patterns: "先...然后...再..."
        if let sequentialRoles = inferredSequentialRoles(for: message) {
            return sequentialRoles
        }

        // Task-specific patterns
        if needsCodeMutation, asksTesting(message), asksReview(message) {
            return [.planner, .coder, .tester, .reviewer]
        }
        if asksReview(message), containsAny(["修复", "fix", "改"], in: message) {
            return [.researcher, .coder, .reviewer]
        }
        if isImplementationRequest(message) && containsAny(["测试", "test"], in: message) {
            return [.coder, .tester]
        }
        if containsAny(["搜索", "调研", "research"], in: message), containsAny(["实现", "写", "改"], in: message) {
            return [.researcher, .coder, .reviewer]
        }
        if message.contains("重构") && asksTesting(message) {
            return [.coder, .tester, .reviewer]
        }
        if isBroadMutationReview(message, needsCodeMutation: needsCodeMutation) {
            return [.planner, .coder, .tester, .reviewer]
        }

        // Complex tasks with multiple action verbs benefit from multi-agent
        if needsCodeMutation && multiAgentActionCount(in: message) >= 3 {
            return [.planner, .coder, .reviewer]
        }
        if needsCodeMutation && containsAny(["编排", "项目", "文件", "代码", "ui", "布局", "界面"], in: message) {
            return [.planner, .coder, .tester, .reviewer]
        }

        return []
    }

    private static func inferredSequentialRoles(for message: String) -> [AgentRole]? {
        guard message.contains("先"), containsAny(["然后", "再", "最后"], in: message) else { return nil }
        var roles: [AgentRole] = []
        let segments = message.components(separatedBy: CharacterSet(charactersIn: "，。；,;"))
        for segment in segments {
            if let role = dominantRole(for: segment), !roles.contains(role) {
                roles.append(role)
            }
        }
        return roles.count >= 2 ? roles : nil
    }

    private static func isImplementationRequest(_ message: String) -> Bool {
        containsAny(["实现", "写", "开发", "创建", "编辑", "维护"], in: message)
    }

    private static func asksTesting(_ message: String) -> Bool {
        containsAny(["测试", "验证"], in: message)
    }

    private static func asksReview(_ message: String) -> Bool {
        containsAny(["审查", "review"], in: message)
    }

    private static func isBroadMutationReview(_ message: String, needsCodeMutation: Bool) -> Bool {
        containsAny(["全面", "完整", "端到端"], in: message)
            && needsCodeMutation
            && (asksTesting(message) || asksReview(message))
    }

    private static func multiAgentActionCount(in message: String) -> Int {
        let actionVerbs = ["读取", "搜索", "修改", "写入", "运行", "测试", "审查", "重构", "优化", "实现", "部署", "创建", "编辑", "维护", "开发"]
        return actionVerbs.filter { message.contains($0) }.count
    }

    private static func containsAny(_ markers: [String], in message: String) -> Bool {
        markers.contains { message.contains($0) }
    }

    private static func needsCodeMutation(_ message: String) -> Bool {
        let mutationMarkers = [
            "修改", "更改", "改掉", "改一下", "编辑", "维护", "创建", "新建", "生成",
            "写入", "实现", "修复", "重构", "部署", "搭建", "开发", "落盘", "保存",
            "优化", "改进", "增强", "完善", "调整", "重做", "重写", "重新设计", "美化",
            "create", "write", "edit", "modify", "fix", "refactor", "implement", "build",
            "optimize", "improve", "redesign", "revamp",
        ]
        return mutationMarkers.contains { message.contains($0) }
    }

    private static func dominantRole(for text: String) -> AgentRole? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedText.contains("规划") || normalizedText.contains("分析") || normalizedText.contains("拆解") { return .planner }
        if normalizedText.contains("搜索") || normalizedText.contains("调研")
            || normalizedText.contains("查找") || normalizedText.contains("了解")
        {
            return .researcher
        }
        let writesCode =
            normalizedText.contains("写") || normalizedText.contains("实现")
            || normalizedText.contains("修改") || normalizedText.contains("编辑")
            || normalizedText.contains("创建") || normalizedText.contains("新建")
            || normalizedText.contains("维护") || normalizedText.contains("修复")
            || normalizedText.contains("开发") || normalizedText.contains("重构")
        if writesCode { return .coder }
        if normalizedText.contains("测试") || normalizedText.contains("验证") || normalizedText.contains("运行") { return .tester }
        if normalizedText.contains("审查") || normalizedText.contains("检查") || normalizedText.contains("review") { return .reviewer }
        return nil
    }

    /// Check if a message warrants multi-agent treatment.
    public static func shouldUseMultiAgent(message: String, intent: UserIntent) -> Bool {
        guard intent == .task else { return false }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard wantsAutomaticMultiAgent(text) else { return false }
        return !inferRoles(for: text, intent: intent).isEmpty
    }

    private static func wantsAutomaticMultiAgent(_ message: String) -> Bool {
        guard !message.isEmpty else { return false }
        if containsAny(["协同", "多agent", "multi-agent", "多会话", "多个 agent", "多个agent", "分工"], in: message) {
            return true
        }
        if inferredSequentialRoles(for: message) != nil { return true }
        let hasMutation = needsCodeMutation(message)
        return matchesAutomaticMultiAgentTaskPattern(message, hasMutation: hasMutation)
    }

    private static func matchesAutomaticMultiAgentTaskPattern(_ message: String, hasMutation: Bool) -> Bool {
        let testing = asksTestingOrTest(message)
        let review = asksReview(message)
        if hasMutation && testing && review { return true }
        if review && containsAny(["修复", "fix", "改"], in: message) { return true }
        if isImplementationRequest(message) && testing { return true }
        if containsAny(["搜索", "调研", "research"], in: message), containsAny(["实现", "写", "改"], in: message) { return true }
        if message.contains("重构") && testing { return true }
        return containsAny(["全面", "完整", "端到端"], in: message) && hasMutation && (testing || review)
    }

    private static func asksTestingOrTest(_ message: String) -> Bool {
        asksTesting(message) || message.contains("test")
    }

    private static let maxAgentRetries = 2

    // MARK: - Execution (parallel + checkpoint + failover)

    /// Run the multi-agent plan. Agents whose dependencies are satisfied run in parallel.
    /// Failed agents retry with connector failover. Completed agents are skipped on resume.
    public func run(
        _ request: RunRequest,
        onStep: @escaping @MainActor (TaskStep) -> Void = { _ in },
        onStreamDelta: @escaping @Sendable @MainActor (String) -> Void = { _ in },
        onPlanUpdate: @escaping @MainActor (MultiAgentPlan) -> Void = { _ in }
    ) async throws -> AgentTask {
        let callbacks = AgentRunCallbacks(
            onStep: onStep,
            onStreamDelta: onStreamDelta,
            onPlanUpdate: onPlanUpdate
        )
        let executionContext = AgentExecutionContext(
            message: request.message,
            intent: request.intent,
            connector: request.connectorSelection.connector,
            allConnectors: request.connectorSelection.allConnectors,
            callbacks: callbacks
        )
        var task = makeInitialTask(request)
        var currentPlan = runningPlan(from: request.plan)
        callbacks.onPlanUpdate(currentPlan)
        emitInitialMultiAgentSteps(message: request.message, plan: currentPlan, task: &task, callbacks: callbacks)
        var agentArtifacts = completedArtifacts(from: currentPlan)

        await executeAgentPlanLoop(
            execution: executionContext,
            plan: &currentPlan,
            task: &task,
            artifacts: &agentArtifacts
        )

        await repairCodingPlanIfNeeded(
            execution: executionContext,
            plan: &currentPlan,
            task: &task,
            artifacts: &agentArtifacts
        )

        await retryFailedAgentsIfUseful(
            execution: executionContext,
            plan: &currentPlan,
            task: &task,
            artifacts: &agentArtifacts
        )

        finalize(plan: &currentPlan, task: &task, artifacts: agentArtifacts, callbacks: callbacks)
        return task
    }

    private func makeInitialTask(_ request: RunRequest) -> AgentTask {
        AgentTask(
            id: request.taskID,
            title: String(request.message.prefix(50)),
            status: .running,
            connectorID: request.connectorSelection.connector.id,
            context: request.context
                ?? AutoContextEngine.buildContext(
                    workspaceRoot: config.workspaceRoot,
                    userInput: request.message
                ),
            multiAgentPlan: request.plan
        )
    }

    private func runningPlan(from plan: MultiAgentPlan) -> MultiAgentPlan {
        var currentPlan = plan
        currentPlan.status = .running
        currentPlan.isEditable = false
        return currentPlan
    }

    private func emitInitialMultiAgentSteps(
        message: String,
        plan: MultiAgentPlan,
        task: inout AgentTask,
        callbacks: AgentRunCallbacks
    ) {
        let userStep = TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false)
        task.steps.append(userStep)
        callbacks.onStep(userStep)

        let parallelCount = plan.readyAgents().count
        let modeLabel = parallelCount > 1 ? "并行" : "顺序"
        let planText = "多会话协同：\(plan.title)\n共 \(plan.agents.count) 个 会话（\(modeLabel)执行）"
        let planStep = TaskStep(kind: .aiThinking, text: planText, isCollapsible: true, isCollapsed: false, agentRole: .planner)
        task.steps.append(planStep)
        callbacks.onStep(planStep)
    }

    private func completedArtifacts(from plan: MultiAgentPlan) -> [UUID: String] {
        Dictionary(
            uniqueKeysWithValues: plan.agents.compactMap { agent in
                agent.status == .completed ? (agent.id, agent.output) : nil
            })
    }

    private func executeAgentPlanLoop(
        execution: AgentExecutionContext,
        plan: inout MultiAgentPlan,
        task: inout AgentTask,
        artifacts: inout [UUID: String]
    ) async {
        while true {
            let runningIDs = Set(plan.agents.filter { $0.status == .running }.map(\.id))
            let ready = plan.readyAgents(excluding: runningIDs)
            if ready.isEmpty { break }
            await runReadyAgents(ready, execution: execution, plan: &plan, task: &task, artifacts: &artifacts)
        }
    }

    private func runReadyAgents(
        _ ready: [AgentNode],
        execution: AgentExecutionContext,
        plan: inout MultiAgentPlan,
        task: inout AgentTask,
        artifacts: inout [UUID: String]
    ) async {
        guard ready.count > 1 else {
            guard let firstReady = ready.first else { return }
            await runSingleAgent(node: firstReady, execution: execution, plan: &plan, task: &task, artifacts: &artifacts)
            return
        }
        await runParallelAgents(ready, execution: execution, plan: &plan, task: &task, artifacts: &artifacts)
    }

    private func runParallelAgents(
        _ ready: [AgentNode],
        execution: AgentExecutionContext,
        plan: inout MultiAgentPlan,
        task: inout AgentTask,
        artifacts: inout [UUID: String]
    ) async {
        emitParallelBatchStep(ready, task: &task, callbacks: execution.callbacks)
        markAgentsRunning(ready, plan: &plan)
        task.multiAgentPlan = plan
        execution.callbacks.onPlanUpdate(plan)
        let snapshot = executionSnapshot(execution: execution, plan: plan, task: task, artifacts: artifacts)
        await withTaskGroup(of: AgentExecutionResult.self) { group in
            for agentNode in ready {
                group.addTask { [self] in await self.executeAgent(node: agentNode, snapshot: snapshot) }
            }
            for await result in group {
                mergeAgentResult(result, plan: &plan, task: &task, artifacts: &artifacts, callbacks: execution.callbacks)
            }
        }
    }

    private func emitParallelBatchStep(_ ready: [AgentNode], task: inout AgentTask, callbacks: AgentRunCallbacks) {
        let batchStep = TaskStep(
            kind: .aiThinking,
            text: "并行启动 \(ready.count) 个会话：\(ready.map { $0.role.title }.joined(separator: "、"))",
            isCollapsible: true,
            isCollapsed: true,
            agentRole: .planner
        )
        task.steps.append(batchStep)
        callbacks.onStep(batchStep)
    }

    private func markAgentsRunning(_ agents: [AgentNode], plan: inout MultiAgentPlan) {
        for agent in agents {
            if let idx = plan.agents.firstIndex(where: { $0.id == agent.id }) {
                plan.agents[idx].status = .running
                plan.agents[idx].updatedAt = .now
            }
        }
    }

    private func executionSnapshot(
        execution: AgentExecutionContext,
        plan: MultiAgentPlan,
        task: AgentTask,
        artifacts: [UUID: String]
    ) -> AgentExecutionSnapshot {
        AgentExecutionSnapshot(
            message: execution.message,
            intent: execution.intent,
            connector: execution.connector,
            allConnectors: execution.allConnectors,
            plan: plan,
            context: task.context,
            artifacts: artifacts
        )
    }

    private func mergeAgentResult(
        _ result: AgentExecutionResult,
        plan: inout MultiAgentPlan,
        task: inout AgentTask,
        artifacts: inout [UUID: String],
        callbacks: AgentRunCallbacks
    ) {
        let agentID = result.agentID
        guard let idx = plan.agents.firstIndex(where: { $0.id == agentID }) else { return }
        for step in result.steps {
            task.steps.append(step)
            plan.agents[idx].stepIDs.append(step.id)
            callbacks.onStep(step)
        }
        let compactOutput = String((result.output ?? "").prefix(2000))
        artifacts[agentID] = compactOutput
        plan.agents[idx].status = result.status
        plan.agents[idx].output = String(compactOutput.prefix(200))
        plan.agents[idx].updatedAt = .now
        updateHandoffs(from: agentID, output: compactOutput, plan: &plan)
        task.multiAgentPlan = plan
        callbacks.onPlanUpdate(plan)
    }

    private func updateHandoffs(from agentID: UUID, output: String, plan: inout MultiAgentPlan) {
        for hunkIndex in plan.handoffs.indices where plan.handoffs[hunkIndex].fromAgentID == agentID {
            plan.handoffs[hunkIndex].artifact = String(output.prefix(500))
        }
    }

    private func finalize(
        plan: inout MultiAgentPlan,
        task: inout AgentTask,
        artifacts: [UUID: String],
        callbacks: AgentRunCallbacks
    ) {
        let allCompleted = plan.agents.allSatisfy { $0.status == .completed }
        plan.status = allCompleted ? .completed : .failed
        plan.updatedAt = .now
        task.multiAgentPlan = plan
        task.status = allCompleted ? .completed : .failed
        task.updatedAt = .now
        callbacks.onPlanUpdate(plan)

        let summaryText = buildSummary(plan: plan, artifacts: artifacts)
        let summaryStep = TaskStep(kind: .textOutput, text: summaryText, isCollapsible: false, isCollapsed: false, agentRole: .planner)
        task.steps.append(summaryStep)
        callbacks.onStep(summaryStep)
    }

    private func repairCodingPlanIfNeeded(
        execution: AgentExecutionContext,
        plan: inout MultiAgentPlan,
        task: inout AgentTask,
        artifacts: inout [UUID: String]
    ) async {
        let message = execution.message
        let connector = execution.connector
        let callbacks = execution.callbacks
        guard Self.needsCodeMutation(message.lowercased()) else { return }
        guard plan.agents.contains(where: { $0.role == .coder && $0.status == .completed }) else { return }

        let failedQualityAgents = plan.agents.filter {
            ($0.role == .tester || $0.role == .reviewer) && $0.status == .failed
        }
        guard !failedQualityAgents.isEmpty else { return }

        let repairStep = TaskStep(
            kind: .aiThinking,
            text: "验证/审查发现问题，自动交回编码员修复后再验证。",
            isCollapsible: true,
            isCollapsed: true,
            agentRole: .planner
        )
        task.steps.append(repairStep)
        callbacks.onStep(repairStep)

        let blockerArtifacts =
            failedQualityAgents
            .map { node -> String in
                let output = artifacts[node.id] ?? node.output
                return "\(node.role.title)：\(output.isEmpty ? node.errorMessage ?? "失败但无输出" : output)"
            }
            .joined(separator: "\n")

        let coderConnector =
            ModelRouter.selectModel(
                forRole: .coder,
                connectors: execution.allConnectors,
                activeConnectorID: connector.id
            ) ?? connector
        var repairNode = AgentNode(role: .coder, connectorID: coderConnector.id)
        repairNode.input = """
            修复上一轮测试/审查发现的问题。必须直接读写项目文件，修复后运行 verify_build 或最接近的 shell_exec 验证。

            失败反馈：
            \(blockerArtifacts)
            """
        plan.agents.append(repairNode)
        plan.handoffs.append(
            contentsOf: failedQualityAgents.map {
                AgentHandoff(fromAgentID: $0.id, toAgentID: repairNode.id, artifact: String((artifacts[$0.id] ?? $0.output).prefix(500)))
            })
        task.multiAgentPlan = plan
        callbacks.onPlanUpdate(plan)

        let repairExecution = AgentExecutionContext(
            message: "\(message)\n\n上一轮验证/审查反馈：\n\(blockerArtifacts)",
            intent: execution.intent,
            connector: coderConnector,
            allConnectors: execution.allConnectors,
            callbacks: callbacks
        )

        await runSingleAgent(
            node: repairNode,
            execution: repairExecution,
            plan: &plan,
            task: &task,
            artifacts: &artifacts
        )

        guard let repairIndex = plan.agents.firstIndex(where: { $0.id == repairNode.id }),
            plan.agents[repairIndex].status == .completed
        else { return }

        for failedNode in failedQualityAgents {
            guard let idx = plan.agents.firstIndex(where: { $0.id == failedNode.id }) else { continue }
            plan.agents[idx].status = .queued
            plan.agents[idx].errorMessage = nil
            plan.agents[idx].retryCount = 0
            plan.agents[idx].dependsOn = [repairNode.id]
            plan.agents[idx].updatedAt = .now
            plan.handoffs.append(
                AgentHandoff(
                    fromAgentID: repairNode.id,
                    toAgentID: failedNode.id,
                    artifact: String((artifacts[repairNode.id] ?? "").prefix(500))
                ))

            await runSingleAgent(
                node: plan.agents[idx],
                execution: execution,
                plan: &plan,
                task: &task,
                artifacts: &artifacts
            )
        }
    }

    private func retryFailedAgentsIfUseful(
        execution: AgentExecutionContext,
        plan: inout MultiAgentPlan,
        task: inout AgentTask,
        artifacts: inout [UUID: String]
    ) async {
        let callbacks = execution.callbacks
        let failedAgents = plan.agents.filter { $0.status == .failed }
        let hasSuccesses = plan.agents.contains { $0.status == .completed }
        guard !failedAgents.isEmpty, hasSuccesses, failedAgents.count <= 2 else { return }

        let replanStep = TaskStep(
            kind: .aiThinking,
            text: "部分子任务失败（\(failedAgents.map { $0.role.title }.joined(separator: "、"))），尝试重新分配并重试…",
            isCollapsible: true, isCollapsed: true, agentRole: .planner
        )
        task.steps.append(replanStep)
        callbacks.onStep(replanStep)

        for failedNode in failedAgents {
            guard let idx = plan.agents.firstIndex(where: { $0.id == failedNode.id }) else { continue }
            plan.agents[idx].status = .queued
            plan.agents[idx].retryCount = 0
            plan.agents[idx].errorMessage = nil
            let altConnector = selectFailoverConnector(
                excluding: failedNode.connectorID,
                allConnectors: execution.allConnectors,
                fallback: execution.connector
            )
            plan.agents[idx].connectorID = altConnector.id
            plan.agents[idx].updatedAt = .now

            let retryExecution = AgentExecutionContext(
                message: execution.message,
                intent: execution.intent,
                connector: altConnector,
                allConnectors: execution.allConnectors,
                callbacks: callbacks
            )

            await runSingleAgent(
                node: plan.agents[idx],
                execution: retryExecution,
                plan: &plan,
                task: &task,
                artifacts: &artifacts
            )
        }
    }

    // MARK: - Single Agent Runner (sequential path)

    private func runSingleAgent(
        node: AgentNode,
        execution: AgentExecutionContext,
        plan: inout MultiAgentPlan,
        task: inout AgentTask,
        artifacts: inout [UUID: String]
    ) async {
        let callbacks = execution.callbacks
        guard let index = plan.agents.firstIndex(where: { $0.id == node.id }) else { return }

        plan.agents[index].status = .running
        plan.agents[index].updatedAt = .now
        task.multiAgentPlan = plan
        callbacks.onPlanUpdate(plan)

        // Emit handoff from dependencies
        for depID in node.dependsOn {
            if let depNode = plan.agents.first(where: { $0.id == depID }) {
                let prevArtifact = artifacts[depID] ?? "已完成"
                let handoffStep = TaskStep(
                    kind: .aiThinking,
                    text: "\(depNode.role.title) → \(node.role.title)：\(String(prevArtifact.prefix(200)))",
                    isCollapsible: true, isCollapsed: true, agentRole: node.role
                )
                task.steps.append(handoffStep)
                callbacks.onStep(handoffStep)
            }
        }

        let agentInput = buildAgentInput(
            message: execution.message,
            role: node.role,
            artifacts: artifacts,
            plan: plan,
            agentIndex: index
        )
        plan.agents[index].input = String(agentInput.prefix(200))

        let startStep = TaskStep(
            kind: .aiThinking,
            text: "[\(node.role.title)] 开始工作…",
            isCollapsible: true,
            isCollapsed: false,
            agentRole: node.role
        )
        task.steps.append(startStep)
        callbacks.onStep(startStep)

        // Execute with retry + connector failover
        let retryResult = await executeWithRetry(
            request: AgentRetryRequest(
                node: node,
                index: index,
                agentInput: agentInput,
                execution: execution,
                context: task.context,
                callbacks: callbacks
            ),
            plan: &plan,
            task: &task
        )

        let compactOutput = String((retryResult.output ?? "").prefix(2000))
        artifacts[node.id] = compactOutput
        plan.agents[index].status = retryResult.status
        plan.agents[index].output = String(compactOutput.prefix(200))
        plan.agents[index].updatedAt = .now
        for handoffIndex in plan.handoffs.indices where plan.handoffs[handoffIndex].fromAgentID == node.id {
            plan.handoffs[handoffIndex].artifact = String(compactOutput.prefix(500))
        }
        task.multiAgentPlan = plan
        callbacks.onPlanUpdate(plan)
    }

    // MARK: - Execute with Retry + Failover

    private func executeWithRetry(
        request: AgentRetryRequest,
        plan: inout MultiAgentPlan,
        task: inout AgentTask
    ) async -> AgentRetryResult {
        let node = request.node
        let index = request.index
        var lastError: String?
        let maxRetries = Self.maxAgentRetries

        for attempt in 0...maxRetries {
            // Connector failover: on retry, try a different healthy connector
            let agentConnector: ConnectorProfile
            if attempt == 0 {
                agentConnector =
                    request.execution.allConnectors.first(where: { $0.id == node.connectorID })
                    ?? request.execution.connector
            } else {
                agentConnector = selectFailoverConnector(
                    excluding: node.connectorID,
                    allConnectors: request.execution.allConnectors,
                    fallback: request.execution.connector
                )
                let retryStep = TaskStep(
                    kind: .aiThinking,
                    text: "[\(node.role.title)] 第\(attempt)次重试，切换到 \(agentConnector.name)…",
                    isCollapsible: true, isCollapsed: true, agentRole: node.role
                )
                task.steps.append(retryStep)
                request.callbacks.onStep(retryStep)
                plan.agents[index].retryCount = attempt
                plan.agents[index].updatedAt = .now
                task.multiAgentPlan = plan
                request.callbacks.onPlanUpdate(plan)
            }

            let result = await executeSingleAgentLoop(
                request: SingleAgentLoopRequest(
                    node: node,
                    agentInput: request.agentInput,
                    intent: request.execution.intent,
                    connector: agentConnector,
                    allConnectors: request.execution.allConnectors,
                    context: request.context
                ),
                onStep: { step in
                    var taggedStep = step
                    taggedStep.agentRole = node.role
                    task.steps.append(taggedStep)
                    plan.agents[index].stepIDs.append(taggedStep.id)
                    request.callbacks.onStep(taggedStep)
                },
                onStreamDelta: request.callbacks.onStreamDelta
            )

            switch result {
            case .success(let output):
                return AgentRetryResult(output: output, status: .completed, steps: [])
            case .failure(let error):
                lastError = error
                plan.agents[index].errorMessage = error
                if attempt < maxRetries {
                    continue
                }
            }
        }

        let errorStep = TaskStep(
            kind: .error,
            text: "[\(node.role.title)] 执行失败（已重试\(maxRetries)次）：\(lastError ?? "未知错误")",
            isFailure: true, recoverable: true, agentRole: node.role
        )
        task.steps.append(errorStep)
        request.callbacks.onStep(errorStep)
        return AgentRetryResult(output: nil, status: .failed, steps: [errorStep])
    }

    // MARK: - Parallel Agent Execution (returns result tuple)

    private func executeAgent(
        node: AgentNode,
        snapshot: AgentExecutionSnapshot
    ) async -> AgentExecutionResult {
        guard let index = snapshot.plan.agents.firstIndex(where: { $0.id == node.id }) else {
            return AgentExecutionResult(agentID: node.id, output: nil, status: .failed, steps: [])
        }

        let agentInput = buildAgentInput(
            message: snapshot.message,
            role: node.role,
            artifacts: snapshot.artifacts,
            plan: snapshot.plan,
            agentIndex: index
        )
        var collectedSteps: [TaskStep] = []

        // Start step
        let startStep = TaskStep(
            kind: .aiThinking,
            text: "[\(node.role.title)] 开始工作…",
            isCollapsible: true,
            isCollapsed: false,
            agentRole: node.role
        )
        collectedSteps.append(startStep)

        // Try with failover
        for attempt in 0...Self.maxAgentRetries {
            let agentConnector: ConnectorProfile
            if attempt == 0 {
                agentConnector = snapshot.allConnectors.first(where: { $0.id == node.connectorID }) ?? snapshot.connector
            } else {
                agentConnector = selectFailoverConnector(
                    excluding: node.connectorID,
                    allConnectors: snapshot.allConnectors,
                    fallback: snapshot.connector
                )
                let retryStep = TaskStep(
                    kind: .aiThinking,
                    text: "[\(node.role.title)] 第\(attempt)次重试，切换到 \(agentConnector.name)…",
                    isCollapsible: true, isCollapsed: true, agentRole: node.role
                )
                collectedSteps.append(retryStep)
            }

            let result = await executeSingleAgentLoop(
                request: SingleAgentLoopRequest(
                    node: node,
                    agentInput: agentInput,
                    intent: snapshot.intent,
                    connector: agentConnector,
                    allConnectors: snapshot.allConnectors,
                    context: snapshot.context
                ),
                onStep: { step in
                    var taggedStep = step
                    taggedStep.agentRole = node.role
                    collectedSteps.append(taggedStep)
                },
                onStreamDelta: { _ in }
            )

            switch result {
            case .success(let output):
                return AgentExecutionResult(
                    agentID: node.id,
                    output: output,
                    status: .completed,
                    steps: collectedSteps
                )
            case .failure(let error):
                if attempt == Self.maxAgentRetries {
                    let errorStep = TaskStep(
                        kind: .error,
                        text: "[\(node.role.title)] 执行失败：\(error)",
                        isFailure: true, recoverable: true, agentRole: node.role
                    )
                    collectedSteps.append(errorStep)
                    return AgentExecutionResult(
                        agentID: node.id,
                        output: nil,
                        status: .failed,
                        steps: collectedSteps
                    )
                }
            }
        }

        return AgentExecutionResult(
            agentID: node.id,
            output: nil,
            status: .failed,
            steps: collectedSteps
        )
    }

    // MARK: - Core Agent Loop Execution

    private enum AgentResult {
        case success(String)
        case failure(String)
    }

    private func executeSingleAgentLoop(
        request: SingleAgentLoopRequest,
        onStep: @MainActor (TaskStep) -> Void,
        onStreamDelta: @Sendable @MainActor (String) -> Void
    ) async -> AgentResult {
        let profile = ConnectorCapabilityProfile.infer(for: request.connector, mode: config.contextMode)
        var agentConfig = AgentLoop.Config(
            maxIterations: maxIterations(for: request.node.role),
            maxTokensPerTurn: profile.maxTokensPerTurn,
            workspaceRoot: config.workspaceRoot,
            supportsToolCalling: profile.supportsToolCalling,
            contextMode: config.contextMode,
            contextWindow: profile.contextWindow,
            customSystemPrompt: roleSystemPrompt(for: request.node.role),
            allowedTools: request.node.role.allowedTools,
            modelName: request.connector.modelName,
            connectorEndpoint: request.connector.endpoint,
            apiKey: request.connector.note
        )
        if request.node.role == .coder {
            agentConfig.maxIterations = max(agentConfig.maxIterations, 24)
        } else if request.node.role == .tester {
            agentConfig.maxIterations = max(agentConfig.maxIterations, 14)
        }

        let loop = AgentLoop(config: agentConfig, runtime: runtime, toolRegistry: toolRegistry)

        do {
            let agentTask = try await loop.run(
                taskID: UUID(),
                message: request.agentInput,
                intent: request.intent,
                connector: request.connector,
                allConnectors: request.allConnectors,
                context: request.context,
                onStep: onStep,
                onStreamDelta: onStreamDelta
            )

            let steps: [TaskStep] = agentTask.steps
            let output =
                steps
                .filter { $0.kind == .textOutput }
                .map { $0.text }
                .joined(separator: "\n")

            if agentTask.status == .failed {
                return .failure(output.isEmpty ? "会话执行失败" : String(output.prefix(500)))
            }
            return .success(output)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Connector Failover

    private func selectFailoverConnector(
        excluding connectorID: UUID?,
        allConnectors: [ConnectorProfile],
        fallback: ConnectorProfile
    ) -> ConnectorProfile {
        // Prefer a healthy connector that isn't the one that failed
        let candidates = allConnectors.filter {
            $0.id != connectorID && $0.health == .ready
        }
        return candidates.first ?? allConnectors.first(where: { $0.id != connectorID }) ?? fallback
    }

    // MARK: - Private Helpers

    private func buildAgentInput(
        message: String,
        role: AgentRole,
        artifacts: [UUID: String],
        plan: MultiAgentPlan,
        agentIndex: Int
    ) -> String {
        var parts: [String] = []

        let node = plan.agents[agentIndex]
        let customPrompt = node.input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Custom prompt extends the role instruction; edited plans and repair agents
        // still keep the discipline for their role.
        parts.append(roleInstruction(for: role))
        parts.append(role.outputContract)
        if !customPrompt.isEmpty {
            parts.append("本轮具体指令：\n\(customPrompt)")
        }
        parts.append("用户原始请求：\(message)")

        // Include artifacts from completed agents
        for depID in node.dependsOn {
            if let artifact = artifacts[depID],
                let depNode = plan.agents.first(where: { $0.id == depID })
            {
                let preview = String(artifact.prefix(1500))
                parts.append("\n\(depNode.role.title)的工作成果：\n\(preview)")
            }
        }

        // Context about the overall plan
        let otherAgents = plan.agents
            .filter { $0.id != node.id }
            .map { "\($0.role.title)（\($0.status.title)）" }
            .joined(separator: "、")
        if !otherAgents.isEmpty {
            parts.append("\n协同会话：\(otherAgents)")
        }
        if [.coder, .tester, .reviewer].contains(role) {
            parts.append(
                """

                项目维护要求：
                - 你运行在真实工作区 `\(config.workspaceRoot)`，需要像 coding agent 一样直接读写、验证项目。
                - 优先用 workspace_index / code_search 找上下文，再 file_read 关键文件。
                - 只有编码员可以写入项目文件；测试员和审查员只能运行验证、读取证据并输出问题。
                - 编码员的代码任务必须落到文件变更；不能只输出方案或伪代码。
                - 输出必须列出实际修改/检查过的文件和验证结果。
                """)
        }

        return parts.joined(separator: "\n\n")
    }

}

// MARK: - ModelRouter Extension for Agent Roles

extension ModelRouter {
    public static func selectModel(
        forRole role: AgentRole,
        connectors: [ConnectorProfile],
        activeConnectorID: UUID?
    ) -> ConnectorProfile? {
        let active = connectors.first(where: { $0.id == activeConnectorID }) ?? connectors.first
        guard connectors.count > 1 else { return active }

        switch role {
        case .planner, .reviewer:
            return connectors.first(where: {
                $0.modelName.contains("gpt-4") || $0.modelName.contains("claude") || $0.modelName.contains("opus")
                    || $0.modelName.contains("max")
            }) ?? active
        case .coder:
            return connectors.first(where: {
                $0.modelName.contains("code") || $0.modelName.contains("coder") || $0.modelName.contains("deepseek")
            }) ?? active
        case .researcher:
            return active
        case .tester:
            return connectors.first(where: {
                $0.modelName.contains("code") || $0.modelName.contains("coder")
            }) ?? active
        }
    }
}

// MARK: - Array Safe Subscript

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
