import Foundation
import LaicaiNativeDomain
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - SQLite Helpers

/// Safe text binding that copies the string immediately (SQLITE_TRANSIENT).
/// Prevents use-after-free when Swift temporaries are freed before sqlite3_step.
@discardableResult
func sqlite3_bind_text_safe(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) -> Int32 {
    let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
    return sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
}

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
    private var db: OpaquePointer?

    private init() {
        openDB()
        loadFromDB()
    }

    // MARK: - SQLite Persistence

    private func openDB() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("Laicai")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("audit.sqlite3")
        if sqlite3_open(path, &db) != SQLITE_OK { db = nil; return }
        sqlite3_exec(db, """
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
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, timestamp, action, tool, input, output, success, user_id FROM audit_log ORDER BY timestamp DESC LIMIT ?", -1, &stmt, nil) == SQLITE_OK else { return }
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
            loaded.append(AuditEntry(id: id, timestamp: timestamp, action: action, tool: tool, input: input, output: output, success: success, userID: userID))
        }
        sqlite3_finalize(stmt)
        entries = loaded
    }

    private func persistEntry(_ entry: AuditEntry) {
        guard let db else { return }
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO audit_log (id, timestamp, action, tool, input, output, success, user_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", -1, &insertStmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text_safe(insertStmt, 1, entry.id.uuidString)
        sqlite3_bind_double(insertStmt, 2, entry.timestamp.timeIntervalSince1970)
        sqlite3_bind_text_safe(insertStmt, 3, entry.action)
        sqlite3_bind_text_safe(insertStmt, 4, entry.tool)
        sqlite3_bind_text_safe(insertStmt, 5, entry.input)
        sqlite3_bind_text_safe(insertStmt, 6, entry.output)
        sqlite3_bind_int(insertStmt, 7, entry.success ? 1 : 0)
        sqlite3_bind_text_safe(insertStmt, 8, entry.userID)
        let stepResult = sqlite3_step(insertStmt)
        if stepResult != SQLITE_DONE && stepResult != SQLITE_ROW {
            let errMsg = String(cString: sqlite3_errmsg(db))
            NSLog("[AuditLog] persistEntry failed: \(errMsg) (code \(stepResult))")
        }
        sqlite3_finalize(insertStmt)
        // Prune old entries
        var pruneStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM audit_log WHERE id NOT IN (SELECT id FROM audit_log ORDER BY timestamp DESC LIMIT ?)", -1, &pruneStmt, nil) == SQLITE_OK {
            sqlite3_bind_int(pruneStmt, 1, Int32(maxEntries))
            sqlite3_step(pruneStmt)
        }
        sqlite3_finalize(pruneStmt)
    }

    private func clearDB() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM audit_log", nil, nil, nil)
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
        for denied in deniedPaths {
            if normalizedPath.contains(denied.lowercased()) {
                return false
            }
        }
        if allowedWritePaths.isEmpty { return true }
        return allowedWritePaths.contains { path.hasPrefix($0) }
    }

    public func isCommandAllowed(_ command: String) -> Bool {
        let normalized = command.lowercased()
        if deniedShellPatterns.contains(where: { normalized.contains($0.lowercased()) }) {
            return false
        }
        return true
    }

    public func isFileSizeAllowed(_ size: Int) -> Bool {
        size <= maxFileSize
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
    /// Reads are unrestricted — only sensitive keyword paths are blocked.
    public func checkRead(path: String) -> String? {
        let normalizedPath = path.lowercased()
        for denied in policy.deniedPaths {
            if normalizedPath.contains(denied.lowercased()) {
                return "路径包含敏感关键词：\(denied)"
            }
        }
        return nil
    }

    /// Check if a path can be written. Returns nil if allowed, or an error message if denied.
    public func checkWrite(path: String) -> String? {
        if let boundaryError = WorkspaceSandbox.shared.enforceWorkspaceBoundary(path: path) {
            return boundaryError
        }
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
        return ShellSecurityCheck(command: command, policy: policy)
    }

    /// Snapshot policy for use in non-MainActor contexts
    public var policySnapshot: SandboxPolicy { policy }

    private static func toolPolicyViolation(forShellCommand command: String) -> String? {
        let normalized = command
            .replacingOccurrences(of: #"\\\s*\n"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Only block unbounded traversals. Allow find with -maxdepth or find -type d.
        let hasBoundedFind = normalized.contains("-maxdepth")
        let projectTraversalPatterns = [
            #"(^|[;&|]\s*)find\s+\.($|\s)"#,             // find . (unbounded from cwd)
            #"(^|[;&|]\s*)ls\s+(-[a-z]*r[a-z]*|-r)"#,    // ls -R
            #"(^|[;&|]\s*)tree(\s|$)"#                     // tree
        ]
        if !hasBoundedFind && projectTraversalPatterns.contains(where: { normalized.range(of: $0, options: .regularExpression) != nil }) {
            return "工具策略拦截：不要用 shell 遍历项目结构。请先使用 workspace.index 建立项目地图，再用 file.read 或 code.search 精确读取。"
        }

        if normalized.contains("sed 's#^./##'")
            || normalized.contains("head -300")
            || normalized.contains("head -200") {
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
    case automatic = "automatic"
    /// Requires review: file writes, shell commands
    case review = "review"
    /// Always denied: destructive operations
    case denied = "denied"

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
        return (lower.hasPrefix("/tmp/laicai-") || lower.hasPrefix("/private/tmp/laicai-"))
            && (last.contains("smoke") || lower.contains("-smoke"))
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

// MARK: - Git Worktree Isolation

public struct GitWorktreeIsolation {
    /// Create a worktree for isolated task execution
    public static func createWorktree(in repoRoot: String, branchName: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repoRoot, "worktree", "add",
                             ".laicai/worktrees/\(branchName)", "-b", "laicai/\(branchName)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return (repoRoot as NSString).appendingPathComponent(".laicai/worktrees/\(branchName)")
        } catch {
            return nil
        }
    }
    
    /// Remove a worktree after task completion
    public static func removeWorktree(in repoRoot: String, branchName: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repoRoot, "worktree", "remove",
                             ".laicai/worktrees/\(branchName)", "--force"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    /// List active worktrees
    public static func listWorktrees(in repoRoot: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repoRoot, "worktree", "list", "--porcelain"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("worktree ") && $0.contains(".laicai/worktrees") }
                .map { line in
                    String(line.dropFirst("worktree ".count))
                }
        } catch {
            return []
        }
    }
}

// MARK: - Legacy Compatibility (tuples for older callers)

public extension SecurityManager {
    @available(*, deprecated, message: "Use checkRead(path:) returning String? instead")
    func checkReadLegacy(path: String) -> (allowed: Bool, reason: String?) {
        if let error = checkRead(path: path) {
            return (false, error)
        }
        return (true, nil)
    }

    @available(*, deprecated, message: "Use checkWrite(path:) returning String? instead")
    func checkWriteLegacy(path: String) -> (allowed: Bool, reason: String?) {
        if let error = checkWrite(path: path) {
            return (false, error)
        }
        return (true, nil)
    }

    @available(*, deprecated, message: "Use checkShell(command:) returning String? instead")
    func checkShellLegacy(command: String) -> (allowed: Bool, reason: String?) {
        if let error = checkShell(command: command) {
            return (false, error)
        }
        return (true, nil)
    }
}

// MARK: - Shell Security Check (non-isolated)

/// Free function for checking shell commands without MainActor requirement.
/// Use with a `SandboxPolicy` snapshot obtained from `SecurityManager.shared.policySnapshot`.
public func ShellSecurityCheck(command: String, policy: SandboxPolicy) -> String? {
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
    let normalizedCmd = trimmed
        .replacingOccurrences(of: #"\\\s*\n"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let projectTraversalPatterns = [
        #"(^|[;&|]\s*)find\s+\.($|\s)"#,
        #"(^|[;&|]\s*)find\s+\S+\s+-type\s+f"#,
        #"(^|[;&|]\s*)ls\s+(-[a-z]*r[a-z]*|-r)"#,
        #"(^|[;&|]\s*)tree(\s|$)"#
    ]
    if projectTraversalPatterns.contains(where: { normalizedCmd.range(of: $0, options: .regularExpression) != nil }) {
        return "工具策略拦截：不要用 shell 遍历项目结构。请先使用 workspace.index 建立项目地图，再用 file.read 或 code.search 精确读取。"
    }
    if normalizedCmd.contains("sed 's#^./##'")
        || normalizedCmd.contains("head -300")
        || normalizedCmd.contains("head -200") {
        return "工具策略拦截：这看起来是在用 shell 生成文件清单。请改用 workspace.index。"
    }
    return nil
}

public enum DangerousOperationGuard {
    public static func shellViolation(command: String) -> String? {
        let normalized = command
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
            #">\s*(/etc/|/usr/|/bin/|/sbin/|/var/|/private/|~/.ssh|.*\.env)"#
        ]
        if exactOrPrefixPatterns.contains(where: { normalized.range(of: $0, options: .regularExpression) != nil }) {
            return "危险操作已拦截：删除、重置、系统安装、强制发布、密钥/系统路径写入等操作需要用户明确审查，不能由 Agent 自动执行。"
        }
        return nil
    }

    public static func writeViolation(path: String, oldContent: String, context: TaskContext) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let lower = standardized.lowercased()
        let sensitiveMarkers = ["/.ssh/", "/.gnupg/", "/keychain", ".env", "secret", "token", "credential", "id_rsa", "id_ed25519", ".pem", ".key"]
        if sensitiveMarkers.contains(where: { lower.contains($0) }) {
            return "危险写入已拦截：目标看起来包含密钥、凭据或敏感配置，默认不允许 Agent 自动准备覆盖。"
        }
        let systemPrefixes = ["/etc/", "/usr/", "/bin/", "/sbin/", "/var/", "/private/etc/"]
        if systemPrefixes.contains(where: { standardized.hasPrefix($0) }),
           !standardized.hasPrefix("/var/folders/"),
           !standardized.hasPrefix("/var/tmp/"),
           !standardized.hasPrefix("/private/var/folders/"),
           !standardized.hasPrefix("/private/var/tmp/") {
            return "危险写入已拦截：目标位于系统目录，必须由用户手动确认处理。"
        }
        let fileExists = FileManager.default.fileExists(atPath: standardized)
        if fileExists, hasUncommittedChange(path: standardized, workspaceRoot: context.workspaceRoot) {
            let readKeys = [standardized, path, relativePath(standardized, workspaceRoot: context.workspaceRoot)]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let hasCurrentRead = !oldContent.isEmpty
                ? readKeys.contains { key in
                    context.memory.fileContentCache[key] == oldContent || context.memory.readFiles.contains(key)
                }
                : readKeys.contains { context.memory.readFiles.contains($0) }
            if !hasCurrentRead {
                return "工作区保护已拦截：\(relativePath(standardized, workspaceRoot: context.workspaceRoot)) 已有未提交改动。请先用 file.read 读取当前磁盘内容，再基于最新内容生成 diff，避免覆盖用户改动。"
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
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private static func hasUncommittedChange(path: String, workspaceRoot: String) -> Bool {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, GitTool.isGitRepository(root) else { return false }
        let relative = relativePath(path, workspaceRoot: root)
        guard !relative.isEmpty else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root, "status", "--porcelain", "--", relative]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
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
