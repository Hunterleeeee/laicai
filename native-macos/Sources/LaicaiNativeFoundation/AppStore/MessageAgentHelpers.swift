import Foundation
import LaicaiNativeDomain

struct CustomAgentInvocation {
    let agent: CustomAgentDefinition
    let message: String
}

extension AppStore {
    func customAgentInvocation(from message: String) -> CustomAgentInvocation? {
        let prefix = "[Agent:"
        guard message.hasPrefix(prefix),
            let endIndex = message.firstIndex(of: "]")
        else {
            return nil
        }
        let nameStart = message.index(message.startIndex, offsetBy: prefix.count)
        let name = String(message[nameStart..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        AgentRegistry.shared.refresh(workspaceRoot: state.settings.workspacePath)
        guard let agent = AgentRegistry.shared.agents.first(where: { $0.name == name }) else {
            notify("未找到 会话「\(name)」", style: .error)
            return nil
        }
        let contentStart = message.index(after: endIndex)
        let content = String(message[contentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return CustomAgentInvocation(agent: agent, message: content.isEmpty ? "请按你的会话职责继续处理当前会话目标。" : content)
    }
}
