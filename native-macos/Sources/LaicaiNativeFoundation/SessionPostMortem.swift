import Foundation
import LaicaiNativeDomain

// MARK: - Session Post-Mortem Analyzer
// Scans completed task sessions for known failure patterns and generates
// precise, actionable diagnoses for SelfImprovementEngine.
//
// Unlike the existing stats-based diagnosis (completion rate, tool failure %),
// this module performs **semantic analysis** of individual step sequences to
// detect root causes that aggregate metrics miss.

public final class SessionPostMortem: Sendable {
    public static let shared = SessionPostMortem()
    private init() {}

    private struct ToolCallHistoryEntry {
        let index: Int
        let name: String
        let pathParam: String
    }

    private static func isFileChangeTool(_ toolName: String?) -> Bool {
        guard let toolName else { return false }
        return ["file.write", "file.edit", "diff.apply"].contains(ToolNameCodec.canonicalName(toolName))
    }

    // MARK: - Failure Pattern Types

    public enum PatternID: String, Sendable, CaseIterable {
        case emptyFileWrite       = "empty_file_write"
        case securityDeniedVault  = "security_denied_vault"
        case shellEncodingGarble  = "shell_encoding_garble"
        case hallucinatedSuccess  = "hallucinated_success"
        case editOnEmptyFile      = "edit_on_empty_file"
        case toolRetryLoop        = "tool_retry_loop"
        case modelParseFailure    = "model_parse_failure"
        case writeNoVerify        = "write_no_verify"
    }

    public enum FindingSeverity: String, Sendable, Comparable {
        case critical, warning, info
        public static func < (lhs: Self, rhs: Self) -> Bool {
            let order: [Self] = [.info, .warning, .critical]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    public struct Finding: Sendable {
        public let pattern: PatternID
        public let severity: FindingSeverity
        public let description: String
        public let evidence: [EvidenceItem]
        public let suggestedFix: FixSuggestion
    }

    public struct EvidenceItem: Sendable {
        public let stepIndex: Int
        public let stepKind: String
        public let toolName: String?
        public let snippet: String  // first 200 chars of step text
    }

    public struct FixSuggestion: Sendable {
        public let sourceFiles: [String]    // e.g. ["ToolEngine.swift:793"]
        public let codeContext: String       // What to look at
        public let fixDescription: String   // Natural language fix
    }

    public struct Report: Sendable {
        public let threadID: UUID
        public let threadTitle: String
        public let analyzedAt: Date
        public let findings: [Finding]
        public let stepCount: Int
        public let toolCallCount: Int
        public let failureCount: Int

        public var hasCritical: Bool { findings.contains { $0.severity == .critical } }
        public var summary: String {
            guard !findings.isEmpty else { return "未发现已知失败模式" }
            let grouped = Dictionary(grouping: findings, by: \.severity)
            var parts: [String] = []
            if let criticalFindings = grouped[.critical] { parts.append("🔴 致命 ×\(criticalFindings.count)") }
            if let warningFindings = grouped[.warning] { parts.append("🟡 警告 ×\(warningFindings.count)") }
            if let infoFindings = grouped[.info] { parts.append("🔵 提示 ×\(infoFindings.count)") }
            let findingLines = findings
                .map { "- [\($0.severity.rawValue)] \($0.pattern.rawValue): \($0.description)" }
                .joined(separator: "\n")
            return parts.joined(separator: "  ") + "\n" + findingLines
        }
    }

    // MARK: - Analysis Entry Point

    /// Analyze a completed thread and return a report of detected failure patterns.
    public func analyze(thread: Thread) -> Report {
        let steps = thread.steps
        var findings: [Finding] = []

        findings.append(contentsOf: detectEmptyFileWrites(steps: steps))
        findings.append(contentsOf: detectSecurityDeniedVault(steps: steps, context: thread.context))
        findings.append(contentsOf: detectShellEncodingGarble(steps: steps))
        findings.append(contentsOf: detectHallucinatedSuccess(steps: steps))
        findings.append(contentsOf: detectEditOnEmptyFile(steps: steps))
        findings.append(contentsOf: detectToolRetryLoop(steps: steps))
        findings.append(contentsOf: detectModelParseFailure(steps: steps))

        // Sort by severity (critical first)
        findings.sort { $0.severity > $1.severity }

        return Report(
            threadID: thread.id,
            threadTitle: thread.title,
            analyzedAt: Date(),
            findings: findings,
            stepCount: steps.count,
            toolCallCount: steps.filter { $0.kind == .toolCall }.count,
            failureCount: steps.filter { $0.isFailure }.count
        )
    }

    // MARK: - Pattern Detectors

    /// P1: file.write produced empty files (diffNew is empty or addedLines=0 with non-empty content param)
    private func detectEmptyFileWrites(steps: [TaskStep]) -> [Finding] {
        var findings: [Finding] = []
        for (stepIndex, step) in steps.enumerated() {
            guard step.kind == .reviewRequest,
                  Self.isFileChangeTool(step.toolName) else { continue }

            let diffNew = step.diffNewContent ?? ""
            let contentParam = step.toolParams?["content"] ?? ""
            let addedLines = step.toolParams?["addedLines"] ?? ""

            // Pattern: has content param but diffNew is empty
            if !contentParam.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && diffNew.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                findings.append(Finding(
                    pattern: .emptyFileWrite,
                    severity: .critical,
                    description: "file.write content参数有\(contentParam.count)字符内容，但diffNew为空 → 文件写空。路径: \(step.diffFilePath ?? "?")",
                    evidence: [Self.evidence(step: step, index: stepIndex)],
                    suggestedFix: FixSuggestion(
                        sourceFiles: ["ToolEngine.swift:793"],
                        codeContext: "WriteFileTool.execute() 的 patch vs full-write 分支选择逻辑",
                        fixDescription: "当 oldContent/newContent 均为空字符串时，不应进入 patch 模式。检查 if-let 是否对空字符串解包成功。"
                    )
                ))
            }

            // Pattern: addedLines=0 but file was supposed to be created
            if addedLines == "0" && !contentParam.isEmpty && step.approved == true {
                let alreadyCounted = findings.contains {
                    $0.pattern == .emptyFileWrite && $0.evidence.first?.stepIndex == stepIndex
                }
                if !alreadyCounted {
                    findings.append(Finding(
                        pattern: .emptyFileWrite,
                        severity: .warning,
                        description: "写入声称成功但 addedLines=0。路径: \(step.diffFilePath ?? "?")",
                        evidence: [Self.evidence(step: step, index: stepIndex)],
                        suggestedFix: FixSuggestion(
                            sourceFiles: ["AgentLoop.swift:1543"],
                            codeContext: "AgentLoop 自动写入后的验证逻辑",
                            fixDescription: "写入后应验证文件实际内容不为空，否则报错而非标记 approved=true。"
                        )
                    ))
                }
            }
        }
        return findings
    }

    /// P2: security_denied when writing to vault path
    private func detectSecurityDeniedVault(steps: [TaskStep], context: TaskContext) -> [Finding] {
        var findings: [Finding] = []
        let vaultRoot = context.vaultRoot ?? ""

        for (stepIndex, step) in steps.enumerated() {
            guard step.isFailure,
                  step.text.contains("security_denied"),
                  let toolName = step.toolName,
                  Self.isFileChangeTool(toolName) else { continue }

            let targetPath = step.toolParams?["path"] ?? step.diffFilePath ?? ""
            let isVaultTarget = !vaultRoot.isEmpty && targetPath.hasPrefix(vaultRoot)
            let isKnowledgeBase = targetPath.contains("知识库") || targetPath.contains("Wiki") || targetPath.contains("vault")

            if isVaultTarget || isKnowledgeBase {
                findings.append(Finding(
                    pattern: .securityDeniedVault,
                    severity: .critical,
                    description: "写入 Vault/知识库路径被 security_denied 拦截。路径: \(targetPath)",
                    evidence: [Self.evidence(step: step, index: stepIndex, toolName: toolName)],
                    suggestedFix: FixSuggestion(
                        sourceFiles: ["AgentLoop.swift:147", "SecurityEngine.swift:244"],
                        codeContext: "Vault 路径未注册到 WorkspaceSandbox.allowedPaths",
                        fixDescription: "在 AgentLoop.run() 启动时，将 taskContext.vaultRoot 加入 WorkspaceSandbox.shared.addAllowedPath()。"
                    )
                ))
            }
        }
        return findings
    }

    /// P3: Shell output contains ???? garbled characters (encoding issue)
    private func detectShellEncodingGarble(steps: [TaskStep]) -> [Finding] {
        var findings: [Finding] = []
        // Pattern: multiple consecutive ? in a file path context
        guard let garblePattern = try? NSRegularExpression(pattern: "/[^/]*\\?{3,}[^/]*/", options: []) else {
            return []
        }

        for (stepIndex, step) in steps.enumerated() {
            guard step.kind == .toolResult,
                  ["shell.exec", "verify.build", "shell_exec"].contains(step.toolName ?? "") else { continue }

            let range = NSRange(step.text.startIndex..., in: step.text)
            if garblePattern.numberOfMatches(in: step.text, range: range) > 0 {
                findings.append(Finding(
                    pattern: .shellEncodingGarble,
                    severity: .warning,
                    description: "Shell 输出包含乱码（中文字符变 ???）。工具: \(step.toolName ?? "")",
                    evidence: [Self.evidence(step: step, index: stepIndex)],
                    suggestedFix: FixSuggestion(
                        sourceFiles: ["ToolEngine.swift:1044"],
                        codeContext: "ShellTool 的 Process 环境变量缺少 LANG/LC_ALL",
                        fixDescription: "在 Process.environment 中设置 LANG=en_US.UTF-8 和 LC_ALL=en_US.UTF-8。"
                    )
                ))
                break // One finding per session is enough
            }
        }
        return findings
    }

    /// P4: Model repeatedly claims success but no actual tool writes succeeded
    private func detectHallucinatedSuccess(steps: [TaskStep]) -> [Finding] {
        var findings: [Finding] = []

        // Find sequences: userInput("还是空的") → textOutput("已完成/已写入")
        // without any successful file.write tool calls in between
        var userComplaintIndices: [Int] = []
        for (stepIndex, step) in steps.enumerated() where step.kind == .userInput {
            let lower = step.text.lowercased()
            if lower.contains("空的") || lower.contains("还是空") || lower.contains("没内容") || lower.contains("幻觉") {
                userComplaintIndices.append(stepIndex)
            }
        }

        guard userComplaintIndices.count >= 2 else { return findings }

        // Check if model claims success after complaints without actual successful writes
        var evidenceItems: [EvidenceItem] = []
        for complaintIndex in userComplaintIndices {
            // Look at next few steps after complaint
            let searchEnd = min(complaintIndex + 5, steps.count)
            for responseIndex in (complaintIndex + 1)..<searchEnd {
                let step = steps[responseIndex]
                if step.kind == .textOutput && (step.text.contains("已完成") || step.text.contains("已成功") || step.text.contains("已写入")) {
                    // Check if there was an actual tool call between complaint and this response
                    let hasToolCall = ((complaintIndex + 1)..<responseIndex).contains { idx in
                        steps[idx].kind == .toolCall && Self.isFileChangeTool(steps[idx].toolName)
                    }
                    if !hasToolCall {
                        evidenceItems.append(Self.evidence(step: step, index: responseIndex, toolName: nil))
                    }
                }
            }
        }

        if !evidenceItems.isEmpty {
            findings.append(Finding(
                pattern: .hallucinatedSuccess,
                severity: .critical,
                description: "用户 \(userComplaintIndices.count) 次投诉文件为空，模型 \(evidenceItems.count) 次声称已完成但未执行实际写入",
                evidence: evidenceItems,
                suggestedFix: FixSuggestion(
                    sourceFiles: ["AgentLoop.swift:1550", "ToolEngine.swift:793"],
                    codeContext: "file.write 返回空 diffNew 后自动标记 approved=true；模型不验证写入结果",
                    fixDescription: "1) WriteFileTool 不应返回空 diffNew  2) AgentLoop 写入后应验证文件非空  3) 空写入应返回 isFailure 阻止模型声称成功"
                )
            ))
        }
        return findings
    }

        /// P5: file.edit attempted on empty file
    private func detectEditOnEmptyFile(steps: [TaskStep]) -> [Finding] {
        var findings: [Finding] = []
        for (stepIndex, step) in steps.enumerated() {
            guard step.kind == .toolResult,
                  step.toolName == "file.edit",
                  step.isFailure,
                  step.text.contains("所有编辑均失败") || step.text.contains("batch_failed") else { continue }

            // Check if the preceding toolCall targeted a file that was empty
            // (we can infer from "该文件为空" hint or from context)
            findings.append(Finding(
                pattern: .editOnEmptyFile,
                severity: .warning,
                description: "file.edit 在空文件上执行失败。模型应改用 file.write。",
                evidence: [Self.evidence(step: step, index: stepIndex)],
                suggestedFix: FixSuggestion(
                    sourceFiles: ["ToolEngine.swift:334"],
                    codeContext: "FileEditTool.executeSingle 在空文件上全部编辑失败时的错误消息",
                    fixDescription: "空文件编辑失败时，错误消息应引导模型改用 file.write 的 content 参数。"
                )
            ))
        }
        return findings
    }

    /// P6: Same tool called 3+ times with similar params (retry loop)
    private func detectToolRetryLoop(steps: [TaskStep]) -> [Finding] {
        var findings: [Finding] = []
        var toolCallHistory: [ToolCallHistoryEntry] = []

        for (stepIndex, step) in steps.enumerated() {
            guard step.kind == .toolCall, let name = step.toolName else { continue }
            let pathParam = step.toolParams?["path"] ?? step.toolParams?["command"]?.prefix(60).description ?? ""
            toolCallHistory.append(ToolCallHistoryEntry(index: stepIndex, name: name, pathParam: pathParam))
        }

        // Sliding window: detect 3+ identical (name, pathParam) in a window of 8 calls
        let windowSize = 8
        for start in 0..<max(0, toolCallHistory.count - windowSize + 1) {
            let window = toolCallHistory[start..<min(start + windowSize, toolCallHistory.count)]
            let grouped = Dictionary(grouping: window, by: { "\($0.name)|\($0.pathParam)" })
            for (key, calls) in grouped where calls.count >= 3 {
                let parts = key.split(separator: "|", maxSplits: 1)
                let toolName = String(parts.first ?? "")
                findings.append(Finding(
                    pattern: .toolRetryLoop,
                    severity: .warning,
                    description: "工具 \(toolName) 在 \(windowSize) 次调用窗口内被重复调用 \(calls.count) 次（参数相同或相似）",
                    evidence: calls.map { EvidenceItem(stepIndex: $0.index, stepKind: "toolCall", toolName: $0.name, snippet: $0.pathParam) },
                    suggestedFix: FixSuggestion(
                        sourceFiles: ["AgentLoop.swift"],
                        codeContext: "模型在工具失败后未切换策略，反复重试相同参数",
                        fixDescription: "AgentLoop 应在检测到连续相同工具调用失败时，注入提示让模型换一个策略。"
                    )
                ))
                break // One finding per loop pattern
            }
            if !findings.contains(where: { $0.pattern == .toolRetryLoop }) { continue }
            break
        }
        return findings
    }

    /// P7: Model response parse failure
    private func detectModelParseFailure(steps: [TaskStep]) -> [Finding] {
        var findings: [Finding] = []
        for (stepIndex, step) in steps.enumerated() {
            guard step.kind == .error,
                  step.text.contains("cannot parse") || step.text.contains("解析失败") else { continue }
            findings.append(Finding(
                pattern: .modelParseFailure,
                severity: .info,
                description: "模型返回了无法解析的响应: \(String(step.text.prefix(100)))",
                evidence: [Self.evidence(step: step, index: stepIndex, toolName: nil)],
                suggestedFix: FixSuggestion(
                    sourceFiles: ["AgentLoop.swift:1138"],
                    codeContext: "SSE 响应解析",
                    fixDescription: "通常是瞬态网络问题。已有自动重试。若频繁出现需检查 connector 的响应格式兼容性。"
                )
            ))
        }
        return findings
    }

    // MARK: - Batch Analysis

    /// Analyze multiple recent threads and aggregate findings.
    public func analyzeRecent(threads: [Thread], limit: Int = 10) -> [Report] {
        let candidates = threads
            .filter { $0.steps.count > 3 } // Skip trivial sessions
            .prefix(limit)
        return candidates.map { analyze(thread: $0) }
    }

    /// Generate an improvement prompt from a report, suitable for SelfImprovementEngine.
    public func generateImprovementPrompt(from report: Report) -> String? {
        guard !report.findings.isEmpty else { return nil }
        let critical = report.findings.filter { $0.severity == .critical }
        guard !critical.isEmpty else { return nil }

        var prompt = """
        # 会话后检诊断报告

        ## 会话信息
        - ID: \(report.threadID)
        - 标题: \(report.threadTitle)
        - 步骤数: \(report.stepCount), 工具调用: \(report.toolCallCount), 失败: \(report.failureCount)

        ## 发现的致命问题
        """

        for (findingIndex, finding) in critical.enumerated() {
            prompt += """

            ### 问题 \(findingIndex + 1): \(finding.pattern.rawValue)
            **描述**: \(finding.description)
            **建议修复文件**: \(finding.suggestedFix.sourceFiles.joined(separator: ", "))
            **代码上下文**: \(finding.suggestedFix.codeContext)
            **修复方向**: \(finding.suggestedFix.fixDescription)

            **证据**:
            """
            for evidenceItem in finding.evidence.prefix(3) {
                prompt += "\n  - Step[\(evidenceItem.stepIndex)] \(evidenceItem.stepKind) "
                prompt += "\(evidenceItem.toolName ?? ""): \(evidenceItem.snippet)"
            }
        }

        // Include warning-level findings as secondary context
        let warnings = report.findings.filter { $0.severity == .warning }
        if !warnings.isEmpty {
            prompt += "\n\n## 次要问题（警告级）\n"
            for warningFinding in warnings {
                prompt += "- [\(warningFinding.pattern.rawValue)] \(warningFinding.description)\n"
            }
        }

        return prompt
    }

    private static func evidence(step: TaskStep, index: Int, toolName: String? = nil) -> EvidenceItem {
        EvidenceItem(
            stepIndex: index,
            stepKind: step.kind.rawValue,
            toolName: toolName ?? step.toolName,
            snippet: String(step.text.prefix(200))
        )
    }
}
