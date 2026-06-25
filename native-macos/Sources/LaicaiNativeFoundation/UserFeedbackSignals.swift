import Foundation
import LaicaiNativeDomain

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
