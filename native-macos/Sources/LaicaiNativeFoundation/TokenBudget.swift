import Foundation
import LaicaiNativeDomain

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
            ("系统预留", Self.format(systemReserveTokens)),
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

        let memoryTokens =
            estimate(text: context.memory.stageConclusions.joined(separator: "\n"))
            + estimate(text: context.memory.checkpoints.joined(separator: "\n"))
            + estimate(text: context.memory.userDecisions.joined(separator: "\n"))
            + estimate(text: context.memory.verificationStatus ?? "")
        let toolTokens =
            estimate(text: context.memory.readFiles.joined(separator: "\n"))
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
