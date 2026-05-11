import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func selectConnector(id: UUID) {
        guard let connector = state.connectors.first(where: { $0.id == id }) else { return }
        state.activeConnectorID = connector.id
        state.settings.defaultConnectorName = connector.name
        if let threadIndex = state.threads.firstIndex(where: { $0.id == state.selectedThreadID }), state.threads[threadIndex].source == .session {
            state.threads[threadIndex].modelName = connector.name
        }
        persistSettings()
        persistConnectors()
        persistThreads()
        scheduleConnectorHealthRefreshIfNeeded(for: connector)
    }

    public func addConnector(_ connector: ConnectorProfile) {
        let normalized = normalizedConnector(connector)
        state.connectors.append(normalized)
        if state.activeConnectorID == nil {
            state.activeConnectorID = normalized.id
            state.settings.defaultConnectorName = normalized.name
        }
        persistSettings()
        persistConnectors()
        scheduleConnectorHealthRefreshIfNeeded(for: normalized, force: true)
    }

    public func updateConnector(_ connector: ConnectorProfile) {
        guard let index = state.connectors.firstIndex(where: { $0.id == connector.id }) else { return }
        let previous = state.connectors[index]
        let normalized = normalizedConnector(connector, previous: previous)
        let configurationChanged = Self.connectorConfigurationChanged(from: previous, to: normalized)
        state.connectors[index] = normalized
        if state.activeConnectorID == normalized.id {
            state.settings.defaultConnectorName = normalized.name
        }
        persistSettings()
        persistConnectors()
        if configurationChanged {
            scheduleConnectorHealthRefreshIfNeeded(for: normalized, force: true)
        }
    }

    public func deleteConnector(id: UUID) {
        state.connectors.removeAll(where: { $0.id == id })
        if state.activeConnectorID == id {
            state.activeConnectorID = state.connectors.first?.id
            state.settings.defaultConnectorName = state.activeConnector?.name ?? "无模型"
        }
        persistSettings()
        persistConnectors()
    }

    public func clearLearnedToolCallingCapability(id: UUID, showsToast: Bool = true) {
        guard let index = state.connectors.firstIndex(where: { $0.id == id }) else {
            if showsToast {
                notify("未找到该连接器", style: .info)
            }
            return
        }
        guard state.connectors[index].toolCallingCapability != nil else {
            if showsToast {
                notify("\(state.connectors[index].name) 当前没有已学习的工具兼容性记录", style: .info)
            }
            return
        }
        state.connectors[index].toolCallingCapability = nil
        state.connectors[index].toolCallingCapabilitySource = nil
        state.connectors[index].toolCallingCapabilityLearnedAt = nil
        refreshActiveAgentLoopIfNeeded(for: id)
        let connector = state.connectors[index]
        let capability = ConnectorCapabilityProfile.infer(for: connector, mode: state.settings.contextMode)
        let statusLine: String
        let toastMessage: String
        switch connector.toolCallingPolicy ?? .automatic {
        case .automatic:
            statusLine = "已清除已学习记录，后续将重新按 automatic 判断；可再次执行连接测试重新学习。"
            toastMessage = "已清除 \(connector.name) 的已学习工具兼容性，后续将重新自动判断。"
        case .enabled, .disabled:
            statusLine = "已清除已学习记录；当前仍按\(capability.toolCallingSource.title)生效。"
            toastMessage = "已清除 \(connector.name) 的已学习工具兼容性，当前仍按\(capability.toolCallingSource.title)生效。"
        }
        recordToolActivity(
            name: "connector.capability",
            summary: "已清除 \(connector.name) 的工具兼容性记录",
            statusLine: statusLine,
            isFailure: false
        )
        persistConnectors()
        if showsToast {
            notify(toastMessage, style: .success)
        }
    }

}
