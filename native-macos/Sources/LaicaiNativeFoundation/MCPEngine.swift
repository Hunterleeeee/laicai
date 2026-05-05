// MCP (Model Context Protocol) Engine
// Connects external tool servers via JSON-RPC over stdio or HTTP(SSE).
// Spec: https://modelcontextprotocol.io/specification
//
// Usage:
//   let server = MCPServer(name: "github", command: "npx", args: ["-y", "@modelcontextprotocol/server-github"])
//   try await server.start()
//   let tools = try await server.listTools()
//   let result = try await server.callTool(name: "search_repositories", arguments: ["query": "swift"])

import Foundation
import LaicaiNativeDomain

// MARK: - MCP JSON-RPC Types

public struct MCPRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public let method: String
    public let params: [String: AnyCodable]?

    public init(id: Int, method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct MCPResponse: Codable, Sendable {
    public let jsonrpc: String?
    public let id: Int?
    public let result: AnyCodable?
    public let error: MCPError?
}

public struct MCPError: Codable, Sendable, Error {
    public let code: Int
    public let message: String
}

public struct MCPNotification: Codable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: [String: AnyCodable]?

    public init(method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

// MARK: - MCP Tool Definition (from server)

public struct MCPToolInfo: Codable, Sendable, Identifiable, Equatable {
    public var name: String
    public var description: String?
    public var inputSchema: [String: AnyCodable]?

    public var id: String { name }

    public static func == (lhs: MCPToolInfo, rhs: MCPToolInfo) -> Bool {
        lhs.name == rhs.name
    }
}

// MARK: - MCP Resource Info

public struct MCPResourceInfo: Codable, Sendable, Identifiable {
    public var uri: String
    public var name: String
    public var description: String?
    public var mimeType: String?

    public var id: String { uri }
}

// MARK: - MCP Server Configuration

public struct MCPServerConfig: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var command: String          // e.g. "npx", "python3", "/usr/local/bin/mcp-server"
    public var args: [String]           // e.g. ["-y", "@modelcontextprotocol/server-github"]
    public var env: [String: String]    // Extra environment variables (API keys etc.)
    public var enabled: Bool
    public var transport: Transport

    public enum Transport: String, Codable, Sendable {
        case stdio
        case sse
    }

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        enabled: Bool = true,
        transport: Transport = .stdio
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
        self.transport = transport
    }
}

// MARK: - MCP Server (stdio transport)

public final class MCPServer: @unchecked Sendable {
    public let config: MCPServerConfig
    public private(set) var tools: [MCPToolInfo] = []
    public private(set) var resources: [MCPResourceInfo] = []
    public private(set) var isRunning = false

    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutPipe: Pipe?
    private var pendingRequests: [Int: CheckedContinuation<MCPResponse, Error>] = [:]
    private var nextID = 1
    private let lock = NSLock()
    private var readBuffer = Data()

    public init(config: MCPServerConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard !isRunning else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [config.command] + config.args

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in config.env {
            environment[key] = value
        }
        proc.environment = environment

        let stdinPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.stdin = stdinPipe.fileHandleForWriting
        self.stdoutPipe = outPipe
        self.process = proc

        try proc.run()
        isRunning = true

        // Start reading stdout in background
        Task.detached { [weak self] in
            self?.readLoop(pipe: outPipe)
        }

        // Initialize MCP handshake
        let initResult = try await sendRequest(method: "initialize", params: [
            "protocolVersion": AnyCodable("2024-11-05"),
            "capabilities": AnyCodable(["tools": [:] as [String: String], "resources": [:] as [String: String]]),
            "clientInfo": AnyCodable(["name": "laicai", "version": "1.0.0"])
        ])

        // Send initialized notification
        sendNotification(method: "notifications/initialized")

        // Discover tools
        await refreshTools()

        _ = initResult
    }

    public func stop() {
        isRunning = false
        process?.terminate()
        process = nil
        stdin = nil
        stdoutPipe = nil
        lock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        lock.unlock()
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError(code: -1, message: "Server stopped"))
        }
    }

    // MARK: - Tool Operations

    public func refreshTools() async {
        do {
            let response = try await sendRequest(method: "tools/list")
            if let result = response.result?.value as? [String: Any],
               let toolsArray = result["tools"] as? [[String: Any]] {
                let data = try JSONSerialization.data(withJSONObject: toolsArray)
                self.tools = (try? JSONDecoder().decode([MCPToolInfo].self, from: data)) ?? []
            }
        } catch {
            // Tools list failed — server may not support tools
            self.tools = []
        }
    }

    public func callTool(name: String, arguments: [String: Any]) async throws -> ToolResult {
        let argsEncodable = arguments.mapValues { AnyCodable($0) }
        let response = try await sendRequest(method: "tools/call", params: [
            "name": AnyCodable(name),
            "arguments": AnyCodable(argsEncodable)
        ])

        if let error = response.error {
            return ToolResult(output: "MCP Error: \(error.message)", success: false)
        }

        if let result = response.result?.value as? [String: Any] {
            // MCP tool results have "content" array with text/image parts
            if let contentArray = result["content"] as? [[String: Any]] {
                let texts = contentArray.compactMap { part -> String? in
                    if part["type"] as? String == "text" {
                        return part["text"] as? String
                    }
                    return nil
                }
                let isError = result["isError"] as? Bool ?? false
                return ToolResult(output: texts.joined(separator: "\n"), success: !isError)
            }
        }

        let jsonData = try JSONSerialization.data(withJSONObject: response.result?.value ?? [:])
        return ToolResult(output: String(data: jsonData, encoding: .utf8) ?? "", success: true)
    }

    // MARK: - Resource Operations

    public func listResources() async throws -> [MCPResourceInfo] {
        let response = try await sendRequest(method: "resources/list")
        if let result = response.result?.value as? [String: Any],
           let array = result["resources"] as? [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: array)
            self.resources = (try? JSONDecoder().decode([MCPResourceInfo].self, from: data)) ?? []
        }
        return self.resources
    }

    public func readResource(uri: String) async throws -> String {
        let response = try await sendRequest(method: "resources/read", params: [
            "uri": AnyCodable(uri)
        ])
        if let result = response.result?.value as? [String: Any],
           let contents = result["contents"] as? [[String: Any]],
           let first = contents.first {
            return first["text"] as? String ?? ""
        }
        return ""
    }

    // MARK: - JSON-RPC Transport

    private func sendRequest(method: String, params: [String: AnyCodable]? = nil) async throws -> MCPResponse {
        let reqID: Int
        lock.lock()
        reqID = nextID
        nextID += 1
        lock.unlock()

        let request = MCPRequest(id: reqID, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        let line = data + Data("\n".utf8)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingRequests[reqID] = continuation
            lock.unlock()
            stdin?.write(line)
        }
    }

    private func sendNotification(method: String, params: [String: AnyCodable]? = nil) {
        let notification = MCPNotification(method: method, params: params)
        if let data = try? JSONEncoder().encode(notification) {
            let line = data + Data("\n".utf8)
            stdin?.write(line)
        }
    }

    private func readLoop(pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        while isRunning {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            readBuffer.append(chunk)

            // Process complete lines
            while let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
                readBuffer = Data(readBuffer[readBuffer.index(after: newlineIndex)...])

                guard !lineData.isEmpty else { continue }

                if let response = try? JSONDecoder().decode(MCPResponse.self, from: lineData),
                   let id = response.id {
                    lock.lock()
                    let continuation = pendingRequests.removeValue(forKey: id)
                    lock.unlock()
                    if let error = response.error {
                        continuation?.resume(throwing: error)
                    } else {
                        continuation?.resume(returning: response)
                    }
                }
                // Notifications from server are currently ignored
            }
        }
    }
}

// MARK: - MCP Tool Adapter (bridges MCPServer tools to LaicaiTool)

public struct MCPToolAdapter: LaicaiTool, @unchecked Sendable {
    public let name: String
    public let description: String
    public let functionDefinition: FunctionDefinition
    public let requiresReview: Bool = false

    private let server: MCPServer
    private let toolInfo: MCPToolInfo

    public init(server: MCPServer, toolInfo: MCPToolInfo) {
        self.server = server
        self.toolInfo = toolInfo
        self.name = "mcp.\(server.config.name).\(toolInfo.name)"
        self.description = toolInfo.description ?? "MCP tool: \(toolInfo.name)"

        // Convert MCP inputSchema to FunctionDefinition
        var params = FunctionParameters()
        if let schema = toolInfo.inputSchema {
            if let props = schema["properties"]?.value as? [String: Any] {
                var converted: [String: FunctionProperty] = [:]
                for (key, val) in props {
                    if let dict = val as? [String: Any] {
                        let type = dict["type"] as? String ?? "string"
                        let desc = dict["description"] as? String
                        converted[key] = FunctionProperty(type: type, description: desc)
                    } else {
                        converted[key] = FunctionProperty(type: "string")
                    }
                }
                params.properties = converted
            }
            if let required = schema["required"]?.value as? [String] {
                params.required = required
            }
        }
        self.functionDefinition = FunctionDefinition(
            name: self.name,
            description: self.description,
            parameters: params
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        guard server.isRunning else {
            return ToolResult(output: "MCP server '\(server.config.name)' is not running", success: false)
        }

        let arguments: [String: Any]
        if let data = argumentsJSON.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = dict
        } else {
            arguments = [:]
        }

        return try await server.callTool(name: toolInfo.name, arguments: arguments)
    }
}

// MARK: - MCP Manager (manages all MCP servers)

@MainActor
public final class MCPManager: ObservableObject {
    public static let shared = MCPManager()

    @Published public var servers: [MCPServer] = []
    @Published public var configs: [MCPServerConfig] = []

    private let configFile: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let laicaiDir = support.appendingPathComponent("Laicai", isDirectory: true)
        try? FileManager.default.createDirectory(at: laicaiDir, withIntermediateDirectories: true)
        self.configFile = laicaiDir.appendingPathComponent("mcp-servers.json")
        loadConfigs()
    }

    // MARK: - Config Persistence

    public func loadConfigs() {
        guard let data = try? Data(contentsOf: configFile),
              let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return
        }
        configs = decoded
    }

    public func saveConfigs() {
        if let data = try? JSONEncoder().encode(configs) {
            try? data.write(to: configFile)
        }
    }

    public func addConfig(_ config: MCPServerConfig) {
        configs.append(config)
        saveConfigs()
    }

    public func removeConfig(id: UUID) {
        if let server = servers.first(where: { $0.config.id == id }) {
            server.stop()
            servers.removeAll { $0.config.id == id }
        }
        configs.removeAll { $0.id == id }
        saveConfigs()
    }

    // MARK: - Server Lifecycle

    public func startAll() async {
        for config in configs where config.enabled {
            await startServer(config: config)
        }
    }

    public func startServer(config: MCPServerConfig) async {
        guard !servers.contains(where: { $0.config.id == config.id }) else { return }

        let server = MCPServer(config: config)
        do {
            try await server.start()
            servers.append(server)
        } catch {
            print("⚠ MCP server '\(config.name)' 启动失败: \(error.localizedDescription)")
        }
    }

    public func stopAll() {
        for server in servers {
            server.stop()
        }
        servers.removeAll()
    }

    // MARK: - Tool Discovery

    /// All tools from all running MCP servers, adapted as LaicaiTool
    public var allTools: [MCPToolAdapter] {
        servers.flatMap { server in
            server.tools.map { MCPToolAdapter(server: server, toolInfo: $0) }
        }
    }

    /// All tool definitions for LLM function calling
    public var toolDefinitions: [ToolDefinition] {
        allTools.map { tool in
            ToolDefinition(function: tool.functionDefinition)
        }
    }

    /// Register all MCP tools into the global ToolRegistry
    public func registerTools(in registry: ToolRegistry) {
        for tool in allTools {
            registry.register(tool)
        }
    }
}

// MARK: - AnyCodable (lightweight type-erased Codable)

public struct AnyCodable: Codable, Sendable, Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Simplified equality for common types
        if let l = lhs.value as? String, let r = rhs.value as? String { return l == r }
        if let l = lhs.value as? Int, let r = rhs.value as? Int { return l == r }
        if let l = lhs.value as? Double, let r = rhs.value as? Double { return l == r }
        if let l = lhs.value as? Bool, let r = rhs.value as? Bool { return l == r }
        return false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode([String: AnyCodable].self) { value = v.mapValues(\.value) }
        else if let v = try? container.decode([AnyCodable].self) { value = v.map(\.value) }
        else if container.decodeNil() { value = NSNull() }
        else { value = "" }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as String: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as Bool: try container.encode(v)
        case let v as [String: Any]:
            try container.encode(v.mapValues { AnyCodable($0) })
        case let v as [Any]:
            try container.encode(v.map { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
