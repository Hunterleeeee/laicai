import Foundation
import LaicaiNativeDomain

@MainActor
extension AppStore {
    func normalizedConnector(_ connector: ConnectorProfile, previous: ConnectorProfile? = nil) -> ConnectorProfile {
        var normalized = connector
        normalized.name = connector.name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.kind = connector.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.endpoint = connector.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.modelName = connector.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.note = connector.note.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.kind = LiveChatRuntime.normalizedConnectorKind(normalized.kind, endpoint: normalized.endpoint)
        if let previous,
           Self.toolCallingIdentityChanged(from: previous, to: normalized) {
            normalized.toolCallingCapability = nil
            normalized.toolCallingCapabilitySource = nil
            normalized.toolCallingCapabilityLearnedAt = nil
        }
        if let previous, Self.connectorConfigurationChanged(from: previous, to: normalized) {
            normalized.health = .attention
        }
        return normalized
    }

    func scheduleConnectorHealthRefreshIfNeeded(for connector: ConnectorProfile, force: Bool = false) {
        guard canAutoCheckConnectorHealth(connector) else { return }
        guard force || connector.health != .ready else { return }
        checkConnectorHealth(id: connector.id, showsToast: false, probeToolCalling: false)
    }

    func canAutoCheckConnectorHealth(_ connector: ConnectorProfile) -> Bool {
        !connector.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !connector.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func markConnectorReady(_ id: UUID) {
        updateConnectorHealth(id, to: .ready)
    }

    func updateConnectorHealth(_ id: UUID, to health: ConnectorHealth) {
        guard let index = state.connectors.firstIndex(where: { $0.id == id }) else { return }
        state.connectors[index].health = health
        state.connectors[index].lastCheckedAt = .now
        persistConnectors()
    }

    func recordConnectorOutcome(_ response: SendMessageResponse, connectorID: UUID) {
        if let health = Self.connectorFailureHealth(from: response) {
            updateConnectorHealth(connectorID, to: health)
            return
        }
        markConnectorReady(connectorID)
    }

    func recordConnectorOutcome(_ task: AgentTask, connectorID: UUID, attemptedToolCalling: Bool) {
        let finalConnectorID = task.connectorID ?? connectorID
        if task.steps.contains(where: { $0.retryAction == AgentLoop.connectorFailoverAction }) {
            updateConnectorHealth(connectorID, to: .offline)
        }
        rememberToolCallingCapabilityIfNeeded(from: task, connectorID: finalConnectorID, attemptedToolCalling: attemptedToolCalling)
        if let health = Self.connectorFailureHealth(from: task) {
            updateConnectorHealth(finalConnectorID, to: health)
            return
        }
        markConnectorReady(finalConnectorID)
    }

    static func connectorConfigurationChanged(from previous: ConnectorProfile, to next: ConnectorProfile) -> Bool {
        previous.kind.trimmingCharacters(in: .whitespacesAndNewlines) != next.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) != next.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.modelName.trimmingCharacters(in: .whitespacesAndNewlines) != next.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.note.trimmingCharacters(in: .whitespacesAndNewlines) != next.note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func toolCallingIdentityChanged(from previous: ConnectorProfile, to next: ConnectorProfile) -> Bool {
        previous.kind.trimmingCharacters(in: .whitespacesAndNewlines) != next.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) != next.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            || previous.modelName.trimmingCharacters(in: .whitespacesAndNewlines) != next.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func rememberToolCallingCapabilityIfNeeded(from task: AgentTask, connectorID: UUID, attemptedToolCalling: Bool) {
        guard attemptedToolCalling else { return }
        let fallbackDetected = task.steps.contains(where: { $0.retryAction == AgentLoop.toolCompatibilityFallbackAction })
        let hasSuccessfulToolCall = task.steps.contains {
            $0.kind == .toolResult && !$0.isFailure && ($0.toolName?.isEmpty == false)
        }
        let nextCapability: ConnectorToolCallingCapability?
        if fallbackDetected {
            nextCapability = .unsupported
        } else if hasSuccessfulToolCall {
            nextCapability = .supported
        } else {
            nextCapability = nil
        }
        if rememberToolCallingCapability(nextCapability, connectorID: connectorID, activitySource: .taskRun) {
            persistConnectors()
        }
    }

    @discardableResult
    func rememberToolCallingCapability(
        _ capability: ConnectorToolCallingCapability?,
        connectorID: UUID,
        activitySource: ConnectorToolCallingCapabilityObservationSource?
    ) -> Bool {
        guard let capability,
              let index = state.connectors.firstIndex(where: { $0.id == connectorID }) else { return false }
        let previousCapability = state.connectors[index].toolCallingCapability
        let previousSource = state.connectors[index].toolCallingCapabilitySource
        let capabilityChanged = previousCapability != capability
        let sourceChanged = activitySource != nil && previousSource != activitySource
        let observedAgain = activitySource != nil
        guard capabilityChanged || observedAgain else { return false }
        state.connectors[index].toolCallingCapability = capability
        if capabilityChanged {
            refreshActiveAgentLoopIfNeeded(for: connectorID)
        }
        if let activitySource {
            state.connectors[index].toolCallingCapabilitySource = activitySource
            state.connectors[index].toolCallingCapabilityLearnedAt = .now
        } else if capabilityChanged {
            state.connectors[index].toolCallingCapabilitySource = nil
            state.connectors[index].toolCallingCapabilityLearnedAt = nil
        }
        guard let activitySource,
              capabilityChanged || sourceChanged else { return true }
        let statusLine: String
        switch (activitySource, capability) {
        case (.connectorProbe, .supported):
            statusLine = "已通过连接测试验证 tools 请求兼容，automatic 模式会继续保留工具调用。"
        case (.connectorProbe, .unsupported):
            statusLine = "已通过连接测试验证 tools 请求不兼容，automatic 模式后续将默认不再发送 tools。"
        case (.taskRun, .supported):
            statusLine = "本次任务已成功携带 tools 请求，automatic 模式后续会继续保留工具调用。"
        case (.taskRun, .unsupported):
            statusLine = "检测到请求格式不兼容，automatic 模式后续将默认不再发送 tools。"
        }
        recordToolActivity(
            name: "connector.capability",
            summary: capability == .supported
                ? "已验证 \(state.connectors[index].name) 支持工具调用"
                : "已验证 \(state.connectors[index].name) 不兼容工具调用",
            statusLine: statusLine,
            isFailure: false
        )
        return true
    }

    func refreshActiveAgentLoopIfNeeded(for connectorID: UUID) {
        // No-op: per-thread loops are created on demand in sendTaskDraft.
    }

    static func connectorFailureHealth(from response: SendMessageResponse) -> ConnectorHealth? {
        let text = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("无法连接") || text.hasPrefix("请求失败：") || text.hasPrefix("模型请求失败：") {
            return .offline
        }
        if response.toolActivities.contains(where: { $0.isFailure }) || looksLikeConnectorFailure(text) {
            return .attention
        }
        return nil
    }

    static func connectorFailureHealth(from task: AgentTask) -> ConnectorHealth? {
        guard let errorStep = task.steps.reversed().first(where: { $0.kind == .error && $0.isFailure }) else { return nil }
        if errorStep.retryAction == "检查端点、模型名和请求兼容性后重试" {
            return .attention
        }
        let text = errorStep.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("模型请求失败：") || text.hasPrefix("请求失败：") || text.hasPrefix("无法连接") {
            return .offline
        }
        return nil
    }

    static func looksLikeConnectorFailure(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let preview = normalizedSessionPreview(text)
        return preview == "未找到接口，请检查端点地址是否正确。"
            || preview == "鉴权失败，请检查 API 密钥是否正确。"
            || preview == "请求失败，请检查连接器配置。"
            || text.contains("HTTP 400")
            || text.contains("HTTP 401")
            || text.contains("HTTP 403")
            || text.contains("HTTP 404")
    }
}
