import Foundation
import LaicaiNativeDomain
import SQLite3

// MARK: - Self-Improvement Engine
// Allows 来财 to detect its own weaknesses, modify its own source code,
// build, and hot-restart — fully autonomous self-evolution.

public final class SelfImprovementEngine: Sendable {
    public static let shared = SelfImprovementEngine()

    // The harness project root — where source code lives.
    // Prefer an explicit override, then derive from the current checkout/app cwd.
    public var harnessRoot: String {
        get { state.withValue { $0.harnessRoot } }
        set { state.withValue { $0.harnessRoot = newValue } }
    }
    public var nativeMacosRoot: String { harnessRoot + "/native-macos" }
    public var sourcesRoot: String { nativeMacosRoot + "/Sources/LaicaiNativeFoundation" }
    public var buildScript: String { nativeMacosRoot + "/build.sh" }
    public var appPath: String { nativeMacosRoot + "/dist/Laicai.app" }

    // Cooldown: don't trigger more than once per hour
    private let cooldownSeconds: TimeInterval = 3600

    // Track consecutive improvement attempts to prevent infinite loops
    private let maxConsecutiveAttempts = 3

    private struct State {
        var harnessRoot = SelfImprovementEngine.resolveHarnessRoot()
        var lastTriggerTime: Date = .distantPast
        var consecutiveAttempts = 0
    }

    private let state = Locked(State())
    private let database = Locked(SelfImprovementEngine.openDatabase())

    private init() {}

    private static func resolveHarnessRoot() -> String {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["LAICAI_HARNESS_ROOT"],
            environment["HARNESS_ROOT"],
            findAncestor(named: "native-macos", from: FileManager.default.currentDirectoryPath),
            findAncestor(named: "native-macos", from: Bundle.main.bundleURL.path),
            findAncestor(named: "native-macos", from: CommandLine.arguments.first ?? "")
        ].compactMap { $0 }

        for candidate in candidates {
            let normalized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            if FileManager.default.fileExists(atPath: normalized + "/native-macos/Package.swift") {
                return normalized
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
    }

    private static func findAncestor(named marker: String, from startPath: String) -> String? {
        guard !startPath.isEmpty else { return nil }
        var url = URL(fileURLWithPath: startPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            url.deleteLastPathComponent()
        }
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(marker).path) {
                return url.path
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: - Diagnosis

    public enum DiagnosisCategory: String, Sendable {
        case lowCompletionRate = "low_completion_rate"
        case highToolFailure = "high_tool_failure"
        case repeatedPattern = "repeated_pattern"
        case slowExecution = "slow_execution"
        case highCancelRate = "high_cancel_rate"
        case skillIneffective = "skill_ineffective"
    }

    public enum DiagnosisSeverity: String, Sendable {
        case critical  // Completion < 30%
        case warning  // Completion < 50%
        case suggestion  // Could be better
    }

    public struct Diagnosis: Sendable {
        public let category: DiagnosisCategory
        public let severity: DiagnosisSeverity
        public let description: String
        public let evidence: String
        public let suggestedFiles: [String]
        public let improvementPrompt: String
    }

    /// Check if self-improvement should trigger based on recent metrics.
    /// Returns a diagnosis if improvement is warranted, nil otherwise.
    public func shouldTrigger() -> Diagnosis? {
        // Cooldown check
        let canAttempt = state.withValue { state in
            Date().timeIntervalSince(state.lastTriggerTime) > cooldownSeconds
                && state.consecutiveAttempts < maxConsecutiveAttempts
        }
        guard canAttempt else { return nil }

        let stats = TaskOutcomeRecorder.shared.stats(days: 3)
        guard !stats.isEmpty else { return nil }

        // 1. Check overall completion rate
        let totalTasks = stats.reduce(0) { $0 + $1.total }
        let totalCompleted = stats.reduce(0) { $0 + $1.completed }
        let totalCancelled = stats.reduce(0) { $0 + $1.cancelled }
        guard totalTasks >= 5 else { return nil }  // Need minimum sample
        let completionRate = Double(totalCompleted) / Double(totalTasks)
        let cancelRate = Double(totalCancelled) / Double(totalTasks)

        // Critical: completion rate below 30%
        if completionRate < 0.3 {
            return Diagnosis(
                category: .lowCompletionRate,
                severity: .critical,
                description: "最近3天会话完成率仅 \(Int(completionRate * 100))%（\(totalCompleted)/\(totalTasks)）",
                evidence: formatStats(stats),
                suggestedFiles: ["AgentLoop.swift", "Orchestrator.swift", "PromptComposer.swift"],
                improvementPrompt: buildImprovementPrompt(for: .lowCompletionRate, evidence: formatStats(stats))
            )
        }

        // High cancel rate
        if cancelRate > 0.4 {
            return Diagnosis(
                category: .highCancelRate,
                severity: .critical,
                description: "最近3天取消率达 \(Int(cancelRate * 100))%（\(totalCancelled)/\(totalTasks)）",
                evidence: formatStats(stats),
                suggestedFiles: ["AgentLoop.swift", "Orchestrator.swift"],
                improvementPrompt: buildImprovementPrompt(for: .highCancelRate, evidence: formatStats(stats))
            )
        }

        // 2. Check tool failure rate
        let toolStats = TaskOutcomeRecorder.shared.toolStats(days: 7)
        for toolStat in toolStats {
            let failRate = toolStat.total >= 5 ? 1.0 - Double(toolStat.successes) / Double(toolStat.total) : 0
            if failRate > 0.6 {
                return Diagnosis(
                    category: .highToolFailure,
                    severity: .warning,
                    description: "工具 \(toolStat.toolName) 失败率 \(Int(failRate * 100))%（\(toolStat.total - toolStat.successes)/\(toolStat.total)）",
                    evidence: "Tool: \(toolStat.toolName), Total: \(toolStat.total), Successes: \(toolStat.successes)",
                    suggestedFiles: ["ToolEngine.swift", "AgentLoop.swift"],
                    improvementPrompt: buildImprovementPrompt(for: .highToolFailure, evidence: "Tool \(toolStat.toolName) fail rate \(Int(failRate * 100))%")
                )
            }
        }

        // 3. Check for repeated failure patterns
        let patterns = FailurePatternDB.shared.topPatterns(limit: 5)
        for pattern in patterns {
            if pattern.frequency >= 5 && pattern.successAfterFix == 0 {
                return Diagnosis(
                    category: .repeatedPattern,
                    severity: .warning,
                    description: "失败模式「\(pattern.rootCause)」出现 \(pattern.frequency) 次，从未成功修复",
                    evidence: "Intent: \(pattern.intent), Tools: \(pattern.triggerTools), Instruction: \(pattern.preemptiveInstruction)",
                    suggestedFiles: ["AgentLoop.swift", "FailurePatternDB.swift"],
                    improvementPrompt: buildImprovementPrompt(for: .repeatedPattern, evidence: "Pattern: \(pattern.rootCause), freq: \(pattern.frequency)")
                )
            }
        }

        // 4. Warning-level: completion rate below 50%
        if completionRate < 0.5 {
            return Diagnosis(
                category: .lowCompletionRate,
                severity: .warning,
                description: "最近3天会话完成率 \(Int(completionRate * 100))%（\(totalCompleted)/\(totalTasks)），低于目标50%",
                evidence: formatStats(stats),
                suggestedFiles: ["AgentLoop.swift", "Orchestrator.swift", "PromptComposer.swift"],
                improvementPrompt: buildImprovementPrompt(for: .lowCompletionRate, evidence: formatStats(stats))
            )
        }

        return nil
    }

    // MARK: - Session Replay & Precise Locator

    /// Extract the critical failure sequence from a thread's steps.
    /// Returns a compact timeline showing: what was attempted → what failed → user complaints.
    public func extractFailureTimeline(steps: [TaskStep]) -> String {
        var timeline: [String] = []
        for (index, step) in steps.enumerated() {
            let tag: String?
            switch step.kind {
            case .toolCall:
                tag = "🔧 [\(index)] \(step.toolName ?? "tool"): \(String(step.text.prefix(100)))"
            case .toolResult where step.isFailure:
                tag = "❌ [\(index)] \(step.toolName ?? "tool"): \(String(step.text.prefix(120)))"
            case .reviewRequest:
                let empty = (step.diffNewContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                tag =
                    empty
                    ? "⚠️ [\(index)] reviewRequest: \(step.diffFilePath ?? "?") — diffNew为空!"
                    : "✅ [\(index)] reviewRequest: \(step.diffFilePath ?? "?") — \((step.diffNewContent ?? "").count)字符"
            case .error:
                tag = "🔴 [\(index)] error: \(String(step.text.prefix(100)))"
            case .userInput:
                let lower = step.text.lowercased()
                if lower.contains("空") || lower.contains("没") || lower.contains("错") || lower.contains("幻觉") || lower.contains("还是") {
                    tag = "👤 [\(index)] 用户投诉: \(String(step.text.prefix(80)))"
                } else {
                    tag = nil
                }
            default:
                tag = nil
            }
            if let tag { timeline.append(tag) }
        }
        return timeline.joined(separator: "\n")
    }

    /// Read source code around a specific file:line reference.
    /// Returns the code snippet with context lines, or nil if file not found.
    public func readSourceContext(fileRef: String, contextLines: Int = 15) -> String? {
        // Parse "FileName.swift:123" format
        let parts = fileRef.split(separator: ":", maxSplits: 1)
        let fileName = String(parts[0])
        let lineNumber = parts.count > 1 ? Int(parts[1]) : nil

        // Find file in sources
        let fullPath: String
        if fileName.hasPrefix("/") {
            fullPath = fileName
        } else {
            fullPath = sourcesRoot + "/" + fileName
        }
        guard FileManager.default.fileExists(atPath: fullPath) else { return nil }
        guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n")
        guard let target = lineNumber, target > 0, target <= lines.count else {
            // No line number — return first 50 lines
            return lines.prefix(50).enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        }

        let start = max(0, target - contextLines - 1)
        let end = min(lines.count, target + contextLines)
        return lines[start..<end].enumerated().map { index, line in
            let lineNum = start + index + 1
            let marker = lineNum == target ? ">>>" : "   "
            return "\(marker) \(lineNum): \(line)"
        }.joined(separator: "\n")
    }

    /// Generate a precise fix prompt from PostMortem findings with actual source code context.
    public func generatePreciseFixPrompt(from report: SessionPostMortem.Report, steps: [TaskStep]) -> String {
        markAttemptStarted()

        var prompt = """
            # 自我修复任务（精准模式）

            你是来财AI系统。会话后检模块检测到以下问题，需要修改自己的源代码来修复。

            ## 失败会话回放
            以下是出问题会话的关键步骤时间线：
            ```
            \(extractFailureTimeline(steps: steps))
            ```

            ## 检测到的问题
            """

        for (index, finding) in report.findings.enumerated() where finding.severity >= .warning {
            prompt += "\n### 问题 \(index + 1): \(finding.pattern.rawValue) [\(finding.severity.rawValue)]\n"
            prompt += "**描述**: \(finding.description)\n"
            prompt += "**修复方向**: \(finding.suggestedFix.fixDescription)\n"

            // Inject actual source code context for each suggested file
            for fileRef in finding.suggestedFix.sourceFiles {
                if let code = readSourceContext(fileRef: fileRef) {
                    prompt += "\n**源码上下文** `\(fileRef)`:\n```swift\n\(code)\n```\n"
                }
            }
        }

        // Include past improvement history to avoid repeating
        let history = recentImprovements(limit: 5)
        if !history.isEmpty {
            prompt += "\n## 历史修复（避免重复）\n"
            for historyItem in history {
                prompt += "- [\(historyItem.buildSuccess ? "成功" : "失败")] \(historyItem.category): \(historyItem.description) → \(historyItem.filesChanged)\n"
            }
        }

        prompt += """

            ## 源代码位置
            - 项目根目录：\(harnessRoot)
            - 主要源码：\(sourcesRoot)/

            ## 执行步骤
            1. 根据上面的源码上下文和问题描述，直接定位并修复代码（最小化修改）
            2. 运行 `bash \(buildScript)` 验证编译通过
            3. 编译通过后：先运行 `git status --short`，只 `git add -- <本轮修改文件>`，再 `git commit -m "self-fix: \(report.findings.first?.pattern.rawValue ?? "postmortem")"`
            4. 重启应用

            ## 限制
            - 只修改 LaicaiNativeFoundation 目录下的 .swift 文件
            - 不要修改 Models.swift 的 struct 定义
            - 每次最多修改 3 个文件
            - 必须编译通过
            """

        return prompt
    }

    // MARK: - Improvement Execution

    /// Generate the full improvement task message that will be sent to the agent loop.
    /// The agent will read its own source, diagnose, edit, build, and restart.
    public func generateImprovementTask(diagnosis: Diagnosis) -> String {
        markAttemptStarted()

        return """
            # 自我改进任务

            ## 诊断
            \(diagnosis.description)

            ## 严重程度
            \(diagnosis.severity.rawValue)

            ## 证据
            \(diagnosis.evidence)

            ##会话要求

            你是来财AI系统，现在需要修改自己的源代码来修复上述问题。

            ### 源代码位置
            - 项目根目录：\(harnessRoot)
            - 主要源码：\(sourcesRoot)/
            - 建议关注文件：\(diagnosis.suggestedFiles.map { sourcesRoot + "/" + $0 }.joined(separator: ", "))

            ### 执行步骤
            1. 先读取相关源文件，理解当前实现
            2. 根据诊断数据找到根因
            3. 用 file_edit 修改代码（最小化修改，只改必要的部分）
            4. 修改后运行 `bash \(buildScript)` 验证编译通过
            5. 如果编译失败，修复编译错误后重新验证
            6. 编译通过后，运行 `git status --short`，只 `git add -- <本轮修改文件>`，再提交 `self-improve: \(diagnosis.category.rawValue) - \(diagnosis.description.prefix(60))`
            7. 重启应用：先运行 `osascript -e 'quit app \"Laicai\"'`，等待1秒，再运行 `open \(appPath)`

            ### 限制
            - 只修改 LaicaiNativeFoundation 目录下的 .swift 文件
            - 不要修改 Models.swift 中的 struct 定义（会影响数据迁移）
            - 不要删除现有功能，只做增量优化
            - 每次最多修改 3 个文件
            - 修改必须编译通过才能提交

            \(diagnosis.improvementPrompt)
            """
    }

    /// Called after a successful self-improvement task to reset the consecutive counter.
    public func onImprovementSuccess() {
        state.withValue { $0.consecutiveAttempts = 0 }
    }

    /// Called after a failed self-improvement to track attempts.
    public func onImprovementFailure() {
        // consecutiveAttempts already incremented in generateImprovementTask
    }

    // MARK: - Build & Restart

    /// Attempt to build the project. Returns (success, output).
    public func buildProject() -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [buildScript]
        process.currentDirectoryURL = URL(fileURLWithPath: nativeMacosRoot)
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let combined = output + errOutput
            return (process.terminationStatus == 0, combined)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Git rollback the last commit if the build failed.
    public func rollbackLastCommit() {
        guard ProcessInfo.processInfo.environment["LAICAI_ALLOW_DESTRUCTIVE_ROLLBACK"] == "1" else {
            LaicaiLog.warning("Self-improvement rollback skipped; set LAICAI_ALLOW_DESTRUCTIVE_ROLLBACK=1 to enable git reset --hard.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "reset", "--hard", "HEAD~1"]
        process.currentDirectoryURL = URL(fileURLWithPath: harnessRoot)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    /// Restart the app by quitting and reopening.
    public func restartApp() {
        Task.detached { [appPath] in
            try? await Task.sleep(for: .milliseconds(500))
            // Quit
            let quit = Process()
            quit.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            quit.arguments = ["-e", "quit app \"Laicai\""]
            quit.standardOutput = Pipe()
            quit.standardError = Pipe()
            try? quit.run()
            quit.waitUntilExit()

            // Wait for clean exit
            try? await Task.sleep(for: .milliseconds(1_500))

            // Reopen
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [appPath]
            open.standardOutput = Pipe()
            open.standardError = Pipe()
            try? open.run()
        }
    }

    // MARK: - History (SQLite)

    public struct ImprovementRecord: Sendable {
        public let id: Int
        public let category: String
        public let description: String
        public let filesChanged: String
        public let buildSuccess: Bool
        public let commitHash: String?
        public let createdAt: Date
    }

    private static func openDatabase() -> OpaquePointer? {
        let baseDir = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let dir = (baseDir as NSString).appendingPathComponent("Laicai")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/self_improvement.sqlite3"
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { return nil }
        sqlite3_exec(
            database,
            """
            CREATE TABLE IF NOT EXISTS improvements (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                category TEXT NOT NULL,
                description TEXT NOT NULL,
                files_changed TEXT DEFAULT '',
                build_success INTEGER DEFAULT 0,
                commit_hash TEXT,
                rolled_back INTEGER DEFAULT 0,
                created_at REAL NOT NULL
            );
            """, nil, nil, nil)
        return database
    }

    public func recordAttempt(
        category: String,
        description: String,
        filesChanged: [String],
        buildSuccess: Bool,
        commitHash: String?
    ) {
        database.withValue { database in
            guard let database else { return }
            let sql = "INSERT INTO improvements (category, description, files_changed, build_success, commit_hash, created_at) VALUES (?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text_safe(stmt, 1, category)
            sqlite3_bind_text_safe(stmt, 2, description)
            sqlite3_bind_text_safe(stmt, 3, filesChanged.joined(separator: ","))
            sqlite3_bind_int(stmt, 4, buildSuccess ? 1 : 0)
            if let hash = commitHash {
                sqlite3_bind_text_safe(stmt, 5, hash)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    public func recentImprovements(limit: Int = 10) -> [ImprovementRecord] {
        database.withValue { database in
            guard let database else { return [] }
            let sql =
                "SELECT id, category, description, files_changed, build_success, commit_hash, created_at FROM improvements ORDER BY created_at DESC LIMIT ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var results: [ImprovementRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(
                    ImprovementRecord(
                        id: Int(sqlite3_column_int(stmt, 0)),
                        category: String(cString: sqlite3_column_text(stmt, 1)),
                        description: String(cString: sqlite3_column_text(stmt, 2)),
                        filesChanged: String(cString: sqlite3_column_text(stmt, 3)),
                        buildSuccess: sqlite3_column_int(stmt, 4) != 0,
                        commitHash: sqlite3_column_type(stmt, 5) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 5)) : nil,
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                    ))
            }
            sqlite3_finalize(stmt)
            return results
        }
    }

    // MARK: - Helpers

    private func formatStats(_ stats: [OutcomeStatsRow]) -> String {
        stats.map { row in
            [
                "intent=\(row.intent)",
                "route=\(row.routeLabel)",
                "total=\(row.total)",
                "completed=\(row.completed)",
                "cancelled=\(row.cancelled)",
                "avgIter=\(String(format: "%.1f", row.avgIterations))"
            ].joined(separator: " ")
        }.joined(separator: "\n")
    }

    private func markAttemptStarted() {
        state.withValue {
            $0.lastTriggerTime = Date()
            $0.consecutiveAttempts += 1
        }
    }

    private func buildImprovementPrompt(for category: DiagnosisCategory, evidence: String) -> String {
        // Include recent improvement history to avoid repeating failed approaches
        let history = recentImprovements(limit: 5)
        let historyBlock =
            history.isEmpty
            ? ""
            : """

            ### 最近的自我改进历史（避免重复失败的方法）
            \(history.map { "- [\($0.buildSuccess ? "成功" : "失败")] \($0.category): \($0.description) (修改: \($0.filesChanged))" }.joined(separator: "\n"))
            """

        switch category {
        case .lowCompletionRate:
            return """
                ### 根因分析方向
                - 检查 AgentLoop 中的迭代控制逻辑是否导致任务过早终止
                - 检查 prompt 中是否有导致模型不调用工具的指令
                - 检查 bootstrap 逻辑是否正确触发
                - 检查上下文是否被过度压缩导致模型丢失关键信息
                \(historyBlock)
                """
        case .highToolFailure:
            return """
                ### 根因分析方向
                - 检查失败工具的参数校验逻辑
                - 检查 ValidationEngine 的重试策略是否合理
                - 检查工具结果格式是否与模型期望匹配
                - 检查工具的错误恢复路径
                \(historyBlock)
                """
        case .repeatedPattern:
            return """
                ### 根因分析方向
                - 检查 FailurePatternDB 的匹配逻辑是否有效注入了经验
                - 检查 preemptive_instruction 是否足够具体
                - 考虑在编排层增加针对此模式的硬编码修复
                \(historyBlock)
                """
        case .highCancelRate:
            return """
                ### 根因分析方向
                - 用户频繁取消可能因为执行太慢或方向错误
                - 检查 bootstrap 是否做了不必要的工作
                - 检查 proactive nudge 是否太晚触发
                - 检查模型是否在做不必要的重复搜索/读取
                \(historyBlock)
                """
        case .slowExecution, .skillIneffective:
            return """
                ### 根因分析方向
                - 检查性能瓶颈：上下文构建、工具调用、token 预算
                - 检查 skill 匹配和注入逻辑
                \(historyBlock)
                """
        }
    }
}

// PatternSummary is returned by FailurePatternDB.topPatterns()
public struct PatternSummary: Sendable {
    public let intent: String
    public let triggerTools: String
    public let rootCause: String
    public let preemptiveInstruction: String
    public let frequency: Int
    public let successAfterFix: Int
}
