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

    public init(
        config: Config,
        runtime: any ChatRuntimeClient,
        toolRegistry: ToolRegistry = .shared
    ) {
        self.config = config
        self.runtime = runtime
        self.toolRegistry = toolRegistry
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

        let roles = inferRoles(for: text, intent: intent)
        guard roles.count >= 2 else { return nil }

        var agents: [AgentNode] = []
        var handoffs: [AgentHandoff] = []
        var previousNode: AgentNode?

        for role in roles {
            let connector = ModelRouter.selectModel(forRole: role, connectors: connectors, activeConnectorID: activeConnectorID)
            let node = AgentNode(
                role: role,
                connectorID: connector?.id
            )
            agents.append(node)

            if let prev = previousNode {
                handoffs.append(AgentHandoff(
                    fromAgentID: prev.id,
                    toAgentID: node.id,
                    artifact: ""
                ))
            }
            previousNode = node
        }

        // Set dependencies: each agent depends on the previous one
        for i in 1..<agents.count {
            agents[i].dependsOn = [agents[i - 1].id]
        }

        let planTitle = roles.map { $0.title }.joined(separator: " → ")
        return MultiAgentPlan(
            title: planTitle,
            agents: agents,
            handoffs: handoffs,
            status: .queued
        )
    }

    /// Infer which agent roles are needed for the given message.
    static func inferRoles(for message: String, intent: UserIntent) -> [AgentRole] {
        // Explicit multi-agent patterns
        if message.contains("协同") || message.contains("多agent") || message.contains("multi-agent") {
            return [.planner, .coder, .reviewer]
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
        if (message.contains("审查") || message.contains("review")) && (message.contains("修复") || message.contains("fix") || message.contains("改")) {
            return [.researcher, .coder, .reviewer]
        }
        if (message.contains("实现") || message.contains("写") || message.contains("开发")) && (message.contains("测试") || message.contains("test")) {
            return [.coder, .tester]
        }
        if (message.contains("搜索") || message.contains("调研") || message.contains("research")) && (message.contains("实现") || message.contains("写") || message.contains("改")) {
            return [.researcher, .coder, .reviewer]
        }
        if message.contains("重构") && (message.contains("测试") || message.contains("验证")) {
            return [.coder, .tester, .reviewer]
        }
        let broadMarkers = message.contains("全面") || message.contains("完整") || message.contains("端到端")
        let hasExplicitMutation = message.contains("修改")
            || message.contains("写入")
            || message.contains("实现")
            || message.contains("修复")
            || message.contains("重构")
            || message.contains("部署")
            || message.contains("改")
        if broadMarkers && hasExplicitMutation && (message.contains("测试") || message.contains("验证") || message.contains("审查") || message.contains("review")) {
            return [.planner, .coder, .tester, .reviewer]
        }

        // Complex tasks with multiple action verbs benefit from multi-agent
        let actionVerbs = ["读取", "搜索", "修改", "写入", "运行", "测试", "审查", "重构", "优化", "实现", "部署"]
        let actionCount = actionVerbs.filter { message.contains($0) }.count
        if hasExplicitMutation && actionCount >= 3 {
            return [.planner, .coder, .reviewer]
        }

        return []
    }

    private static func dominantRole(for text: String) -> AgentRole? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.contains("规划") || t.contains("分析") || t.contains("拆解") { return .planner }
        if t.contains("搜索") || t.contains("调研") || t.contains("查找") || t.contains("了解") { return .researcher }
        if t.contains("写") || t.contains("实现") || t.contains("修改") || t.contains("修复") || t.contains("开发") || t.contains("重构") { return .coder }
        if t.contains("测试") || t.contains("验证") || t.contains("运行") { return .tester }
        if t.contains("审查") || t.contains("检查") || t.contains("review") { return .reviewer }
        return nil
    }

    /// Check if a message warrants multi-agent treatment.
    public static func shouldUseMultiAgent(message: String, intent: UserIntent) -> Bool {
        guard intent == .task else { return false }
        return !inferRoles(for: message.lowercased(), intent: intent).isEmpty
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
        onStep: @MainActor (TaskStep) -> Void = { _ in },
        onStreamDelta: @Sendable @MainActor (String) -> Void = { _ in },
        onPlanUpdate: @MainActor (MultiAgentPlan) -> Void = { _ in }
    ) async throws -> AgentTask {
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
        let planText = "多Agent协同任务：\(currentPlan.title)\n共 \(currentPlan.agents.count) 个Agent（\(modeLabel)执行）"
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
                    message: message,
                    intent: intent,
                    connector: connector,
                    allConnectors: allConnectors,
                    plan: &currentPlan,
                    task: &task,
                    artifacts: &agentArtifacts,
                    onStep: onStep,
                    onStreamDelta: onStreamDelta,
                    onPlanUpdate: onPlanUpdate
                )
            } else {
                // Parallel: run multiple agents concurrently
                let batchStep = TaskStep(
                    kind: .aiThinking,
                    text: "并行启动 \(ready.count) 个Agent：\(ready.map { $0.role.title }.joined(separator: "、"))",
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

                // Run concurrently using TaskGroup
                await withTaskGroup(of: (UUID, String?, TaskStatus, [TaskStep]).self) { group in
                    for agentNode in ready {
                        group.addTask { [self] in
                            await self.executeAgent(
                                node: agentNode,
                                message: message,
                                intent: intent,
                                connector: connector,
                                allConnectors: allConnectors,
                                plan: planSnapshot,
                                context: contextSnapshot,
                                artifacts: artifactSnapshot
                            )
                        }
                    }

                    for await (agentID, output, status, steps) in group {
                        guard let idx = currentPlan.agents.firstIndex(where: { $0.id == agentID }) else { continue }
                        // Merge steps
                        for step in steps {
                            task.steps.append(step)
                            currentPlan.agents[idx].stepIDs.append(step.id)
                            onStep(step)
                        }
                        // Update node
                        let compactOutput = String((output ?? "").prefix(2000))
                        agentArtifacts[agentID] = compactOutput
                        currentPlan.agents[idx].status = status
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

        // Re-plan: if some agents failed but others succeeded, retry failed ones with a different connector
        let failedAgents = currentPlan.agents.filter { $0.status == .failed }
        let hasSuccesses = currentPlan.agents.contains { $0.status == .completed }
        if !failedAgents.isEmpty && hasSuccesses && failedAgents.count <= 2 {
            let replanStep = TaskStep(
                kind: .aiThinking,
                text: "部分子任务失败（\(failedAgents.map { $0.role.title }.joined(separator: "、"))），尝试重新分配并重试…",
                isCollapsible: true, isCollapsed: true, agentRole: .planner
            )
            task.steps.append(replanStep)
            onStep(replanStep)

            for failedNode in failedAgents {
                guard let idx = currentPlan.agents.firstIndex(where: { $0.id == failedNode.id }) else { continue }
                // Reset status for retry
                currentPlan.agents[idx].status = .queued
                currentPlan.agents[idx].retryCount = 0
                currentPlan.agents[idx].errorMessage = nil
                // Switch to a different connector
                let altConnector = selectFailoverConnector(excluding: failedNode.connectorID, allConnectors: allConnectors, fallback: connector)
                currentPlan.agents[idx].connectorID = altConnector.id
                currentPlan.agents[idx].updatedAt = .now

                await runSingleAgent(
                    node: currentPlan.agents[idx], message: message, intent: intent,
                    connector: altConnector, allConnectors: allConnectors,
                    plan: &currentPlan, task: &task, artifacts: &agentArtifacts,
                    onStep: onStep, onStreamDelta: onStreamDelta, onPlanUpdate: onPlanUpdate
                )
            }
        }

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

    // MARK: - Single Agent Runner (sequential path)

    private func runSingleAgent(
        node: AgentNode,
        message: String,
        intent: UserIntent,
        connector: ConnectorProfile,
        allConnectors: [ConnectorProfile],
        plan: inout MultiAgentPlan,
        task: inout AgentTask,
        artifacts: inout [UUID: String],
        onStep: @MainActor (TaskStep) -> Void,
        onStreamDelta: @Sendable @MainActor (String) -> Void,
        onPlanUpdate: @MainActor (MultiAgentPlan) -> Void
    ) async {
        guard let index = plan.agents.firstIndex(where: { $0.id == node.id }) else { return }

        plan.agents[index].status = .running
        plan.agents[index].updatedAt = .now
        task.multiAgentPlan = plan
        onPlanUpdate(plan)

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
                onStep(handoffStep)
            }
        }

        let agentInput = buildAgentInput(message: message, role: node.role, artifacts: artifacts, plan: plan, agentIndex: index)
        plan.agents[index].input = String(agentInput.prefix(200))

        let startStep = TaskStep(kind: .aiThinking, text: "[\(node.role.title)] 开始工作…", isCollapsible: true, isCollapsed: false, agentRole: node.role)
        task.steps.append(startStep)
        onStep(startStep)

        // Execute with retry + connector failover
        let (output, status, _) = await executeWithRetry(
            node: node, index: index,
            agentInput: agentInput, intent: intent,
            connector: connector, allConnectors: allConnectors,
            context: task.context, artifacts: artifacts,
            plan: &plan, task: &task,
            onStep: onStep, onStreamDelta: onStreamDelta, onPlanUpdate: onPlanUpdate
        )

        let compactOutput = String((output ?? "").prefix(2000))
        artifacts[node.id] = compactOutput
        plan.agents[index].status = status
        plan.agents[index].output = String(compactOutput.prefix(200))
        plan.agents[index].updatedAt = .now
        for hi in plan.handoffs.indices where plan.handoffs[hi].fromAgentID == node.id {
            plan.handoffs[hi].artifact = String(compactOutput.prefix(500))
        }
        task.multiAgentPlan = plan
        onPlanUpdate(plan)
    }

    // MARK: - Execute with Retry + Failover

    private func executeWithRetry(
        node: AgentNode, index: Int,
        agentInput: String, intent: UserIntent,
        connector: ConnectorProfile, allConnectors: [ConnectorProfile],
        context: TaskContext, artifacts: [UUID: String],
        plan: inout MultiAgentPlan, task: inout AgentTask,
        onStep: @MainActor (TaskStep) -> Void,
        onStreamDelta: @Sendable @MainActor (String) -> Void,
        onPlanUpdate: @MainActor (MultiAgentPlan) -> Void
    ) async -> (String?, TaskStatus, [TaskStep]) {
        var lastError: String?
        let maxRetries = Self.maxAgentRetries

        for attempt in 0...maxRetries {
            // Connector failover: on retry, try a different healthy connector
            let agentConnector: ConnectorProfile
            if attempt == 0 {
                agentConnector = allConnectors.first(where: { $0.id == node.connectorID }) ?? connector
            } else {
                agentConnector = selectFailoverConnector(
                    excluding: node.connectorID,
                    allConnectors: allConnectors,
                    fallback: connector
                )
                let retryStep = TaskStep(
                    kind: .aiThinking,
                    text: "[\(node.role.title)] 第\(attempt)次重试，切换到 \(agentConnector.name)…",
                    isCollapsible: true, isCollapsed: true, agentRole: node.role
                )
                task.steps.append(retryStep)
                onStep(retryStep)
                plan.agents[index].retryCount = attempt
                plan.agents[index].updatedAt = .now
                task.multiAgentPlan = plan
                onPlanUpdate(plan)
            }

            let result = await executeSingleAgentLoop(
                node: node, agentInput: agentInput, intent: intent,
                connector: agentConnector, allConnectors: allConnectors,
                context: context,
                onStep: { step in
                    var taggedStep = step
                    taggedStep.agentRole = node.role
                    task.steps.append(taggedStep)
                    plan.agents[index].stepIDs.append(taggedStep.id)
                    onStep(taggedStep)
                },
                onStreamDelta: onStreamDelta
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
        onStep(errorStep)
        return (nil, .failed, [errorStep])
    }

    // MARK: - Parallel Agent Execution (returns result tuple)

    private func executeAgent(
        node: AgentNode,
        message: String,
        intent: UserIntent,
        connector: ConnectorProfile,
        allConnectors: [ConnectorProfile],
        plan: MultiAgentPlan,
        context: TaskContext,
        artifacts: [UUID: String]
    ) async -> (UUID, String?, TaskStatus, [TaskStep]) {
        guard let index = plan.agents.firstIndex(where: { $0.id == node.id }) else {
            return (node.id, nil, .failed, [])
        }

        let agentInput = buildAgentInput(message: message, role: node.role, artifacts: artifacts, plan: plan, agentIndex: index)
        var collectedSteps: [TaskStep] = []

        // Start step
        let startStep = TaskStep(kind: .aiThinking, text: "[\(node.role.title)] 开始工作…", isCollapsible: true, isCollapsed: false, agentRole: node.role)
        collectedSteps.append(startStep)

        // Try with failover
        for attempt in 0...Self.maxAgentRetries {
            let agentConnector: ConnectorProfile
            if attempt == 0 {
                agentConnector = allConnectors.first(where: { $0.id == node.connectorID }) ?? connector
            } else {
                agentConnector = selectFailoverConnector(excluding: node.connectorID, allConnectors: allConnectors, fallback: connector)
                let retryStep = TaskStep(
                    kind: .aiThinking,
                    text: "[\(node.role.title)] 第\(attempt)次重试，切换到 \(agentConnector.name)…",
                    isCollapsible: true, isCollapsed: true, agentRole: node.role
                )
                collectedSteps.append(retryStep)
            }

            let result = await executeSingleAgentLoop(
                node: node, agentInput: agentInput, intent: intent,
                connector: agentConnector, allConnectors: allConnectors,
                context: context,
                onStep: { step in
                    var taggedStep = step
                    taggedStep.agentRole = node.role
                    collectedSteps.append(taggedStep)
                },
                onStreamDelta: { _ in }
            )

            switch result {
            case .success(let output):
                return (node.id, output, .completed, collectedSteps)
            case .failure(let error):
                if attempt == Self.maxAgentRetries {
                    let errorStep = TaskStep(
                        kind: .error,
                        text: "[\(node.role.title)] 执行失败：\(error)",
                        isFailure: true, recoverable: true, agentRole: node.role
                    )
                    collectedSteps.append(errorStep)
                    return (node.id, nil, .failed, collectedSteps)
                }
            }
        }

        return (node.id, nil, .failed, collectedSteps)
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
        let agentConfig = AgentLoop.Config(
            maxIterations: maxIterations(for: node.role),
            maxTokensPerTurn: config.contextMode.maxTokensPerTurn,
            workspaceRoot: config.workspaceRoot,
            supportsToolCalling: true,
            contextMode: config.contextMode
        )

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
                return .failure(output.isEmpty ? "Agent执行失败" : String(output.prefix(500)))
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

        // Custom agent systemPrompt takes priority over default role instruction
        let node = plan.agents[agentIndex]
        let customPrompt = node.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customPrompt.isEmpty {
            parts.append(customPrompt)
        } else {
            parts.append(roleInstruction(for: role))
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
            parts.append("\n协同Agent：\(otherAgents)")
        }

        return parts.joined(separator: "\n\n")
    }

    private func roleInstruction(for role: AgentRole) -> String {
        switch role {
        case .planner:
            return """
            你是规划员。你的任务是分析用户需求，理解项目结构，制定执行计划。
            重点：读取关键文件、建立项目索引、梳理依赖关系。
            输出：清晰的任务分解和执行建议，供后续Agent参考。
            """
        case .coder:
            return """
            你是编码员。你的任务是根据计划实现代码修改。
            重点：精确的文件读写、遵循项目风格、最小化变更范围。
            输出：完成的代码修改和变更说明。
            """
        case .reviewer:
            return """
            你是审查员。你的任务是审查其他Agent的工作成果。
            重点：检查代码质量、发现潜在问题、验证逻辑正确性。
            输出：审查意见和改进建议。不要重复执行已完成的操作。
            """
        case .researcher:
            return """
            你是研究员。你的任务是收集和整理相关信息。
            重点：搜索代码库、查阅文档、联网获取最新资料。
            输出：整理好的参考资料和分析结论，供其他Agent使用。
            """
        case .tester:
            return """
            你是测试员。你的任务是验证变更的正确性。
            重点：运行测试、检查构建、验证功能是否正常。
            输出：测试结果和发现的问题。
            """
        }
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
        parts.append("## 多Agent协同完成报告\n")
        parts.append("**流程：**\(plan.title)\n")

        for agent in plan.agents {
            let status = agent.status == .completed ? "✅" : "❌"
            let output = agent.output.isEmpty ? "无输出" : agent.output
            parts.append("**\(status) \(agent.role.title)：**\(output)\n")
        }

        let completed = plan.agents.filter { $0.status == .completed }.count
        parts.append("\n完成 \(completed)/\(plan.agents.count) 个Agent")

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
