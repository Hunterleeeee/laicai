import Foundation
import LaicaiNativeDomain

// MARK: - Workflow Parameter (user-facing input)

public struct WorkflowParam: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var key: String  // maps to step param key or template variable
    public var label: String  // display label
    public var placeholder: String
    public var kind: ParamKind
    public var required: Bool
    public var defaultValue: String

    public enum ParamKind: String, Codable, Sendable, Equatable {
        case text  // free text
        case filePath  // file chooser
        case directoryPath  // directory chooser
        case choice  // predefined options (comma-sep in defaultValue)
    }

    public init(
        id: UUID = UUID(),
        key: String,
        label: String,
        placeholder: String = "",
        kind: ParamKind = .text,
        required: Bool = true,
        defaultValue: String = ""
    ) {
        self.id = id
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.kind = kind
        self.required = required
        self.defaultValue = defaultValue
    }
}

// MARK: - Workflow Category

public enum WorkflowCategory: String, Codable, Sendable, Equatable {
    case review  // code review
    case generate  // test-gen, doc-gen
    case debug  // debug
    case refactor  // refactor
    case transform  // translate, format
    case product  // PM: PRD, user stories, competitive analysis
    case project  // project management: release planning, retrospective
    case custom  // user-defined

    public var icon: String {
        switch self {
        case .review: return "eye"
        case .generate: return "doc.badge.plus"
        case .debug: return "ant"
        case .refactor: return "arrow.triangle.2.circlepath"
        case .transform: return "arrow.left.arrow.right"
        case .product: return "lightbulb"
        case .project: return "calendar.badge.clock"
        case .custom: return "arrow.triangle.branch"
        }
    }

    public var tintHex: String {
        switch self {
        case .review: return "3B82F6"  // blue
        case .generate: return "10B981"  // green
        case .debug: return "EF4444"  // red
        case .refactor: return "8B5CF6"  // purple
        case .transform: return "F59E0B"  // amber
        case .product: return "EC4899"  // pink
        case .project: return "F97316"  // orange
        case .custom: return "06B6D4"  // teal
        }
    }
}

// MARK: - Workflow Definition

public struct WorkflowStep: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var tool: String
    public var params: [String: String]
    public var condition: String?
    public var onFailure: String?
    /// LLM prompt template for "llm" tool type (supports variable substitution)
    public var prompt: String?

    public init(
        id: UUID = UUID(),
        name: String,
        tool: String,
        params: [String: String] = [:],
        condition: String? = nil,
        onFailure: String? = nil,
        prompt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.tool = tool
        self.params = params
        self.condition = condition
        self.onFailure = onFailure
        self.prompt = prompt
    }
}

public struct WorkflowDefinition: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var description: String
    public var steps: [WorkflowStep]
    public var isBuiltin: Bool
    public var category: WorkflowCategory
    public var inputParams: [WorkflowParam]

    public init(
        id: UUID = UUID(),
        name: String,
        description: String,
        steps: [WorkflowStep],
        isBuiltin: Bool = false,
        category: WorkflowCategory = .custom,
        inputParams: [WorkflowParam] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.steps = steps
        self.isBuiltin = isBuiltin
        self.category = category
        self.inputParams = inputParams
    }
}

// MARK: - Workflow Parser (YAML-like)

public struct WorkflowParser {
    public static func parse(_ source: String) -> WorkflowDefinition? {
        parseWithErrors(source).definition
    }

    /// Parse with detailed error messages for invalid YAML
    public static func parseWithErrors(_ source: String) -> (definition: WorkflowDefinition?, errors: [String]) {
        var state = ParserState()
        state.parse(source.components(separatedBy: "\n"))
        return state.result()
    }

    private struct StepDraft {
        var name: String
        var tool: String = ""
        var params: [String: String] = [:]
        var condition: String?
        var onFailure: String?
        var prompt: String?

        var workflowStep: WorkflowStep {
            WorkflowStep(name: name, tool: tool, params: params, condition: condition, onFailure: onFailure, prompt: prompt)
        }
    }

    private struct ParserState {
        var errors: [String] = []
        var name = ""
        var description = ""
        var steps: [WorkflowStep] = []
        var currentStep: StepDraft?
        var promptMode = false
        var promptLines: [String] = []

        mutating func parse(_ lines: [String]) {
            for (index, rawLine) in lines.enumerated() {
                let lineNum = index + 1
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                if handlePromptContinuation(rawLine: rawLine) { continue }
                if handleTopLevel(trimmed: trimmed, lineNum: lineNum) { continue }
                if handleStepStart(trimmed: trimmed) { continue }
                if handleStepField(trimmed: trimmed, lineNum: lineNum) { continue }
                _ = handleParamLine(rawLine: rawLine, trimmed: trimmed, lineNum: lineNum)
            }
            flushStep()
        }

        mutating func result() -> (definition: WorkflowDefinition?, errors: [String]) {
            validateRequiredFields()
            guard !name.isEmpty, !steps.isEmpty, errors.isEmpty else {
                return (nil, errors)
            }
            return (WorkflowDefinition(name: name, description: description, steps: steps), errors)
        }

        private mutating func flushPrompt() {
            guard promptMode else { return }
            currentStep?.prompt =
                promptLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            promptMode = false
            promptLines = []
        }

        private mutating func flushStep() {
            flushPrompt()
            if let step = currentStep, !step.name.isEmpty, !step.tool.isEmpty {
                steps.append(step.workflowStep)
            } else if let step = currentStep {
                appendMissingStepFieldErrors(step)
            }
            currentStep = nil
        }

        private mutating func appendMissingStepFieldErrors(_ step: StepDraft) {
            if step.name.isEmpty {
                errors.append("步骤缺少名称（name 字段）")
            }
            if step.tool.isEmpty {
                errors.append("步骤「\(step.name)」缺少工具（tool 字段）")
            }
        }

        private mutating func handlePromptContinuation(rawLine: String) -> Bool {
            guard promptMode else { return false }
            if rawLine.hasPrefix("    ") || rawLine.hasPrefix("\t") {
                promptLines.append(rawLine.replacingOccurrences(of: #"^\s{4}"#, with: "", options: .regularExpression))
                return true
            }
            flushPrompt()
            return false
        }

        private mutating func handleTopLevel(trimmed: String, lineNum: Int) -> Bool {
            guard currentStep == nil else { return false }
            if trimmed.hasPrefix("name:") {
                name = WorkflowParser.value(after: "name:", in: trimmed)
                if name.isEmpty { errors.append("第 \(lineNum) 行：工作流名称为空") }
                return true
            }
            guard trimmed.hasPrefix("description:") || trimmed.hasPrefix("desc:") else { return false }
            let prefix = trimmed.hasPrefix("description:") ? "description:" : "desc:"
            description = WorkflowParser.value(after: prefix, in: trimmed)
            return true
        }

        private mutating func handleStepStart(trimmed: String) -> Bool {
            guard trimmed.hasPrefix("- step:") || trimmed.hasPrefix("- name:") else { return false }
            flushStep()
            let prefix = trimmed.hasPrefix("- step:") ? "- step:" : "- name:"
            currentStep = StepDraft(name: WorkflowParser.value(after: prefix, in: trimmed))
            return true
        }

        private mutating func handleStepField(trimmed: String, lineNum: Int) -> Bool {
            if handleToolField(trimmed: trimmed, lineNum: lineNum) { return true }
            if handlePromptField(trimmed: trimmed) { return true }
            if handleFailureOrConditionField(trimmed: trimmed, lineNum: lineNum) { return true }
            return trimmed.hasPrefix("params:")
        }

        private mutating func handleToolField(trimmed: String, lineNum: Int) -> Bool {
            guard trimmed.hasPrefix("tool:") else { return false }
            currentStep?.tool = WorkflowParser.value(after: "tool:", in: trimmed)
            if currentStep?.tool.isEmpty == true {
                errors.append("第 \(lineNum) 行：步骤「\(currentStep?.name ?? "")」的工具名为空")
            }
            return true
        }

        private mutating func handlePromptField(trimmed: String) -> Bool {
            guard trimmed.hasPrefix("prompt:") else { return false }
            let prompt = WorkflowParser.value(after: "prompt:", in: trimmed)
            if prompt == "|" || prompt == "|-" {
                promptMode = true
                promptLines = []
            } else {
                currentStep?.prompt = prompt
            }
            return true
        }

        private mutating func handleFailureOrConditionField(trimmed: String, lineNum: Int) -> Bool {
            if handleFailureField(trimmed: trimmed, lineNum: lineNum) { return true }
            guard trimmed.hasPrefix("condition:") || trimmed.hasPrefix("when:") else { return false }
            currentStep?.condition = WorkflowParser.value(
                after: trimmed.hasPrefix("condition:") ? "condition:" : "when:",
                in: trimmed
            )
            return true
        }

        private mutating func handleFailureField(trimmed: String, lineNum: Int) -> Bool {
            guard trimmed.hasPrefix("on_failure:") || trimmed.hasPrefix("onFailure:") else { return false }
            let prefix = trimmed.hasPrefix("on_failure:") ? "on_failure:" : "onFailure:"
            let val = WorkflowParser.value(after: prefix, in: trimmed)
            if !["abort", "skip", "retry", "stop", "continue"].contains(val.lowercased()) {
                errors.append("第 \(lineNum) 行：on_failure 值「\(val)」无效，应为 abort/skip/retry")
            }
            currentStep?.onFailure = val
            return true
        }

        private mutating func handleParamLine(rawLine: String, trimmed: String, lineNum: Int) -> Bool {
            guard rawLine.hasPrefix("  ") || rawLine.hasPrefix("\t") else { return false }
            guard let eqRange = trimmed.range(of: ":") else {
                errors.append("第 \(lineNum) 行：参数格式错误，应为 key: value")
                return true
            }
            let key = String(trimmed[..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[eqRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty {
                currentStep?.params[key] = value
            }
            return true
        }

        private mutating func validateRequiredFields() {
            if name.isEmpty {
                errors.insert("工作流缺少名称（name 字段）", at: 0)
            }
            if steps.isEmpty && name.isEmpty {
                errors.insert("工作流内容为空或格式不正确", at: 0)
            } else if steps.isEmpty {
                errors.append("工作流「\(name)」没有有效步骤")
            }
        }
    }

    private static func value(after prefix: String, in line: String) -> String {
        String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}

// MARK: - Workflow Library

public class WorkflowLibrary {
    public init() {}
    public static func available(workspaceRoot: String) -> [WorkflowDefinition] {
        var workflows = BuiltinWorkflows.all
        for workflow in loadCustomWorkflows(workspaceRoot: workspaceRoot)
        where !workflows.contains(where: { $0.name == workflow.name }) {
            workflows.append(workflow)
        }
        return workflows
    }

    public static func find(named name: String, workspaceRoot: String) -> WorkflowDefinition? {
        available(workspaceRoot: workspaceRoot).first { $0.name == name }
    }

    /// Shared instance for accessing instance-level state like lastLoadErrors
    public static let shared = WorkflowLibrary()
    public private(set) var lastLoadErrors: [String] = []

    public func clearLoadErrors() { lastLoadErrors = [] }
    public func appendLoadError(_ error: String) { lastLoadErrors.append(error) }

    public static func loadCustomWorkflows(workspaceRoot: String) -> [WorkflowDefinition] {
        shared.clearLoadErrors()
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return [] }

        let dirs = [
            (root as NSString).appendingPathComponent(".laicai/workflows"),
            (root as NSString).appendingPathComponent(".windsurf/workflows"),
        ]
        let manager = FileManager.default
        var workflows: [WorkflowDefinition] = []

        for dir in dirs where manager.fileExists(atPath: dir) {
            guard
                let urls = try? manager.contentsOfDirectory(
                    at: URL(fileURLWithPath: dir),
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            for url in urls where ["yaml", "yml"].contains(url.pathExtension.lowercased()) {
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let (definition, errors) = WorkflowParser.parseWithErrors(source)
                if let definition {
                    var workflow = definition
                    workflow.isBuiltin = false
                    workflows.append(workflow)
                }
                if !errors.isEmpty {
                    let fileName = url.lastPathComponent
                    for error in errors {
                        shared.appendLoadError("\(fileName)：\(error)")
                    }
                }
            }
        }

        return workflows.sorted { $0.name < $1.name }
    }
}

// MARK: - Step Executor

@MainActor
public struct StepExecutor {
    private struct LLMStepExecutionContext {
        let taskContext: TaskContext
        let runtime: (any ChatRuntimeClient)?
        let connector: ConnectorProfile?
        let accumulatedResults: [String]
    }

    /// Execute a single workflow step
    public static func executeStep(
        _ step: WorkflowStep,
        context: TaskContext,
        registry: ToolRegistry? = nil,
        runtime: (any ChatRuntimeClient)? = nil,
        connector: ConnectorProfile? = nil,
        accumulatedResults: [String] = [],
        userParams: [String: String] = [:],
        onStreamDelta: @Sendable @MainActor (String) -> Void = { _ in }
    ) async -> ToolResult {
        let renderedStep = render(step: step, context: context, accumulatedResults: accumulatedResults, userParams: userParams)
        let registry = registry ?? .shared

        // "llm" is a special tool type for LLM decision nodes
        if renderedStep.tool == "llm" {
            return await executeLLMStep(
                step: renderedStep,
                execution: LLMStepExecutionContext(
                    taskContext: context,
                    runtime: runtime,
                    connector: connector,
                    accumulatedResults: accumulatedResults
                ),
                onStreamDelta: onStreamDelta
            )
        }

        // Regular tool execution
        guard let tool = registry.tool(named: renderedStep.tool) else {
            return ToolResult(output: "未找到工具：\(renderedStep.tool)", success: false, error: "tool_not_found")
        }

        // Skip file tools when required path param is empty (unresolved template var)
        if ["file.read", "file.write", "file.edit", "diff.apply"].contains(ToolNameCodec.canonicalName(renderedStep.tool)) {
            let pathVal = (renderedStep.params["path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if pathVal.isEmpty {
                return ToolResult(output: "跳过：未指定目标文件路径。", success: true)
            }
        }

        let (result, validation) = await ValidationEngine.executeWithValidation(
            tool: tool,
            params: renderedStep.params,
            context: context
        )

        if !validation.isValid, let onFailure = renderedStep.onFailure {
            switch onFailure {
            case "skip":
                return ToolResult(output: "步骤跳过（验证失败）", success: true)
            case "abort":
                return ToolResult(output: "工作流中止：\(validation.error ?? "验证失败")", success: false, error: validation.error)
            case "retry":
                let retry = await ValidationEngine.executeWithValidation(
                    tool: tool,
                    params: renderedStep.params,
                    context: context,
                    maxRetries: 1
                )
                return retry.result
            default:
                return result
            }
        }

        return result
    }

    private static func render(step: WorkflowStep, context: TaskContext, accumulatedResults: [String], userParams: [String: String] = [:])
        -> WorkflowStep
    {
        var rendered = step
        let results = accumulatedResults.joined(separator: "\n\n---\n\n")
        let previous = accumulatedResults.last ?? ""
        rendered.params = step.params.mapValues { value in
            renderTemplate(value, context: context, results: results, previous: previous, userParams: userParams)
        }
        rendered.prompt = step.prompt.map {
            renderTemplate($0, context: context, results: results, previous: previous, userParams: userParams)
        }
        return rendered
    }

    private static func renderTemplate(
        _ value: String, context: TaskContext, results: String, previous: String, userParams: [String: String] = [:]
    ) -> String {
        var out =
            value
            .replacingOccurrences(of: "{{results}}", with: results)
            .replacingOccurrences(of: "{{previous.output}}", with: previous)
            .replacingOccurrences(of: "{{workspace}}", with: context.workspaceRoot)
            .replacingOccurrences(of: "{{vault}}", with: context.vaultRoot ?? "")
        // Substitute user-provided params
        for (key, val) in userParams {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: val)
        }
        // Strip any remaining unresolved {{...}} placeholders to empty string
        if let regex = try? NSRegularExpression(pattern: "\\{\\{[^}]+\\}\\}", options: []) {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Execute an LLM decision node step
    private static func executeLLMStep(
        step: WorkflowStep,
        execution: LLMStepExecutionContext,
        onStreamDelta: @Sendable @MainActor (String) -> Void
    ) async -> ToolResult {
        guard let runtime = execution.runtime, let connector = execution.connector else {
            return ToolResult(
                output: "LLM 步骤需要有效的连接器",
                success: false,
                error: "no_connector"
            )
        }

        // Build prompt from step config or use default analysis prompt
        let prompt: String
        if let stepPrompt = step.prompt {
            // Substitute variables: {{results}}, {{context}}, etc.
            prompt =
                stepPrompt
                .replacingOccurrences(of: "{{results}}", with: execution.accumulatedResults.joined(separator: "\n\n---\n\n"))
                .replacingOccurrences(of: "{{context}}", with: execution.taskContext.workspaceRoot)
        } else {
            // Default analysis prompt
            prompt = """
                基于以下信息，分析代码问题并给出建议：

                工作区：\(execution.taskContext.workspaceRoot)

                已收集信息：
                \(execution.accumulatedResults.joined(separator: "\n\n"))

                请：
                1. 总结发现的问题
                2. 分析根本原因
                3. 提出具体的修复建议
                """
        }

        // Send to LLM
        let request = SendMessageRequest(
            sessionID: UUID(),
            message: prompt,
            connector: connector,
            modeLabel: "构建",
            systemPrompt: PromptComposer.composeSystemPrompt(context: execution.taskContext, intent: .workflow("analysis"))
        )

        do {
            let response = try await runtime.sendMessageStream(request, onChunk: onStreamDelta)
            return ToolResult(
                output: response.assistantText,
                data: ["step": step.name]
            )
        } catch {
            return ToolResult(
                output: "LLM 分析失败：\(error.localizedDescription)",
                success: false,
                error: error.localizedDescription
            )
        }
    }

    /// Progress info emitted per-step
    public struct StepProgress: Sendable {
        public let stepIndex: Int
        public let totalSteps: Int
        public let stepName: String
        public let taskStep: TaskStep
    }

    /// Execute a complete workflow
    public static func executeWorkflow(
        _ workflow: WorkflowDefinition,
        context: TaskContext,
        connector: ConnectorProfile? = nil,
        runtime: (any ChatRuntimeClient)? = nil,
        registry: ToolRegistry? = nil,
        userParams: [String: String] = [:],
        onStepProgress: @MainActor (StepProgress) -> Void = { _ in },
        onStreamDelta: @Sendable @MainActor (String) -> Void = { _ in }
    ) async -> [TaskStep] {
        let registry = registry ?? .shared
        var taskSteps: [TaskStep] = []
        var accumulatedResults: [String] = []
        var hadFailure = false
        var aborted = false
        var previousSuccess = true

        // Workflow start step
        let startStep = TaskStep(
            kind: .aiThinking,
            text: "开始工作流：\(workflow.name)（\(workflow.steps.count) 步）",
            isCollapsible: false
        )
        taskSteps.append(startStep)
        onStepProgress(StepProgress(stepIndex: 0, totalSteps: workflow.steps.count, stepName: "初始化", taskStep: startStep))

        for (index, step) in workflow.steps.enumerated() {
            if !shouldRun(step: step, previousSuccess: previousSuccess) {
                let skipStep = TaskStep(
                    kind: .aiThinking,
                    text: "跳过步骤：\(step.name)",
                    isCollapsible: true,
                    isCollapsed: true
                )
                taskSteps.append(skipStep)
                onStepProgress(StepProgress(stepIndex: index, totalSteps: workflow.steps.count, stepName: step.name, taskStep: skipStep))
                continue
            }

            let toolCallStep = TaskStep(
                kind: .toolCall,
                text: "\(workflow.name) → \(step.name)  [\(index + 1)/\(workflow.steps.count)]",
                toolName: step.tool,
                toolParams: step.params,
                isCollapsible: true,
                isCollapsed: false
            )
            taskSteps.append(toolCallStep)
            onStepProgress(StepProgress(stepIndex: index, totalSteps: workflow.steps.count, stepName: step.name, taskStep: toolCallStep))

            let result = await executeStep(
                step,
                context: context,
                registry: registry,
                runtime: runtime,
                connector: connector,
                accumulatedResults: accumulatedResults,
                userParams: userParams,
                onStreamDelta: onStreamDelta
            )

            // Accumulate successful results for LLM steps
            if result.success {
                accumulatedResults.append("### \(step.name)\n\(result.output)")
            }
            previousSuccess = result.success

            let resultStep = TaskStep(
                kind: .toolResult,
                text: result.success ? String(result.output.prefix(200)) : "失败：\(result.error ?? result.output)",
                toolName: step.tool,
                isCollapsible: true,
                isCollapsed: result.success,
                isFailure: !result.success
            )
            taskSteps.append(resultStep)
            onStepProgress(StepProgress(stepIndex: index, totalSteps: workflow.steps.count, stepName: step.name, taskStep: resultStep))
            if result.success, step.tool == "llm" {
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !output.isEmpty {
                    let outputStep = TaskStep(kind: .textOutput, text: output, isCollapsible: false)
                    taskSteps.append(outputStep)
                    onStepProgress(
                        StepProgress(stepIndex: index, totalSteps: workflow.steps.count, stepName: step.name, taskStep: outputStep))
                }
            }

            if !result.success && step.onFailure == "abort" {
                hadFailure = true
                aborted = true
                taskSteps.append(
                    TaskStep(
                        kind: .error,
                        text: "工作流中止：步骤 \(step.name) 失败",
                        isFailure: true,
                        recoverable: false
                    ))
                break
            }
            if !result.success {
                hadFailure = true
            }
        }

        if !hadFailure {
            taskSteps.append(
                TaskStep(
                    kind: .textOutput,
                    text: "工作流 \(workflow.name) 执行完成",
                    isCollapsible: false
                ))
        } else if !aborted {
            taskSteps.append(
                TaskStep(
                    kind: .error,
                    text: "工作流 \(workflow.name) 部分步骤失败，请检查上方失败项后重试。",
                    isFailure: true,
                    recoverable: true,
                    retryAction: "重试"
                ))
        }

        return taskSteps
    }

    private static func shouldRun(step: WorkflowStep, previousSuccess: Bool) -> Bool {
        guard let condition = step.condition?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !condition.isEmpty
        else {
            return true
        }
        switch condition {
        case "previous.success", "success", "result.success":
            return previousSuccess
        case "previous.failure", "failure", "result.failure":
            return !previousSuccess
        default:
            return true
        }
    }
}
