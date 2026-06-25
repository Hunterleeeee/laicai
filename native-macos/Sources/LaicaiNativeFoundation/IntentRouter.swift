import Foundation
import LaicaiNativeDomain

// MARK: - Intent Router

public struct PlannerDecision: Equatable, Sendable {
    public var intent: UserIntent
    public var confidence: Double
    public var reason: String
    public var routeLabel: String
    public var expectedCapabilities: [String]
    public var needsClarification: Bool

    public init(
        intent: UserIntent,
        confidence: Double,
        reason: String,
        routeLabel: String,
        expectedCapabilities: [String],
        needsClarification: Bool = false
    ) {
        self.intent = intent
        self.confidence = confidence
        self.reason = reason
        self.routeLabel = routeLabel
        self.expectedCapabilities = expectedCapabilities
        self.needsClarification = needsClarification
    }
}

public struct IntentRouter {
    public static func classify(_ input: String) -> UserIntent {
        plan(input, includeRoutingDrift: false).intent
    }

    public static func plan(_ input: String) -> PlannerDecision {
        plan(input, includeRoutingDrift: true)
    }

    private static func plan(_ input: String, includeRoutingDrift: Bool) -> PlannerDecision {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let signals = IntentSignals(input: trimmed)
        let routed: (PlannerDecision) -> PlannerDecision = { decision in
            includeRoutingDrift ? applyRoutingDrift(decision) : decision
        }

        if signals.isCreativePromptChat {
            return PlannerDecision(
                intent: .chat,
                confidence: 0.90,
                reason: "这是创作提示词、歌曲/MV 描述或风格补充，不需要读取工作区或调用本地工具。",
                routeLabel: "会话 问答",
                expectedCapabilities: ["创作", "润色", "规划"]
            )
        }

        if signals.capabilityOnly {
            return PlannerDecision(
                intent: .chat,
                confidence: 0.86,
                reason: "这是能力确认问题，不应触发工具或工作流。",
                routeLabel: "会话 问答",
                expectedCapabilities: ["解释", "分析", "规划"]
            )
        }

        if let workflow = signals.workflow {
            return routed(PlannerDecision(
                intent: .workflow(workflow),
                confidence: 0.86,
                reason: signals.workflowReason(for: workflow),
                routeLabel: "会话 工作流",
                expectedCapabilities: signals.workflowCapabilities(for: workflow)
            ))
        }

        if signals.isResearch {
            return routed(PlannerDecision(
                intent: .task,
                confidence: 0.85,
                reason: signals.researchReason,
                routeLabel: "会话 研究",
                expectedCapabilities: ["联网检索", "整理交付"]
            ))
        }

        if signals.requestsImageGeneration {
            return routed(PlannerDecision(
                intent: .task,
                confidence: 0.84,
                reason: "用户在要求生成视觉素材，应调用图片生成能力。",
                routeLabel: "会话 图片",
                expectedCapabilities: ["生成图片", "整理交付"]
            ))
        }

        if signals.isPersonalDeviceHowToQuestion {
            return PlannerDecision(
                intent: .chat,
                confidence: 0.82,
                reason: "这是个人设备或系统设置咨询，先给操作建议，不默认搜索当前项目或执行本地命令。",
                routeLabel: "会话 问答",
                expectedCapabilities: ["解释", "操作建议", "风险提示"]
            )
        }

        if signals.shouldInspectBeforeActing, signals.prefersAnalysisOnly {
            return routed(PlannerDecision(
                intent: .task,
                confidence: 0.80,
                reason: "用户要求理解/诊断/评估实际对象，但表达为建议、方案或只读分析。先读证据，再给结论；不默认修改文件。",
                routeLabel: "会话 分析",
                expectedCapabilities: signals.expectedCapabilities
            ))
        }

        if signals.requiresExecution {
            return routed(PlannerDecision(
                intent: .task,
                confidence: signals.executionConfidence,
                reason: signals.executionReason,
                routeLabel: "会话 执行",
                expectedCapabilities: signals.expectedCapabilities
            ))
        }

        if signals.shouldInspectBeforeActing {
            return routed(PlannerDecision(
                intent: .task,
                confidence: 0.80,
                reason: "用户要求理解/诊断/评估实际对象。先读证据，再继续形成可执行结论或落地修改；只有用户明确说只分析/先别改时才停止在建议层。",
                routeLabel: signals.prefersAnalysisOnly ? "会话 分析" : "会话 执行",
                expectedCapabilities: signals.expectedCapabilities
            ))
        }

        if signals.isQuestion && !signals.requestsAction {
            return routed(PlannerDecision(
                intent: .chat,
                confidence: 0.82,
                reason: "这是能力、概念或判断类问题，不需要立即调用工具。",
                routeLabel: "会话 问答",
                expectedCapabilities: ["解释", "分析", "规划"]
            ))
        }

        if signals.requestsAction {
            return routed(PlannerDecision(
                intent: .task,
                confidence: 0.68,
                reason: "用户希望产出具体结果，但没有匹配到专门工作流。",
                routeLabel: "会话 执行",
                expectedCapabilities: signals.expectedCapabilities
            ))
        }

        // Ambiguous input should stay lightweight. Tool execution is opt-in through
        // concrete action, project/file, web, generation, or workflow signals.
        return PlannerDecision(
            intent: .chat,
            confidence: 0.64,
            reason: "没有检测到明确的执行、文件、项目、联网或生成信号，先作为轻量问答处理，避免误开任务和误用工具。",
            routeLabel: "会话 问答",
            expectedCapabilities: ["解释", "澄清", "规划"]
        )
    }

    /// Apply routing drift correction from historical outcome data.
    /// If a route historically has high cancel/fail rate, reduce confidence;
    /// if it performs well, slightly boost confidence.
    private static func applyRoutingDrift(_ decision: PlannerDecision) -> PlannerDecision {
        let outcomes = TaskOutcomeRecorder.shared.stats(days: 7)
        guard let suggestion = ResultEvaluator.suggestRoutingAdjustment(
            outcomes: outcomes,
            intent: decision.intent,
            currentRouteLabel: decision.routeLabel
        ) else { return decision }

        var adjusted = decision
        switch suggestion.direction {
        case .relax:
            // Historical high cancel rate → reduce confidence so downstream may reconsider
            adjusted.confidence = max(0.3, adjusted.confidence - 0.15 * suggestion.confidence)
            adjusted.reason += " [路由漂移纠偏：\(suggestion.reason)]"
        case .reclassify:
            // Historically poor fit → significantly reduce confidence
            adjusted.confidence = max(0.3, adjusted.confidence - 0.25 * suggestion.confidence)
            adjusted.reason += " [路由漂移纠偏：\(suggestion.reason)]"
        case .tighten:
            // Historically under-performing → slightly boost
            adjusted.confidence = min(0.95, adjusted.confidence + 0.05)
        case .keep:
            // Working well — slight confidence boost
            adjusted.confidence = min(0.95, adjusted.confidence + 0.03)
        }
        return adjusted
    }
}
