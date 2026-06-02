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
                routeLabel: signals.isExplicitPlanOnly ? "会话 分析" : "会话 执行",
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

// MARK: - Frustration / Correction Signals

public struct UserFrustrationDetector {
    public static func isFrustrated(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let markers = [
            "胡说八道", "乱说", "瞎说", "不对", "错了", "又错", "还是不行",
            "没读", "没看", "没理解", "没上下文", "上下文没了", "新建会话",
            "自动创建新", "说一半", "被截断", "没发完", "别重复", "不要重复",
            "费token", "费 token", "省点token", "省点 token", "认真", "一次性",
            "卡的", "难受", "差距", "你看了吗", "你看看",
            "干活干不明白", "干不明白", "没干活", "只回答", "不干活"
        ]
        return markers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    public static func shouldRecoverRecentTask(_ input: String) -> Bool {
        guard isFrustrated(input) else { return false }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskMarkers = [
            "刚才", "最近", "上个", "上一轮", "这个会话", "那个会话", "这个任务", "那个任务",
            "上下文", "新会话", "本地项目", "读取项目", "输出", "截断", "没发完", "没说完",
            "干活", "只回答"
        ]
        return taskMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// Detect positive feedback from user (praise, satisfaction).
    /// Used to reinforce the learned skill that produced the praised output.
    public static func isPositive(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let markers = [
            "很好", "不错", "正确", "完美", "太好了", "厉害", "漂亮", "好的",
            "对了", "就这样", "可以", "没问题", "牛", "强", "感谢", "谢谢",
            "good", "great", "perfect", "nice", "awesome", "thanks", "correct",
            "exactly", "well done"
        ]
        return markers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    public static var guidance: String {
        """
        用户正在纠错或表达不满。进入证据优先修复模式：
        - 先承认当前问题，不要长篇辩解。
        - 基于已有上下文和真实工具结果回答；证据不足就明确说不足。
        - 不要重复已经失败或已经完成的搜索/读取。
        - 优先说明下一步如何修复、继续或验证。
        - 不要声称执行了未实际发生的工具调用。
        """
    }
}

// MARK: - Result Evaluator (self-evolution metrics)

public struct ResultEvaluator {
    /// Score a task outcome on a 0–100 scale for self-evolution.
    /// Higher = better user experience. Used to compare routing decisions and prompt variants.
    public static func score(
        status: TaskStatus,
        iterations: Int,
        maxIterations: Int,
        hadFailure: Bool,
        wasCancelled: Bool,
        wasTruncated: Bool,
        durationSeconds: Double,
        userFollowupCount: Int
    ) -> Int {
        var score = 100

        // Heavy penalty for cancellation or failure
        if wasCancelled { score -= 40 }
        if status == .failed { score -= 30 }
        if hadFailure { score -= 15 }

        // Penalty for truncation (incomplete output)
        if wasTruncated { score -= 10 }

        // Penalty for excessive iterations (inefficiency)
        let iterationRatio = Double(iterations) / Double(max(maxIterations, 1))
        if iterationRatio > 0.8 {
            score -= 15
        } else if iterationRatio > 0.5 {
            score -= 8
        } else if iterationRatio > 0.3 {
            score -= 3
        }

        // Penalty for long duration on simple tasks
        if durationSeconds > 120 {
            score -= Int(min(15, durationSeconds / 60))
        }

        // Penalty for user needing to follow up repeatedly
        score -= min(20, userFollowupCount * 5)

        return max(0, min(100, score))
    }

    /// Determine if an outcome suggests the routing was wrong.
    /// E.g. a simple question routed as task but then cancelled.
    public static func isRoutingMistake(
        intent: UserIntent,
        status: TaskStatus,
        wasCancelled: Bool,
        iterations: Int,
        userFollowupCount: Int
    ) -> Bool {
        // Chat intent forced into task path and then cancelled/failed quickly = likely routing mistake
        if intent == .chat && (wasCancelled || status == .failed) && iterations <= 3 {
            return true
        }
        // Read-only task that got cancelled after few iterations = might have been chat
        if wasCancelled && iterations <= 2 && userFollowupCount >= 1 {
            return true
        }
        return false
    }

    /// Convert UserIntent to string for outcome matching.
    public static func intentString(_ intent: UserIntent) -> String {
        switch intent {
        case .chat: return "chat"
        case .research: return "research"
        case .task: return "task"
        case .workflow(let name): return "workflow:\(name)"
        }
    }

    /// Suggest a routing drift direction based on recent outcome patterns.
    public static func suggestRoutingAdjustment(
        outcomes: [OutcomeStatsRow],
        intent: UserIntent,
        currentRouteLabel: String
    ) -> RoutingSuggestion? {
        let intentStr = intentString(intent)
        let relevant = outcomes.filter { $0.intent == intentStr && $0.routeLabel == currentRouteLabel }
        guard let stats = relevant.first, stats.total >= 5 else { return nil }

        let completionRate = stats.completionRate
        let cancelRate = stats.cancellationRate
        let avgIter = stats.avgIterations

        // High cancellation on a route suggests it is too aggressive
        if cancelRate > 0.4 {
            return RoutingSuggestion(
                direction: .relax,
                reason: "\(currentRouteLabel) 取消率 \(Int(cancelRate * 100))%，建议降低自动工具调用强度。",
                confidence: min(0.95, cancelRate)
            )
        }

        // Low completion with high iterations suggests task is being forced into wrong path
        if completionRate < 0.3 && avgIter > 8 {
            return RoutingSuggestion(
                direction: .reclassify,
                reason: "\(currentRouteLabel) 完成率仅 \(Int(completionRate * 100))%，平均 \(Int(avgIter)) 轮，建议重新分类意图。",
                confidence: 0.8
            )
        }

        // Very fast completions with no issues = route is working well
        if completionRate > 0.8 && avgIter < 4 {
            return RoutingSuggestion(
                direction: .keep,
                reason: "\(currentRouteLabel) 表现良好（完成率 \(Int(completionRate * 100))%，平均 \(Int(avgIter)) 轮），保持当前策略。",
                confidence: 0.9
            )
        }

        return nil
    }
}

public struct RoutingSuggestion: Sendable {
    public enum Direction: Sendable {
        case relax      // Reduce automatic tool use
        case tighten    // Increase tool use
        case reclassify // Consider different intent classification
        case keep       // Current strategy is working
    }

    public let direction: Direction
    public let reason: String
    public let confidence: Double
}

private struct IntentSignals {
    let input: String

    /// Strip negated phrases so "不用说建议" doesn't match "建议"
    private var effectiveInput: String {
        var s = input
        let negationPrefixes = ["不用说", "不用给", "不要说", "不要给", "不需要", "别给我", "别说", "不用", "不要", "别"]
        for prefix in negationPrefixes {
            // Remove "不用说建议" → removes the whole negated phrase
            if let range = s.range(of: prefix) {
                let after = s[range.upperBound...]
                // Remove up to 4 chars after the negation prefix (the negated keyword)
                let charsToRemove = min(4, after.count)
                s.removeSubrange(range.lowerBound..<s.index(range.upperBound, offsetBy: charsToRemove))
            }
        }
        return s
    }

    private var isDirectQuestion: Bool {
        let prefixes = ["什么", "为什么", "怎么", "如何", "是否", "哪里", "哪个", "多少", "能介绍", "请问", "你是", "你能", "你有", "你会"]
        let suffixes = ["吗", "么", "呢", "？", "?", "模型", "啥"]
        let contains = ["是什么", "什么是", "怎么样", "是谁", "多少", "几个", "几种", "能不能", "可不可以", "有没有"]
        return prefixes.contains(where: { input.hasPrefix($0) })
            || suffixes.contains(where: { input.hasSuffix($0) })
            || contains.contains(where: { input.contains($0) })
    }

    var isQuestion: Bool {
        isDirectQuestion
            // Short inputs without action markers are likely questions.
            || (input.count <= 15 && !hasDirectActionCue)
    }

    private var hasDirectActionCue: Bool {
        containsExplicitURLAction
            || requestsFreshInformation
            || requestsLocalIO
            || requestsShellExecution
            || requestsWikiPersistence
            || requestsMutation
            || rawRequestsWebResearch
            || requestsModelCurrentInfo
            || rawRequestedDeliverable
            || requestsPMDocument
    }

    var isCreativePromptChat: Bool {
        guard !containsLocalPath,
              !referencesOfficeDocument,
              !containsExplicitURLAction,
              !requestsShellExecution,
              !requestsLocalIO,
              !requestsMutation else { return false }

        let promptMarkers = ["prompt", "提示词", "描述词", "描述prompt", "怎么描述", "描述一下", "梳理一下", "帮我梳理", "润色"]
        let creativeTargets = ["gemini", "歌曲", "写歌", "作一首歌", "作歌", "音乐", "歌词", "mv", "视频", "短片", "画面", "风格", "电影感", "古风", "电子"]
        if promptMarkers.contains(where: { input.localizedCaseInsensitiveContains($0) })
            && creativeTargets.contains(where: { input.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        let styleWords = ["古风", "电子", "电影感", "男生", "女生", "故事", "伤感", "治愈", "热血", "赛博", "国风", "摇滚", "民谣"]
        let separators = [",", "，", "、", " "]
        let looksLikeStyleList = separators.contains(where: { input.contains($0) })
            && styleWords.filter { input.contains($0) }.count >= 2
            && input.count <= 80
        return looksLikeStyleList
    }

    var workflow: String? {
        if wantsCodeReview { return "code-review" }
        if wantsTestGeneration { return "test-gen" }
        if wantsDebugWorkflow { return "debug" }
        if wantsRefactorWorkflow { return "refactor" }
        if wantsDocumentationWorkflow { return "doc-gen" }
        if wantsTranslationWorkflow { return "translate" }
        return nil
    }

    /// Information retrieval that needs web search but NOT file writes or shell commands
    var isResearch: Bool {
        guard !requestsShellExecution, !requestsMutation, !requestsWikiPersistence else { return false }
        return requestsExternalInfo || requestsMarketSurvey || requestsRecommendation || requestsFreshInfoOnly || rawRequestsWebResearch
    }

    var researchReason: String {
        if requestsMarketSurvey { return "用户在了解市面上有什么选择，需要联网搜索获取信息。" }
        if requestsRecommendation { return "用户在请求推荐或对比，需要联网搜索获取最新信息。" }
        if requestsFreshInfoOnly { return "用户在询问新闻或时事信息，需要联网搜索获取最新信息。" }
        return "用户需要外部信息检索，需要联网搜索。"
    }

    /// Fresh information request WITHOUT any local/mutation intent — this is research, not task
    private var requestsFreshInfoOnly: Bool {
        guard requestsFreshInformation else { return false }
        return !requestsLocalIO && !requestsMutation && !requestsShellExecution
    }

    private var requestsExternalInfo: Bool {
        // Questions about external things that require web search, NOT workspace operations
        let externalMarkers = ["有什么", "有哪些", "哪些好用", "哪些好的", "市面上", "市场上", "行业", "趋势"]
        let topicMarkers = ["工具", "框架", "库", "方案", "产品", "服务", "平台", "skill", "plugin", "tool", "sdk", "api"]
        return externalMarkers.contains(where: { input.contains($0) })
            && topicMarkers.contains(where: { input.contains($0) })
    }

    private var requestsMarketSurvey: Bool {
        let strongMarkers = ["市面上", "市场上"]
        if strongMarkers.contains(where: { input.contains($0) }) { return true }
        let weakMarkers = ["有什么好用", "有什么有用", "有哪些好的", "有哪些有用", "都有什么", "都有哪些"]
        let topicMarkers = ["工具", "框架", "库", "方案", "产品", "服务", "平台", "模型", "插件", "sdk", "api", "app"]
        return weakMarkers.contains(where: { input.contains($0) })
            && topicMarkers.contains(where: { input.contains($0) })
    }

    private var requestsRecommendation: Bool {
        ["推荐", "推荐一下", "建议用", "建议用什么", "选哪个", "用哪个", "哪个好"].contains { input.contains($0) }
            && !capabilityOnly
    }

    var requiresExecution: Bool {
        input.hasPrefix("/")
            || containsLocalPath
            || referencesOfficeDocument
            || containsExplicitURLAction
            || requestsImageGeneration
            || requestsFreshInformation
            || requestsShellExecution
            || requestsWikiPersistence
            || requestsMutation
            || requestsWebResearch
            || requestsModelCurrentInfo
            || requestsPMDocument
    }

    var requestsAction: Bool {
        requestsImageGeneration
            || requestsFreshInformation
            || requestsLocalIO
            || requestsShellExecution
            || requestsWikiPersistence
            || requestsMutation
            || requestsWebResearch
            || requestsModelCurrentInfo
            || requestedDeliverable
            || referencesOfficeDocument
            || requestsPMDocument
    }

    var shouldInspectBeforeActing: Bool {
        let contextualInspection = hasInspectableLocalContext
            && (requestsDiagnosis || requestsAdvice || requestsEvaluation || requestsSummary || requestsPlanOnly || reportsInspectableProblem)
        return requestsLocalIO || contextualInspection
    }

    var isExplicitPlanOnly: Bool {
        explicitPlanOnly
    }

    var isPersonalDeviceHowToQuestion: Bool {
        guard isQuestion,
              !containsURL,
              !containsLocalPath,
              !referencesOfficeDocument,
              !codeOrProjectContext,
              !requestsWikiPersistence,
              !requestsImageGeneration,
              !requestsWebResearch,
              !requestsFreshInformation,
              !requestsModelCurrentInfo,
              !requestsPMDocument else {
            return false
        }
        let deviceMarkers = [
            "我的电脑", "电脑", "macos", "系统", "本机", "网络", "网卡", "虚拟网卡",
            "vpn", "终端", "命令行", "浏览器", "键盘", "鼠标", "显示器"
        ]
        let howToMarkers = [
            "怎么弄", "怎么设置", "如何设置", "怎么开", "如何开启", "怎么打开",
            "怎么配置", "如何配置", "应该怎么", "怎么办", "怎么用"
        ]
        let explicitExecutionMarkers = [
            "帮我运行", "帮我执行", "直接运行", "直接执行", "现在运行", "现在执行",
            "帮我安装", "直接安装", "帮我创建", "直接创建", "跑一下"
        ]
        return deviceMarkers.contains { input.localizedCaseInsensitiveContains($0) }
            && howToMarkers.contains { input.localizedCaseInsensitiveContains($0) }
            && !explicitExecutionMarkers.contains { input.localizedCaseInsensitiveContains($0) }
    }

    private var containsURL: Bool {
        input.contains("http://") || input.contains("https://")
    }

    private var containsLocalPath: Bool {
        input.range(of: #"/[^\s，。；;）)\]}>\"']+"#, options: .regularExpression) != nil
    }

    private var referencesOfficeDocument: Bool {
        input.range(of: #"[A-Za-z0-9_./\-\u{4e00}-\u{9fff}]+\.(pptx|docx|xlsx|xlsm|ppt|doc|xls)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// URL presence alone should not trigger execution. Only trigger if user explicitly
    /// wants to act on the URL (read, fetch, visit, open, download).
    private var containsExplicitURLAction: Bool {
        guard containsURL else { return false }
        let actionMarkers = ["打开", "访问", "读取", "获取", "下载", "fetch", "download", "visit", "read this", "open this", "看看这个链接", "看看这个网页", "访问一下", "打开这个"]
        return actionMarkers.contains(where: { input.contains($0) })
    }

    private var requestsFreshInformation: Bool {
        let temporal = ["今天", "今日", "最新", "刚刚", "新闻", "早间", "日报", "周报", "趋势", "现在", "近期", "本周", "本月", "2026"]
        let topics = ["新闻", "整理", "搜索", "查", "汇总", "简报", "动态", "发生", "发布", "更新", "价格", "版本"]
        return temporal.contains(where: { input.contains($0) })
            && topics.contains(where: { input.contains($0) })
    }

    private var requestsWebResearch: Bool {
        rawRequestsWebResearch && !capabilityOnly
    }

    private var rawRequestsWebResearch: Bool {
        let markers = ["联网", "上网", "网页", "官网", "搜一下", "搜搜", "查一下", "查查"]
        // "搜索" alone is too broad — "你搜索到的" refers to past results, not a web search request.
        // Only count "搜索" if it's NOT preceded by backward-referencing context.
        let hasSearchMarker = markers.contains { input.contains($0) }
        let hasPlainSearch = input.contains("搜索")
            && !["搜索到的", "搜索结果", "你搜索", "已搜索", "刚搜索"].contains(where: { input.contains($0) })
        return hasSearchMarker || hasPlainSearch
    }

    private var requestsModelCurrentInfo: Bool {
        let comparisonIntent = ["对比", "比较", "比", "能力", "强多少", "发布", "最新"].contains { input.contains($0) }
        guard comparisonIntent else { return false }
        let modelMarkers = ["qwen", "gpt", "glm", "kimi", "claude", "deepseek", "llama", "gemini", "模型"]
        if modelMarkers.contains(where: { input.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        return input.range(of: #"[a-zA-Z\u{4e00}-\u{9fff}]+[0-9]+(\.[0-9]+)?"#, options: .regularExpression) != nil
    }

    private var requestsLocalIO: Bool {
        if containsLocalPath || referencesOfficeDocument { return true }
        return ["读取", "读一下", "打开文件", "看这个文件", "这个路径", "这些路径", "搜索", "搜索项目", "搜索代码", "查找文件", "当前项目", "工作区",
         "看看项目", "看下项目", "看一下项目", "看看代码", "看下代码", "查看项目", "查看代码",
         "检查项目", "检查代码", "分析项目", "分析代码", "找到", "找一下", "定位"].contains {
            input.contains($0)
        }
    }

    private var requestsDiagnosis: Bool {
        ["诊断", "排查", "分析一下", "看下原因", "为什么", "哪里出问题", "问题在哪", "哪里不好", "不对劲", "不好用", "难用", "卡住",
         "卡顿", "卡死", "很卡", "各种卡", "慢", "很慢", "延迟", "掉帧", "性能"].contains {
            input.contains($0)
        }
    }

    private var requestsAdvice: Bool {
        ["优化建议", "怎么优化", "如何优化", "怎么改进", "如何改进", "应该怎么", "给建议", "出方案", "给思路", "看法"].contains {
            effectiveInput.contains($0)
        }
    }

    private var requestsEvaluation: Bool {
        ["评估", "评价", "review一下", "看一下质量", "优缺点", "利弊", "风险", "可行性"].contains {
            input.contains($0)
        }
    }

    private var requestsSummary: Bool {
        ["总结", "汇总", "梳理", "复盘", "整理一下", "讲清楚", "说明一下"].contains {
            input.contains($0)
        }
    }

    private var requestsPlanOnly: Bool {
        ["计划", "规划", "roadmap", "路线图", "步骤", "下一步", "先别改", "不要改", "只给建议", "只分析"].contains {
            input.contains($0)
        }
    }

    private var explicitPlanOnly: Bool {
        ["先别改", "不要改", "别改", "不用改", "只给建议", "只分析", "先只分析", "不要执行", "先不执行", "只要方案"].contains {
            input.contains($0)
        }
    }

    private var requestsShellExecution: Bool {
        ["运行", "执行命令", "跑测试", "构建", "部署", "启动服务",
         "安装", "卸载", "升级", "更新", "下载", "编译", "打包", "发布",
         "npm install", "pip install", "brew install", "cargo install", "apt install", "yarn add", "pnpm add",
         "make", "cmake", "build", "run", "setup"].contains { input.contains($0) }
    }

    private var requestsMutation: Bool {
        ["直接改", "帮我改", "修改", "写入", "创建文件", "删除文件", "添加", "增加", "实现", "修复", "改一下", "改写",
         "配置", "设置", "接入", "集成", "迁移", "替换", "重命名", "移动", "复制",
         "加入", "注册", "导入", "导出", "初始化", "保存", "另存", "翻译成", "转成",
         "改成", "换成", "改为", "调整", "改进", "优化", "优化下", "优化一下", "性能优化", "提升性能", "提速", "加速", "重写", "拆分", "合并",
         "记住", "记下", "长期记忆", "写进记忆", "保存偏好", "保存到记忆", "remember",
         "fix", "implement", "create", "add", "remove", "update", "refactor", "rewrite"].contains { input.contains($0) }
    }

    private var requestsWikiPersistence: Bool {
        RoutingTextHeuristics.requestsWikiPersistence(input)
    }

    private var requestedDeliverable: Bool {
        rawRequestedDeliverable && !capabilityOnly
    }

    private var rawRequestedDeliverable: Bool {
        ["生成", "创建", "整理", "汇总", "给我一份", "写一个", "写一份", "写一段", "做一个"].contains { input.contains($0) }
    }

    var requestsImageGeneration: Bool {
        guard !capabilityOnly else { return false }
        return RoutingTextHeuristics.requestsImageGeneration(input)
    }

    private var requestsPMDocument: Bool {
        let pmMarkers = ["prd", "PRD", "需求文档", "产品需求", "用户故事", "user story", "user stories",
                         "竞品分析", "竞品调研", "competitive analysis", "实验设计", "a/b test", "ab test",
                         "okr", "OKR", "复盘", "retrospective", "用户画像", "persona",
                         "上线清单", "launch checklist", "发版说明", "release notes",
                         "jtbd", "JTBD", "验收标准", "acceptance criteria",
                         "边界用例", "edge case", "方案简述", "solution brief",
                         "架构决策", "adr", "ADR", "问题定义", "problem statement",
                         "假设验证", "hypothesis", "干系人汇报"]
        return pmMarkers.contains { input.localizedCaseInsensitiveContains($0) }
    }

    private var wantsCodeReview: Bool {
        let reviewMarkers = ["代码审查", "审查代码", "review", "审查", "看下改动", "看一下改动", "检查改动"]
        guard reviewMarkers.contains(where: { input.contains($0) }) else { return false }
        return codeOrProjectContext
    }

    private var wantsTestGeneration: Bool {
        let testMarkers = ["生成测试", "写测试", "补测试", "测试用例", "单元测试"]
        guard testMarkers.contains(where: { input.contains($0) }) else { return false }
        return codeOrProjectContext || input.contains("这个模块") || input.contains("这个函数")
    }

    private var wantsDebugWorkflow: Bool {
        let debugMarkers = ["调试", "诊断", "排查", "排查报错", "分析报错", "定位报错", "这个报错"]
        guard debugMarkers.contains(where: { input.contains($0) }) else { return false }
        return codeOrProjectContext || input.contains("日志") || input.contains("堆栈") || input.contains("异常") || input.contains("报错") || input.contains("crash")
    }

    private var wantsRefactorWorkflow: Bool {
        let refactorMarkers = ["重构", "优化结构"]
        guard refactorMarkers.contains(where: { input.contains($0) }) else { return false }
        return codeOrProjectContext
    }

    private var wantsDocumentationWorkflow: Bool {
        let docMarkers = ["生成文档", "写文档", "补文档", "接口文档"]
        guard docMarkers.contains(where: { input.contains($0) }) else { return false }
        return codeOrProjectContext || input.contains("readme")
    }

    private var wantsTranslationWorkflow: Bool {
        let translateMarkers = ["翻译文件", "翻译这个文件", "翻译成", "转成英文", "英文版", "国际化", "i18n", "本地化"]
        return translateMarkers.contains { input.contains($0) } && (codeOrProjectContext || containsLocalPath || referencesOfficeDocument)
    }

    private var codeOrProjectContext: Bool {
        let markers = [
            "代码", "项目", "文件", "模块", "函数", "类", "组件", "接口", "仓库",
            "diff", "commit", "pr", "分支", "变更", "改动", ".swift", ".ts", ".tsx",
            ".js", ".py", ".md", ".pptx", ".docx", ".xlsx", ".xlsm", "package.json", "readme"
        ]
        return markers.contains { input.contains($0) }
    }

    private var hasInspectableLocalContext: Bool {
        if requestsLocalIO || codeOrProjectContext || containsLocalPath || referencesOfficeDocument {
            return true
        }
        let appContextMarkers = [
            "页面", "界面", "按钮", "输入", "输入框", "交互", "性能", "侧栏", "左边", "右边", "窗口",
            "会话", "追问", "历史任务", "新会话", "上下文", "agent", "Agent",
            "连接器", "工具调用", "工具", "来财", "app", "应用", "UI", "ui"
        ]
        return appContextMarkers.contains { input.contains($0) }
    }

    private var reportsInspectableProblem: Bool {
        guard hasInspectableLocalContext else { return false }
        let problemMarkers = [
            "有问题", "不对", "丢失", "没反应", "没生效", "坏了", "异常",
            "报错", "bug", "Bug", "卡", "慢", "卡顿", "不好用", "难用"
        ]
        return problemMarkers.contains { input.contains($0) }
    }

    func workflowReason(for workflow: String) -> String {
        switch workflow {
        case "code-review":
            return "用户要求审查代码或项目改动，适合进入代码审查工作流。"
        case "test-gen":
            return "用户要求为代码或模块补测试，适合进入测试生成工作流。"
        case "debug":
            return "用户要求定位报错或异常，适合进入调试诊断工作流。"
        case "refactor":
            return "用户要求重构代码或项目结构，适合进入重构工作流。"
        case "doc-gen":
            return "用户要求生成或补充项目文档，适合进入文档工作流。"
        case "translate":
            return "用户要求翻译文件或做本地化，适合进入翻译工作流。"
        default:
            return "用户目标匹配可复用工作流。"
        }
    }

    func workflowCapabilities(for workflow: String) -> [String] {
        switch workflow {
        case "code-review":
            return ["读取变更", "审查风险", "汇总问题"]
        case "test-gen":
            return ["读取代码", "生成测试", "提出文件修改"]
        case "debug":
            return ["搜索错误", "运行诊断", "定位原因"]
        case "refactor":
            return ["读取结构", "规划重构", "提出文件修改"]
        case "doc-gen":
            return ["读取项目", "生成文档", "提出文件修改"]
        case "translate":
            return ["读取文件", "翻译内容", "提出文件修改"]
        default:
            return ["读取上下文", "执行预设步骤", "汇总结果"]
        }
    }

    fileprivate var capabilityOnly: Bool {
        let capabilityPatterns = ["你能", "能不能", "可以", "会不会", "是否支持", "支持", "能否", "可不可以"]
        guard isDirectQuestion, capabilityPatterns.contains(where: { input.contains($0) }) else { return false }
        guard !requestsMutation else { return false }
        return !input.contains("帮我") && !input.contains("给我") && !input.contains("现在") && !input.contains("一下")
    }

    var executionConfidence: Double {
        if containsURL || requestsFreshInformation || requestsWebResearch || requestsModelCurrentInfo { return 0.88 }
        if requestsWikiPersistence { return 0.86 }
        if requestsImageGeneration { return 0.84 }
        if requestsMutation || requestsShellExecution { return 0.84 }
        if requestsLocalIO { return 0.80 }
        return 0.70
    }

    var executionReason: String {
        if containsURL { return "用户提供了网页链接，需要读取外部资料。" }
        if requestsWikiPersistence { return "用户要求把当前材料沉淀到 Wiki/知识库，需要调用知识库写入能力。" }
        if requestsImageGeneration { return "用户要求生成视觉素材，需要调用图片生成能力。" }
        if requestsFreshInformation || requestsWebResearch || requestsModelCurrentInfo { return "用户需要联网或时效信息，需要调用搜索/网页工具。" }
        if requestsLocalIO { return "用户要求读取、搜索或理解本地工作区。" }
        if requestsShellExecution { return "用户要求运行命令、测试、构建或部署。" }
        if requestsMutation { return "用户要求修改或生成本地文件，需要进入可审查的执行流程。" }
        return "用户要求产出具体结果。"
    }

    var expectedCapabilities: [String] {
        var capabilities: [String] = []
        if requestsImageGeneration { capabilities.append("生成图片") }
        if requestsFreshInformation || requestsWebResearch || requestsModelCurrentInfo || containsURL { capabilities.append("联网检索") }
        let contextualInspection = hasInspectableLocalContext
            && (requestsDiagnosis || requestsAdvice || requestsEvaluation || requestsSummary || requestsPlanOnly || reportsInspectableProblem)
        if requestsLocalIO || contextualInspection { capabilities.append("读取工作区") }
        if requestsShellExecution { capabilities.append("运行命令") }
        if requestsWikiPersistence { capabilities.append("写入知识库") }
        if requestsMutation || (!explicitPlanOnly && hasInspectableLocalContext && (requestsDiagnosis || requestsAdvice || reportsInspectableProblem)) { capabilities.append("提出文件修改") }
        if requestedDeliverable || requestsWikiPersistence { capabilities.append("整理交付") }
        if !explicitPlanOnly, !capabilities.contains("形成可验证结果") { capabilities.append("形成可验证结果") }
        return capabilities.isEmpty ? ["规划", "执行", "总结"] : capabilities
    }
}

// MARK: - Auto Context Engine

public struct AutoContextEngine {
    public static func buildContext(
        workspaceRoot: String,
        vaultRoot: String? = nil,
        userInput: String,
        fileLimit: Int = 200,
        comfyUIServerURL: String? = nil,
        comfyUIModelName: String? = nil
    ) -> TaskContext {
        let cleanVault = vaultRoot?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeWorkspaceRoot: String
        if WorkspaceSandbox.isOverlyBroadWorkspace(workspaceRoot)
            || WorkspaceSandbox.isDisposableSmokeWorkspace(workspaceRoot) {
            safeWorkspaceRoot = ""
        } else {
            safeWorkspaceRoot = workspaceRoot
        }
        var context = TaskContext(
            workspaceRoot: safeWorkspaceRoot,
            vaultRoot: cleanVault?.isEmpty == false ? cleanVault : nil,
            comfyUIServerURL: comfyUIServerURL,
            comfyUIModelName: comfyUIModelName
        )
        if safeWorkspaceRoot.isEmpty, !workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.metadata["workspaceRootRejected"] = workspaceRoot
        }

        // PERF-1+3: Run git + file scan in parallel; skip heavy ops for chat (fileLimit=0)
        let isChatFastPath = fileLimit == 0
        let group = DispatchGroup()
        var claudeMD: String?
        var gitBranch: String?
        var gitDiff: String?
        var relevantFiles: [FileInfo] = []

        let q = DispatchQueue(label: "laicai.context-build", attributes: .concurrent)
        group.enter()
        q.async {
            claudeMD = loadProjectInstructions(workspaceRoot: safeWorkspaceRoot)
            group.leave()
        }
        group.enter()
        q.async {
            gitBranch = currentGitBranch(workspaceRoot: safeWorkspaceRoot)
            group.leave()
        }
        if !isChatFastPath {
            group.enter()
            q.async {
                gitDiff = currentGitDiff(workspaceRoot: safeWorkspaceRoot)
                group.leave()
            }
            group.enter()
            q.async {
                relevantFiles = findRelevantFiles(workspaceRoot: safeWorkspaceRoot, query: userInput, limit: fileLimit)
                group.leave()
            }
        }
        group.wait()

        context.claudeMD = claudeMD
        context.gitBranch = gitBranch
        context.gitDiff = gitDiff
        context.relevantFiles = relevantFiles

        return context
    }

    private static func loadProjectInstructions(workspaceRoot: String) -> String? {
        // Priority-ordered instruction files (higher priority first)
        let instructionFiles = [
            "LAICAI.md",
            "AGENTS.md",
            ".agents/AGENTS.md",
            "CLAUDE.md",
            ".claude/CLAUDE.md",
            ".laicai/CLAUDE.md",
            ".cursor/rules",
            ".cursorrules"
        ]
        let loaded = instructionFiles.compactMap { relativePath -> String? in
            let fullPath = (workspaceRoot as NSString).appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) else { return nil }
            let content: String?
            if isDirectory.boolValue {
                content = loadInstructionDirectory(fullPath)
            } else {
                content = try? String(contentsOfFile: fullPath, encoding: .utf8)
            }
            guard let trimmed = content?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return "### \(relativePath)\n\(String(trimmed.prefix(12_000)))"
        }

        // README summary (first 3000 chars, typically contains project overview)
        let readmeFiles = ["README.md", "README", "README.txt", "readme.md"]
        let readmeContent = readmeFiles.compactMap { name -> String? in
            let fullPath = (workspaceRoot as NSString).appendingPathComponent(name)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { return nil }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return "### \(name)\n\(String(trimmed.prefix(3_000)))"
        }.first

        // Package config summaries (extract key metadata, not full content)
        let packageConfigs: [(path: String, label: String)] = [
            ("Package.swift", "Swift Package"),
            ("pyproject.toml", "Python Project"),
            ("package.json", "Node Package"),
            ("Cargo.toml", "Rust Package"),
            ("go.mod", "Go Module"),
            ("pom.xml", "Maven Project"),
            ("build.gradle", "Gradle Project"),
            ("Gemfile", "Ruby Gems"),
            ("requirements.txt", "Python Requirements"),
            ("Podfile", "CocoaPods"),
        ]
        let packageSummaries = packageConfigs.compactMap { config -> String? in
            let fullPath = (workspaceRoot as NSString).appendingPathComponent(config.path)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { return nil }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Only include first 800 chars for package configs — enough for name/version/deps
            return "### \(config.label) (\(config.path))\n\(String(trimmed.prefix(800)))"
        }

        // Subdirectory rule inheritance: scan top-level subdirs for .laicai/CLAUDE.md
        let subDirRules = loadSubDirectoryRules(workspaceRoot: workspaceRoot)

        var allSections = loaded
        if let readme = readmeContent { allSections.append(readme) }
        allSections.append(contentsOf: packageSummaries)
        if !subDirRules.isEmpty { allSections.append(subDirRules) }

        guard !allSections.isEmpty else { return nil }
        return allSections.joined(separator: "\n\n")
    }

    /// Load rule files from top-level subdirectories (one level deep).
    /// This enables per-module instructions like `src/.laicai/CLAUDE.md`.
    private static func loadSubDirectoryRules(workspaceRoot: String) -> String {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: workspaceRoot) else { return "" }

        var rules: [String] = []
        for entry in entries.sorted().prefix(20) {
            let subPath = (workspaceRoot as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
            // Skip hidden and common non-project dirs
            guard !entry.hasPrefix(".") && !["node_modules", "build", "dist", ".git", "DerivedData"].contains(entry) else { continue }

            let ruleFile = (subPath as NSString).appendingPathComponent(".laicai/CLAUDE.md")
            guard let content = try? String(contentsOfFile: ruleFile, encoding: .utf8) else { continue }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            rules.append("### \(entry)/.laicai/CLAUDE.md\n\(String(trimmed.prefix(2_000)))")
        }
        return rules.isEmpty ? "" : "## 子目录规则\n" + rules.joined(separator: "\n\n")
    }

    private static func loadInstructionDirectory(_ path: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return entries
            .sorted()
            .filter { $0.hasSuffix(".md") || $0.hasSuffix(".mdc") || $0.hasSuffix(".txt") }
            .prefix(6)
            .compactMap { entry in
                let full = (path as NSString).appendingPathComponent(entry)
                guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { return nil }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return "#### \(entry)\n\(String(trimmed.prefix(4_000)))"
            }
            .joined(separator: "\n\n")
    }

    private static func currentGitBranch(workspaceRoot: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--abbrev-ref", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func currentGitDiff(workspaceRoot: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "diff", "--stat"]
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }

    private static func findRelevantFiles(workspaceRoot: String, query: String, limit: Int) -> [FileInfo] {
        let fm = FileManager.default
        var files: [FileInfo] = []
        let boundedLimit = max(0, min(limit, 500))
        guard boundedLimit > 0 else { return [] }
        let ignored: Set<String> = [
            ".git", "node_modules", ".build", "DerivedData", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
            ".venv", "venv", ".next", "dist", "build",
            ".config", ".ssh", ".aws", ".gnupg", ".docker", ".kube", ".cursor", "Library", "Applications", "Downloads",
            "Movies", "Music", "Pictures", "Public"
        ]
        let sensitiveNames: Set<String> = ["auth.json", "credentials", "credentials.json", ".env", ".env.local", "id_rsa", "id_ed25519"]
        let codeExtensions: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "rb", "java", "kt", "c", "cpp", "h", "hpp", "css", "html", "yaml", "yml", "json", "toml", "md"]

        let enumerator = fm.enumerator(atPath: workspaceRoot)
        while let file = enumerator?.nextObject() as? String {
            let ext = (file as NSString).pathExtension
            let name = (file as NSString).lastPathComponent
            let components = file.components(separatedBy: "/")
            let dir = components.first ?? ""
            if ignored.contains(name) || ignored.contains(dir) || components.contains(where: { ignored.contains($0) }) || sensitiveNames.contains(name) {
                enumerator?.skipDescendants()
                continue
            }
            if codeExtensions.contains(ext) {
                // PERF-2: Skip reading file content — pure path scan is 10-50× faster.
                // Detailed content is loaded later by workspace_index or file_read tools.
                files.append(FileInfo(path: file, language: ext, summary: ""))
                if files.count >= boundedLimit { break }
            }
        }
        return files
    }
}

// MARK: - Token Budget

public struct TokenBudget: Sendable, Equatable {
    public var mode: ContextMode
    public var estimatedTokens: Int
    public var budget: Int
    public var inputTokens: Int
    public var projectTokens: Int
    public var memoryTokens: Int
    public var toolTokens: Int
    public var attachmentTokens: Int
    public var systemReserveTokens: Int
    public var trimDetails: [String]

    public init(
        mode: ContextMode,
        estimatedTokens: Int,
        budget: Int,
        inputTokens: Int = 0,
        projectTokens: Int = 0,
        memoryTokens: Int = 0,
        toolTokens: Int = 0,
        attachmentTokens: Int = 0,
        systemReserveTokens: Int = 0,
        trimDetails: [String] = []
    ) {
        self.mode = mode
        self.estimatedTokens = estimatedTokens
        self.budget = budget
        self.inputTokens = inputTokens
        self.projectTokens = projectTokens
        self.memoryTokens = memoryTokens
        self.toolTokens = toolTokens
        self.attachmentTokens = attachmentTokens
        self.systemReserveTokens = systemReserveTokens
        self.trimDetails = trimDetails
    }

    public var usageRatio: Double {
        guard budget > 0 else { return 0 }
        return min(1, Double(estimatedTokens) / Double(budget))
    }

    public var displayText: String {
        "\(Self.format(estimatedTokens)) / \(Self.format(budget))"
    }

    public var compressionSummary: String {
        if usageRatio > 0.88 {
            return "接近上限：会优先压缩旧消息、长工具结果和文件摘要。"
        }
        if usageRatio > 0.72 {
            return "用量偏高：会保留近期上下文，压缩较早历史。"
        }
        return "预算健康：仅在长历史或大文件时自动压缩。"
    }

    public var breakdownRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [
            ("当前输入", Self.format(inputTokens)),
            ("项目上下文", Self.format(projectTokens)),
            ("任务记忆", Self.format(memoryTokens)),
            ("工具结果", Self.format(toolTokens)),
            ("附件线索", Self.format(attachmentTokens)),
            ("系统预留", Self.format(systemReserveTokens))
        ].filter { $0.value != "0" }
        if !trimDetails.isEmpty {
            rows.append(("裁剪明细", trimDetails.joined(separator: "；")))
        }
        return rows
    }

    public static func estimate(text: String) -> Int {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return 0 }
        return max(1, Int(ceil(Double(cleaned.count) / 4.0)))
    }

    public static func estimate(context: TaskContext, userInput: String = "", mode: ContextMode) -> TokenBudget {
        let inputTokens = estimate(text: userInput)
        var projectTokens = 0
        projectTokens += estimate(text: context.workspaceRoot)
        projectTokens += estimate(text: context.vaultRoot ?? "")
        projectTokens += estimate(text: context.claudeMD ?? "")
        projectTokens += estimate(text: context.gitBranch ?? "")
        projectTokens += estimate(text: context.gitDiff ?? "")
        for file in context.relevantFiles {
            projectTokens += estimate(text: file.path)
            projectTokens += estimate(text: file.summary)
        }

        let memoryTokens = estimate(text: context.memory.stageConclusions.joined(separator: "\n"))
            + estimate(text: context.memory.checkpoints.joined(separator: "\n"))
            + estimate(text: context.memory.userDecisions.joined(separator: "\n"))
            + estimate(text: context.memory.verificationStatus ?? "")
        let toolTokens = estimate(text: context.memory.readFiles.joined(separator: "\n"))
            + estimate(text: context.memory.searchedQueries.joined(separator: "\n"))
            + estimate(text: context.memory.failedTools.joined(separator: "\n"))
        let attachmentTokens = estimate(text: context.memory.pendingFiles.joined(separator: "\n"))
        let systemReserveTokens = max(240, mode.maxTokensPerTurn / 12)
        let total = inputTokens + projectTokens + memoryTokens + toolTokens + attachmentTokens + systemReserveTokens

        // Generate trim details when over budget
        var trimDetails: [String] = []
        if total > mode.tokenBudget {
            let overage = total - mode.tokenBudget
            if toolTokens > 0 && overage > toolTokens / 2 {
                trimDetails.append("工具结果已压缩")
            }
            if projectTokens > 0 && overage > projectTokens / 2 {
                trimDetails.append("项目上下文已裁剪")
            }
            if memoryTokens > 0 && overage > memoryTokens / 3 {
                trimDetails.append("早期记忆已摘要")
            }
            if attachmentTokens > 0 && overage > attachmentTokens / 2 {
                trimDetails.append("附件线索已截断")
            }
            if context.relevantFiles.count > mode.relevantFileLimit {
                trimDetails.append("相关文件已裁剪至\(mode.relevantFileLimit)个")
            }
        }

        return TokenBudget(
            mode: mode,
            estimatedTokens: total,
            budget: mode.tokenBudget,
            inputTokens: inputTokens,
            projectTokens: projectTokens,
            memoryTokens: memoryTokens,
            toolTokens: toolTokens,
            attachmentTokens: attachmentTokens,
            systemReserveTokens: systemReserveTokens,
            trimDetails: trimDetails
        )
    }

    private static func format(_ value: Int) -> String {
        if value >= 1000 {
            let amount = Double(value) / 1000.0
            return String(format: "%.1fk", amount)
        }
        return "\(value)"
    }
}

// MARK: - Prompt Composer

public struct PromptComposer {
    /// Compose system prompt with project context for the agent loop.
    /// This is used as the system message for LLM calls with function calling.
    public static func composeSystemPrompt(context: TaskContext, intent: UserIntent) -> String {
        var parts: [String] = []

        parts.append("你是来财（Laicai），macOS 本机 AI 助手。\(currentDateString())。")

        if intent == .chat {
            parts.append("直接回答问题。简洁、准确、不啰嗦。")
            if let claudeMD = context.claudeMD {
                parts.append("\n## 项目记忆\n\(claudeMD)")
            }
            return parts.joined(separator: "\n")
        }

        // Non-chat: compact workflow protocol
        parts.append("""
        ## 核心原则
        - 目标：完成用户交给的任务。根据当前证据决定下一步，不盲目调用工具，不套固定流程。
        - 证据优先：没读过的文件不判断内容。以工具返回的结果为准。
        - 失败恢复：同参数不重试，换工具/参数/路径。连续失败才向用户说明阻塞。
        - 危险操作（删除、sudo、密钥、强推）默认停止并说明风险，除非用户明确授权。
        - 收口只说：做了什么、验证了什么、剩余风险。
        """)

        if let protocolGoal = context.metadata["taskProtocolGoal"] {
            parts.append("\n## 任务协议\n目标：\(protocolGoal)\n工作区：\(context.workspaceRoot.isEmpty ? "未指定" : context.workspaceRoot)")
        }

        // Context injection
        if let claudeMD = context.claudeMD {
            parts.append("\n## 项目记忆\n\(claudeMD)")
        }
        if let projectCtx = ProjectManager.buildProjectContext(projects: ProjectManager.cachedProjects, rootPath: context.workspaceRoot) {
            parts.append("\n## 项目概况\n\(projectCtx)")
        }
        if let branch = context.gitBranch {
            parts.append("\n## 分支\n\(branch)")
        } else if !context.workspaceRoot.isEmpty {
            let isGit = FileManager.default.fileExists(atPath: (context.workspaceRoot as NSString).appendingPathComponent(".git"))
            if !isGit { parts.append("\n## 非 Git 工作区\n不要调用 git 工具。") }
        }
        if let diff = context.gitDiff {
            parts.append("\n## 未提交变更\n\(diff)")
        }
        if let vaultRoot = context.vaultRoot, !vaultRoot.isEmpty {
            parts.append("\n## Vault\n\(vaultRoot)")
        }
        if !context.relevantFiles.isEmpty {
            let fileList = context.relevantFiles.prefix(10).map { "- \($0.path)" }.joined(separator: "\n")
            parts.append("\n## 相关文件\n\(fileList)")
        }

        // Intent-specific mode
        switch intent {
        case .chat: break
        case .research:
            parts.append("\n## 研究模式\n优先 web_search 获取来源，web_fetch 读详情，基于来源整理结论。不写文件不装软件，除非用户要求。")
        case .task:
            parts.append("\n## 执行模式\nfile_edit 改已有文件，file_write 新建文件。代码改后 verify_build 验证。")
            if let verifyCmd = ValidationEngine.suggestVerificationCommand(workspaceRoot: context.workspaceRoot) {
                parts.append("验证命令：`\(verifyCmd)`")
            }
        case .workflow(let name):
            parts.append("\n## 工作流模式\n\(name)。工具结果证明需要调整时先调整，最终以完成用户目标为准。")
        }

        return parts.joined(separator: "\n")
    }

    private static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: Date())
    }
    /// Compose system prompt for simple chat (no tools)
    public static func composeChatPrompt(context: TaskContext) -> String {
        var parts: [String] = []
        parts.append("""
        你是来财（Laicai），运行在用户 macOS 上的本地助手。当前日期：\(currentDateString())。
        
        会话问答规则：
        - 直接回答问题，保持简洁有深度
        - 认真阅读会话历史，保持上下文连贯
        - 用户追问时，基于之前的会话内容回答，不要要求重复
        - 你是运行在本机的会话，拥有文件读写、代码搜索、命令执行、联网搜索等工具能力
        - 你是来财，不是 ChatGPT/Qwen/DeepSeek
        - **输出禁令**：禁止输出「阶段总结」「Plan/Execute/Verify/Summarize」「证据清单」「完成检查」等内部推理格式。只用自然语言回答。
        """)

        if let claudeMD = context.claudeMD {
            parts.append("\n## 项目记忆\n\(claudeMD)")
        }

        if let branch = context.gitBranch {
            parts.append("\n## 当前分支\n\(branch)")
        }

        return parts.joined(separator: "\n")
    }

}
