import Foundation
import SQLite3

// MARK: - Self-Improvement Engine
// Allows 来财 to detect its own weaknesses, modify its own source code,
// build, and hot-restart — fully autonomous self-evolution.

public final class SelfImprovementEngine: @unchecked Sendable {
    public static let shared = SelfImprovementEngine()

    // The harness project root — where source code lives
    public var harnessRoot: String = "/Users/lifenghe/Documents/troe_projects/harness"
    public var nativeMacosRoot: String { harnessRoot + "/native-macos" }
    public var sourcesRoot: String { nativeMacosRoot + "/Sources/LaicaiNativeFoundation" }
    public var buildScript: String { nativeMacosRoot + "/build.sh" }
    public var appPath: String { nativeMacosRoot + "/dist/Laicai.app" }

    // Cooldown: don't trigger more than once per hour
    private var lastTriggerTime: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 3600

    // Track consecutive improvement attempts to prevent infinite loops
    private var consecutiveAttempts = 0
    private let maxConsecutiveAttempts = 3

    private init() {}

    // MARK: - Diagnosis

    public struct Diagnosis: Sendable {
        public let category: Category
        public let severity: Severity
        public let description: String
        public let evidence: String
        public let suggestedFiles: [String]
        public let improvementPrompt: String

        public enum Category: String, Sendable {
            case lowCompletionRate = "low_completion_rate"
            case highToolFailure = "high_tool_failure"
            case repeatedPattern = "repeated_pattern"
            case slowExecution = "slow_execution"
            case highCancelRate = "high_cancel_rate"
            case skillIneffective = "skill_ineffective"
        }

        public enum Severity: String, Sendable {
            case critical    // Completion < 30%
            case warning     // Completion < 50%
            case suggestion  // Could be better
        }
    }

    /// Check if self-improvement should trigger based on recent metrics.
    /// Returns a diagnosis if improvement is warranted, nil otherwise.
    public func shouldTrigger() -> Diagnosis? {
        // Cooldown check
        guard Date().timeIntervalSince(lastTriggerTime) > cooldownSeconds else { return nil }
        guard consecutiveAttempts < maxConsecutiveAttempts else { return nil }

        let stats = TaskOutcomeRecorder.shared.stats(days: 3)
        guard !stats.isEmpty else { return nil }

        // 1. Check overall completion rate
        let totalTasks = stats.reduce(0) { $0 + $1.total }
        let totalCompleted = stats.reduce(0) { $0 + $1.completed }
        let totalCancelled = stats.reduce(0) { $0 + $1.cancelled }
        guard totalTasks >= 5 else { return nil } // Need minimum sample
        let completionRate = Double(totalCompleted) / Double(totalTasks)
        let cancelRate = Double(totalCancelled) / Double(totalTasks)

        // Critical: completion rate below 30%
        if completionRate < 0.3 {
            return Diagnosis(
                category: .lowCompletionRate,
                severity: .critical,
                description: "最近3天任务完成率仅 \(Int(completionRate * 100))%（\(totalCompleted)/\(totalTasks)）",
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
        for ts in toolStats {
            let failRate = ts.total >= 5 ? 1.0 - Double(ts.successes) / Double(ts.total) : 0
            if failRate > 0.6 {
                return Diagnosis(
                    category: .highToolFailure,
                    severity: .warning,
                    description: "工具 \(ts.toolName) 失败率 \(Int(failRate * 100))%（\(ts.total - ts.successes)/\(ts.total)）",
                    evidence: "Tool: \(ts.toolName), Total: \(ts.total), Successes: \(ts.successes)",
                    suggestedFiles: ["ToolEngine.swift", "AgentLoop.swift"],
                    improvementPrompt: buildImprovementPrompt(for: .highToolFailure, evidence: "Tool \(ts.toolName) fail rate \(Int(failRate * 100))%")
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
                description: "最近3天任务完成率 \(Int(completionRate * 100))%（\(totalCompleted)/\(totalTasks)），低于目标50%",
                evidence: formatStats(stats),
                suggestedFiles: ["AgentLoop.swift", "Orchestrator.swift", "PromptComposer.swift"],
                improvementPrompt: buildImprovementPrompt(for: .lowCompletionRate, evidence: formatStats(stats))
            )
        }

        return nil
    }

    // MARK: - Improvement Execution

    /// Generate the full improvement task message that will be sent to the agent loop.
    /// The agent will read its own source, diagnose, edit, build, and restart.
    public func generateImprovementTask(diagnosis: Diagnosis) -> String {
        lastTriggerTime = Date()
        consecutiveAttempts += 1

        return """
        # 自我改进任务

        ## 诊断
        \(diagnosis.description)

        ## 严重程度
        \(diagnosis.severity.rawValue)

        ## 证据
        \(diagnosis.evidence)

        ## 任务要求

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
        6. 编译通过后，运行 `cd \(harnessRoot) && git add -A && git commit -m "self-improve: \(diagnosis.category.rawValue) - \(diagnosis.description.prefix(60))"` 提交更改
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
        consecutiveAttempts = 0
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [appPath] in
            // Quit
            let quit = Process()
            quit.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            quit.arguments = ["-e", "quit app \"Laicai\""]
            quit.standardOutput = Pipe()
            quit.standardError = Pipe()
            try? quit.run()
            quit.waitUntilExit()

            // Wait for clean exit
            Foundation.Thread.sleep(forTimeInterval: 1.5)

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

    private var db: OpaquePointer? = {
        let dir = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first! + "/Laicai"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/self_improvement.sqlite3"
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
        sqlite3_exec(db, """
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
        return db
    }()

    public func recordAttempt(
        category: String,
        description: String,
        filesChanged: [String],
        buildSuccess: Bool,
        commitHash: String?
    ) {
        guard let db else { return }
        let sql = "INSERT INTO improvements (category, description, files_changed, build_success, commit_hash, created_at) VALUES (?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (category as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (description as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (filesChanged.joined(separator: ",") as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 4, buildSuccess ? 1 : 0)
        if let hash = commitHash {
            sqlite3_bind_text(stmt, 5, (hash as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    public func recentImprovements(limit: Int = 10) -> [ImprovementRecord] {
        guard let db else { return [] }
        let sql = "SELECT id, category, description, files_changed, build_success, commit_hash, created_at FROM improvements ORDER BY created_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var results: [ImprovementRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(ImprovementRecord(
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

    // MARK: - Helpers

    private func formatStats(_ stats: [OutcomeStatsRow]) -> String {
        stats.map { row in
            "intent=\(row.intent) route=\(row.routeLabel) total=\(row.total) completed=\(row.completed) cancelled=\(row.cancelled) avgIter=\(String(format: "%.1f", row.avgIterations))"
        }.joined(separator: "\n")
    }

    private func buildImprovementPrompt(for category: Diagnosis.Category, evidence: String) -> String {
        // Include recent improvement history to avoid repeating failed approaches
        let history = recentImprovements(limit: 5)
        let historyBlock = history.isEmpty ? "" : """

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
