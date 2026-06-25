import Foundation
import LaicaiNativeDomain

// MARK: - Prompt Composer

public struct PromptComposer {
    /// Compose system prompt with project context for the agent loop.
    /// This is used as the system message for LLM calls with function calling.
    public static func composeSystemPrompt(context: TaskContext, intent: UserIntent) -> String {
        var parts: [String] = []

        parts.append("你是来财（Laicai），macOS 本机 AI 助手。\(currentDateString())。")

        if intent == .chat {
            parts.append("直接回答问题。简洁、准确、不啰嗦。")
            if let claudeMD = context.claudeMD {
                parts.append("\n## 项目记忆\n\(claudeMD)")
            }
            return parts.joined(separator: "\n")
        }

        // Non-chat: compact workflow protocol
        parts.append("""
        ## 核心原则
        - 目标：完成用户交给的任务。根据当前证据决定下一步，不盲目调用工具，不套固定流程。
        - 证据优先：没读过的文件不判断内容。以工具返回的结果为准。
        - 失败恢复：同参数不重试，换工具/参数/路径。连续失败才向用户说明阻塞。
        - 危险操作（删除、sudo、密钥、强推）默认停止并说明风险，除非用户明确授权。
        - 收口只说：做了什么、验证了什么、剩余风险。
        """)

        if let protocolGoal = context.metadata["taskProtocolGoal"] {
            parts.append("\n## 任务协议\n目标：\(protocolGoal)\n工作区：\(context.workspaceRoot.isEmpty ? "未指定" : context.workspaceRoot)")
        }

        // Context injection
        if let claudeMD = context.claudeMD {
            parts.append("\n## 项目记忆\n\(claudeMD)")
        }
        if let projectCtx = ProjectManager.buildProjectContext(projects: ProjectManager.cachedProjects, rootPath: context.workspaceRoot) {
            parts.append("\n## 项目概况\n\(projectCtx)")
        }
        if let branch = context.gitBranch {
            parts.append("\n## 分支\n\(branch)")
        } else if !context.workspaceRoot.isEmpty {
            let isGit = FileManager.default.fileExists(atPath: (context.workspaceRoot as NSString).appendingPathComponent(".git"))
            if !isGit { parts.append("\n## 非 Git 工作区\n不要调用 git 工具。") }
        }
        if let diff = context.gitDiff {
            parts.append("\n## 未提交变更\n\(diff)")
        }
        if let vaultRoot = context.vaultRoot, !vaultRoot.isEmpty {
            parts.append("\n## Vault\n\(vaultRoot)")
        }
        if !context.relevantFiles.isEmpty {
            let fileList = context.relevantFiles.prefix(10).map { "- \($0.path)" }.joined(separator: "\n")
            parts.append("\n## 相关文件\n\(fileList)")
        }

        // Intent-specific mode
        switch intent {
        case .chat: break
        case .research:
            parts.append("\n## 研究模式\n优先 web_search 获取来源，web_fetch 读详情，基于来源整理结论。不写文件不装软件，除非用户要求。")
        case .task:
            parts.append("\n## 执行模式\nfile_edit 改已有文件，file_write 新建文件。代码改后 verify_build 验证。")
            if let verifyCmd = ValidationEngine.suggestVerificationCommand(workspaceRoot: context.workspaceRoot) {
                parts.append("验证命令：`\(verifyCmd)`")
            }
        case .workflow(let name):
            parts.append("\n## 工作流模式\n\(name)。工具结果证明需要调整时先调整，最终以完成用户目标为准。")
        }

        return parts.joined(separator: "\n")
    }

    private static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: Date())
    }
    /// Compose system prompt for simple chat (no tools)
    public static func composeChatPrompt(context: TaskContext) -> String {
        var parts: [String] = []
        parts.append("""
        你是来财（Laicai），运行在用户 macOS 上的本地助手。当前日期：\(currentDateString())。
        
        会话问答规则：
        - 直接回答问题，保持简洁有深度
        - 认真阅读会话历史，保持上下文连贯
        - 用户追问时，基于之前的会话内容回答，不要要求重复
        - 你是运行在本机的会话，拥有文件读写、代码搜索、命令执行、联网搜索等工具能力
        - 你是来财，不是 ChatGPT/Qwen/DeepSeek
        - **输出禁令**：禁止输出「阶段总结」「Plan/Execute/Verify/Summarize」「证据清单」「完成检查」等内部推理格式。只用自然语言回答。
        """)

        if let claudeMD = context.claudeMD {
            parts.append("\n## 项目记忆\n\(claudeMD)")
        }

        if let branch = context.gitBranch {
            parts.append("\n## 当前分支\n\(branch)")
        }

        return parts.joined(separator: "\n")
    }

}
