import Foundation
import LaicaiNativeDomain

extension AppStore {
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
