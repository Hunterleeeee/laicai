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
                guard let idx = self.state.connectors.firstIndex(where: { $0.id == id }) else { return }
                let current = self.state.connectors[idx]
                if Self.connectorConfigurationChanged(from: connector, to: current) {
                    shouldRecheck = self.canAutoCheckConnectorHealth(current)
                    return
                }
                self.state.connectors[idx].health = probe.health
                self.state.connectors[idx].lastCheckedAt = .now
                if let ctxWindow = probe.contextWindow, ctxWindow > 0 {
                    self.state.connectors[idx].probedContextWindow = ctxWindow
                }
                let capabilityChanged = self.rememberToolCallingCapability(
                    probe.toolCallingCapability,
                    connectorID: id,
                    activitySource: probeToolCalling ? .connectorProbe : nil
                )
                let capabilityProfile = ConnectorCapabilityProfile.infer(
                    for: self.state.connectors[idx],
                    mode: self.state.settings.contextMode
                )
                if showsToast {
                    switch probe.health {
                    case .ready:
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
                    case .attention:
                        self.notify("\(connector.name) 配置需确认：服务可达，但模型或接口响应不匹配", style: .warning)
                    case .offline:
                        self.notify("\(connector.name) 离线", style: .error)
                    }
                }
                _ = capabilityChanged
            } catch {
                guard let idx = self.state.connectors.firstIndex(where: { $0.id == id }) else { return }
                let current = self.state.connectors[idx]
                if Self.connectorConfigurationChanged(from: connector, to: current) {
                    shouldRecheck = self.canAutoCheckConnectorHealth(current)
                    return
                }
                self.state.connectors[idx].health = .offline
                self.state.connectors[idx].lastCheckedAt = .now
                if showsToast { self.notify("\(connector.name) 连接失败：\(error.localizedDescription)", style: .error) }
            }
            self.persistConnectors()
        }
    }

    public func checkAllConnectorsHealth(showsToast: Bool = false, probeToolCalling: Bool = false) {
        for connector in state.connectors {
            checkConnectorHealth(id: connector.id, showsToast: showsToast, probeToolCalling: probeToolCalling)
        }
    }
}
