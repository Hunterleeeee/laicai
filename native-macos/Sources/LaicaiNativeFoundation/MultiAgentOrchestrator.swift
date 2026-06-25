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

    private let config: Config
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
        if message.contains("协同") || message.contains("多agent") || message.contains("multi-agent") {
            return needsCodeMutation ? [.planner, .coder, .tester, .reviewer] : [.planner, .coder, .reviewer]
        }

        // Sequential patterns: "先...然后...再..."
        let sequentialPattern = message.contains("先") && (message.contains("然后") || message.contains("再") || message.contains("最后"))
        if sequentialPattern {
            var roles: [AgentRole] = []
            let segments = message.components(separatedBy: CharacterSet(charactersIn: "，。；,;"))
            for segment in segments {
                if let role = dominantRole(for: segment) {
                    if !roles.contains(role) { roles.append(role) }
                }
            }
            if roles.count >= 2 { return roles }
        }

        // Task-specific patterns
        if needsCodeMutation, (message.contains("测试") || message.contains("验证")) && (message.contains("审查") || message.contains("review")) {
            return [.planner, .coder, .tester, .reviewer]
        }
        if (message.contains("审查") || message.contains("review")) && (message.contains("修复") || message.contains("fix") || message.contains("改")) {
            return [.researcher, .coder, .reviewer]
        }
        let implementationRequest = message.contains("实现") || message.contains("写")
            || message.contains("开发") || message.contains("创建")
            || message.contains("编辑") || message.contains("维护")
        if implementationRequest && (message.contains("测试") || message.contains("test")) {
            return [.coder, .tester]
        }
        if (message.contains("搜索") || message.contains("调研") || message.contains("research")) && (message.contains("实现") || message.contains("写") || message.contains("改")) {
            return [.researcher, .coder, .reviewer]
        }
        if message.contains("重构") && (message.contains("测试") || message.contains("验证")) {
            return [.coder, .tester, .reviewer]
        }
        let broadMarkers = message.contains("全面") || message.contains("完整") || message.contains("端到端")
        let hasExplicitMutation = needsCodeMutation
        if broadMarkers && hasExplicitMutation && (message.contains("测试") || message.contains("验证") || message.contains("审查") || message.contains("review")) {
            return [.planner, .coder, .tester, .reviewer]
        }

        // Complex tasks with multiple action verbs benefit from multi-agent
        let actionVerbs = ["读取", "搜索", "修改", "写入", "运行", "测试", "审查", "重构", "优化", "实现", "部署", "创建", "编辑", "维护", "开发"]
        let actionCount = actionVerbs.filter { message.contains($0) }.count
        if hasExplicitMutation && actionCount >= 3 {
            return [.planner, .coder, .reviewer]
        }
        if hasExplicitMutation && (message.contains("编排") || message.contains("项目") || message.contains("文件") || message.contains("代码") || message.contains("ui") || message.contains("布局") || message.contains("界面")) {
            return [.planner, .coder, .tester, .reviewer]
        }

        return []
    }

    private static func needsCodeMutation(_ message: String) -> Bool {
        let mutationMarkers = [
            "修改", "更改", "改掉", "改一下", "编辑", "维护", "创建", "新建", "生成",
            "写入", "实现", "修复", "重构", "部署", "搭建", "开发", "落盘", "保存",
            "优化", "改进", "增强", "完善", "调整", "重做", "重写", "重新设计", "美化",
            "create", "write", "edit", "modify", "fix", "refactor", "implement", "build",
            "optimize", "improve", "redesign", "revamp"
        ]
        return mutationMarkers.contains { message.contains($0) }
    }

    private static func dominantRole(for text: String) -> AgentRole? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedText.contains("规划") || normalizedText.contains("分析") || normalizedText.contains("拆解") { return .planner }
        if normalizedText.contains("搜索") || normalizedText.contains("调研")
            || normalizedText.contains("查找") || normalizedText.contains("了解") {
            return .researcher
        }
        let writesCode = normalizedText.contains("写") || normalizedText.contains("实现")
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
        if message.contains("协同")
            || message.contains("多agent")
            || message.contains("multi-agent")
            || message.contains("多会话")
            || message.contains("多个 agent")
            || message.contains("多个agent")
            || message.contains("分工") {
            return true
        }

        let sequentialPattern = message.contains("先")
            && (message.contains("然后") || message.contains("再") || message.contains("最后"))
        if sequentialPattern {
            let segments = message.components(separatedBy: CharacterSet(charactersIn: "，。；,;"))
            let roles = segments.compactMap { dominantRole(for: $0) }
            var uniqueRoles: [AgentRole] = []
            for role in roles where !uniqueRoles.contains(role) {
                uniqueRoles.append(role)
            }
            if uniqueRoles.count >= 2 { return true }
        }

        let hasMutation = needsCodeMutation(message)
        let asksTesting = message.contains("测试") || message.contains("验证") || message.contains("test")
        let asksReview = message.contains("审查") || message.contains("review")
        if hasMutation && asksTesting && asksReview { return true }
        if asksReview && (message.contains("修复") || message.contains("fix") || message.contains("改")) { return true }

        let implementationRequest = message.contains("实现") || message.contains("写")
            || message.contains("开发") || message.contains("创建")
            || message.contains("编辑") || message.contains("维护")
        if implementationRequest && asksTesting { return true }
        if (message.contains("搜索") || message.contains("调研") || message.contains("research"))
            && (message.contains("实现") || message.contains("写") || message.contains("改")) {
            return true
        }
        if message.contains("重构") && asksTesting { return true }

        let broadMarkers = message.contains("全面") || message.contains("完整") || message.contains("端到端")
        return broadMarkers && hasMutation && (asksTesting || asksReview)
    }

    private static let maxAgentRetries = 2

    // MARK: - Execution (parallel + checkpoint + failover)

    /// Run the multi-agent plan. Agents whose dependencies are satisfied run in parallel.
    /// Failed agents retry with connector failover. Completed agents are skipped on resume.
    public func run(
        taskID: UUID,
        message: String,
        intent: UserIntent,
        connector: ConnectorProfile,
        allConnectors: [ConnectorProfile],
        context: TaskContext?,
        plan: MultiAgentPlan,
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
            message: message,
            intent: intent,
            connector: connector,
            allConnectors: allConnectors,
            callbacks: callbacks
        )
        var task = AgentTask(
            id: taskID,
            title: String(message.prefix(50)),
            status: .running,
            connectorID: connector.id,
            context: context ?? AutoContextEngine.buildContext(workspaceRoot: config.workspaceRoot, userInput: message),
            multiAgentPlan: plan
        )

        var currentPlan = plan
        currentPlan.status = .running
        currentPlan.isEditable = false
        onPlanUpdate(currentPlan)

        // Emit user input step
        let userStep = TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false)
        task.steps.append(userStep)
        onStep(userStep)

        // Emit plan overview step
        let parallelCount = currentPlan.readyAgents().count
        let modeLabel = parallelCount > 1 ? "并行" : "顺序"
        let planText = "多会话协同：\(currentPlan.title)\n共 \(currentPlan.agents.count) 个 会话（\(modeLabel)执行）"
        let planStep = TaskStep(kind: .aiThinking, text: planText, isCollapsible: true, isCollapsed: false, agentRole: .planner)
        task.steps.append(planStep)
        onStep(planStep)

        // Collect artifacts from each agent
        var agentArtifacts: [UUID: String] = [:]

        // Pre-fill artifacts from already-completed agents (resume scenario)
        for agent in currentPlan.agents where agent.status == .completed {
            agentArtifacts[agent.id] = agent.output
        }

        // Main execution loop: keep running until no more agents can be scheduled
        while true {
            let runningIDs = Set(currentPlan.agents.filter { $0.status == .running }.map(\.id))
            let ready = currentPlan.readyAgents(excluding: runningIDs)
            if ready.isEmpty && runningIDs.isEmpty { break }
            if ready.isEmpty { break } // shouldn't happen, but safety valve

            if ready.count == 1 {
                // Sequential: run single agent directly
                let agentNode = ready[0]
                await runSingleAgent(
                    node: agentNode,
                    execution: executionContext,
                    plan: &currentPlan,
                    task: &task,
                    artifacts: &agentArtifacts
                )
            } else {
                // Parallel: run multiple agents concurrently
                let batchStep = TaskStep(
                    kind: .aiThinking,
                    text: "并行启动 \(ready.count) 个会话：\(ready.map { $0.role.title }.joined(separator: "、"))",
                    isCollapsible: true,
                    isCollapsed: true,
                    agentRole: .planner
                )
                task.steps.append(batchStep)
                onStep(batchStep)

                // Mark all as running
                for agent in ready {
                    if let idx = currentPlan.agents.firstIndex(where: { $0.id == agent.id }) {
                        currentPlan.agents[idx].status = .running
                        currentPlan.agents[idx].updatedAt = .now
                    }
                }
                task.multiAgentPlan = currentPlan
                onPlanUpdate(currentPlan)

                // Snapshot for concurrent access
                let planSnapshot = currentPlan
                let contextSnapshot = task.context
                let artifactSnapshot = agentArtifacts
                let executionSnapshot = AgentExecutionSnapshot(
                    message: message,
                    intent: intent,
                    connector: connector,
                    allConnectors: allConnectors,
                    plan: planSnapshot,
                    context: contextSnapshot,
                    artifacts: artifactSnapshot
                )

                // Run concurrently using TaskGroup
                await withTaskGroup(of: AgentExecutionResult.self) { group in
                    for agentNode in ready {
                        group.addTask { [self] in
                            await self.executeAgent(
                                node: agentNode,
                                snapshot: executionSnapshot
                            )
                        }
                    }

                    for await result in group {
                        let agentID = result.agentID
                        guard let idx = currentPlan.agents.firstIndex(where: { $0.id == agentID }) else { continue }
                        // Merge steps
                        for step in result.steps {
                            task.steps.append(step)
                            currentPlan.agents[idx].stepIDs.append(step.id)
                            onStep(step)
                        }
                        // Update node
                        let compactOutput = String((result.output ?? "").prefix(2000))
                        agentArtifacts[agentID] = compactOutput
                        currentPlan.agents[idx].status = result.status
                        currentPlan.agents[idx].output = String(compactOutput.prefix(200))
                        currentPlan.agents[idx].updatedAt = .now
                        // Update handoffs
                        for hi in currentPlan.handoffs.indices where currentPlan.handoffs[hi].fromAgentID == agentID {
                            currentPlan.handoffs[hi].artifact = String(compactOutput.prefix(500))
                        }
                        task.multiAgentPlan = currentPlan
                        onPlanUpdate(currentPlan)
                    }
                }
            }
        }

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

        // Finalize
        let allCompleted = currentPlan.agents.allSatisfy { $0.status == .completed }
        currentPlan.status = allCompleted ? .completed : .failed
        currentPlan.updatedAt = .now
        task.multiAgentPlan = currentPlan
        task.status = allCompleted ? .completed : .failed
        task.updatedAt = .now
        onPlanUpdate(currentPlan)

        // Emit summary step
        let summaryText = buildSummary(plan: currentPlan, artifacts: agentArtifacts)
        let summaryStep = TaskStep(kind: .textOutput, text: summaryText, isCollapsible: false, isCollapsed: false, agentRole: .planner)
        task.steps.append(summaryStep)
        onStep(summaryStep)

        return task
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

        let blockerArtifacts = failedQualityAgents
            .map { node -> String in
                let output = artifacts[node.id] ?? node.output
                return "\(node.role.title)：\(output.isEmpty ? node.errorMessage ?? "失败但无输出" : output)"
            }
            .joined(separator: "\n")

        let coderConnector = ModelRouter.selectModel(
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
        plan.handoffs.append(contentsOf: failedQualityAgents.map {
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
              plan.agents[repairIndex].status == .completed else { return }

        for failedNode in failedQualityAgents {
            guard let idx = plan.agents.firstIndex(where: { $0.id == failedNode.id }) else { continue }
            plan.agents[idx].status = .queued
            plan.agents[idx].errorMessage = nil
            plan.agents[idx].retryCount = 0
            plan.agents[idx].dependsOn = [repairNode.id]
            plan.agents[idx].updatedAt = .now
            plan.handoffs.append(AgentHandoff(
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
        let (output, status, _) = await executeWithRetry(
            node: node, index: index,
            agentInput: agentInput,
            execution: execution,
            context: task.context,
            plan: &plan, task: &task,
            callbacks: callbacks
        )

        let compactOutput = String((output ?? "").prefix(2000))
        artifacts[node.id] = compactOutput
        plan.agents[index].status = status
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
        node: AgentNode, index: Int,
        agentInput: String,
        execution: AgentExecutionContext,
        context: TaskContext,
        plan: inout MultiAgentPlan, task: inout AgentTask,
        callbacks: AgentRunCallbacks
    ) async -> (String?, TaskStatus, [TaskStep]) {
        var lastError: String?
        let maxRetries = Self.maxAgentRetries

        for attempt in 0...maxRetries {
            // Connector failover: on retry, try a different healthy connector
            let agentConnector: ConnectorProfile
            if attempt == 0 {
                agentConnector = execution.allConnectors.first(where: { $0.id == node.connectorID }) ?? execution.connector
            } else {
                agentConnector = selectFailoverConnector(
                    excluding: node.connectorID,
                    allConnectors: execution.allConnectors,
                    fallback: execution.connector
                )
                let retryStep = TaskStep(
                    kind: .aiThinking,
                    text: "[\(node.role.title)] 第\(attempt)次重试，切换到 \(agentConnector.name)…",
                    isCollapsible: true, isCollapsed: true, agentRole: node.role
                )
                task.steps.append(retryStep)
                callbacks.onStep(retryStep)
                plan.agents[index].retryCount = attempt
                plan.agents[index].updatedAt = .now
                task.multiAgentPlan = plan
                callbacks.onPlanUpdate(plan)
            }

            let result = await executeSingleAgentLoop(
                node: node, agentInput: agentInput, intent: execution.intent,
                connector: agentConnector, allConnectors: execution.allConnectors,
                context: context,
                onStep: { step in
                    var taggedStep = step
                    taggedStep.agentRole = node.role
                    task.steps.append(taggedStep)
                    plan.agents[index].stepIDs.append(taggedStep.id)
                    callbacks.onStep(taggedStep)
                },
                onStreamDelta: callbacks.onStreamDelta
            )

            switch result {
            case .success(let output):
                return (output, .completed, [])
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
        callbacks.onStep(errorStep)
        return (nil, .failed, [errorStep])
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
                node: node, agentInput: agentInput, intent: snapshot.intent,
                connector: agentConnector, allConnectors: snapshot.allConnectors,
                context: snapshot.context,
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
        node: AgentNode,
        agentInput: String,
        intent: UserIntent,
        connector: ConnectorProfile,
        allConnectors: [ConnectorProfile],
        context: TaskContext,
        onStep: @MainActor (TaskStep) -> Void,
        onStreamDelta: @Sendable @MainActor (String) -> Void
    ) async -> AgentResult {
        let profile = ConnectorCapabilityProfile.infer(for: connector, mode: config.contextMode)
        var agentConfig = AgentLoop.Config(
            maxIterations: maxIterations(for: node.role),
            maxTokensPerTurn: profile.maxTokensPerTurn,
            workspaceRoot: config.workspaceRoot,
            supportsToolCalling: profile.supportsToolCalling,
            contextMode: config.contextMode,
            contextWindow: profile.contextWindow,
            customSystemPrompt: roleSystemPrompt(for: node.role),
            allowedTools: node.role.allowedTools,
            modelName: connector.modelName,
            connectorEndpoint: connector.endpoint,
            apiKey: connector.note
        )
        if node.role == .coder {
            agentConfig.maxIterations = max(agentConfig.maxIterations, 24)
        } else if node.role == .tester {
            agentConfig.maxIterations = max(agentConfig.maxIterations, 14)
        }

        let loop = AgentLoop(config: agentConfig, runtime: runtime, toolRegistry: toolRegistry)

        do {
            let agentTask = try await loop.run(
                taskID: UUID(),
                message: agentInput,
                intent: intent,
                connector: connector,
                allConnectors: allConnectors,
                context: context,
                onStep: onStep,
                onStreamDelta: onStreamDelta
            )

            let steps: [TaskStep] = agentTask.steps
            let output = steps
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
               let depNode = plan.agents.first(where: { $0.id == depID }) {
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
            parts.append("""

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

    private func roleInstruction(for role: AgentRole) -> String {
        switch role {
        case .planner:
            return """
            你是规划员。你的任务是分析用户需求，理解项目结构，制定执行计划。
            重点：读取关键文件、建立项目索引、梳理依赖关系，并明确哪些文件需要创建/编辑。
            输出：清晰的任务分解、待修改文件、验证命令和风险点，供后续会话参考。不要停在泛泛建议，不要让编码员猜路径。不得写入项目文件。
            """
        case .coder:
            return """
            你是编码员。你的任务是根据计划实现代码修改。
            重点：必须使用 file_read / file_edit / file_write / diff_apply 真实创建、编辑、维护项目文件；必要时用 shell_exec / verify_build 验证。
            流程：先确认路径与现状，再写入变更；已有文件优先 file_edit，失败后 file_read → file_write 完整写回；新文件用 file_write。
            输出：已修改的文件、验证结果和变更说明。没有工具成功写入时，不准声称已完成。
            """
        case .reviewer:
            return """
            你是审查员。你的任务是审查其他会话的工作成果。
            重点：读取 diff/关键文件，检查代码质量、潜在回归、测试缺口；必要时运行 verify_build 或 shell_exec。
            输出：按严重程度列出问题；没有发现问题要明确说明剩余风险。不得写入项目文件。
            """
        case .researcher:
            return """
            你是研究员。你的任务是收集和整理相关信息。
            重点：搜索代码库、查阅文档、联网获取最新资料。
            输出：整理好的参考资料和分析结论，供其他会话使用。不得写入项目文件。
            """
        case .tester:
            return """
            你是测试员。你的任务是验证变更的正确性。
            重点：使用 verify_build 或 shell_exec 运行项目构建/测试/静态检查，必要时读取失败文件定位原因。
            输出：测试结果和发现的问题；失败时必须给编码员可执行的修复线索（文件/命令/关键错误）。不得写入项目文件。
            """
        }
    }

    private func roleSystemPrompt(for role: AgentRole) -> String {
        var prompt = roleInstruction(for: role)
        switch role {
        case .coder:
            prompt += """

            ## 编码员执行纪律
            - 你有真实项目文件读写能力。创建文件用 file_write，修改已有文件优先 file_edit，复杂补丁可用 diff_apply。
            - 不要只给代码片段或建议；除非用户只问方案，否则必须把变更写入工作区。
            - 如果要维护项目结构，允许创建目录/文件、更新配置、调整测试或文档，但必须保持改动范围清晰。
            - 修改后读取关键文件或运行 verify_build / shell_exec 验证。
            - 如果 file_edit 匹配失败，先 file_read 最新内容，再用 file_write 写回完整正确内容。
            - 最终只总结真实成功的工具结果。
            """
        case .tester:
            prompt += """

            ## 测试员执行纪律
            - 优先调用 verify_build；没有构建系统时再用项目脚本或 shell_exec 做最接近的验证。
            - 验证失败时，读取相关文件定位原因，并输出“失败命令 / 关键错误 / 建议修改文件”。
            - 不要因为环境命令缺失而宣布代码失败；要区分环境问题和代码问题。
            """
        case .reviewer:
            prompt += """

            ## 审查员执行纪律
            - 以代码审查口吻输出问题，优先具体文件和行为风险。
            - 可以运行 verify_build 辅助确认，但不要把“没有运行测试”说成“已通过”。
            - 不直接写入文件；如果发现问题，明确交回编码员处理。
            """
        default:
            break
        }
        return prompt
    }

    private func maxIterations(for role: AgentRole) -> Int {
        let base: Int
        switch role {
        case .planner: base = 6
        case .coder: base = 12
        case .reviewer: base = 6
        case .researcher: base = 8
        case .tester: base = 8
        }
        // Scale with context mode: deep gets 2x, economy stays at base
        switch config.contextMode {
        case .economy: return base
        case .balanced: return Int(Double(base) * 1.5)
        case .deep: return base * 2
        }
    }

    private func buildSummary(plan: MultiAgentPlan, artifacts: [UUID: String]) -> String {
        var parts: [String] = []
        let completed = plan.agents.filter { $0.status == .completed }.count
        let allCompleted = completed == plan.agents.count
        parts.append(allCompleted ? "## 多会话协同完成报告\n" : "## 多会话协同执行报告\n")
        parts.append("**流程：**\(plan.title)\n")
        if !allCompleted {
            parts.append("**状态：**任务未完成，\(plan.agents.count - completed) 个会话失败。请以上方失败工具和错误步骤为准，不要把部分输出当成交付结果。\n")
        }

        for agent in plan.agents {
            let status = agent.status == .completed ? "✅" : "❌"
            let output = agent.output.isEmpty ? "无输出" : agent.output
            parts.append("**\(status) \(agent.role.title)：**\(output)\n")
        }

        parts.append("\n完成 \(completed)/\(plan.agents.count) 个会话")

        return parts.joined(separator: "\n")
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
                $0.modelName.contains("gpt-4") || $0.modelName.contains("claude") ||
                $0.modelName.contains("opus") || $0.modelName.contains("max")
            }) ?? active
        case .coder:
            return connectors.first(where: {
                $0.modelName.contains("code") || $0.modelName.contains("coder") ||
                $0.modelName.contains("deepseek")
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
