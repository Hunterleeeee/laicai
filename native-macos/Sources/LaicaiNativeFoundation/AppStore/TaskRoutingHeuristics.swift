import Foundation
import LaicaiNativeDomain

extension AppStore {
    static func isLightweightStatusQuery(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 30 else { return false }
        if ["?", "？", "??", "？？"].contains(normalized) { return true }
        let statusMarkers = [
            "怎么回事", "怎么了", "为啥", "为什么", "啥情况", "什么情况",
            "怎么这么", "是不是", "有没有",
            "你确定", "真的吗", "对吗", "好了吗", "完事了吗",
            "卡住了吗", "出错了吗", "断了吗", "停了吗",
            "你是什么", "你能", "你会", "现在能", "现在有"
        ]
        if statusMarkers.contains(where: { normalized.contains($0) }) { return true }
        let actionVerbs = ["改", "写", "建", "做", "执行", "运行", "搜", "查", "读", "整理", "保存", "翻译", "重写"]
        let hasAction = actionVerbs.contains(where: { normalized.contains($0) })
        let endsWithQuestion = normalized.hasSuffix("？") || normalized.hasSuffix("?") || normalized.hasSuffix("吗")
        return endsWithQuestion && !hasAction
    }

    static func isTinyFollowUp(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["?", "？", "??", "？？"].contains(normalized)
            || normalized.count <= 4 && ["然后", "继续", "接着", "为啥", "为什么"].contains(where: { normalized.contains($0) })
    }

    static func isEmptySessionPlaceholder(_ session: ChatSession) -> Bool {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.turns.isEmpty && (title.isEmpty || title == "新会话" || title == "新对话")
    }

    static func isContinuationCommand(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return normalized.contains("继续")
            || normalized.contains("接着")
            || normalized.contains("续跑")
            || normalized.contains("未完成")
            || normalized.localizedCaseInsensitiveContains("continue")
    }

    static func isContextualTaskReference(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let threadMarkers = [
            "这个会话", "那个会话", "当前会话", "这轮对话", "那轮对话", "这条对话",
            "新会话", "上下文", "丢了", "丢失", "没上下文"
        ]
        let taskMarkers = [
            "这个任务", "那个任务", "刚才的任务", "上个任务", "读取本地项目",
            "本地项目", "输出没结束", "被截断", "截断了", "没发完", "没写完", "没说完"
        ]
        return threadMarkers.contains { normalized.contains($0) }
            || taskMarkers.contains { normalized.contains($0) }
    }

    static func isLikelyTaskFollowUp(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if isStandaloneCapabilityOrConceptQuestion(normalized) { return false }
        if isStandaloneInfoQuestion(normalized) { return false }
        if normalized.count <= 12 { return true }
        let actionMarkers = [
            "下一步", "接着", "然后", "继续", "再", "还", "另外", "也", "帮我", "改一下", "修一下",
            "优化", "调整", "补充", "完善", "修复", "修改", "改进", "重构", "测试", "运行",
            "确认", "验证", "检查", "看看", "核对", "对比", "比较", "分析一下", "总结一下",
            "刚才", "之前", "上面的", "这样", "那样", "把它", "把这个", "把那个"
        ]
        if actionMarkers.contains(where: { normalized.contains($0) }) { return true }
        if (normalized.hasSuffix("？") || normalized.hasSuffix("?")) && normalized.count <= 24 {
            return true
        }
        return false
    }

    static func shouldRouteChatFollowUpIntoSelectedTask(message: String, task: AgentTask) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if isStandaloneCapabilityOrConceptQuestion(normalized) {
            return false
        }
        if taskHasTruncatedOutput(task), isTruncationContinuation(normalized) {
            return true
        }
        if UserFrustrationDetector.shouldRecoverRecentTask(normalized) {
            return true
        }
        if isTinyFollowUp(normalized) || isContinuationCommand(normalized) || isTaskStatusQuestion(normalized) || isLikelyTaskFollowUp(normalized) {
            return true
        }

        let explicitTaskMarkers = ["这个任务", "那个任务", "这个会话", "那个会话", "当前会话", "这轮对话", "这条任务", "刚才", "最近的", "最近这个", "上个", "上一轮", "前面", "上面", "上下文", "新会话", "丢失", "接着这个", "继续这个"]
        if explicitTaskMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        let taskActionMarkers = ["再读", "补读", "继续读", "总结", "列出", "修复", "修改", "优化", "跑一下", "测试一下", "重新跑", "重试", "按这个", "基于这个", "把它"]
        if taskActionMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        let pronounOnlyMarkers = ["这个", "那个", "它", "这里", "上面的"]
        if normalized.count <= 16, pronounOnlyMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        let lastUserInput = task.steps.reversed().first { $0.kind == .userInput }?.text ?? task.title
        let sharedKeywords = semanticOverlapKeywords(in: normalized).intersection(semanticOverlapKeywords(in: lastUserInput))
        return sharedKeywords.count >= 2
    }

    static func isStandaloneInfoQuestion(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasSuffix("？") || normalized.hasSuffix("?") else { return false }
        let infoStarts = ["今天", "最近", "最新", "现在", "有什么新", "有哪些新"]
        let infoTopics = ["新闻", "消息", "动态", "进展", "更新", "发布"]
        let startsLike = infoStarts.contains { normalized.hasPrefix($0) }
        let hasTopic = infoTopics.contains { normalized.contains($0) }
        return startsLike && hasTopic
    }

    static func isStandaloneCapabilityOrConceptQuestion(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasSuffix("？") || normalized.hasSuffix("?") || normalized.contains("吗") else { return false }
        let capabilityStarts = [
            "你能", "你现在能", "你可以", "你会", "能不能", "能否", "是否可以",
            "可不可以", "会不会", "你支持", "你是什么", "你是谁"
        ]
        let conceptStarts = ["什么是", "为什么", "怎么理解", "如何理解"]
        let startsLikeStandalone = capabilityStarts.contains { normalized.hasPrefix($0) }
            || conceptStarts.contains { normalized.hasPrefix($0) }
        guard startsLikeStandalone else { return false }
        let taskAnchors = [
            "这个任务", "这条任务", "刚才", "上面", "前面", "继续", "接着", "被截断",
            "没发完", "文件", "代码", "项目", "报错", "工具失败"
        ]
        return !taskAnchors.contains { normalized.contains($0) }
    }

    static func taskHasTruncatedOutput(_ task: AgentTask) -> Bool {
        task.steps.contains { step in
            step.text.contains("输出达到当前上限")
                || step.text.contains("回复已被截断")
                || step.text.contains("输出上限截断")
                || step.text.contains("内容可能被截断")
        }
    }

    static func isTruncationContinuation(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let markers = [
            "接着说", "继续输出", "继续说", "接着输出", "没发完", "没写完",
            "没说完", "没结束", "被截断", "截断了", "断了", "后面呢",
            "剩下的", "接上", "继续"
        ]
        return markers.contains { normalized.contains($0) }
    }

    static func semanticOverlapKeywords(in text: String) -> Set<String> {
        let normalized = text.lowercased()
        let stopwords: Set<String> = ["这个", "那个", "一下", "为什么", "怎么", "什么", "可以", "是不是", "我", "你", "帮我", "请", "的", "了", "吧", "吗", "呢"]
        var tokens: [String] = []
        var current = ""
        for scalar in normalized.unicodeScalars {
            let isAsciiToken = CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "." || scalar == "-"
            let isHan = scalar.value >= 0x4E00 && scalar.value <= 0x9FFF
            if isAsciiToken || isHan {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return Set(tokens.filter { $0.count >= 2 && !stopwords.contains($0) })
    }

    static func isTaskStatusQuestion(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let statusMarkers = ["什么情况", "怎么了", "哪里失败", "失败原因", "几个工具失败", "工具失败", "没完成", "卡住", "还在执行", "执行中", "进度", "状态"]
        let whyAboutCurrentTask = (normalized.contains("为什么") || normalized.contains("为啥"))
            && ["失败", "没完成", "卡住", "中断", "新会话", "上下文", "任务", "工具"].contains { normalized.contains($0) }
        let asksStatus = statusMarkers.contains { normalized.contains($0) }
            || whyAboutCurrentTask
            || ["?", "？"].contains(normalized)
        guard asksStatus else { return false }
        let actionMarkers = ["继续执行", "继续做", "继续任务", "重试", "重新跑", "改", "修复", "写入", "读取", "搜索", "联网", "跑测试", "接着说", "继续输出", "没发完", "没写完", "没说完", "被截断"]
        return !actionMarkers.contains { normalized.contains($0) }
    }

    static func taskStatusAnswer(for task: AgentTask, question: String) -> String {
        let toolCalls = task.steps.filter { $0.kind == .toolCall }.count
        let failures = task.steps.filter { $0.isFailure || $0.kind == .error }
        let failedTools = task.steps.filter { $0.kind == .toolResult && $0.isFailure }
        let lastOutput = task.steps.reversed().first {
            $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastFailure = failures.last?.text.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = []
        lines.append("这条任务当前是“\(task.status.title)”。")
        if toolCalls > 0 {
            lines.append("已经调用过 \(toolCalls) 次工具，其中失败 \(failedTools.count) 次。")
        }
        if !failedTools.isEmpty {
            let grouped = Dictionary(grouping: failedTools, by: { $0.toolName ?? "tool" })
                .map { "\($0.key) ×\($0.value.count)" }
                .sorted()
                .joined(separator: "、")
            lines.append("失败主要来自：\(grouped)。")
        }
        if let lastFailure, !lastFailure.isEmpty {
            lines.append("最近的失败信息是：\(String(lastFailure.prefix(180)))")
        }
        if let lastOutput, !lastOutput.isEmpty {
            lines.append("已经形成过阶段性输出：\(String(lastOutput.prefix(220)))")
        }

        let hasShellFailure = failedTools.contains { $0.toolName == "shell.exec" }
        if hasShellFailure {
            lines.append("判断：它不是单纯“模型不会做”，而是执行路径不稳。模型多次尝试 shell 命令列项目文件，其中部分命令被安全策略或系统退出码拦住。更好的下一步是走受控的项目索引/文件读取，而不是继续让模型自由拼 shell。")
        } else if !failedTools.isEmpty {
            lines.append("判断：任务有工具失败，需要换执行路径或补充目标后续跑。")
        } else if task.status == .completed {
            lines.append("判断：任务已完成。如果你追问细节，我会基于这条任务已有上下文解释，不再重复调用工具。")
        } else {
            lines.append("判断：任务没有检测到明确工具失败，但还需要补充下一步目标。")
        }
        lines.append("建议下一步：先让来财总结已读到的项目结构，再按关键模块继续读取；需要改代码时再进入审查写入。")
        return lines.joined(separator: "\n")
    }
}
