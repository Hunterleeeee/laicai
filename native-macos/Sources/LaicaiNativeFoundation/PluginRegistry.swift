import Foundation
import Darwin
import LaicaiNativeDomain

// MARK: - Plugin System
// Loads third-party tool plugins from .laicai/plugins/ directory.
// Each plugin is a JSON manifest that either:
// 1. Wraps a shell command (type: "shell")
// 2. Wraps an MCP server (type: "mcp")
// 3. Wraps an HTTP endpoint (type: "http")

public struct PluginManifest: Codable, Sendable, Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var displayName: String
    public var description: String
    public var version: String
    public var type: PluginType
    public var parameters: [PluginParam]
    public var command: String?         // for shell type
    public var mcpServer: String?       // for mcp type — server config name
    public var endpoint: String?        // for http type
    public var httpMethod: String?      // for http type
    public var enabled: Bool

    public enum PluginType: String, Codable, Sendable {
        case shell
        case mcp
        case http
    }

    public struct PluginParam: Codable, Sendable, Equatable {
        public var name: String
        public var description: String
        public var type: String         // "string", "number", "boolean"
        public var required: Bool

        public init(name: String, description: String, type: String = "string", required: Bool = true) {
            self.name = name
            self.description = description
            self.type = type
            self.required = required
        }
    }

    public init(
        name: String, displayName: String, description: String,
        version: String = "1.0", type: PluginType = .shell,
        parameters: [PluginParam] = [], command: String? = nil,
        mcpServer: String? = nil, endpoint: String? = nil,
        httpMethod: String? = nil, enabled: Bool = true
    ) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.version = version
        self.type = type
        self.parameters = parameters
        self.command = command
        self.mcpServer = mcpServer
        self.endpoint = endpoint
        self.httpMethod = httpMethod
        self.enabled = enabled
    }
}

// MARK: - Plugin Tool Adapter

public struct PluginToolAdapter: LaicaiTool {
    public let manifest: PluginManifest

    public var name: String { "plugin.\(manifest.name)" }
    public var description: String { manifest.description }

    public var functionDefinition: FunctionDefinition {
        let properties = Dictionary(uniqueKeysWithValues: manifest.parameters.map { param in
            (param.name, FunctionProperty(type: param.type, description: param.description))
        })
        let required = manifest.parameters.filter(\.required).map(\.name)

        return FunctionDefinition(
            name: name,
            description: "[\(manifest.displayName)] \(manifest.description)",
            parameters: FunctionParameters(
                properties: properties,
                required: required
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        let params = (try? JSONSerialization.jsonObject(with: argumentsJSON.data(using: .utf8) ?? Data())) as? [String: Any] ?? [:]

        switch manifest.type {
        case .shell:
            return try await executeShell(params: params, context: context)
        case .http:
            return try await executeHTTP(params: params)
        case .mcp:
            return try await executeMCP(params: params)
        }
    }

    private func executeShell(params: [String: Any], context: TaskContext) async throws -> ToolResult {
        guard var command = manifest.command else {
            return ToolResult(output: "插件缺少 command 配置", success: false, error: "missing_command")
        }
        // Substitute {{param}} placeholders
        for (key, value) in params {
            command = command.replacingOccurrences(of: "{{\(key)}}", with: "\(value)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: context.workspaceRoot)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        if !Self.waitForExit(process, timeoutSeconds: 60) {
            process.terminate()
            if !Self.waitForExit(process, timeoutSeconds: 2) {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = Self.waitForExit(process, timeoutSeconds: 1)
            }
            return ToolResult(output: "插件执行超时", success: false, error: "plugin_timeout")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return ToolResult(output: String(output.prefix(8000)), success: process.terminationStatus == 0)
    }

    private static func waitForExit(_ process: Process, timeoutSeconds: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if !process.isRunning { return true }
        let result = semaphore.wait(timeout: .now() + timeoutSeconds)
        process.terminationHandler = nil
        return result == .success || !process.isRunning
    }

    private func executeHTTP(params: [String: Any]) async throws -> ToolResult {
        guard let urlString = manifest.endpoint else {
            return ToolResult(output: "插件缺少 endpoint 配置", success: false, error: "missing_endpoint")
        }
        guard let url = URL(string: urlString) else {
            return ToolResult(output: "无效的 URL: \(urlString)", success: false, error: "invalid_url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = manifest.httpMethod ?? "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !params.isEmpty {
            request.httpBody = try? JSONSerialization.data(withJSONObject: params)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        return ToolResult(output: String(body.prefix(8000)), success: (200...299).contains(status))
    }

    private func executeMCP(params: [String: Any]) async throws -> ToolResult {
        guard let serverName = manifest.mcpServer else {
            return ToolResult(output: "插件缺少 mcpServer 配置", success: false, error: "missing_mcp_server")
        }
        guard let server = await MCPManager.shared.servers.first(where: { $0.config.name == serverName }) else {
            return ToolResult(output: "MCP 服务器 '\(serverName)' 未运行", success: false, error: "mcp_not_running")
        }
        return try await server.callTool(name: manifest.name, arguments: params)
    }
}

// MARK: - Plugin Registry

@MainActor
public final class PluginRegistry: ObservableObject {
    public static let shared = PluginRegistry()

    @Published public var plugins: [PluginManifest] = []

    private init() {}

    /// Scan .laicai/plugins/ directory for plugin manifests
    public func loadPlugins(workspaceRoot: String) {
        guard WorkspaceTrust.isTrusted(workspaceRoot) else {
            plugins = []
            return
        }
        let pluginDir = (workspaceRoot as NSString).appendingPathComponent(".laicai/plugins")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: pluginDir) else { return }

        guard let files = try? fileManager.contentsOfDirectory(atPath: pluginDir) else { return }
        var loaded: [PluginManifest] = []

        for file in files where file.hasSuffix(".json") {
            let path = (pluginDir as NSString).appendingPathComponent(file)
            guard let data = fileManager.contents(atPath: path),
                  let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
                continue
            }
            loaded.append(manifest)
        }

        plugins = loaded
        registerTools()
    }

    /// Register enabled plugins as tools in the global ToolRegistry
    public func registerTools() {
        for manifest in plugins where manifest.enabled {
            let adapter = PluginToolAdapter(manifest: manifest)
            ToolRegistry.shared.register(adapter)
        }
    }

    /// Create a template plugin manifest file
    public func createTemplate(workspaceRoot: String) throws {
        let pluginDir = (workspaceRoot as NSString).appendingPathComponent(".laicai/plugins")
        try FileManager.default.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)
        let template = PluginManifest(
            name: "my_tool",
            displayName: "我的工具",
            description: "自定义工具描述",
            type: .shell,
            parameters: [
                .init(name: "input", description: "输入参数")
            ],
            command: "echo '处理: {{input}}'",
            enabled: true
        )
        let data = try JSONEncoder().encode(template)
        let path = (pluginDir as NSString).appendingPathComponent("my_tool.json")
        try data.write(to: URL(fileURLWithPath: path))
    }
}
