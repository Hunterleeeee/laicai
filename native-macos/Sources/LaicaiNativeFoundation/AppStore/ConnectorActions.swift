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

    func updateLiveActivity(from step: TaskStep) {
        switch step.kind {
        case .aiThinking:
            state.liveActivity = "正在思考…"
        case .toolCall:
            if let name = step.toolName {
                state.liveActivity = "正在\(Self.friendlyActivityName(name, params: step.toolParams))"
            } else {
                state.liveActivity = "正在调用工具…"
            }
        case .toolResult:
            if step.isFailure {
                state.liveActivity = "工具执行失败，正在处理…"
            }
        case .textOutput:
            state.liveActivity = "正在生成回复…"
        case .reviewRequest:
            state.liveActivity = "等待审查确认"
        case .error:
            if step.recoverable {
                state.liveActivity = "遇到错误，尝试恢复…"
            } else {
                state.liveActivity = ""
            }
        case .userInput, .reviewResult:
            break
        }
    }

    static func friendlyActivityName(_ toolName: String, params: [String: String]?) -> String {
        switch toolName {
        case "workspace.index": return "索引项目结构…"
        case "code.search":
            if let q = params?["query"], !q.isEmpty { return "搜索「\(String(q.prefix(20)))」…" }
            return "搜索代码…"
        case "file.read":
            if let p = params?["path"] ?? params?["fullPath"] {
                let name = URL(fileURLWithPath: p).lastPathComponent
                return "读取 \(name)…"
            }
            return "读取文件…"
        case "file.write", "file.edit", "diff.apply":
            if let p = params?["path"] ?? params?["fullPath"] {
                let name = URL(fileURLWithPath: p).lastPathComponent
                return "修改 \(name)…"
            }
            return "写入文件…"
        case "shell.exec":
            if let cmd = params?["command"] { return "执行 \(String(cmd.prefix(25)))…" }
            return "执行命令…"
        case "git": return "查看 Git 信息…"
        case "web.search":
            if let q = params?["query"] { return "搜索「\(String(q.prefix(20)))」…" }
            return "联网搜索…"
        case "web.fetch": return "读取网页…"
        case "wiki.build": return "构建知识页…"
        case "image.generate": return "生成图片…"
        case "verify.build": return "验证构建…"
        case "llm": return "LLM 分析…"
        default: return "调用 \(toolName)…"
        }
    }
}
