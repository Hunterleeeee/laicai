import Foundation
import LaicaiNativeDomain

// MARK: - Agent Loop Core Types

final class AgentShellStreamState: Sendable {
    private struct State {
        var output = ""
        var didResume = false
    }

    private let state = Locked(State())

    func append(_ chunk: String) -> String {
        state.withValue {
            $0.output += chunk
            return $0.output
        }
    }

    func finish() -> (String, Bool) {
        state.withValue {
            if $0.didResume {
                return ($0.output, false)
            }
            $0.didResume = true
            return ($0.output, true)
        }
    }
}

extension Notification.Name {
    static let shellStreamUpdate = Notification.Name("laicai.shellStreamUpdate")
}

extension AgentLoop {
    public static let connectorFailoverAction = "connector.failover"

    public struct Config: Sendable {
        public var maxIterations: Int
        public var maxTokensPerTurn: Int
        public var workspaceRoot: String
        public var supportsToolCalling: Bool
        public var contextMode: ContextMode
        public var contextWindow: Int
        public var customSystemPrompt: String?
        public var allowedTools: Set<String>?
        public var modelName: String
        public var connectorEndpoint: String
        public var apiKey: String
        public var emitDebugSteps: Bool

        public init(
            maxIterations: Int = 50,
            maxTokensPerTurn: Int = 4096,
            workspaceRoot: String = "",
            supportsToolCalling: Bool = true,
            contextMode: ContextMode = .balanced,
            contextWindow: Int = 200_000,
            customSystemPrompt: String? = nil,
            allowedTools: Set<String>? = nil,
            modelName: String = "",
            connectorEndpoint: String = "",
            apiKey: String = "",
            emitDebugSteps: Bool = false
        ) {
            self.maxIterations = maxIterations
            self.maxTokensPerTurn = maxTokensPerTurn
            self.workspaceRoot = workspaceRoot
            self.supportsToolCalling = supportsToolCalling
            self.contextMode = contextMode
            self.contextWindow = contextWindow
            self.customSystemPrompt = customSystemPrompt
            self.allowedTools = allowedTools
            self.modelName = modelName
            self.connectorEndpoint = connectorEndpoint
            self.apiKey = apiKey
            self.emitDebugSteps = emitDebugSteps
        }
    }

    public enum LoopEvent: Sendable {
        case step(TaskStep)
        case streamDelta(String)
        case completed(AgentTask)
        case failed(Error)
    }

    func filteredToolDefinitions(_ definitions: [ToolDefinition]) -> [ToolDefinition] {
        guard let allowedTools = config.allowedTools, !allowedTools.isEmpty else {
            return definitions
        }
        let canonicalAllowedTools = Self.canonicalToolSet(allowedTools) ?? []
        return definitions.filter { definition in
            canonicalAllowedTools.contains(ToolNameCodec.canonicalName(definition.function.name))
        }
    }

    func isToolAllowed(_ name: String) -> Bool {
        Self.allowsTool(name, allowedTools: config.allowedTools)
    }
}
