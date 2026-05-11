import Foundation
import LaicaiNativeDomain

// MARK: - Workflow Parameter (user-facing input)

public struct WorkflowParam: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var key: String        // maps to step param key or template variable
    public var label: String      // display label
    public var placeholder: String
    public var kind: ParamKind
    public var required: Bool
    public var defaultValue: String

    public enum ParamKind: String, Codable, Sendable, Equatable {
        case text          // free text
        case filePath      // file chooser
        case directoryPath // directory chooser
        case choice        // predefined options (comma-sep in defaultValue)
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
    case review     // code review
    case generate   // test-gen, doc-gen
    case debug      // debug
    case refactor   // refactor
    case transform  // translate, format
    case product    // PM: PRD, user stories, competitive analysis
    case project    // project management: release planning, retrospective
    case custom     // user-defined

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
        case .review: return "3B82F6"    // blue
        case .generate: return "10B981"  // green
        case .debug: return "EF4444"     // red
        case .refactor: return "8B5CF6"  // purple
        case .transform: return "F59E0B" // amber
        case .product: return "EC4899"   // pink
        case .project: return "F97316"   // orange
        case .custom: return "06B6D4"    // teal
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
        var errors: [String] = []
        let lines = source.components(separatedBy: "\n")
        var name = ""
        var description = ""
        var steps: [WorkflowStep] = []
        var currentStep: StepDraft?
        var promptMode = false
        var promptLines: [String] = []
        var stepLineNumbers: [Int] = []

        func flushPrompt() {
            guard promptMode else { return }
            currentStep?.prompt = promptLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            promptMode = false
            promptLines = []
        }

        func flushStep() {
            flushPrompt()
            if let step = currentStep, !step.name.isEmpty, !step.tool.isEmpty {
                steps.append(step.workflowStep)
            } else if let step = currentStep {
                if step.name.isEmpty {
                    errors.append("步骤缺少名称（name 字段）")
                }
                if step.tool.isEmpty {
                    errors.append("步骤「\(step.name)」缺少工具（tool 字段）")
                }
            }
            currentStep = nil
        }

        for (index, rawLine) in lines.enumerated() {
            let lineNum = index + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if promptMode {
                if rawLine.hasPrefix("    ") || rawLine.hasPrefix("\t") {
                    promptLines.append(rawLine.replacingOccurrences(of: #"^\s{4}"#, with: "", options: .regularExpression))
                    continue
                }
                flushPrompt()
            }

            if trimmed.hasPrefix("name:"), currentStep == nil {
                name = value(after: "name:", in: trimmed)
                if name.isEmpty {
                    errors.append("第 \(lineNum) 行：工作流名称为空")
                }
            } else if trimmed.hasPrefix("description:") || trimmed.hasPrefix("desc:"), currentStep == nil {
                let prefix = trimmed.hasPrefix("description:") ? "description:" : "desc:"
                description = value(after: prefix, in: trimmed)
            } else if trimmed.hasPrefix("- step:") || trimmed.hasPrefix("- name:") {
                flushStep()
                let stepName: String
                if trimmed.hasPrefix("- step:") {
                    stepName = value(after: "- step:", in: trimmed)
                } else {
                    stepName = value(after: "- name:", in: trimmed)
                }
                currentStep = StepDraft(name: stepName)
                stepLineNumbers.append(lineNum)
            } else if trimmed.hasPrefix("tool:") {
                currentStep?.tool = value(after: "tool:", in: trimmed)
                if currentStep?.tool.isEmpty == true {
                    errors.append("第 \(lineNum) 行：步骤「\(currentStep?.name ?? "")」的工具名为空")
                }
            } else if trimmed.hasPrefix("prompt:") {
                let prompt = value(after: "prompt:", in: trimmed)
                if prompt == "|" || prompt == "|-" {
                    promptMode = true
                    promptLines = []
                } else {
                    currentStep?.prompt = prompt
                }
            } else if trimmed.hasPrefix("on_failure:") || trimmed.hasPrefix("onFailure:") {
                let val = value(after: trimmed.hasPrefix("on_failure:") ? "on_failure:" : "onFailure:", in: trimmed)
                let valid = ["abort", "skip", "retry", "stop", "continue"]
                if !valid.contains(val.lowercased()) {
                    errors.append("第 \(lineNum) 行：on_failure 值「\(val)」无效，应为 abort/skip/retry")
                }
                currentStep?.onFailure = val
            } else if trimmed.hasPrefix("condition:") || trimmed.hasPrefix("when:") {
                currentStep?.condition = value(after: trimmed.hasPrefix("condition:") ? "condition:" : "when:", in: trimmed)
            } else if trimmed.hasPrefix("params:") {
                continue
            } else if rawLine.hasPrefix("  ") || rawLine.hasPrefix("\t") {
                let paramLine = trimmed
                if let eqRange = paramLine.range(of: ":") {
                    let key = String(paramLine[..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let value = String(paramLine[eqRange.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !key.isEmpty {
                        currentStep?.params[key] = value
                    }
                } else {
                    errors.append("第 \(lineNum) 行：参数格式错误，应为 key: value")
                }
            }
        }

        flushStep()

        if name.isEmpty {
            errors.insert("工作流缺少名称（name 字段）", at: 0)
        }
        if steps.isEmpty && name.isEmpty {
            errors.insert("工作流内容为空或格式不正确", at: 0)
        } else if steps.isEmpty {
            errors.append("工作流「\(name)」没有有效步骤")
        }

        if let step = currentStep {
            if step.name.isEmpty {
                errors.append("最后一个步骤缺少名称")
            }
            if step.tool.isEmpty {
                errors.append("步骤「\(step.name)」缺少工具（tool 字段）")
            }
        }

        guard !name.isEmpty, !steps.isEmpty, errors.isEmpty else {
            return (nil, errors)
        }
        return (WorkflowDefinition(name: name, description: description, steps: steps), errors)
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
            (root as NSString).appendingPathComponent(".windsurf/workflows")
        ]
        let manager = FileManager.default
        var workflows: [WorkflowDefinition] = []

        for dir in dirs where manager.fileExists(atPath: dir) {
            guard let urls = try? manager.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in urls where ["yaml", "yml"].contains(url.pathExtension.lowercased()) {
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let (definition, errors) = WorkflowParser.parseWithErrors(source)
                if let definition {
                    var wf = definition
                    wf.isBuiltin = false
                    workflows.append(wf)
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
    /// Execute a single workflow step
    public static func executeStep(
        _ step: WorkflowStep,
        context: TaskContext,
        registry: ToolRegistry = .shared,
        runtime: (any ChatRuntimeClient)? = nil,
        connector: ConnectorProfile? = nil,
        accumulatedResults: [String] = [],
        userParams: [String: String] = [:],
        onStreamDelta: @Sendable @MainActor (String) -> Void = { _ in }
    ) async -> ToolResult {
        let renderedStep = render(step: step, context: context, accumulatedResults: accumulatedResults, userParams: userParams)

        // "llm" is a special tool type for LLM decision nodes
        if renderedStep.tool == "llm" {
            return await executeLLMStep(
                step: renderedStep,
                context: context,
                runtime: runtime,
                connector: connector,
                accumulatedResults: accumulatedResults,
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

    private static func render(step: WorkflowStep, context: TaskContext, accumulatedResults: [String], userParams: [String: String] = [:]) -> WorkflowStep {
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

    private static func renderTemplate(_ value: String, context: TaskContext, results: String, previous: String, userParams: [String: String] = [:]) -> String {
        var out = value
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
        context: TaskContext,
        runtime: (any ChatRuntimeClient)?,
        connector: ConnectorProfile?,
        accumulatedResults: [String],
        onStreamDelta: @Sendable @MainActor (String) -> Void
    ) async -> ToolResult {
        guard let runtime = runtime, let connector = connector else {
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
            prompt = stepPrompt
                .replacingOccurrences(of: "{{results}}", with: accumulatedResults.joined(separator: "\n\n---\n\n"))
                .replacingOccurrences(of: "{{context}}", with: context.workspaceRoot)
        } else {
            // Default analysis prompt
            prompt = """
            基于以下信息，分析代码问题并给出建议：

            工作区：\(context.workspaceRoot)

            已收集信息：
            \(accumulatedResults.joined(separator: "\n\n"))

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
            systemPrompt: PromptComposer.composeSystemPrompt(context: context, intent: .workflow("analysis"))
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
        registry: ToolRegistry = .shared,
        userParams: [String: String] = [:],
        onStepProgress: @MainActor (StepProgress) -> Void = { _ in },
        onStreamDelta: @Sendable @MainActor (String) -> Void = { _ in }
    ) async -> [TaskStep] {
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

            if !result.success && step.onFailure == "abort" {
                hadFailure = true
                aborted = true
                taskSteps.append(TaskStep(
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
            taskSteps.append(TaskStep(
                kind: .textOutput,
                text: "工作流 \(workflow.name) 执行完成",
                isCollapsible: false
            ))
        } else if !aborted {
            taskSteps.append(TaskStep(
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
              !condition.isEmpty else {
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

// MARK: - Built-in Workflows

public struct BuiltinWorkflows {
    public static let all: [WorkflowDefinition] = [
        codeReview,
        testGen,
        debug,
        refactor,
        docGen,
        translate,
        securityAudit,
        performanceAudit,
        changelog,
        projectOnboarding,
        codeCleanup,
        apiDesign,
        dependencyAudit,
        i18nScan,
        gitSummary,
        migrationPlan,
        // Product & Project
        prdGen,
        userStoryBreakdown,
        competitiveAnalysis,
        releasePlan,
        feedbackAnalysis,
        retrospective
    ]

    public static let codeReview = WorkflowDefinition(
        name: "code-review",
        description: "代码审查：读取变更文件，分析问题，给出建议",
        steps: [
            WorkflowStep(name: "获取变更统计", tool: "git", params: ["subcommand": "diff", "args": "--stat"], onFailure: "abort"),
            WorkflowStep(name: "读取变更详情", tool: "git", params: ["subcommand": "diff"], onFailure: "abort"),
            WorkflowStep(name: "搜索相关测试", tool: "code.search", params: ["query": "test", "scope": "files"], onFailure: "skip"),
            WorkflowStep(
                name: "分析代码质量",
                tool: "llm",
                prompt: """
                请审查以下代码变更，关注：
                1. 潜在 bug 或逻辑错误
                2. 代码风格和最佳实践
                3. 性能问题
                4. 测试覆盖

                变更信息：
                {{results}}

                给出具体的改进建议。
                """
            ),
        ],
        isBuiltin: true,
        category: .review,
        inputParams: [
            WorkflowParam(key: "branch", label: "分支", placeholder: "留空则审查当前工作区变更", required: false)
        ]
    )

    public static let testGen = WorkflowDefinition(
        name: "test-gen",
        description: "生成测试：读取源文件，生成对应测试文件",
        steps: [
            WorkflowStep(name: "读取源文件", tool: "file.read", params: ["path": "{{target_file}}"]),
            WorkflowStep(name: "搜索已有测试", tool: "code.search", params: ["query": "test", "scope": "files"], onFailure: "skip"),
            WorkflowStep(
                name: "生成测试代码",
                tool: "llm",
                prompt: """
                基于以下源代码，生成单元测试：

                源代码：
                {{results}}

                要求：
                1. 覆盖主要功能和边界情况
                2. 使用项目的测试框架
                3. 测试命名清晰

                输出完整的测试文件内容。
                """
            ),
        ],
        isBuiltin: true,
        category: .generate,
        inputParams: [
            WorkflowParam(key: "target_file", label: "源文件", placeholder: "选择要生成测试的文件", kind: .filePath)
        ]
    )

    public static let debug = WorkflowDefinition(
        name: "debug",
        description: "调试：搜索错误信息，定位相关代码，分析原因",
        steps: [
            WorkflowStep(name: "搜索错误", tool: "code.search", params: ["query": "{{error_keyword}}", "scope": "content"]),
            WorkflowStep(name: "查看 git 状态", tool: "git", params: ["subcommand": "status"]),
            WorkflowStep(name: "查看最近变更", tool: "git", params: ["subcommand": "log", "args": "--oneline -10"]),
            WorkflowStep(
                name: "分析错误原因",
                tool: "llm",
                prompt: """
                分析以下错误和代码变更，找出可能的原因：

                收集信息：
                {{results}}

                请：
                1. 定位错误源头
                2. 分析根本原因
                3. 提出修复方案
                """
            ),
        ],
        isBuiltin: true,
        category: .debug,
        inputParams: [
            WorkflowParam(key: "error_keyword", label: "错误关键词", placeholder: "输入要搜索的错误信息", defaultValue: "error")
        ]
    )

    public static let refactor = WorkflowDefinition(
        name: "refactor",
        description: "重构：读取文件，分析结构，提出重构方案",
        steps: [
            WorkflowStep(name: "建立项目索引", tool: "workspace.index", params: [:], onFailure: "skip"),
            WorkflowStep(name: "读取目标文件", tool: "file.read", params: ["path": "{{target_file}}"], onFailure: "skip"),
            WorkflowStep(name: "搜索引用", tool: "code.search", params: ["query": "", "scope": "content"], onFailure: "skip"),
            WorkflowStep(
                name: "提出重构方案",
                tool: "llm",
                prompt: """
                分析以下代码，提出重构建议：

                代码：
                {{results}}

                关注：
                1. 减少重复代码
                2. 提高可读性
                3. 遵循 SOLID 原则
                4. 保持向后兼容

                给出具体的重构步骤和代码示例。
                """
            ),
        ],
        isBuiltin: true,
        category: .refactor,
        inputParams: [
            WorkflowParam(key: "target_file", label: "目标文件", placeholder: "选择要重构的文件", kind: .filePath)
        ]
    )

    public static let docGen = WorkflowDefinition(
        name: "doc-gen",
        description: "文档生成：读取源文件，生成文档注释和 README",
        steps: [
            WorkflowStep(name: "读取源文件", tool: "file.read", params: ["path": "{{target_file}}"]),
            WorkflowStep(name: "搜索现有文档", tool: "code.search", params: ["query": "README", "scope": "files"], onFailure: "skip"),
            WorkflowStep(
                name: "生成文档",
                tool: "llm",
                prompt: """
                为以下代码生成文档：

                代码：
                {{results}}

                要求：
                1. 生成清晰的文档注释
                2. 包含使用示例
                3. 说明参数和返回值
                4. 符合项目的文档风格

                输出文档内容。
                """
            ),
        ],
        isBuiltin: true,
        category: .generate,
        inputParams: [
            WorkflowParam(key: "target_file", label: "源文件", placeholder: "选择要生成文档的文件", kind: .filePath)
        ]
    )

    public static let translate = WorkflowDefinition(
        name: "translate",
        description: "翻译：读取文件，将内容翻译为目标语言",
        steps: [
            WorkflowStep(name: "读取源文件", tool: "file.read", params: ["path": "{{target_file}}"]),
            WorkflowStep(
                name: "翻译内容",
                tool: "llm",
                prompt: """
                将以下内容翻译为{{target_language}}：

                原文：
                {{results}}

                保持原文的格式和结构。
                """
            ),
        ],
        isBuiltin: true,
        category: .transform,
        inputParams: [
            WorkflowParam(key: "target_file", label: "源文件", placeholder: "选择要翻译的文件", kind: .filePath),
            WorkflowParam(key: "target_language", label: "目标语言", placeholder: "例如：English, 日本語", kind: .choice, defaultValue: "English,日本語,한국어")
        ]
    )

    // MARK: - Security Audit

    public static let securityAudit = WorkflowDefinition(
        name: "security-audit",
        description: "安全审计：扫描代码中的安全隐患和敏感信息泄露",
        steps: [
            WorkflowStep(name: "搜索硬编码密钥", tool: "code.search", params: ["query": "password|secret|api_key|token|credential", "scope": "content"]),
            WorkflowStep(name: "搜索不安全函数", tool: "code.search", params: ["query": "eval|exec|innerHTML|dangerouslySetInnerHTML|subprocess", "scope": "content"], onFailure: "skip"),
            WorkflowStep(name: "检查依赖文件", tool: "code.search", params: ["query": "package.json|Podfile|Gemfile|requirements.txt|Cargo.toml", "scope": "files"], onFailure: "skip"),
            WorkflowStep(name: "查看 gitignore", tool: "file.read", params: ["path": "{{workspace}}/.gitignore"], onFailure: "skip"),
            WorkflowStep(
                name: "安全分析",
                tool: "llm",
                prompt: """
                基于以下扫描结果，进行安全审计：

                {{results}}

                请检查：
                1. 硬编码的密钥、密码、Token
                2. 不安全的函数调用（eval、exec 等）
                3. SQL 注入、XSS 风险
                4. .gitignore 是否遗漏敏感文件
                5. 依赖项是否有已知漏洞

                按严重程度（高/中/低）分类列出问题，并给出修复建议。
                """
            ),
        ],
        isBuiltin: true,
        category: .review,
        inputParams: []
    )

    // MARK: - Performance Audit

    public static let performanceAudit = WorkflowDefinition(
        name: "performance-audit",
        description: "性能审计：分析代码性能瓶颈，提出优化建议",
        steps: [
            WorkflowStep(name: "读取目标文件", tool: "file.read", params: ["path": "{{target_file}}"]),
            WorkflowStep(name: "搜索性能敏感模式", tool: "code.search", params: ["query": "for.*in|while|forEach|map|filter|reduce|async.*await|Promise", "scope": "content"], onFailure: "skip"),
            WorkflowStep(name: "搜索缓存使用", tool: "code.search", params: ["query": "cache|memoize|lazy|debounce|throttle", "scope": "content"], onFailure: "skip"),
            WorkflowStep(
                name: "性能分析",
                tool: "llm",
                prompt: """
                分析以下代码的性能：

                {{results}}

                请关注：
                1. 时间复杂度过高的算法（O(n²) 或更差）
                2. 不必要的重复计算
                3. 内存泄漏风险
                4. 可以利用缓存/惰性求值的场景
                5. 异步操作的并发优化空间
                6. 大数据量下的性能瓶颈

                给出具体的优化建议和代码示例。
                """
            ),
        ],
        isBuiltin: true,
        category: .review,
        inputParams: [
            WorkflowParam(key: "target_file", label: "目标文件", placeholder: "选择要分析性能的文件", kind: .filePath)
        ]
    )

    // MARK: - Changelog

    public static let changelog = WorkflowDefinition(
        name: "changelog",
        description: "变更日志：从 Git 历史生成结构化的 CHANGELOG",
        steps: [
            WorkflowStep(name: "获取最近提交", tool: "git", params: ["subcommand": "log", "args": "--oneline -30"]),
            WorkflowStep(name: "获取变更统计", tool: "git", params: ["subcommand": "diff", "args": "--stat {{since_tag}}"], onFailure: "skip"),
            WorkflowStep(name: "查看现有 CHANGELOG", tool: "file.read", params: ["path": "{{workspace}}/CHANGELOG.md"], onFailure: "skip"),
            WorkflowStep(
                name: "生成 CHANGELOG",
                tool: "llm",
                prompt: """
                基于以下 Git 提交历史，生成结构化的 CHANGELOG：

                {{results}}

                格式要求：
                1. 按语义分类：✨ 新功能、🐛 修复、♻️ 重构、📝 文档、🔧 配置
                2. 每条记录简洁明了
                3. 如果有现有 CHANGELOG，在其基础上追加
                4. 遵循 Keep a Changelog 格式

                输出完整的 CHANGELOG 内容。
                """
            ),
        ],
        isBuiltin: true,
        category: .generate,
        inputParams: [
            WorkflowParam(key: "since_tag", label: "起始版本", placeholder: "例如：v1.0.0（留空则使用最近30条提交）", required: false)
        ]
    )

    // MARK: - Project Onboarding

    public static let projectOnboarding = WorkflowDefinition(
        name: "project-onboarding",
        description: "项目入门：分析项目结构，生成开发者入门指南",
        steps: [
            WorkflowStep(name: "查看 README", tool: "file.read", params: ["path": "{{workspace}}/README.md"], onFailure: "skip"),
            WorkflowStep(name: "扫描项目结构", tool: "code.search", params: ["query": "", "scope": "files"]),
            WorkflowStep(name: "查看构建配置", tool: "code.search", params: ["query": "package.json|Makefile|build.sh|CMakeLists|Cargo.toml|Package.swift|*.gradle", "scope": "files"], onFailure: "skip"),
            WorkflowStep(name: "查看 Git 状态", tool: "git", params: ["subcommand": "log", "args": "--oneline -5"], onFailure: "skip"),
            WorkflowStep(
                name: "生成入门指南",
                tool: "llm",
                prompt: """
                基于以下项目信息，生成开发者入门指南：

                {{results}}

                请包含：
                1. 项目概述（做什么、技术栈）
                2. 目录结构说明
                3. 环境搭建步骤
                4. 构建和运行命令
                5. 关键模块说明
                6. 常见问题和注意事项
                7. 代码规范概要

                用简洁清晰的中文撰写。
                """
            ),
        ],
        isBuiltin: true,
        category: .generate,
        inputParams: []
    )

    // MARK: - Code Cleanup

    public static let codeCleanup = WorkflowDefinition(
        name: "code-cleanup",
        description: "代码清理：查找死代码、未使用导入、冗余逻辑",
        steps: [
            WorkflowStep(name: "读取目标文件", tool: "file.read", params: ["path": "{{target_file}}"]),
            WorkflowStep(name: "搜索引用", tool: "code.search", params: ["query": "", "scope": "content"], onFailure: "skip"),
            WorkflowStep(
                name: "分析清理项",
                tool: "llm",
                prompt: """
                分析以下代码，找出可以清理的部分：

                {{results}}

                请检查：
                1. 未使用的 import/导入
                2. 死代码（永远不会执行的分支）
                3. 注释掉的代码块
                4. 冗余的类型转换或条件判断
                5. 过时的 TODO/FIXME
                6. 可以简化的复杂表达式
                7. 重复的代码片段

                列出每个问题的位置和建议的修改方式。
                """
            ),
        ],
        isBuiltin: true,
        category: .refactor,
        inputParams: [
            WorkflowParam(key: "target_file", label: "目标文件", placeholder: "选择要清理的文件", kind: .filePath)
        ]
    )

    // MARK: - API Design

    public static let apiDesign = WorkflowDefinition(
        name: "api-design",
        description: "API 设计：根据需求生成 RESTful API 接口文档",
        steps: [
            WorkflowStep(name: "搜索现有接口", tool: "code.search", params: ["query": "router|route|endpoint|@Get|@Post|@Put|@Delete|app.get|app.post", "scope": "content"], onFailure: "skip"),
            WorkflowStep(name: "搜索数据模型", tool: "code.search", params: ["query": "struct|class|interface|schema|model|entity", "scope": "content"], onFailure: "skip"),
            WorkflowStep(
                name: "设计 API",
                tool: "llm",
                prompt: """
                基于以下现有代码和需求，设计 API 接口：

                需求：{{api_requirement}}

                现有代码参考：
                {{results}}

                请生成：
                1. 接口列表（方法、路径、描述）
                2. 每个接口的请求/响应格式（JSON Schema）
                3. 错误码定义
                4. 认证方式
                5. 分页/过滤约定
                6. 接口版本策略

                使用 OpenAPI/Swagger 兼容格式。
                """
            ),
        ],
        isBuiltin: true,
        category: .generate,
        inputParams: [
            WorkflowParam(key: "api_requirement", label: "需求描述", placeholder: "描述要设计的 API 功能")
        ]
    )

    // MARK: - Dependency Audit

    public static let dependencyAudit = WorkflowDefinition(
        name: "dependency-audit",
        description: "依赖审计：检查项目依赖的健康状况和更新建议",
        steps: [
            WorkflowStep(name: "搜索依赖文件", tool: "code.search", params: ["query": "package.json|Podfile|Gemfile|requirements.txt|Cargo.toml|Package.swift|go.mod|pom.xml", "scope": "files"]),
            WorkflowStep(name: "读取主依赖文件", tool: "file.read", params: ["path": "{{dep_file}}"]),
            WorkflowStep(name: "搜索 lock 文件", tool: "code.search", params: ["query": "package-lock|yarn.lock|Podfile.lock|Gemfile.lock|Cargo.lock|Package.resolved", "scope": "files"], onFailure: "skip"),
            WorkflowStep(
                name: "依赖分析",
                tool: "llm",
                prompt: """
                分析以下项目依赖：

                {{results}}

                请检查：
                1. 是否有已知不安全的依赖版本
                2. 主要依赖是否过时（超过 1 年未更新）
                3. 是否有可以合并或替代的重复依赖
                4. 依赖数量是否合理（是否过度依赖）
                5. 生产依赖 vs 开发依赖是否正确分类
                6. 版本锁定策略是否合理

                给出具体的更新建议和风险评估。
                """
            ),
        ],
        isBuiltin: true,
        category: .review,
        inputParams: [
            WorkflowParam(key: "dep_file", label: "依赖文件", placeholder: "选择 package.json / requirements.txt 等", kind: .filePath)
        ]
    )

    // MARK: - i18n Scan

    public static let i18nScan = WorkflowDefinition(
        name: "i18n-scan",
        description: "国际化扫描：查找硬编码字符串，生成翻译清单",
        steps: [
            WorkflowStep(name: "读取目标文件", tool: "file.read", params: ["path": "{{target_file}}"]),
            WorkflowStep(name: "搜索现有翻译", tool: "code.search", params: ["query": "i18n|locale|intl|translate|NSLocalizedString|LocalizedStringKey|t\\(|\\$t\\(", "scope": "content"], onFailure: "skip"),
            WorkflowStep(
                name: "提取翻译项",
                tool: "llm",
                prompt: """
                分析以下代码，提取需要国际化的内容：

                {{results}}

                请：
                1. 列出所有硬编码的用户可见字符串（按钮文字、提示信息、标题等）
                2. 为每个字符串生成翻译 key（遵循 feature.component.description 命名）
                3. 生成翻译文件内容（中文 + {{target_language}}）
                4. 标注哪些字符串不需要翻译（如专有名词、代码标识符）
                5. 建议项目采用的国际化框架/方案

                输出完整的翻译清单。
                """
            ),
        ],
        isBuiltin: true,
        category: .transform,
        inputParams: [
            WorkflowParam(key: "target_file", label: "目标文件", placeholder: "选择要扫描的文件", kind: .filePath),
            WorkflowParam(key: "target_language", label: "目标语言", placeholder: "翻译目标语言", kind: .choice, defaultValue: "English,日本語,한국어,Français,Deutsch")
        ]
    )

    // MARK: - Git Summary

    public static let gitSummary = WorkflowDefinition(
        name: "git-summary",
        description: "Git 摘要：总结最近的代码变更活动",
        steps: [
            WorkflowStep(name: "最近提交", tool: "git", params: ["subcommand": "log", "args": "--oneline --since={{since_days}} -50"]),
            WorkflowStep(name: "变更统计", tool: "git", params: ["subcommand": "diff", "args": "--stat HEAD~10"], onFailure: "skip"),
            WorkflowStep(name: "分支列表", tool: "git", params: ["subcommand": "branch", "args": "-a --sort=-committerdate"], onFailure: "skip"),
            WorkflowStep(name: "贡献者统计", tool: "git", params: ["subcommand": "shortlog", "args": "-sn --since={{since_days}}"], onFailure: "skip"),
            WorkflowStep(
                name: "生成摘要",
                tool: "llm",
                prompt: """
                基于以下 Git 信息，生成代码活动摘要：

                {{results}}

                请生成：
                1. 活动概览（提交数、活跃贡献者、变更文件数）
                2. 主要变更分类总结
                3. 活跃分支及其用途推测
                4. 代码趋势分析（新增 vs 删除、模块热度）
                5. 建议关注的事项
                """
            ),
        ],
        isBuiltin: true,
        category: .review,
        inputParams: [
            WorkflowParam(key: "since_days", label: "时间范围", placeholder: "例如：7.days.ago", kind: .choice, defaultValue: "1.day.ago,3.days.ago,7.days.ago,30.days.ago")
        ]
    )

    // MARK: - Migration Plan

    public static let migrationPlan = WorkflowDefinition(
        name: "migration-plan",
        description: "迁移方案：分析现有代码，制定技术迁移计划",
        steps: [
            WorkflowStep(name: "扫描项目结构", tool: "code.search", params: ["query": "", "scope": "files"]),
            WorkflowStep(name: "读取目标文件", tool: "file.read", params: ["path": "{{target_file}}"], onFailure: "skip"),
            WorkflowStep(name: "搜索依赖", tool: "code.search", params: ["query": "import|require|include|using|from", "scope": "content"], onFailure: "skip"),
            WorkflowStep(name: "查看测试", tool: "code.search", params: ["query": "test|spec|_test|Test", "scope": "files"], onFailure: "skip"),
            WorkflowStep(
                name: "生成迁移方案",
                tool: "llm",
                prompt: """
                基于以下项目信息，生成迁移方案：

                迁移目标：{{migration_goal}}

                项目现状：
                {{results}}

                请制定：
                1. 现状评估（技术栈、架构、代码量）
                2. 迁移范围和影响分析
                3. 分阶段实施计划（每阶段目标、预估工时）
                4. 风险点和缓解策略
                5. 兼容性保障措施（旧版本并行、回滚方案）
                6. 测试验证策略
                7. 数据迁移方案（如适用）

                确保方案可执行，不丢失现有功能。
                """
            ),
        ],
        isBuiltin: true,
        category: .refactor,
        inputParams: [
            WorkflowParam(key: "target_file", label: "核心文件", placeholder: "选择要迁移的核心文件（可选）", kind: .filePath, required: false),
            WorkflowParam(key: "migration_goal", label: "迁移目标", placeholder: "例如：从 UIKit 迁移到 SwiftUI")
        ]
    )

    // MARK: - PRD Generation

    public static let prdGen = WorkflowDefinition(
        name: "prd-gen",
        description: "需求文档：根据产品构想生成结构化 PRD",
        steps: [
            WorkflowStep(name: "搜索现有文档", tool: "code.search", params: ["query": "README|doc|spec|requirement|design", "scope": "files"], onFailure: "skip"),
            WorkflowStep(name: "查看项目说明", tool: "file.read", params: ["path": "{{workspace}}/README.md"], onFailure: "skip"),
            WorkflowStep(
                name: "生成 PRD",
                tool: "llm",
                prompt: """
                根据以下产品需求，生成完整的 PRD（产品需求文档）：

                **产品需求**：{{product_idea}}

                项目现有信息：
                {{results}}

                请按以下结构输出：

                ## 1. 概述
                - 产品背景和目标
                - 目标用户群体
                - 核心价值主张

                ## 2. 功能需求
                - P0（必须有）：核心功能清单
                - P1（应该有）：重要功能
                - P2（可以有）：锦上添花

                ## 3. 用户场景
                - 每个核心功能对应 1-2 个用户故事
                - 格式：作为 [角色]，我希望 [行为]，以便 [价值]

                ## 4. 交互设计要点
                - 关键页面/流程描述
                - 信息架构建议

                ## 5. 非功能性需求
                - 性能要求
                - 安全要求
                - 兼容性要求

                ## 6. 验收标准
                - 每个 P0 功能的验收条件

                ## 7. 里程碑建议
                - MVP → V1.0 → V1.1 的功能分配

                用专业但易读的中文撰写。
                """
            ),
        ],
        isBuiltin: true,
        category: .product,
        inputParams: [
            WorkflowParam(key: "product_idea", label: "产品需求", placeholder: "描述你的产品想法或功能需求")
        ]
    )

    // MARK: - User Story Breakdown

    public static let userStoryBreakdown = WorkflowDefinition(
        name: "user-story",
        description: "用户故事拆解：将需求拆分为可执行的用户故事和任务",
        steps: [
            WorkflowStep(name: "搜索现有代码结构", tool: "code.search", params: ["query": "", "scope": "files"], onFailure: "skip"),
            WorkflowStep(
                name: "拆解用户故事",
                tool: "llm",
                prompt: """
                将以下需求拆解为用户故事和开发任务：

                **需求描述**：{{requirement}}

                {{results}}

                请按以下格式输出：

                ## Epic: [需求名称]

                ### 用户故事 1: [故事标题]
                **描述**：作为 [角色]，我希望 [行为]，以便 [价值]
                **验收标准**：
                - [ ] 条件 1
                - [ ] 条件 2
                **估时**：[S/M/L/XL]
                **优先级**：[P0/P1/P2]
                **开发任务**：
                1. 前端：...
                2. 后端：...
                3. 测试：...

                ### 用户故事 2: ...

                ---

                ## 依赖关系
                - 故事 X 依赖 故事 Y

                ## 建议排期
                - Sprint 1: 故事 1, 2
                - Sprint 2: 故事 3, 4

                确保故事足够小（可在 1-3 天内完成），且相互独立。
                """
            ),
        ],
        isBuiltin: true,
        category: .product,
        inputParams: [
            WorkflowParam(key: "requirement", label: "需求描述", placeholder: "详细描述要拆解的需求")
        ]
    )

    // MARK: - Competitive Analysis

    public static let competitiveAnalysis = WorkflowDefinition(
        name: "competitive-analysis",
        description: "竞品分析：分析竞品特点，提出差异化策略",
        steps: [
            WorkflowStep(name: "查看项目说明", tool: "file.read", params: ["path": "{{workspace}}/README.md"], onFailure: "skip"),
            WorkflowStep(
                name: "竞品分析",
                tool: "llm",
                prompt: """
                进行竞品分析：

                **我们的产品**：{{our_product}}
                **竞品列表**：{{competitors}}

                项目信息：
                {{results}}

                请按以下结构输出：

                ## 1. 竞品概览
                | 维度 | 我们 | 竞品A | 竞品B | ... |
                |------|------|-------|-------|-----|
                | 定位 | | | | |
                | 核心功能 | | | | |
                | 定价 | | | | |
                | 技术栈 | | | | |
                | 用户群 | | | | |

                ## 2. 功能对比矩阵
                - 详细功能点对比（✅ 有 / ❌ 无 / 🔶 部分）

                ## 3. 竞品优劣分析
                - 每个竞品的 3 个优点 + 3 个缺点

                ## 4. 差异化机会
                - 竞品都没做好的领域
                - 我们的独特优势
                - 建议的差异化方向

                ## 5. 行动建议
                - 短期（1个月）：快速补齐的功能
                - 中期（3个月）：差异化功能
                - 长期（6个月）：护城河建设

                基于公开信息和行业认知进行分析。
                """
            ),
        ],
        isBuiltin: true,
        category: .product,
        inputParams: [
            WorkflowParam(key: "our_product", label: "我们的产品", placeholder: "简述你的产品定位和核心功能"),
            WorkflowParam(key: "competitors", label: "竞品名称", placeholder: "例如：Cursor, Windsurf, GitHub Copilot")
        ]
    )

    // MARK: - Release Plan

    public static let releasePlan = WorkflowDefinition(
        name: "release-plan",
        description: "发版计划：基于 Git 状态生成发版 checklist 和风险评估",
        steps: [
            WorkflowStep(name: "查看未合并提交", tool: "git", params: ["subcommand": "log", "args": "--oneline -20"]),
            WorkflowStep(name: "查看变更文件", tool: "git", params: ["subcommand": "diff", "args": "--stat"], onFailure: "skip"),
            WorkflowStep(name: "查看分支", tool: "git", params: ["subcommand": "branch", "args": "-a"], onFailure: "skip"),
            WorkflowStep(name: "搜索 TODO/FIXME", tool: "code.search", params: ["query": "TODO|FIXME|HACK|WORKAROUND|XXX", "scope": "content"], onFailure: "skip"),
            WorkflowStep(name: "查看 CHANGELOG", tool: "file.read", params: ["path": "{{workspace}}/CHANGELOG.md"], onFailure: "skip"),
            WorkflowStep(
                name: "生成发版计划",
                tool: "llm",
                prompt: """
                基于以下信息，生成发版计划：

                **版本号**：{{version}}

                {{results}}

                请输出：

                ## 发版概要
                - 版本号、预计发布日期
                - 本次发版的主题/重点

                ## 变更内容
                - 新功能
                - Bug 修复
                - 改进优化
                - 破坏性变更（如有）

                ## 发版 Checklist
                - [ ] 代码冻结
                - [ ] 全量回归测试
                - [ ] 性能基准测试
                - [ ] 文档更新
                - [ ] CHANGELOG 更新
                - [ ] 灰度发布
                - [ ] 监控告警配置
                - [ ] 回滚方案确认

                ## 风险评估
                - 高风险变更及缓解措施
                - 未解决的 TODO/FIXME 评估

                ## 发布后关注
                - 关键监控指标
                - 第一小时观察要点
                """
            ),
        ],
        isBuiltin: true,
        category: .project,
        inputParams: [
            WorkflowParam(key: "version", label: "版本号", placeholder: "例如：v2.0.0")
        ]
    )

    // MARK: - Feedback Analysis

    public static let feedbackAnalysis = WorkflowDefinition(
        name: "feedback-analysis",
        description: "反馈分析：整理用户反馈，提取需求和改进点",
        steps: [
            WorkflowStep(name: "读取反馈数据", tool: "file.read", params: ["path": "{{feedback_file}}"], onFailure: "skip"),
            WorkflowStep(
                name: "分析反馈",
                tool: "llm",
                prompt: """
                整理和分析以下用户反馈：

                **反馈内容**：
                {{user_feedback}}

                已有数据：
                {{results}}

                请输出：

                ## 1. 反馈分类统计
                | 类型 | 数量 | 情感倾向 |
                |------|------|----------|
                | Bug 报告 | | |
                | 功能需求 | | |
                | 使用困惑 | | |
                | 正面评价 | | |

                ## 2. 高频问题 TOP 5
                - 问题描述 + 出现频次 + 影响范围

                ## 3. 需求提取
                - P0 需求（用户强烈要求，影响留存）
                - P1 需求（多人提到，提升体验）
                - P2 需求（个别用户，锦上添花）

                ## 4. 体验优化建议
                - 当前的 UX 痛点
                - 具体改进方案

                ## 5. 积极反馈总结
                - 用户认可的功能和亮点
                - 可强化的产品优势

                ## 6. 行动项
                - 本周应修复的问题
                - 下一迭代应规划的功能
                - 需要进一步调研的方向
                """
            ),
        ],
        isBuiltin: true,
        category: .product,
        inputParams: [
            WorkflowParam(key: "user_feedback", label: "用户反馈", placeholder: "粘贴用户反馈内容（多条用换行分隔）"),
            WorkflowParam(key: "feedback_file", label: "反馈文件", placeholder: "或选择包含反馈的文件（可选）", kind: .filePath, required: false)
        ]
    )

    // MARK: - Retrospective

    public static let retrospective = WorkflowDefinition(
        name: "retrospective",
        description: "复盘总结：基于项目活动生成迭代复盘报告",
        steps: [
            WorkflowStep(name: "最近提交", tool: "git", params: ["subcommand": "log", "args": "--oneline --since={{period}} -50"]),
            WorkflowStep(name: "变更规模", tool: "git", params: ["subcommand": "diff", "args": "--shortstat HEAD~20"], onFailure: "skip"),
            WorkflowStep(name: "搜索已解决问题", tool: "code.search", params: ["query": "fix|resolve|close|完成|修复", "scope": "content"], onFailure: "skip"),
            WorkflowStep(
                name: "生成复盘报告",
                tool: "llm",
                prompt: """
                基于以下项目活动，生成迭代复盘报告：

                **复盘周期**：{{period}}

                {{results}}

                请按以下结构输出：

                ## 迭代概要
                - 时间范围、提交数、涉及文件数
                - 本迭代目标回顾

                ## ✅ 做得好的
                - 完成的功能和改进
                - 值得延续的实践
                - 团队协作亮点

                ## ❌ 需改进的
                - 遇到的问题和阻塞
                - 技术债务累积
                - 流程中的低效环节

                ## 💡 改进行动
                - 下一迭代具体改进措施
                - 流程优化建议
                - 工具/自动化建议

                ## 📊 关键指标
                - 代码变更量
                - 功能交付数
                - Bug 修复数
                - 未解决的 TODO/FIXME 数

                ## 下一迭代展望
                - 优先级最高的 3 件事
                - 风险预警
                """
            ),
        ],
        isBuiltin: true,
        category: .project,
        inputParams: [
            WorkflowParam(key: "period", label: "复盘周期", placeholder: "时间范围", kind: .choice, defaultValue: "1.week.ago,2.weeks.ago,1.month.ago")
        ]
    )

    public static func find(named name: String) -> WorkflowDefinition? {
        all.first(where: { $0.name == name })
    }
}
