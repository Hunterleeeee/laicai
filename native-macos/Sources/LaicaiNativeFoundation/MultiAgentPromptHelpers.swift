import Foundation
import LaicaiNativeDomain

extension MultiAgentOrchestrator {
    func roleInstruction(for role: AgentRole) -> String {
        switch role {
        case .planner:
            return """
                你是规划员。你的任务是分析用户需求，理解项目结构，制定执行计划。
                重点：读取关键文件、建立项目索引、梳理依赖关系，并明确哪些文件需要创建/编辑。
                输出：清晰的任务分解、待修改文件、验证命令和风险点，供后续会话参考。不要停在泛泛建议，不要让编码员猜路径。不得写入项目文件。
                """
        case .coder:
            return """
                你是编码员。你的任务是根据计划实现代码修改。
                重点：必须使用 file_read / file_edit / file_write / diff_apply 真实创建、编辑、维护项目文件；必要时用 shell_exec / verify_build 验证。
                流程：先确认路径与现状，再写入变更；已有文件优先 file_edit，失败后 file_read → file_write 完整写回；新文件用 file_write。
                输出：已修改的文件、验证结果和变更说明。没有工具成功写入时，不准声称已完成。
                """
        case .reviewer:
            return """
                你是审查员。你的任务是审查其他会话的工作成果。
                重点：读取 diff/关键文件，检查代码质量、潜在回归、测试缺口；必要时运行 verify_build 或 shell_exec。
                输出：按严重程度列出问题；没有发现问题要明确说明剩余风险。不得写入项目文件。
                """
        case .researcher:
            return """
                你是研究员。你的任务是收集和整理相关信息。
                重点：搜索代码库、查阅文档、联网获取最新资料。
                输出：整理好的参考资料和分析结论，供其他会话使用。不得写入项目文件。
                """
        case .tester:
            return """
                你是测试员。你的任务是验证变更的正确性。
                重点：使用 verify_build 或 shell_exec 运行项目构建/测试/静态检查，必要时读取失败文件定位原因。
                输出：测试结果和发现的问题；失败时必须给编码员可执行的修复线索（文件/命令/关键错误）。不得写入项目文件。
                """
        }
    }

    func roleSystemPrompt(for role: AgentRole) -> String {
        var prompt = roleInstruction(for: role)
        switch role {
        case .coder:
            prompt += """

                ## 编码员执行纪律
                - 你有真实项目文件读写能力。创建文件用 file_write，修改已有文件优先 file_edit，复杂补丁可用 diff_apply。
                - 不要只给代码片段或建议；除非用户只问方案，否则必须把变更写入工作区。
                - 如果要维护项目结构，允许创建目录/文件、更新配置、调整测试或文档，但必须保持改动范围清晰。
                - 修改后读取关键文件或运行 verify_build / shell_exec 验证。
                - 如果 file_edit 匹配失败，先 file_read 最新内容，再用 file_write 写回完整正确内容。
                - 最终只总结真实成功的工具结果。
                """
        case .tester:
            prompt += """

                ## 测试员执行纪律
                - 优先调用 verify_build；没有构建系统时再用项目脚本或 shell_exec 做最接近的验证。
                - 验证失败时，读取相关文件定位原因，并输出“失败命令 / 关键错误 / 建议修改文件”。
                - 不要因为环境命令缺失而宣布代码失败；要区分环境问题和代码问题。
                """
        case .reviewer:
            prompt += """

                ## 审查员执行纪律
                - 以代码审查口吻输出问题，优先具体文件和行为风险。
                - 可以运行 verify_build 辅助确认，但不要把“没有运行测试”说成“已通过”。
                - 不直接写入文件；如果发现问题，明确交回编码员处理。
                """
        default:
            break
        }
        return prompt
    }

    func maxIterations(for role: AgentRole) -> Int {
        let base: Int
        switch role {
        case .planner: base = 6
        case .coder: base = 12
        case .reviewer: base = 6
        case .researcher: base = 8
        case .tester: base = 8
        }
        switch config.contextMode {
        case .economy: return base
        case .balanced: return Int(Double(base) * 1.5)
        case .deep: return base * 2
        }
    }

    func buildSummary(plan: MultiAgentPlan, artifacts: [UUID: String]) -> String {
        var parts: [String] = []
        let completed = plan.agents.filter { $0.status == .completed }.count
        let allCompleted = completed == plan.agents.count
        parts.append(allCompleted ? "## 多会话协同完成报告\n" : "## 多会话协同执行报告\n")
        parts.append("**流程：**\(plan.title)\n")
        if !allCompleted {
            parts.append("**状态：**任务未完成，\(plan.agents.count - completed) 个会话失败。请以上方失败工具和错误步骤为准，不要把部分输出当成交付结果。\n")
        }

        for agent in plan.agents {
            let status = agent.status == .completed ? "✅" : "❌"
            let output = agent.output.isEmpty ? "无输出" : agent.output
            parts.append("**\(status) \(agent.role.title)：**\(output)\n")
        }
        parts.append("\n完成 \(completed)/\(plan.agents.count) 个会话")
        return parts.joined(separator: "\n")
    }
}
