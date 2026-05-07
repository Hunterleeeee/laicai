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

public final class MCPServer: Sendable {
    public let config: MCPServerConfig
    public var tools: [MCPToolInfo] { state.withValue { $0.tools } }
    public var resources: [MCPResourceInfo] { state.withValue { $0.resources } }
    public var isRunning: Bool { state.withValue { $0.isRunning } }

    private struct State {
        var tools: [MCPToolInfo] = []
        var resources: [MCPResourceInfo] = []
        var isRunning = false
        var process: Process?
        var stdin: FileHandle?
        var stdoutPipe: Pipe?
        var pendingRequests: [Int: CheckedContinuation<MCPResponse, Error>] = [:]
        var nextID = 1
        var readBuffer = Data()
    }

    private let state = Locked(State())

    public init(config: MCPServerConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard state.withValue({ !$0.isRunning }) else { return }

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

        state.withValue {
            $0.stdin = stdinPipe.fileHandleForWriting
            $0.stdoutPipe = outPipe
            $0.process = proc
        }

        do {
            try proc.run()
            state.withValue { $0.isRunning = true }
        } catch {
            state.withValue {
                $0.process = nil
                $0.stdin = nil
                $0.stdoutPipe = nil
            }
            throw error
        }

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
        let (process, pending) = state.withValue { state in
            state.isRunning = false
            let process = state.process
            state.process = nil
            state.stdin = nil
            state.stdoutPipe = nil
            let pending = state.pendingRequests
            state.pendingRequests.removeAll()
            state.readBuffer.removeAll()
            return (process, pending)
        }
        process?.terminate()
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError(code: -1, message: "Server stopped"))
        }
    }

    // MARK: - Tool Operations

    public func refreshTools() async {
        do {
            let response = try await sendRequest(method: "tools/list")
            if let result = response.result?.objectValue,
               let toolsArray = result["tools"] as? [[String: Any]] {
                let data = try JSONSerialization.data(withJSONObject: toolsArray)
                let decoded = (try? JSONDecoder().decode([MCPToolInfo].self, from: data)) ?? []
                state.withValue { $0.tools = decoded }
            }
        } catch {
            // Tools list failed — server may not support tools
            state.withValue { $0.tools = [] }
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

        if let result = response.result?.objectValue {
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

        let jsonData = try JSONSerialization.data(withJSONObject: response.result?.untypedValue ?? [String: Any]())
        return ToolResult(output: String(data: jsonData, encoding: .utf8) ?? "", success: true)
    }

    // MARK: - Resource Operations

    public func listResources() async throws -> [MCPResourceInfo] {
        let response = try await sendRequest(method: "resources/list")
        if let result = response.result?.objectValue,
           let array = result["resources"] as? [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: array)
            let decoded = (try? JSONDecoder().decode([MCPResourceInfo].self, from: data)) ?? []
            state.withValue { $0.resources = decoded }
        }
        return resources
    }

    public func readResource(uri: String) async throws -> String {
        let response = try await sendRequest(method: "resources/read", params: [
            "uri": AnyCodable(uri)
        ])
        if let result = response.result?.objectValue,
           let contents = result["contents"] as? [[String: Any]],
           let first = contents.first {
            return first["text"] as? String ?? ""
        }
        return ""
    }

    // MARK: - JSON-RPC Transport

    private func sendRequest(method: String, params: [String: AnyCodable]? = nil) async throws -> MCPResponse {
        let reqID: Int
        reqID = state.withValue {
            let id = $0.nextID
            $0.nextID += 1
            return id
        }

        let request = MCPRequest(id: reqID, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        let line = data + Data("\n".utf8)

        return try await withCheckedThrowingContinuation { continuation in
            let stdin: FileHandle? = state.withValue { state in
                guard state.isRunning, let stdin = state.stdin else { return nil }
                state.pendingRequests[reqID] = continuation
                return stdin
            }
            guard let stdin else {
                continuation.resume(throwing: MCPError(code: -1, message: "Server is not running"))
                return
            }
            stdin.write(line)
        }
    }

    private func sendNotification(method: String, params: [String: AnyCodable]? = nil) {
        let notification = MCPNotification(method: method, params: params)
        if let data = try? JSONEncoder().encode(notification) {
            let line = data + Data("\n".utf8)
            let stdin = state.withValue { $0.stdin }
            stdin?.write(line)
        }
    }

    private func readLoop(pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        while isRunning {
            let chunk = handle.availableData
            if chunk.isEmpty { break }

            // Process complete lines
            let lines = state.withValue { state in
                state.readBuffer.append(chunk)
                var completeLines: [Data] = []
                while let newlineIndex = state.readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = state.readBuffer[state.readBuffer.startIndex..<newlineIndex]
                    state.readBuffer = Data(state.readBuffer[state.readBuffer.index(after: newlineIndex)...])
                    if !lineData.isEmpty {
                        completeLines.append(Data(lineData))
                    }
                }
                return completeLines
            }

            for lineData in lines {
                guard let response = try? JSONDecoder().decode(MCPResponse.self, from: lineData),
                      let id = response.id else { continue }
                let continuation = state.withValue { $0.pendingRequests.removeValue(forKey: id) }
                if let error = response.error {
                    continuation?.resume(throwing: error)
                } else {
                    continuation?.resume(returning: response)
                }
                // Notifications from server are currently ignored
            }
        }
    }
}

// MARK: - MCP Tool Adapter (bridges MCPServer tools to LaicaiTool)

public struct MCPToolAdapter: LaicaiTool {
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
            if let props = schema["properties"]?.objectValue {
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
            if let required = schema["required"]?.stringArrayValue {
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
            LaicaiLog.error("MCP server '\(config.name)' 启动失败: \(error.localizedDescription)")
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
    public let value: JSONValue

    public init(_ value: Any) {
        self.value = Self.jsonValue(from: value)
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        lhs.value == rhs.value
    }

    public init(from decoder: Decoder) throws {
        value = try JSONValue(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    public var objectValue: [String: Any]? {
        guard case .object(let object) = value else { return nil }
        return object.mapValues(Self.anyValue(from:))
    }

    public var arrayValue: [Any]? {
        guard case .array(let array) = value else { return nil }
        return array.map(Self.anyValue(from:))
    }

    public var stringArrayValue: [String]? {
        switch value {
        case .array(let array):
            return array.compactMap { item in
                guard case .string(let value) = item else { return nil }
                return value
            }
        default:
            return nil
        }
    }

    public var untypedValue: Any {
        Self.anyValue(from: value)
    }

    private static func jsonValue(from value: Any) -> JSONValue {
        switch value {
        case let value as JSONValue:
            return value
        case let value as AnyCodable:
            return value.value
        case let value as String:
            return .string(value)
        case let value as Int:
            return .number(Double(value))
        case let value as Int64:
            return .number(Double(value))
        case let value as UInt:
            return .number(Double(value))
        case let value as UInt64:
            return .number(Double(value))
        case let value as Float:
            return .number(Double(value))
        case let value as Double:
            return .number(value)
        case let value as Decimal:
            return .number(NSDecimalNumber(decimal: value).doubleValue)
        case let value as Bool:
            return .bool(value)
        case _ as NSNull:
            return .null
        case let value as [String: AnyCodable]:
            return .object(value.mapValues(\.value))
        case let value as [String: JSONValue]:
            return .object(value)
        case let value as [String: Any]:
            return .object(value.mapValues(Self.jsonValue(from:)))
        case let value as [AnyCodable]:
            return .array(value.map(\.value))
        case let value as [JSONValue]:
            return .array(value)
        case let value as [Any]:
            return .array(value.map(Self.jsonValue(from:)))
        default:
            return .null
        }
    }

    private static func anyValue(from value: JSONValue) -> Any {
        switch value {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(Self.anyValue(from:))
        case .array(let value):
            return value.map(Self.anyValue(from:))
        case .null:
            return NSNull()
        }
    }
}
