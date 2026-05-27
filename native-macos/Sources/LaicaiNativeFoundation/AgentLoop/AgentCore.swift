import Foundation
import LaicaiNativeDomain

// MARK: - AgentCore (Codex-style clean loop)
//
// Replaces the 2000+ line AgentLoop.run() with a minimal, Codex-style execution kernel.
//
// Core principle: the loop is ~200 lines. All orchestration noise (failure pattern
// injection, phase switching, quality gates, plan-only nudges, etc.) lives OUTSIDE
// the loop. The model sees a clean conversation: system prompt, user input,
// tool calls, tool results. Period.
//
// What lives here (safety + minimum viable execution):
//   - Send → receive → execute → loop
//   - Streaming text + reasoning
//   - Tool call dispatch and JSON-arg parsing
//   - Hard safety: max iterations, max steps, max consecutive empty, simple circuit
//     breaker (same tool+args N times → break)
//   - Steer message injection (running task can receive user follow-ups)
//   - Cancellation
//
// What does NOT live here (handled outside, around AgentCore):
//   - System prompt composition (caller passes a finished prompt)
//   - Tool set filtering (caller passes ready-to-go tool list)
//   - Failure pattern DB, skill guidance, quality gates
//   - Auto-recovery, chained tool reads, auto-verify
//   - Phase inference, phase-based model routing
//   - Working set / progress state injection
//   - Bootstrap tool calls
//   - Task finalization / learning
//
// Callers compose AgentCore inside the existing AgentLoop.run() or runPipeline().
// The first integration target is a new `runLean()` path that exercises only this
// core, so we can A/B against the existing heavy path.

/// Result of running the core loop. Callers merge `newSteps` into the task and
/// keep `messages` if they want to continue the conversation.
public struct AgentCoreResult: Sendable {
    public var newSteps: [TaskStep]
    public var messages: [ChatMessage]
    public var iterations: Int
    public var didComplete: Bool
    public var hadFailure: Bool
    public var wasTruncated: Bool
    /// Last assistant text the model produced (the final answer when didComplete is true).
    public var finalText: String

    public init(
        newSteps: [TaskStep] = [],
        messages: [ChatMessage] = [],
        iterations: Int = 0,
        didComplete: Bool = false,
        hadFailure: Bool = false,
        wasTruncated: Bool = false,
        finalText: String = ""
    ) {
        self.newSteps = newSteps
        self.messages = messages
        self.iterations = iterations
        self.didComplete = didComplete
        self.hadFailure = hadFailure
        self.wasTruncated = wasTruncated
        self.finalText = finalText
    }
}

/// Configuration knobs for AgentCore. Caller fills in based on connector + intent.
public struct AgentCoreConfig: Sendable {
    public var maxIterations: Int
    public var maxSteps: Int
    public var maxOutputTokens: Int
    public var maxConsecutiveEmpty: Int
    public var maxRepeatedToolFailures: Int
    /// Modes:
    /// - .openAIToolCalls (default): standard OpenAI-style tool_calls + role=tool messages.
    /// - .ollamaPseudoChat: some local models cannot replay role=tool; feed results back
    ///   as plain user messages instead.
    public var toolReplayMode: ToolReplayMode

    public enum ToolReplayMode: Sendable {
        case openAIToolCalls
        case ollamaPseudoChat
    }

    public init(
        maxIterations: Int = 40,
        maxSteps: Int = 120,
        maxOutputTokens: Int = 4096,
        maxConsecutiveEmpty: Int = 3,
        maxRepeatedToolFailures: Int = 3,
        toolReplayMode: ToolReplayMode = .openAIToolCalls
    ) {
        self.maxIterations = maxIterations
        self.maxSteps = maxSteps
        self.maxOutputTokens = maxOutputTokens
        self.maxConsecutiveEmpty = maxConsecutiveEmpty
        self.maxRepeatedToolFailures = maxRepeatedToolFailures
        self.toolReplayMode = toolReplayMode
    }
}

/// Codex-style minimal agent loop. Stateless: state lives in `messages` (in/out)
/// and callbacks. The instance only exists for `steer()` injection.
@MainActor
public final class AgentCore {
    public let runtime: any ChatRuntimeClient
    public let toolRegistry: ToolRegistry
    public let config: AgentCoreConfig

    private var pendingSteer: String?

    public init(
        runtime: any ChatRuntimeClient,
        toolRegistry: ToolRegistry? = nil,
        config: AgentCoreConfig = AgentCoreConfig()
    ) {
        self.runtime = runtime
        self.toolRegistry = toolRegistry ?? .shared
        self.config = config
    }

    /// Inject a follow-up user message into the running loop.
    public func steer(_ message: String) {
        pendingSteer = message
    }

    /// Run the core loop. `messages` should already contain system prompt + initial
    /// user input (and any prior conversation the caller wants to resume from).
    ///
    /// `tools` are the OpenAI-style tool definitions the model can call. Pass empty
    /// to disable tool calling.
    ///
    /// `taskID`/`context` are needed only for tool execution.
    /// All callbacks are non-escaping — they are only invoked synchronously within
    /// the awaited body of this function.
    public func run(
        taskID: UUID,
        messages: [ChatMessage],
        tools: [ToolDefinition],
        connector: ConnectorProfile,
        context: TaskContext,
        onStep: @MainActor (TaskStep) -> Void,
        onStreamDelta: @Sendable @MainActor (String) -> Void,
        onReasoningDelta: @Sendable @MainActor (String) -> Void,
        onCheckInterrupt: @MainActor () -> String?
    ) async throws -> AgentCoreResult {
        var messages = messages
        var newSteps: [TaskStep] = []
        var iteration = 0
        var didComplete = false
        var hadFailure = false
        var wasTruncated = false
        var finalText = ""
        var consecutiveEmpty = 0
        var toolFailureCounts: [String: Int] = [:]
        var brokenToolKeys: Set<String> = []

        let toolDefs = tools

        while iteration < config.maxIterations {
            try Task.checkCancellation()
            if newSteps.count >= config.maxSteps {
                hadFailure = true
                break
            }
            iteration += 1

            // ── 1. Inject steer / interrupt as a user message before sending ──
            if let steer = pendingSteer {
                pendingSteer = nil
                let step = TaskStep(
                    kind: .userInput,
                    text: steer,
                    isCollapsible: false,
                    isCollapsed: false
                )
                newSteps.append(step)
                onStep(step)
                messages.append(ChatMessage(role: "user", content: steer))
            } else if let followUp = onCheckInterrupt() {
                let step = TaskStep(
                    kind: .userInput,
                    text: followUp,
                    isCollapsible: false,
                    isCollapsed: false
                )
                newSteps.append(step)
                onStep(step)
                messages.append(ChatMessage(role: "user", content: followUp))
            }

            // ── 2. Call the model ──
            let request = SendMessageRequest(
                sessionID: taskID,
                message: "",
                connector: connector,
                modeLabel: "执行",
                systemPrompt: nil, // system prompt is already inside `messages[0]`
                tools: toolDefs.isEmpty ? nil : toolDefs,
                messages: messages,
                maxOutputTokens: config.maxOutputTokens
            )

            let response: SendMessageResponse
            do {
                response = try await runtime.sendMessageStream(
                    request,
                    onChunk: onStreamDelta,
                    onReasoningChunk: onReasoningDelta
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let step = TaskStep(
                    kind: .error,
                    text: "模型请求失败：\(error.localizedDescription)",
                    isFailure: true,
                    recoverable: true
                )
                newSteps.append(step)
                onStep(step)
                hadFailure = true
                break
            }

            // ── 3. Branch: tool calls vs text reply ──
            if response.hasToolCalls {
                consecutiveEmpty = 0

                // Surface assistant thinking/text alongside tool calls.
                let sanitizedAssistant = AgentLoop.sanitizeAssistantVisibleText(response.assistantText)
                let preface = (sanitizedAssistant.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !preface.isEmpty || response.reasoningContent != nil {
                    let step = TaskStep(
                        kind: .aiThinking,
                        text: preface,
                        isCollapsible: true,
                        reasoningContent: response.reasoningContent
                    )
                    newSteps.append(step)
                    onStep(step)
                }
                // Add assistant message to history. Ollama-style replays use a flat
                // text summary because some local models reject role=tool follow-ups.
                switch config.toolReplayMode {
                case .ollamaPseudoChat:
                    let toolNames = response.toolCalls
                        .map { ToolNameCodec.canonicalName($0.function.name) }
                        .joined(separator: ", ")
                    messages.append(ChatMessage(role: "assistant", content: "我将调用：\(toolNames)"))
                case .openAIToolCalls:
                    messages.append(ChatMessage(
                        role: "assistant",
                        content: sanitizedAssistant.text,
                        reasoningContent: response.reasoningContent,
                        toolCalls: response.toolCalls
                    ))
                }

                // Execute tools sequentially. (Parallel batches are an optimization
                // we deliberately skip in the lean path; can be reintroduced later.)
                for toolCall in response.toolCalls {
                    let apiName = toolCall.function.name
                    let toolName = ToolNameCodec.canonicalName(apiName)
                    let argumentsJSON = toolCall.function.arguments
                    let callID = toolCall.id ?? "call_\(toolName)_\(iteration)"
                    let toolParams = Self.parseParams(argumentsJSON)

                    let callStep = TaskStep(
                        kind: .toolCall,
                        text: Self.callDisplayText(toolName: toolName, params: toolParams),
                        toolName: toolName,
                        toolParams: toolParams,
                        toolCallId: callID,
                        isCollapsible: true,
                        isCollapsed: true
                    )
                    newSteps.append(callStep)
                    onStep(callStep)

                    // Circuit breaker: stop the same failing tool+target combo from
                    // running endlessly. Keep the check simple and local.
                    let cbKey = "\(toolName):\(Self.circuitTarget(params: toolParams).prefix(60))"
                    if brokenToolKeys.contains(cbKey) {
                        let result = ToolResult(
                            output: "已熔断：\(toolName) 对该参数重复失败 \(config.maxRepeatedToolFailures) 次，已停止重试。请换一种方式。",
                            success: false,
                            error: "circuit_broken"
                        )
                        Self.appendToolResultStep(
                            result: result,
                            toolName: toolName,
                            callID: callID,
                            params: toolParams,
                            replayMode: config.toolReplayMode,
                            messages: &messages,
                            newSteps: &newSteps
                        )
                        onStep(newSteps.last!)
                        hadFailure = true
                        continue
                    }

                    // Execute.
                    let result: ToolResult
                    if let tool = toolRegistry.tool(named: apiName) {
                        do {
                            result = try await tool.execute(argumentsJSON: argumentsJSON, context: context)
                        } catch {
                            result = ToolResult(
                                output: "工具执行异常：\(error.localizedDescription)",
                                success: false,
                                error: "exception"
                            )
                        }
                    } else {
                        result = ToolResult(
                            output: "未知工具：\(toolName)",
                            success: false,
                            error: "unknown_tool"
                        )
                    }

                    if !result.success {
                        toolFailureCounts[cbKey, default: 0] += 1
                        if toolFailureCounts[cbKey, default: 0] >= config.maxRepeatedToolFailures {
                            brokenToolKeys.insert(cbKey)
                        }
                        hadFailure = true
                    } else {
                        toolFailureCounts[cbKey] = 0
                    }

                    Self.appendToolResultStep(
                        result: result,
                        toolName: toolName,
                        callID: callID,
                        params: toolParams,
                        replayMode: config.toolReplayMode,
                        messages: &messages,
                        newSteps: &newSteps
                    )
                    onStep(newSteps.last!)
                }

                // Continue loop: model will see tool results and decide next action.
                continue
            }

            // ── 4. Pure text reply path ──
            let rawText = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            let promotedReasoning: String? = rawText.isEmpty
                ? response.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            let effectiveText = rawText.isEmpty ? (promotedReasoning ?? "") : rawText

            if effectiveText.isEmpty {
                consecutiveEmpty += 1
                if consecutiveEmpty >= config.maxConsecutiveEmpty {
                    let step = TaskStep(
                        kind: .error,
                        text: "模型连续 \(consecutiveEmpty) 次返回空响应，停止。",
                        isFailure: true,
                        recoverable: true
                    )
                    newSteps.append(step)
                    onStep(step)
                    hadFailure = true
                    break
                }
                // Light nudge — keep noise minimal.
                messages.append(ChatMessage(role: "user", content: "请继续：直接给出最终结果，或调用工具继续推进。"))
                continue
            }

            consecutiveEmpty = 0

            let outputStep = TaskStep(
                kind: .textOutput,
                text: effectiveText,
                isCollapsible: false,
                isCollapsed: false,
                metrics: response.metrics
            )
            newSteps.append(outputStep)
            onStep(outputStep)
            finalText = effectiveText

            if response.finishReason == "length" {
                wasTruncated = true
            }

            didComplete = !wasTruncated
            break
        }

        return AgentCoreResult(
            newSteps: newSteps,
            messages: messages,
            iterations: iteration,
            didComplete: didComplete,
            hadFailure: hadFailure,
            wasTruncated: wasTruncated,
            finalText: finalText
        )
    }

    // MARK: - Helpers

    /// Append the tool result to both the user-visible steps list and the model conversation history.
    /// The caller is responsible for invoking the `onStep` callback for the newly-appended step.
    static func appendToolResultStep(
        result: ToolResult,
        toolName: String,
        callID: String,
        params: [String: String],
        replayMode: AgentCoreConfig.ToolReplayMode,
        messages: inout [ChatMessage],
        newSteps: inout [TaskStep]
    ) {
        let displayText = result.output
        let stepTextLimit = 4000
        let stepText = displayText.count > stepTextLimit
            ? String(displayText.prefix(stepTextLimit)) + "\n\n… 共 \(displayText.count) 字，完整内容已发送给模型"
            : displayText
        let resultStep = TaskStep(
            kind: .toolResult,
            text: stepText,
            toolName: toolName,
            toolParams: params,
            toolCallId: callID,
            isCollapsible: true,
            isCollapsed: !["shell.exec", "verify.build"].contains(toolName),
            isFailure: !result.success
        )
        newSteps.append(resultStep)

        // Feed back to model.
        switch replayMode {
        case .ollamaPseudoChat:
            messages.append(ChatMessage(
                role: "user",
                content: "工具 \(toolName) 执行结果：\n\(result.output)"
            ))
        case .openAIToolCalls:
            messages.append(ChatMessage(
                role: "tool",
                content: result.output,
                toolCallId: callID
            ))
        }
    }

    /// Parse a JSON-encoded tool argument string into a flat [String: String] map for UI display.
    /// Non-string scalars are coerced to their string form; nested objects/arrays are JSON-serialized.
    static func parseParams(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
            else if let b = v as? Bool { out[k] = b ? "true" : "false" }
            else if let n = v as? NSNumber { out[k] = n.stringValue }
            else if let nested = try? JSONSerialization.data(withJSONObject: v),
                    let s = String(data: nested, encoding: .utf8) {
                out[k] = s
            }
        }
        return out
    }

    /// Build a short, user-facing label for a tool call.
    static func callDisplayText(toolName: String, params: [String: String]) -> String {
        let primary = params["path"]
            ?? params["query"]
            ?? params["command"]
            ?? params["url"]
            ?? params["name"]
            ?? ""
        if primary.isEmpty { return toolName }
        let trimmed = primary.count > 80 ? String(primary.prefix(80)) + "…" : primary
        return "\(toolName)（\(trimmed)）"
    }

    /// Generate the circuit-breaker target key (path / command / query / first-arg).
    static func circuitTarget(params: [String: String]) -> String {
        params["path"]
            ?? params["command"]
            ?? params["query"]
            ?? params["url"]
            ?? params.values.first
            ?? ""
    }
}
