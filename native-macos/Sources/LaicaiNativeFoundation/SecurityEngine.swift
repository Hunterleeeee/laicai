import Foundation
import LaicaiNativeDomain

#if canImport(SQLite3)
    import SQLite3
#endif

// MARK: - Audit Log

public struct AuditEntry: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var timestamp: Date
    public var action: String
    public var tool: String
    public var input: String
    public var output: String
    public var success: Bool
    public var userID: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        action: String,
        tool: String,
        input: String = "",
        output: String = "",
        success: Bool = true,
        userID: String = "default"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.tool = tool
        self.input = input
        self.output = String(output.prefix(500))
        self.success = success
        self.userID = userID
    }
}

@MainActor
public final class AuditLog: ObservableObject {
    public static let shared = AuditLog()

    @Published public private(set) var entries: [AuditEntry] = []

    private let maxEntries = 500
    private var database: OpaquePointer?

    private init() {
        openDB()
        loadFromDB()
    }

    // MARK: - SQLite Persistence

    private func openDB() {
        let directory = LaicaiStoragePaths.ensureDirectory(LaicaiStoragePaths.appDirectory)
        let path = directory.appendingPathComponent("audit.sqlite3").path
        if sqlite3_open(path, &database) != SQLITE_OK {
            database = nil
            return
        }
        sqlite3_exec(
            database,
            """
            CREATE TABLE IF NOT EXISTS audit_log (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                action TEXT NOT NULL,
                tool TEXT NOT NULL,
                input TEXT NOT NULL DEFAULT '',
                output TEXT NOT NULL DEFAULT '',
                success INTEGER NOT NULL DEFAULT 1,
                user_id TEXT NOT NULL DEFAULT 'default'
            )
            """, nil, nil, nil)
    }

    private func loadFromDB() {
        guard let database else { return }
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT id, timestamp, action, tool, input, output, success, user_id FROM audit_log ORDER BY timestamp DESC LIMIT ?", -1,
                &stmt, nil)
                == SQLITE_OK
        else { return }
        sqlite3_bind_int(stmt, 1, Int32(maxEntries))
        var loaded: [AuditEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let action = String(cString: sqlite3_column_text(stmt, 2))
            let tool = String(cString: sqlite3_column_text(stmt, 3))
            let input = String(cString: sqlite3_column_text(stmt, 4))
            let output = String(cString: sqlite3_column_text(stmt, 5))
            let success = sqlite3_column_int(stmt, 6) != 0
            let userID = String(cString: sqlite3_column_text(stmt, 7))
            loaded.append(
                AuditEntry(
                    id: id, timestamp: timestamp, action: action, tool: tool, input: input, output: output, success: success, userID: userID
                ))
        }
        sqlite3_finalize(stmt)
        entries = loaded
    }

    private func persistEntry(_ entry: AuditEntry) {
        guard let database else { return }
        let insertSQL = """
            INSERT OR REPLACE INTO audit_log
            (id, timestamp, action, tool, input, output, success, user_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else { return }
        sqlite3BindTextSafe(insertStmt, 1, entry.id.uuidString)
        sqlite3_bind_double(insertStmt, 2, entry.timestamp.timeIntervalSince1970)
        sqlite3BindTextSafe(insertStmt, 3, entry.action)
        sqlite3BindTextSafe(insertStmt, 4, entry.tool)
        sqlite3BindTextSafe(insertStmt, 5, entry.input)
        sqlite3BindTextSafe(insertStmt, 6, entry.output)
        sqlite3_bind_int(insertStmt, 7, entry.success ? 1 : 0)
        sqlite3BindTextSafe(insertStmt, 8, entry.userID)
        let stepResult = sqlite3_step(insertStmt)
        if stepResult != SQLITE_DONE && stepResult != SQLITE_ROW {
            let errMsg = String(cString: sqlite3_errmsg(database))
            NSLog("[AuditLog] persistEntry failed: \(errMsg) (code \(stepResult))")
        }
        sqlite3_finalize(insertStmt)
        // Prune old entries
        var pruneStmt: OpaquePointer?
        if sqlite3_prepare_v2(
            database, "DELETE FROM audit_log WHERE id NOT IN (SELECT id FROM audit_log ORDER BY timestamp DESC LIMIT ?)", -1, &pruneStmt,
            nil)
            == SQLITE_OK
        {
            sqlite3_bind_int(pruneStmt, 1, Int32(maxEntries))
            sqlite3_step(pruneStmt)
        }
        sqlite3_finalize(pruneStmt)
    }

    private func clearDB() {
        guard let database else { return }
        sqlite3_exec(database, "DELETE FROM audit_log", nil, nil, nil)
    }

    // MARK: - Public API

    public func record(
        tool: String,
        input: String = "",
        output: String = "",
        success: Bool = true
    ) {
        let entry = AuditEntry(
            action: "tool_call",
            tool: tool,
            input: String(input.prefix(200)),
            output: String(output.prefix(500)),
            success: success
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        persistEntry(entry)
    }

    public func clear() {
        entries.removeAll()
        clearDB()
    }

    public var recentEntries: [AuditEntry] {
        Array(entries.prefix(50))
    }

    public var writeOperations: [AuditEntry] {
        entries.filter { $0.tool == "file.write" || $0.tool == "shell.exec" }
    }

    public var rejectedOperations: [AuditEntry] {
        entries.filter { !$0.success }
    }
}

// MARK: - Sandbox Policy

public struct SandboxPolicy: Sendable {
    public var allowedWritePaths: [String]
    public var deniedPaths: Set<String>
    public var allowedShellCommands: Set<String>
    public var deniedShellPatterns: Set<String>
    public var maxFileSize: Int
    public var requireApprovalForWrites: Bool

    public init(
        allowedWritePaths: [String] = [],
        deniedPaths: Set<String> = [".env", "credentials", "secrets", ".ssh", "id_rsa", "id_ed25519", ".pem", ".key"],
        allowedShellCommands: Set<String> = Set(ShellTool.allowedPrefixes),
        deniedShellPatterns: Set<String> = ["rm -rf", "sudo ", "chmod 777", "chown ", "mkfs", ":(){", "> /dev/", "curl | sh", "wget | sh"],
        maxFileSize: Int = 1_000_000,
        requireApprovalForWrites: Bool = true
    ) {
        self.allowedWritePaths = allowedWritePaths
        self.deniedPaths = deniedPaths
        self.allowedShellCommands = allowedShellCommands
        self.deniedShellPatterns = deniedShellPatterns
        self.maxFileSize = maxFileSize
        self.requireApprovalForWrites = requireApprovalForWrites
    }

    public func isPathAllowed(_ path: String) -> Bool {
        let normalizedPath = path.lowercased()
        for denied in deniedPaths where normalizedPath.contains(denied.lowercased()) {
            return false
        }
        if allowedWritePaths.isEmpty { return true }
        return allowedWritePaths.contains { path.hasPrefix($0) }
    }

    public func isCommandAllowed(_ command: String) -> Bool {
        let normalized = command.lowercased()
        if deniedShellPatterns.contains(where: { normalized.contains($0.lowercased()) }) {
            return false
        }
        guard !allowedShellCommands.isEmpty else { return true }
        return ShellCommandAllowlistValidator.validate(
            command,
            allowedCommands: allowedShellCommands
        )
    }

    public func isFileSizeAllowed(_ size: Int) -> Bool {
        size <= maxFileSize
    }
}

private enum ShellCommandAllowlistValidator {
    private struct CommandInvocation {
        let executable: String
        let arguments: [String]
    }

    private struct CommandTokenizer {
        private var segments: [[String]] = []
        private var tokens: [String] = []
        private var token = ""
        private var quote: Character?
        private var escaped = false

        mutating func tokenize(_ command: String) -> [[String]]? {
            let characters = Array(command)
            for index in characters.indices {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                guard consume(characters[index], next: next) else { return nil }
            }

            guard quote == nil, !escaped else { return nil }
            flushSegment()
            return segments
        }

        private mutating func consume(_ character: Character, next: Character?) -> Bool {
            if escaped {
                token.append(character)
                escaped = false
                return true
            }
            if character == "\\" && quote != "'" {
                escaped = true
                return true
            }
            if quote != "'", isCommandSubstitutionStart(character, next: next) {
                return false
            }
            if let activeQuote = quote {
                return consumeQuoted(character, activeQuote: activeQuote)
            }
            return consumeUnquoted(character, next: next)
        }

        private mutating func consumeQuoted(_ character: Character, activeQuote: Character) -> Bool {
            if character == activeQuote {
                quote = nil
            } else {
                token.append(character)
            }
            return true
        }

        private mutating func consumeUnquoted(_ character: Character, next: Character?) -> Bool {
            if character == "'" || character == "\"" {
                quote = character
                return true
            }
            if character == "(" || character == ")" || (character == "<" && next == "<") {
                return false
            }
            if character.isWhitespace {
                consumeWhitespace(character)
                return true
            }
            if character == ";" || character == "|" {
                flushSegment()
                return true
            }
            if character == "&" {
                consumeAmpersand()
                return true
            }
            token.append(character)
            return true
        }

        private func isCommandSubstitutionStart(_ character: Character, next: Character?) -> Bool {
            character == "`" || (character == "$" && next == "(")
        }

        private mutating func consumeWhitespace(_ character: Character) {
            if character == "\n" || character == "\r" {
                flushSegment()
            } else {
                flushToken()
            }
        }

        private mutating func consumeAmpersand() {
            if token.hasSuffix(">") {
                token.append("&")
            } else {
                flushSegment()
            }
        }

        private mutating func flushToken() {
            guard !token.isEmpty else { return }
            tokens.append(token)
            token.removeAll(keepingCapacity: true)
        }

        private mutating func flushSegment() {
            flushToken()
            guard !tokens.isEmpty else { return }
            segments.append(tokens)
            tokens.removeAll(keepingCapacity: true)
        }
    }

    static func validate(_ command: String, allowedCommands: Set<String>) -> Bool {
        guard let invocations = invocations(in: command), !invocations.isEmpty else {
            return false
        }
        let allowed = Set(
            allowedCommands.compactMap { entry -> String? in
                let token = entry.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                guard !token.isEmpty else { return nil }
                return executableName(token)
            })
        return invocations.allSatisfy { invocation in
            allowed.contains(invocation.executable)
                && !usesInlineEvaluation(invocation)
                && !usesUnsafeRedirection(invocation)
                && !usesDirectMutation(invocation)
        }
    }

    private static func invocations(in command: String) -> [CommandInvocation]? {
        guard let segments = commandSegments(command) else { return nil }
        var result: [CommandInvocation] = []
        for segment in segments where !segment.isEmpty {
            guard let invocation = invocation(from: segment) else { return nil }
            result.append(invocation)
        }
        return result
    }

    /// Tokenizes only enough shell syntax to validate every command in a chain.
    /// Unsupported constructs are rejected instead of being guessed at.
    private static func commandSegments(_ command: String) -> [[String]]? {
        var tokenizer = CommandTokenizer()
        return tokenizer.tokenize(command)
    }

    private static func invocation(from tokens: [String]) -> CommandInvocation? {
        var index = 0
        while index < tokens.count, isEnvironmentAssignment(tokens[index]) {
            index += 1
        }
        guard index < tokens.count else { return nil }

        var executable = executableName(tokens[index])
        if executable == "env" {
            index += 1
            while index < tokens.count, isEnvironmentAssignment(tokens[index]) {
                index += 1
            }
            if index == tokens.count {
                return CommandInvocation(executable: "env", arguments: [])
            }
            guard !tokens[index].hasPrefix("-") else { return nil }
            executable = executableName(tokens[index])
        }
        return CommandInvocation(
            executable: executable,
            arguments: Array(tokens.dropFirst(index + 1))
        )
    }

    private static func executableName(_ token: String) -> String {
        (token as NSString).lastPathComponent.lowercased()
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        token.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*=.*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func usesInlineEvaluation(_ invocation: CommandInvocation) -> Bool {
        let flags = Set(invocation.arguments)
        switch invocation.executable {
        case "python", "python3", "ruby":
            return flags.contains("-c") || flags.contains("-e")
        case "node", "deno", "bun":
            return !flags.isDisjoint(with: ["-e", "--eval", "-p", "--print"])
        default:
            return false
        }
    }

    private static func usesUnsafeRedirection(_ invocation: CommandInvocation) -> Bool {
        invocation.arguments.contains { argument in
            guard argument.contains(">") || argument.contains("<") else { return false }
            let allowedDescriptorRedirect =
                argument.range(
                    of: #"^[012]?[<>]&[012]$"#,
                    options: .regularExpression
                ) != nil
            let allowedNullRedirect =
                argument.range(
                    of: #"^[012]?[<>]/dev/null$"#,
                    options: .regularExpression
                ) != nil
            return !allowedDescriptorRedirect && !allowedNullRedirect
        }
    }

    private static func usesDirectMutation(_ invocation: CommandInvocation) -> Bool {
        let arguments = invocation.arguments.map { $0.lowercased() }
        switch invocation.executable {
        case "sed":
            return arguments.contains { $0 == "-i" || $0.hasPrefix("-i") }
        case "find":
            return arguments.contains { ["-delete", "-exec", "-execdir", "-ok", "-okdir"].contains($0) }
        case "awk":
            return arguments.contains { $0.contains("system(") }
        case "curl":
            return arguments.contains { ["-o", "--output", "--remote-name"].contains($0) }
        case "git":
            return isMutatingGitInvocation(arguments)
        default:
            return false
        }
    }

    private static func isMutatingGitInvocation(_ arguments: [String]) -> Bool {
        guard let subcommand = arguments.first(where: { !$0.hasPrefix("-") }) else {
            return false
        }
        let readOnly = Set([
            "status", "diff", "log", "show", "rev-parse", "grep", "ls-files",
            "describe", "remote", "tag", "blame", "shortlog",
        ])
        return !readOnly.contains(subcommand)
    }
}

// MARK: - Security Manager

@MainActor
public final class SecurityManager: ObservableObject {
    public static let shared = SecurityManager()

    @Published public var policy: SandboxPolicy = SandboxPolicy()
    @Published public var sandboxConfig: SandboxConfig = .default

    private init() {}

    /// Check if a path can be read. Returns nil if allowed, or an error message if denied.
    public func checkRead(path: String) -> String? {
        if let boundaryError = WorkspaceSandbox.shared.enforceWorkspaceBoundary(path: path) {
            return boundaryError
        }
        return checkSensitiveRead(path: path)
    }

    /// Check if a path can be read within the task's current workspace.
    public func checkRead(path: String, workspaceRoot: String) -> String? {
        if let boundaryError = WorkspaceSandbox.shared.enforceWorkspaceBoundary(path: path, workspaceRoot: workspaceRoot) {
            return boundaryError
        }
        return checkSensitiveRead(path: path)
    }

    private func checkSensitiveRead(path: String) -> String? {
        let normalizedPath = path.lowercased()
        for denied in policy.deniedPaths where normalizedPath.contains(denied.lowercased()) {
            return "路径包含敏感关键词：\(denied)"
        }
        return nil
    }

    /// Check if a path can be written. Returns nil if allowed, or an error message if denied.
    public func checkWrite(path: String) -> String? {
        if let boundaryError = WorkspaceSandbox.shared.enforceWorkspaceBoundary(path: path) {
            return boundaryError
        }
        return checkWritePolicy(path: path)
    }

    /// Check a write against the task's explicit workspace. Tool executions must use
    /// this overload so a previous task's global sandbox state cannot leak into them.
    public func checkWrite(path: String, workspaceRoot: String) -> String? {
        if let boundaryError = WorkspaceSandbox.shared.enforceWorkspaceBoundary(
            path: path,
            workspaceRoot: workspaceRoot
        ) {
            return boundaryError
        }
        return checkWritePolicy(path: path)
    }

    private func checkWritePolicy(path: String) -> String? {
        if !policy.isPathAllowed(path) {
            return "路径不在允许列表中或包含敏感关键词"
        }
        if policy.requireApprovalForWrites {
            // Still allowed, but needs review - return nil for now
            // The tool will handle the review flow
        }
        return nil  // Allowed (may need review)
    }

    /// Check if a shell command can be executed. Returns nil if allowed, or an error message if denied.
    public func checkShell(command: String) -> String? {
        return shellSecurityCheck(command: command, policy: policy)
    }

    /// Snapshot policy for use in non-MainActor contexts
    public var policySnapshot: SandboxPolicy { policy }

    private static func toolPolicyViolation(forShellCommand command: String) -> String? {
        let normalized =
            command
            .replacingOccurrences(of: #"\\\s*\n"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Only block unbounded traversals. Allow find with -maxdepth or find -type d.
        let hasBoundedFind = normalized.contains("-maxdepth")
        let projectTraversalPatterns = [
            #"(^|[;&|]\s*)find\s+\.($|\s)"#,  // find . (unbounded from cwd)
            #"(^|[;&|]\s*)ls\s+(-[a-z]*r[a-z]*|-r)"#,  // ls -R
            #"(^|[;&|]\s*)tree(\s|$)"#,  // tree
        ]
        if !hasBoundedFind && projectTraversalPatterns.contains(where: { normalized.range(of: $0, options: .regularExpression) != nil }) {
            return "工具策略拦截：不要用 shell 遍历项目结构。请先使用 workspace.index 建立项目地图，再用 file.read 或 code.search 精确读取。"
        }

        if normalized.contains("sed 's#^./##'")
            || normalized.contains("head -300")
            || normalized.contains("head -200")
        {
            return "工具策略拦截：这看起来是在用 shell 生成文件清单。请改用 workspace.index。"
        }
        return nil
    }

    /// Check if a file size is within limits.
    public func checkFileSize(_ size: Int) -> String? {
        if !policy.isFileSizeAllowed(size) {
            return "文件大小超出限制（\(size) > \(policy.maxFileSize)）"
        }
        return nil
    }

    /// Add a path to the denied list
    public func denyPath(_ path: String) {
        var newDenied = policy.deniedPaths
        newDenied.insert(path)
        policy.deniedPaths = newDenied
    }

    /// Add a command to the allowed list
    public func allowCommand(_ command: String) {
        var newAllowed = policy.allowedShellCommands
        newAllowed.insert(command)
        policy.allowedShellCommands = newAllowed
    }

    /// Add a write path prefix to the allowed list
    public func allowWritePath(_ path: String) {
        var newPaths = policy.allowedWritePaths
        newPaths.append(path)
        policy.allowedWritePaths = newPaths
    }
}

// MARK: - Permission Level

public enum PermissionLevel: String, Codable, Sendable, CaseIterable {
    /// Auto-approved: reads, searches, indexing
    case automatic
    /// Requires review: file writes, shell commands
    case review
    /// Always denied: destructive operations
    case denied

    public var title: String {
        switch self {
        case .automatic: return "自动"
        case .review: return "审查"
        case .denied: return "禁止"
        }
    }
}

// MARK: - Workspace Sandbox

@MainActor
public final class WorkspaceSandbox: ObservableObject {
    public static let shared = WorkspaceSandbox()

    @Published public var workspaceRoot: String = ""
    @Published public var permissionOverrides: [String: PermissionLevel] = [:]
    /// Additional paths allowed for the current task (e.g. user-specified target directories)
    @Published public var allowedPaths: Set<String> = []

    private init() {}

    /// Grant write access to a specific path for the current task
    public func addAllowedPath(_ path: String) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        allowedPaths.insert(standardized)
    }

    /// Clear task-specific allowed paths (call when task ends)
    public func clearAllowedPaths() {
        allowedPaths.removeAll()
    }

    /// Default permission for a tool action
    public func defaultPermission(for action: SandboxAction) -> PermissionLevel {
        switch action {
        case .read, .search, .index:
            return .automatic
        case .write, .shell:
            return .review
        case .delete, .destructiveShell:
            return .denied
        }
    }

    /// Effective permission considering overrides
    public func effectivePermission(for action: SandboxAction) -> PermissionLevel {
        if let override = permissionOverrides[action.rawValue] {
            return override
        }
        return defaultPermission(for: action)
    }

    /// Check if a path is within the workspace sandbox or in allowed paths
    public func isWithinWorkspace(_ path: String) -> Bool {
        guard !workspaceRoot.isEmpty else { return true }
        let absolute: String
        if path.hasPrefix("/") {
            absolute = path
        } else {
            absolute = (workspaceRoot as NSString).appendingPathComponent(path)
        }
        let standardized = URL(fileURLWithPath: absolute).standardizedFileURL.path
        let rootStandardized = URL(fileURLWithPath: workspaceRoot).standardizedFileURL.path
        if standardized.hasPrefix(rootStandardized + "/") || standardized == rootStandardized {
            return true
        }
        // Check task-specific allowed paths
        for allowed in allowedPaths {
            if standardized.hasPrefix(allowed + "/") || standardized == allowed {
                return true
            }
        }
        return false
    }

    /// Enforce workspace boundary: returns error if path is outside workspace
    public func enforceWorkspaceBoundary(path: String) -> String? {
        guard !workspaceRoot.isEmpty else { return nil }
        if !isWithinWorkspace(path) {
            return "路径超出工作区范围：\(path) 不在 \(workspaceRoot) 内"
        }
        return nil
    }

    /// Enforce a specific task workspace boundary without mutating global sandbox state.
    public func enforceWorkspaceBoundary(path: String, workspaceRoot root: String) -> String? {
        let cleanedRoot = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedRoot.isEmpty else { return nil }
        let absolute =
            path.hasPrefix("/")
            ? path
            : (cleanedRoot as NSString).appendingPathComponent(path)
        let standardized = URL(fileURLWithPath: absolute).standardizedFileURL.path
        let rootStandardized = URL(fileURLWithPath: cleanedRoot).standardizedFileURL.path
        if standardized.hasPrefix(rootStandardized + "/") || standardized == rootStandardized {
            return nil
        }
        for allowed in allowedPaths {
            if standardized.hasPrefix(allowed + "/") || standardized == allowed {
                return nil
            }
        }
        return "路径超出工作区范围：\(path) 不在 \(cleanedRoot) 内"
    }

    /// Check if a workspace root is dangerously broad (home dir, /Users, / etc.)
    public nonisolated static func isOverlyBroadWorkspace(_ path: String) -> Bool {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return true }
        let standardized = URL(fileURLWithPath: cleaned).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let dangerousPaths: Set<String> = ["/", "/Users", "/var", "/tmp", "/private", home]
        return dangerousPaths.contains(standardized)
    }

    /// Development smoke-test workspaces are intentionally disposable. They must
    /// never become the user's real default workspace through persisted settings.
    public nonisolated static func isDisposableSmokeWorkspace(_ path: String) -> Bool {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let standardized = URL(fileURLWithPath: cleaned).standardizedFileURL.path
        let lower = standardized.lowercased()
        let last = URL(fileURLWithPath: standardized).lastPathComponent.lowercased()
        if isEphemeralWorkspacePath(standardized), lower.contains("laicai-") {
            return true
        }
        return (lower.hasPrefix("/tmp/laicai-") || lower.hasPrefix("/private/tmp/laicai-"))
            && (last.contains("smoke") || lower.contains("-smoke"))
    }

    private nonisolated static func isEphemeralWorkspacePath(_ standardizedPath: String) -> Bool {
        let lower = standardizedPath.lowercased()
        if lower.hasPrefix("/var/folders/") || lower.hasPrefix("/private/var/folders/") {
            return true
        }
        if lower.hasPrefix("/var/tmp/") || lower.hasPrefix("/private/var/tmp/") {
            return true
        }
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path.lowercased()
        if !tempRoot.isEmpty, tempRoot != "/", lower.hasPrefix(tempRoot) {
            return true
        }
        return false
    }

    /// Set permission override for a specific action
    public func setPermissionOverride(for action: SandboxAction, level: PermissionLevel) {
        permissionOverrides[action.rawValue] = level
    }

    public enum SandboxAction: String, Sendable {
        case read = "read"
        case search = "search"
        case index = "index"
        case write = "write"
        case shell = "shell"
        case delete = "delete"
        case destructiveShell = "destructive_shell"
    }
}

// MARK: - Shell Security Check (non-isolated)

/// Free function for checking shell commands without MainActor requirement.
/// Use with a `SandboxPolicy` snapshot obtained from `SecurityManager.shared.policySnapshot`.
public func shellSecurityCheck(command: String, policy: SandboxPolicy) -> String? {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.lowercased()
    if let dangerous = DangerousOperationGuard.shellViolation(command: trimmed) {
        return dangerous
    }
    if let denied = policy.deniedShellPatterns.first(where: { normalized.contains($0.lowercased()) }) {
        return "命令包含危险模式：\(denied)"
    }
    if !policy.isCommandAllowed(trimmed) {
        return "命令不在白名单中：\(command.split(separator: " ").first ?? "")"
    }
    // Tool policy violation check
    let normalizedCmd =
        trimmed
        .replacingOccurrences(of: #"\\\s*\n"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let projectTraversalPatterns = [
        #"(^|[;&|]\s*)find\s+\.($|\s)"#,
        #"(^|[;&|]\s*)find\s+\S+\s+-type\s+f"#,
        #"(^|[;&|]\s*)ls\s+(-[a-z]*r[a-z]*|-r)"#,
        #"(^|[;&|]\s*)tree(\s|$)"#,
    ]
    if projectTraversalPatterns.contains(where: { normalizedCmd.range(of: $0, options: .regularExpression) != nil }) {
        return "工具策略拦截：不要用 shell 遍历项目结构。请先使用 workspace.index 建立项目地图，再用 file.read 或 code.search 精确读取。"
    }
    if normalizedCmd.contains("sed 's#^./##'")
        || normalizedCmd.contains("head -300")
        || normalizedCmd.contains("head -200")
    {
        return "工具策略拦截：这看起来是在用 shell 生成文件清单。请改用 workspace.index。"
    }
    return nil
}

public enum DangerousOperationGuard {
    public static func shellViolation(command: String) -> String? {
        let normalized =
            command
            .replacingOccurrences(of: #"\\\s*\n"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        let exactOrPrefixPatterns = [
            #"(^|[;&|]\s*)sudo(\s|$)"#,
            #"(^|[;&|]\s*)su(\s|$)"#,
            #"(^|[;&|]\s*)rm\s+(-[a-z]*r[a-z]*f|-rf|-fr)(\s|$)"#,
            #"(^|[;&|]\s*)git\s+reset\s+--hard(\s|$)"#,
            #"(^|[;&|]\s*)git\s+clean\s+-[a-z]*f"#,
            #"(^|[;&|]\s*)git\s+push(\s+\S+)*\s+--force"#,
            #"(^|[;&|]\s*)git\s+push(\s+\S+)*\s+-f(\s|$)"#,
            #"(^|[;&|]\s*)git\s+rebase(\s|$)"#,
            #"(^|[;&|]\s*)brew\s+(install|uninstall|upgrade|tap|services)(\s|$)"#,
            #"(^|[;&|]\s*)curl\s+[^|;&]+[|]\s*(sh|bash|zsh)(\s|$)"#,
            #"(^|[;&|]\s*)wget\s+[^|;&]+[|]\s*(sh|bash|zsh)(\s|$)"#,
            #">\s*(/etc/|/usr/|/bin/|/sbin/|/var/|/private/|~/.ssh|.*\.env)"#,
        ]
        if exactOrPrefixPatterns.contains(where: { normalized.range(of: $0, options: .regularExpression) != nil }) {
            return "危险操作已拦截：删除、重置、系统安装、强制发布、密钥/系统路径写入等操作需要用户明确审查，不能由会话自动执行。"
        }
        return nil
    }

    public static func writeViolation(path: String, oldContent: String, context: TaskContext) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let lower = standardized.lowercased()
        let sensitiveMarkers = [
            "/.ssh/", "/.gnupg/", "/keychain", ".env", "secret", "token", "credential", "id_rsa", "id_ed25519", ".pem", ".key",
        ]
        if sensitiveMarkers.contains(where: { lower.contains($0) }) {
            return "危险写入已拦截：目标看起来包含密钥、凭据或敏感配置，默认不允许会话自动准备覆盖。"
        }
        let systemPrefixes = ["/etc/", "/usr/", "/bin/", "/sbin/", "/var/", "/private/etc/"]
        if systemPrefixes.contains(where: { standardized.hasPrefix($0) }),
            !standardized.hasPrefix("/var/folders/"),
            !standardized.hasPrefix("/var/tmp/"),
            !standardized.hasPrefix("/private/var/folders/"),
            !standardized.hasPrefix("/private/var/tmp/")
        {
            return "危险写入已拦截：目标位于系统目录，必须由用户手动确认处理。"
        }
        let fileExists = FileManager.default.fileExists(atPath: standardized)
        if fileExists, hasUncommittedChange(path: standardized, workspaceRoot: context.workspaceRoot) {
            let readKeys = [standardized, path, relativePath(standardized, workspaceRoot: context.workspaceRoot)]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let hasCurrentRead =
                !oldContent.isEmpty
                ? readKeys.contains { key in
                    context.memory.fileContentCache[key] == oldContent || context.memory.readFiles.contains(key)
                }
                : readKeys.contains { context.memory.readFiles.contains($0) }
            if !hasCurrentRead {
                return
                    "工作区保护已拦截：\(relativePath(standardized, workspaceRoot: context.workspaceRoot)) 已有未提交改动。请先用 file.read 读取当前磁盘内容，再基于最新内容生成 diff，避免覆盖用户改动。"
            }
        }
        return nil
    }

    public static func documentWriteViolation(path: String, context: TaskContext) -> String? {
        writeViolation(path: path, oldContent: existingContentIfText(path), context: context)
    }

    private static func existingContentIfText(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: path),
            let data = FileManager.default.contents(atPath: path),
            data.count <= 1_000_000,
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    private static func hasUncommittedChange(path: String, workspaceRoot: String) -> Bool {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, GitTool.isGitRepository(root) else { return false }
        let relative = relativePath(path, workspaceRoot: root)
        guard !relative.isEmpty else { return false }
        do {
            let result = try ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["git", "-C", root, "status", "--porcelain", "--", relative],
                timeout: 10
            )
            guard result.exitCode == 0, !result.timedOut else { return false }
            let output = result.stdoutString
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    private static func relativePath(_ path: String, workspaceRoot: String) -> String {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return path }
        let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        if path == standardizedRoot { return "." }
        if path.hasPrefix(standardizedRoot + "/") {
            return String(path.dropFirst(standardizedRoot.count + 1))
        }
        return path
    }
}
