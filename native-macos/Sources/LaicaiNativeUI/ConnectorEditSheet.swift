import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Connector Edit Mode

enum ConnectorEditMode: Identifiable {
    case add
    case edit(ConnectorProfile)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let connector): return connector.id.uuidString
        }
    }
}

// MARK: - Connector Editor Sheet

struct ConnectorEditSheet: View {
    let mode: ConnectorEditMode
    let onSave: (ConnectorProfile) -> Void
    let onSaveAndTest: ((ConnectorProfile) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind = "openai-compatible"
    @State private var endpoint = ""
    @State private var modelName = ""
    @State private var apiKey = ""
    @State private var role: ConnectorRole?
    @State private var toolCallingPolicy: ConnectorToolCallingPolicy = .automatic

    init(
        mode: ConnectorEditMode,
        onSave: @escaping (ConnectorProfile) -> Void,
        onSaveAndTest: ((ConnectorProfile) -> Void)? = nil
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onSaveAndTest = onSaveAndTest
        if case .edit(let connector) = mode {
            _name = State(initialValue: connector.name)
            _kind = State(initialValue: connector.kind)
            _endpoint = State(initialValue: connector.endpoint)
            _modelName = State(initialValue: connector.modelName)
            _apiKey = State(initialValue: connector.note)
            _role = State(initialValue: connector.role)
            _toolCallingPolicy = State(initialValue: connector.toolCallingPolicy ?? .automatic)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isAdding ? "添加连接器" : "编辑连接器")
                    .font(AppFont.headline)
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(TextGrade.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AppSpace.extraLarge)
            .padding(.top, AppSpace.extraLarge)
            .padding(.bottom, AppSpace.large)

            Divider()

            Form {
                Section {
                    TextField("名称", text: $name)
                        .textFieldStyle(.plain)

                    Picker("类型", selection: $kind) {
                        HStack { Image(systemName: "globe"); Text("OpenAI 兼容") }
                            .tag("openai-compatible")
                        HStack { Image(systemName: "brain.head.profile"); Text("Anthropic") }
                            .tag("anthropic")
                        HStack { Image(systemName: "laptopcomputer"); Text("Ollama 本地") }
                            .tag("ollama")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("基本信息")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.muted)
                }

                Section {
                    TextField("端点", text: $endpoint)
                        .textFieldStyle(.plain)
                        .help(endpointHelpText)

                    if !endpoint.trimmingCharacters(in: .whitespaces).isEmpty && !isEndpointValid {
                        Text("端点地址无效，请检查协议、主机和端口（端口需在 1-65535）。")
                            .font(AppFont.caption)
                            .foregroundStyle(Semantic.error)
                    }

                    TextField("模型名称", text: $modelName)
                        .textFieldStyle(.plain)
                        .help("例如：gpt-4.1、claude-sonnet、qwen3")
                } header: {
                    Text("模型配置")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.muted)
                }

                Section {
                    SecureField("API 密钥", text: $apiKey)
                        .textFieldStyle(.plain)
                        .help(kind == "ollama" ? "本地 Ollama 留空" : "填入 API 密钥")
                } header: {
                    Text("认证")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.muted)
                }

                Section {
                    HStack(spacing: 8) {
                        ForEach(ConnectorRole.allCases, id: \.self) { connectorRole in
                            Button {
                                role = role == connectorRole ? nil : connectorRole
                            } label: {
                                Label(connectorRole.title, systemImage: connectorRole.icon)
                                    .font(AppFont.captionMedium)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(role == connectorRole ? Color.accentColor.opacity(0.15) : Color.clear)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(roleHint)
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                } header: {
                    Text("路由角色")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.muted)
                }

                Section {
                    Picker("工具调用", selection: $toolCallingPolicy) {
                        ForEach(ConnectorToolCallingPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("自动：沿用默认判断；开启：总是发送 tools；关闭：执行姿态不再发送 tools。")

                    Text(toolCallingStatusText)
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                } header: {
                    Text("能力策略")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.muted)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onChange(of: kind) { _, newKind in
                if newKind == "ollama" && endpoint.trimmingCharacters(in: .whitespaces).isEmpty {
                    endpoint = "http://127.0.0.1:11434"
                } else if newKind == "anthropic" && (endpoint.isEmpty || endpoint.contains("openai") || endpoint.contains("11434")) {
                    endpoint = "https://api.anthropic.com"
                }
            }

            Divider()

            // Actions
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    let connector = makeConnector()
                    if let onSaveAndTest {
                        onSaveAndTest(connector)
                    } else {
                        onSave(connector)
                    }
                    dismiss()
                } label: {
                    Label("保存并测试", systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)
                .disabled(!isValid)

                Button("保存") {
                    onSave(makeConnector())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(.horizontal, AppSpace.extraLarge)
            .padding(.vertical, AppSpace.large)
        }
        .frame(width: 440)
    }

    private var endpointHelpText: String {
        switch kind {
        case "ollama": return "http://127.0.0.1:11434 或完整 /api/chat"
        case "anthropic": return "https://api.anthropic.com 或自定义代理地址"
        default: return "https://api.openai.com/v1"
        }
    }

    private var isAdding: Bool {
        if case .add = mode { return true }
        return false
    }

    private var isValid: Bool {
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
            && isEndpointValid
            && !modelName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var roleHint: String {
        if let role {
            switch role {
            case .fast: return "探索、聊天、搜索等需要快速响应的场景优先使用此连接器。"
            case .code: return "代码生成、文件编辑、重构等编码任务优先使用此连接器。"
            case .strong: return "验证、审查、复杂推理等需要高质量输出的场景优先使用此连接器。"
            }
        }
        return "未指定角色时，路由会根据模型名称自动推断（可留空）。"
    }

    private func makeConnector() -> ConnectorProfile {
        buildConnector(lastCheckedAt: .now)
    }

    private func buildConnector(lastCheckedAt: Date? = nil) -> ConnectorProfile {
        let policy: ConnectorToolCallingPolicy? = toolCallingPolicy == .automatic ? nil : toolCallingPolicy
        let endpointValue = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKind = LiveChatRuntime.normalizedConnectorKind(kind, endpoint: endpointValue)
        switch mode {
        case .add:
            return ConnectorProfile(
                name: name.trimmingCharacters(in: .whitespaces),
                kind: resolvedKind,
                endpoint: endpointValue,
                modelName: modelName.trimmingCharacters(in: .whitespaces),
                note: apiKey,
                role: role,
                toolCallingPolicy: policy,
                health: .attention,
                lastCheckedAt: lastCheckedAt ?? .now
            )
        case .edit(let existing):
            return ConnectorProfile(
                id: existing.id,
                name: name.trimmingCharacters(in: .whitespaces),
                kind: resolvedKind,
                endpoint: endpointValue,
                modelName: modelName.trimmingCharacters(in: .whitespaces),
                note: apiKey,
                role: role,
                toolCallingPolicy: policy,
                toolCallingCapability: existing.toolCallingCapability,
                toolCallingCapabilitySource: existing.toolCallingCapabilitySource,
                toolCallingCapabilityLearnedAt: existing.toolCallingCapabilityLearnedAt,
                health: existing.health,
                lastCheckedAt: lastCheckedAt ?? existing.lastCheckedAt
            )
        }
    }

    private var isEndpointValid: Bool {
        let endpointValue = endpoint.trimmingCharacters(in: .whitespaces)
        guard !endpointValue.isEmpty,
              let components = URLComponents(string: endpointValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            return false
        }

        if let declaredPort = declaredPort(in: endpointValue) {
            guard let port = Int(declaredPort), (1...65535).contains(port) else {
                return false
            }
        }

        return true
    }

    private var previewConnector: ConnectorProfile {
        buildConnector()
    }

    private var toolCallingStatusText: String {
        let endpointValue = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelValue = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if toolCallingPolicy == .automatic,
           previewConnector.toolCallingCapability == nil,
           endpointValue.isEmpty || modelValue.isEmpty {
            return "当前生效：等待端点和模型填写完整后再自动判断工具调用能力。"
        }
        let capability = ConnectorCapabilityProfile.infer(for: previewConnector, mode: .balanced)
        let tools = capability.supportsToolCalling ? "工具调用已开启" : "工具调用已关闭"
        var lines = ["当前生效：\(tools) · \(capability.toolCallingSourceDetail)"]
        if let conflict = capability.toolCallingConflict {
            let followup = conflict == .unsupported
                ? "如果切回自动，后续会话会默认不再发送 tools。"
                : "如果切回自动，后续会话会恢复发送 tools。"
            lines.append("系统记录：\(conflict.title)。\(followup)")
        } else if toolCallingPolicy == .automatic,
                  let learned = capability.learnedToolCallingDetail {
            if let learnedAt = capability.learnedToolCallingLearnedAt {
                lines.append("系统记录：\(learned) · \(RelativeTimeFormatter.string(for: learnedAt))。")
            } else {
                lines.append("系统记录：\(learned)。")
            }
        } else if let learned = capability.learnedToolCallingDetail {
            if let learnedAt = capability.learnedToolCallingLearnedAt {
                lines.append("历史记录：\(learned) · \(RelativeTimeFormatter.string(for: learnedAt))。")
            } else {
                lines.append("历史记录：\(learned)。")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func declaredPort(in endpointValue: String) -> String? {
        guard let schemeRange = endpointValue.range(of: "://") else { return nil }
        let afterScheme = endpointValue[schemeRange.upperBound...]
        let authority = afterScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard let colon = authority.lastIndex(of: ":") else { return nil }
        let port = authority[authority.index(after: colon)...]
        return port.isEmpty ? nil : String(port)
    }
}
