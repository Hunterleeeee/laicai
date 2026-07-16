import Foundation
import LaicaiNativeDomain

extension AppStore {
    func applySkillPromptHint(_ match: SkillMatchResult, connector: ConnectorProfile, loopConfig: inout AgentLoop.Config) {
        let skill = match.skill
        var hint = "\n\n## 已激活技能：\(skill.name)\n\(skill.description)"
        if let systemHint = skill.systemHint, !systemHint.isEmpty {
            hint += "\n\n\(systemHint)"
        }
        if !skill.tools.isEmpty {
            hint += "\n推荐工具：\(skill.tools.joined(separator: "、"))"
        }
        hint += """

            执行要求：
            - 先按技能指南确认输入边界，再调用所需工具；不要只复述技能说明。
            - 输出必须符合该技能的格式要求；保存类技能只有在 save_note/wiki_build/file_write 成功后才能说已保存。
            - 如果技能请求与用户当前目标冲突，以用户当前目标为准，并说明取舍。
            """
        loopConfig.customSystemPrompt = (loopConfig.customSystemPrompt ?? "") + hint
        state.liveActivity = "已激活技能：\(skill.name)"
        if let preferred = ModelRouter.selectModel(for: skill, connectors: state.connectors, activeConnectorID: state.activeConnectorID),
            preferred.id != connector.id
        {
            loopConfig.modelName = preferred.modelName
        }
    }
}
