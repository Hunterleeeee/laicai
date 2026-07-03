import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func checkConnectorHealth(id: UUID, showsToast: Bool = true, probeToolCalling: Bool = true) {
        guard let connector = state.connectors.first(where: { $0.id == id }) else { return }
        guard let index = state.connectors.firstIndex(where: { $0.id == id }) else { return }
        guard !healthChecksInFlight.contains(id) else { return }
        healthChecksInFlight.insert(id)
        if state.connectors[index].health != .ready {
            state.connectors[index].health = .attention
        }
        state.connectors[index].lastCheckedAt = .now

        Task {
            await self.runConnectorHealthCheck(
                id: id,
                connector: connector,
                showsToast: showsToast,
                probeToolCalling: probeToolCalling
            )
        }
    }

    public func checkAllConnectorsHealth(showsToast: Bool = false, probeToolCalling: Bool = false) {
        for connector in state.connectors {
            checkConnectorHealth(id: connector.id, showsToast: showsToast, probeToolCalling: probeToolCalling)
        }
    }

    private func runConnectorHealthCheck(
        id: UUID,
        connector: ConnectorProfile,
        showsToast: Bool,
        probeToolCalling: Bool
    ) async {
        var shouldRecheck = false
        defer {
            self.healthChecksInFlight.remove(id)
            if shouldRecheck {
                self.checkConnectorHealth(id: id, showsToast: false, probeToolCalling: probeToolCalling)
            }
        }
        do {
            let probe = try await environment.runtimeClient.probeConnector(
                endpoint: connector.endpoint,
                model: connector.modelName,
                apiKey: connector.note,
                kind: connector.kind,
                probeToolCalling: probeToolCalling
            )
            shouldRecheck = applyConnectorProbe(
                probe,
                id: id,
                originalConnector: connector,
                showsToast: showsToast,
                probeToolCalling: probeToolCalling
            )
        } catch {
            shouldRecheck = applyConnectorProbeFailure(error, id: id, originalConnector: connector, showsToast: showsToast)
        }
        if !shouldRecheck {
            self.persistConnectors()
        }
    }

    private func applyConnectorProbe(
        _ probe: ConnectorProbeResult,
        id: UUID,
        originalConnector: ConnectorProfile,
        showsToast: Bool,
        probeToolCalling: Bool
    ) -> Bool {
        guard let idx = self.state.connectors.firstIndex(where: { $0.id == id }) else { return false }
        let current = self.state.connectors[idx]
        if Self.connectorConfigurationChanged(from: originalConnector, to: current) {
            return self.canAutoCheckConnectorHealth(current)
        }
        self.state.connectors[idx].health = probe.health
        self.state.connectors[idx].lastCheckedAt = .now
        if let ctxWindow = probe.contextWindow, ctxWindow > 0 {
            self.state.connectors[idx].probedContextWindow = ctxWindow
        }
        _ = self.rememberToolCallingCapability(
            probe.toolCallingCapability,
            connectorID: id,
            activitySource: probeToolCalling ? .connectorProbe : nil
        )
        if showsToast {
            notifyConnectorProbeSuccess(probe, connector: originalConnector, index: idx)
        }
        return false
    }

    private func applyConnectorProbeFailure(
        _ error: Error,
        id: UUID,
        originalConnector: ConnectorProfile,
        showsToast: Bool
    ) -> Bool {
        guard let idx = self.state.connectors.firstIndex(where: { $0.id == id }) else { return false }
        let current = self.state.connectors[idx]
        if Self.connectorConfigurationChanged(from: originalConnector, to: current) {
            return self.canAutoCheckConnectorHealth(current)
        }
        self.state.connectors[idx].health = .offline
        self.state.connectors[idx].lastCheckedAt = .now
        if showsToast {
            self.notify("\(originalConnector.name) 连接失败：\(error.localizedDescription)", style: .error)
        }
        return false
    }

    private func notifyConnectorProbeSuccess(
        _ probe: ConnectorProbeResult,
        connector: ConnectorProfile,
        index: Int
    ) {
        let capabilityProfile = ConnectorCapabilityProfile.infer(
            for: self.state.connectors[index],
            mode: self.state.settings.contextMode
        )
        switch probe.health {
        case .ready:
            notifyReadyConnectorProbe(probe, connector: connector, capabilityProfile: capabilityProfile)
        case .attention:
            self.notify("\(connector.name) 配置需确认：服务可达，但模型或接口响应不匹配", style: .warning)
        case .offline:
            self.notify("\(connector.name) 离线", style: .error)
        }
    }

    private func notifyReadyConnectorProbe(
        _ probe: ConnectorProbeResult,
        connector: ConnectorProfile,
        capabilityProfile: ConnectorCapabilityProfile
    ) {
        if capabilityProfile.toolCallingConflict == .unsupported {
            self.notify("\(connector.name) 已验证不兼容工具调用，但当前仍手动开启。", style: .warning)
        } else if capabilityProfile.toolCallingConflict == .supported {
            self.notify("\(connector.name) 已验证支持工具调用，但当前仍手动关闭。", style: .warning)
        } else if probe.toolCallingCapability == .unsupported {
            self.notify("\(connector.name) 已连接，但不兼容工具调用", style: .warning)
        } else if probe.toolCallingCapability == .supported {
            self.notify("\(connector.name) 就绪，已验证支持工具调用", style: .success)
        } else {
            self.notify("\(connector.name) 就绪", style: .success)
        }
    }
}
