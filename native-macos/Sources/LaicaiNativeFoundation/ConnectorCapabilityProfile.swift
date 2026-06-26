import Foundation
import LaicaiNativeDomain

public enum SpeedTier: String, Equatable, Sendable {
    case fast
    case medium
    case slow

    public var title: String {
        switch self {
        case .fast: return "快速"
        case .medium: return "中等"
        case .slow: return "较慢"
        }
    }

    public var icon: String {
        switch self {
        case .fast: return "hare.fill"
        case .medium: return "tortoise"
        case .slow: return "tortoise.fill"
        }
    }
}

public enum StabilityScore: String, Equatable, Sendable {
    case stable
    case moderate
    case unstable

    public var title: String {
        switch self {
        case .stable: return "稳定"
        case .moderate: return "一般"
        case .unstable: return "不稳定"
        }
    }

    public var icon: String {
        switch self {
        case .stable: return "checkmark.shield.fill"
        case .moderate: return "shield"
        case .unstable: return "shield.slash"
        }
    }
}

public enum ConnectorToolCallingResolutionSource: String, Equatable, Sendable {
    case manualEnabled
    case manualDisabled
    case learnedSupported
    case learnedUnsupported
    case automaticHeuristic

    public var title: String {
        switch self {
        case .manualEnabled: return "手动开启"
        case .manualDisabled: return "手动关闭"
        case .learnedSupported: return "已验证支持"
        case .learnedUnsupported: return "已验证不兼容"
        case .automaticHeuristic: return "自动判断"
        }
    }
}

public struct ConnectorCapabilityProfile: Equatable, Sendable {
    public var isLocal: Bool
    public var supportsToolCalling: Bool
    public var toolCallingSource: ConnectorToolCallingResolutionSource
    public var learnedToolCallingCapability: ConnectorToolCallingCapability?
    public var learnedToolCallingSource: ConnectorToolCallingCapabilityObservationSource?
    public var learnedToolCallingLearnedAt: Date?
    public var toolCallingConflict: ConnectorToolCallingCapability?
    public var maxIterations: Int
    public var maxTokensPerTurn: Int
    public var directOutputLimit: Int?
    public var relevantFileLimit: Int
    public var contextWindow: Int
    public var estimatedContextLength: Int
    public var speedTier: SpeedTier
    public var stabilityScore: StabilityScore

    public var toolCallingSourceDetail: String {
        switch (toolCallingSource, toolCallingConflict) {
        case (.manualEnabled, .unsupported):
            return "手动开启，覆盖已验证不兼容"
        case (.manualDisabled, .supported):
            return "手动关闭，覆盖已验证支持"
        default:
            return toolCallingSource.title
        }
    }

    public var learnedToolCallingDetail: String? {
        guard let capability = learnedToolCallingCapability else { return nil }
        if let source = learnedToolCallingSource {
            return "\(capability.title) · \(source.title)"
        }
        return capability.title
    }

    public static func infer(for connector: ConnectorProfile?, mode: ContextMode) -> ConnectorCapabilityProfile {
        let local = connector.map { Self.isLocalConnector($0) } ?? false
        let iterationCap = local ? localIterationCap(for: mode) : mode.maxIterations
        let toolCallingResolution = connector.map { Self.resolveToolCalling(for: $0) }
            ?? (supports: true, source: .automaticHeuristic)
        let learnedCapability = connector?.toolCallingCapability
        let model = connector?.modelName.lowercased() ?? ""
        let contextLen = connector?.probedContextWindow ?? inferContextLength(model: model, isLocal: local)
        let speed = inferSpeedTier(model: model, isLocal: local)
        let stability = inferStability(connector: connector, isLocal: local)
        let maxTokensPerTurn: Int
        if local {
            maxTokensPerTurn = min(mode.maxTokensPerTurn, 1400)
        } else {
            maxTokensPerTurn = mode.maxTokensPerTurn
        }
        return ConnectorCapabilityProfile(
            isLocal: local,
            supportsToolCalling: toolCallingResolution.supports,
            toolCallingSource: toolCallingResolution.source,
            learnedToolCallingCapability: learnedCapability,
            learnedToolCallingSource: connector?.toolCallingCapabilitySource,
            learnedToolCallingLearnedAt: connector?.toolCallingCapabilityLearnedAt,
            toolCallingConflict: connector.flatMap { Self.toolCallingConflict(for: $0) },
            maxIterations: local ? iterationCap : mode.maxIterations,
            maxTokensPerTurn: maxTokensPerTurn,
            directOutputLimit: local ? 512 : nil,
            relevantFileLimit: mode.relevantFileLimit,
            contextWindow: local ? max(32768, mode.tokenBudget) : max(mode.tokenBudget, contextLen),
            estimatedContextLength: contextLen,
            speedTier: speed,
            stabilityScore: stability
        )
    }

    public static func supportsToolCalling(for connector: ConnectorProfile) -> Bool {
        resolveToolCalling(for: connector).supports
    }

    public static func isImageOnlyModel(_ modelName: String) -> Bool {
        let model = modelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        guard !model.isEmpty else { return false }

        return model.hasPrefix("gpt-image")
            || model.contains("/gpt-image")
            || model.hasPrefix("agnes-image")
            || model.contains("/agnes-image")
            || model.hasPrefix("dall-e")
            || model.contains("/dall-e")
            || model.hasPrefix("imagen")
            || model.contains("/imagen")
            || model.contains("midjourney")
            || model.contains("stable-diffusion")
            || model.contains("sdxl")
            || model.contains("flux.1")
    }

    public static func imageOnlyModelChatMessage(modelName: String) -> String {
        let displayName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelLabel = displayName.isEmpty ? "当前模型" : "`\(displayName)`"
        return "当前选择的是图片生成模型 \(modelLabel)，不能作为通用会话模型使用。生成图片请直接发送“生成图片”，或切换到支持文字和工具的模型（如 gpt-5.5、gpt-4o、Claude）处理文字目标。"
    }

    public static func resolveToolCalling(for connector: ConnectorProfile) -> (supports: Bool, source: ConnectorToolCallingResolutionSource) {
        switch connector.toolCallingPolicy ?? .automatic {
        case .enabled:
            return (true, .manualEnabled)
        case .disabled:
            return (false, .manualDisabled)
        case .automatic:
            switch connector.toolCallingCapability {
            case .supported:
                return (true, .learnedSupported)
            case .unsupported:
                return (false, .learnedUnsupported)
            case .none:
                return (inferredAutomaticToolCallingSupport(for: connector), .automaticHeuristic)
            }
        }
    }

    public static func toolCallingConflict(for connector: ConnectorProfile) -> ConnectorToolCallingCapability? {
        switch (connector.toolCallingPolicy ?? .automatic, connector.toolCallingCapability) {
        case (.enabled, .unsupported):
            return .unsupported
        case (.disabled, .supported):
            return .supported
        default:
            return nil
        }
    }

    public static func isLocalConnector(_ connector: ConnectorProfile) -> Bool {
        if LiveChatRuntime.usesOllamaNativeProtocol(endpoint: connector.endpoint, kind: connector.kind) {
            return true
        }
        if connector.name.localizedCaseInsensitiveContains("本地")
            || connector.name.localizedCaseInsensitiveContains("local")
            || connector.name.localizedCaseInsensitiveContains("ollama") {
            return true
        }
        guard let host = URL(string: connector.endpoint)?.host?.lowercased() else {
            return connector.endpoint.contains("127.0.0.1")
                || connector.endpoint.contains("localhost")
                || connector.endpoint.contains(":11434")
        }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host == "0.0.0.0"
            || host.hasSuffix(".local")
            || host.hasPrefix("192.168.")
            || host.hasPrefix("10.")
            || host.range(of: #"^172\.(1[6-9]|2[0-9]|3[0-1])\."#, options: .regularExpression) != nil
    }

    private static func localIterationCap(for mode: ContextMode) -> Int {
        switch mode {
        case .economy: return 15
        case .balanced: return 30
        case .deep: return 50
        }
    }

    private static func inferredAutomaticToolCallingSupport(for connector: ConnectorProfile) -> Bool {
        !connector.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !connector.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Context Length Inference

    private static func inferContextLength(model: String, isLocal: Bool) -> Int {
        if isLocal { return 32768 }
        // Known model context lengths (keep up-to-date — 2025/2026)
        // OpenAI
        if model.contains("gpt-5") || model.contains("gpt5") { return 1_000_000 }  // GPT-5 / 5.5
        if model.contains("o3") || model.contains("o4") || model.contains("o1") { return 1_000_000 }
        if model.contains("gpt-4.1") { return 1_000_000 }
        if model.contains("gpt-4o") || model.contains("gpt-4-turbo") { return 128_000 }
        if model.contains("gpt-4") { return 128_000 }
        if model.contains("gpt-3.5-turbo") || model.contains("gpt-35-turbo") { return 16_385 }
        // Anthropic
        if model.contains("claude-4") || model.contains("claude-3.7") { return 1_000_000 }
        if model.contains("claude-3-5") || model.contains("claude-3.5") { return 200_000 }
        if model.contains("claude-3") { return 200_000 }
        if model.contains("claude-2") { return 100_000 }
        // DeepSeek
        if model.contains("deepseek") || model.contains("deep-seek") {
            if model.contains("v4") || model.contains("r2") { return 1_000_000 }
            if model.contains("v3") || model.contains("r1") || model.contains("chat") { return 128_000 }
            return 128_000
        }
        // Qwen
        if model.contains("qwen") {
            if model.contains("long") || model.contains("max") || model.contains("3") { return 1_000_000 }
            if model.contains("plus") || model.contains("72b") || model.contains("turbo") { return 128_000 }
            return 128_000
        }
        // Meta Llama
        if model.contains("llama-4") || model.contains("llama4") { return 1_000_000 }
        if model.contains("llama-3") || model.contains("llama3") { return 128_000 }
        // Google
        if model.contains("gemini") {
            return 1_000_000  // All Gemini 1.5+ support 1M
        }
        // Mistral
        if model.contains("mistral") || model.contains("mixtral") {
            if model.contains("large") || model.contains("medium") { return 256_000 }
            return 128_000
        }
        return 256_000  // 2025+ API models generally support 256K+
    }

    // MARK: - Speed Tier Inference

    private static func inferSpeedTier(model: String, isLocal: Bool) -> SpeedTier {
        if isLocal { return .slow }
        if model.contains("gpt-4o-mini") || model.contains("gpt-3.5") || model.contains("haiku") { return .fast }
        if model.contains("gpt-4") || model.contains("claude-3-5") || model.contains("sonnet") { return .medium }
        if model.contains("opus") || model.contains("gpt-4-turbo") { return .slow }
        return .medium
    }

    // MARK: - Stability Inference

    private static func inferStability(connector: ConnectorProfile?, isLocal: Bool) -> StabilityScore {
        guard let connector = connector else { return .moderate }
        // If tool calling was learned unsupported, likely unstable
        if connector.toolCallingCapability == .unsupported { return .unstable }
        // If tool calling was learned supported, likely stable
        if connector.toolCallingCapability == .supported { return .stable }
        // Local connectors tend to be less stable
        if isLocal { return .moderate }
        // Known stable providers
        let endpoint = connector.endpoint.lowercased()
        if endpoint.contains("openai.com") || endpoint.contains("api.anthropic.com") { return .stable }
        if endpoint.contains("api.deepseek.com") { return .stable }
        return .moderate
    }
}
