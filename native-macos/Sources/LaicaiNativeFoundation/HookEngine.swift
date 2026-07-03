import Foundation
import Darwin
import LaicaiNativeDomain

// MARK: - Hook Definition

/// A hook that runs before or after a tool execution.
/// Loaded from .laicai/hooks/ directory as JSON files.
public struct HookDefinition: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var phase: Phase
    public var toolPattern: String
    public var command: String
    public var condition: String?
    public var enabled: Bool

    public enum Phase: String, Codable, Sendable {
        case pre
        case post
    }

    public init(
        id: UUID = UUID(),
        name: String,
        phase: Phase,
        toolPattern: String,
        command: String,
        condition: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.phase = phase
        self.toolPattern = toolPattern
        self.command = command
        self.condition = condition
        self.enabled = enabled
    }

    /// Check if this hook matches the given tool name
    public func matches(toolName: String) -> Bool {
        guard enabled else { return false }
        if toolPattern == "*" { return true }
        if toolPattern == toolName { return true }
        // Glob: "file.*" matches "file.read", "file.write"
        if toolPattern.hasSuffix("*") {
            let prefix = String(toolPattern.dropLast())
            return toolName.hasPrefix(prefix)
        }
        return false
    }
}

// MARK: - Hook Engine

@MainActor
public final class HookEngine: ObservableObject {
    public static let shared = HookEngine()

    @Published public private(set) var hooks: [HookDefinition] = []
    @Published public private(set) var lastHookResults: [String: HookResult] = [:]

    public struct HookResult: Sendable {
        public let hookName: String
        public let output: String
        public let success: Bool
        public let duration: TimeInterval
    }

    private init() {}

    // MARK: - Load hooks from disk

    public func loadHooks(workspaceRoot: String) {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }

        var hookDirs = [
            (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "")
                .appending("/Laicai/hooks")
        ]
        if WorkspaceTrust.isTrusted(root) {
            hookDirs.insert((root as NSString).appendingPathComponent(".laicai/hooks"), at: 0)
        }

        var loadedHooks: [HookDefinition] = []
        let decoder = JSONDecoder()

        for dir in hookDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".json") {
                let path = (dir as NSString).appendingPathComponent(file)
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let hook = try? decoder.decode(HookDefinition.self, from: data) else { continue }
                loadedHooks.append(hook)
            }
        }

        hooks = loadedHooks
    }

    // MARK: - Execute hooks

    /// Run all pre-hooks for a tool. Returns aggregated output or nil if no hooks matched.
    public func runPreHooks(toolName: String, params: [String: String], context: TaskContext) async -> String? {
        let matching = hooks.filter { $0.phase == .pre && $0.matches(toolName: toolName) }
        guard !matching.isEmpty else { return nil }

        var outputs: [String] = []
        for hook in matching {
            let result = await executeHook(hook, toolName: toolName, params: params, context: context)
            lastHookResults[hook.name] = result
            if !result.success {
                outputs.append("⚠️ pre-hook「\(hook.name)」失败：\(result.output)")
            } else if !result.output.isEmpty {
                outputs.append("hook「\(hook.name)」：\(result.output)")
            }
        }
        return outputs.isEmpty ? nil : outputs.joined(separator: "\n")
    }

    /// Run all post-hooks for a tool. Returns aggregated output or nil.
    public func runPostHooks(toolName: String, params: [String: String], result: ToolResult, context: TaskContext) async -> String? {
        let matching = hooks.filter { $0.phase == .post && $0.matches(toolName: toolName) }
        guard !matching.isEmpty else { return nil }

        var outputs: [String] = []
        for hook in matching {
            // Skip post-hook if condition requires success and tool failed
            if let condition = hook.condition, condition == "on_success" && !result.success { continue }
            if let condition = hook.condition, condition == "on_failure" && result.success { continue }

            let hookResult = await executeHook(hook, toolName: toolName, params: params, context: context)
            lastHookResults[hook.name] = hookResult
            if !hookResult.output.isEmpty {
                outputs.append("post-hook「\(hook.name)」：\(hookResult.output)")
            }
        }
        return outputs.isEmpty ? nil : outputs.joined(separator: "\n")
    }

    /// Execute a single hook command
    private func executeHook(_ hook: HookDefinition, toolName: String, params: [String: String], context: TaskContext) async -> HookResult {
        let start = CFAbsoluteTimeGetCurrent()

        // Substitute variables in command
        var cmd = hook.command
            .replacingOccurrences(of: "{{tool}}", with: toolName)
            .replacingOccurrences(of: "{{workspace}}", with: context.workspaceRoot)
        for (key, value) in params {
            cmd = cmd.replacingOccurrences(of: "{{\(key)}}", with: value)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", cmd]
        process.currentDirectoryURL = URL(fileURLWithPath: context.workspaceRoot.isEmpty ? NSHomeDirectory() : context.workspaceRoot)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()

            if !Self.waitForExit(process, timeoutSeconds: 10) {
                process.terminate()
                if !Self.waitForExit(process, timeoutSeconds: 2) {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = Self.waitForExit(process, timeoutSeconds: 1)
                }
            }

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errOutput = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let duration = CFAbsoluteTimeGetCurrent() - start

            let success = process.terminationStatus == 0
            let combinedOutput = [output, errOutput].filter { !$0.isEmpty }.joined(separator: "\n")

            return HookResult(hookName: hook.name, output: String(combinedOutput.prefix(500)), success: success, duration: duration)
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - start
            return HookResult(hookName: hook.name, output: "Hook执行失败：\(error.localizedDescription)", success: false, duration: duration)
        }
    }

    // MARK: - Hook Management

    public func addHook(_ hook: HookDefinition, workspaceRoot: String) {
        hooks.append(hook)
        saveHook(hook, workspaceRoot: workspaceRoot)
    }

    public func removeHook(id: UUID, workspaceRoot: String) {
        guard let index = hooks.firstIndex(where: { $0.id == id }) else { return }
        let hook = hooks.remove(at: index)
        let dir = (workspaceRoot as NSString).appendingPathComponent(".laicai/hooks")
        let slug = hook.name.lowercased().replacingOccurrences(of: " ", with: "-")
        let path = (dir as NSString).appendingPathComponent("\(slug).json")
        try? FileManager.default.removeItem(atPath: path)
    }

    public func toggleHook(id: UUID) {
        guard let index = hooks.firstIndex(where: { $0.id == id }) else { return }
        hooks[index].enabled.toggle()
    }

    private func saveHook(_ hook: HookDefinition, workspaceRoot: String) {
        let dir = (workspaceRoot as NSString).appendingPathComponent(".laicai/hooks")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let slug = hook.name.lowercased().replacingOccurrences(of: " ", with: "-")
        let path = (dir as NSString).appendingPathComponent("\(slug).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(hook) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func waitForExit(_ process: Process, timeoutSeconds: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if !process.isRunning { return true }
        let result = semaphore.wait(timeout: .now() + timeoutSeconds)
        process.terminationHandler = nil
        return result == .success || !process.isRunning
    }
}
