import Foundation
import LaicaiNativeDomain

extension AppStore {
    private static let simpleActivityNames: [String: String] = [
        "workspace.index": "索引项目结构…",
        "git": "查看 Git 信息…",
        "web.fetch": "读取网页…",
        "wiki.build": "构建知识页…",
        "image.generate": "生成图片…",
        "verify.build": "验证构建…",
        "llm": "LLM 分析…"
    ]

    func updateLiveActivity(from step: TaskStep, for threadID: UUID) {
        guard let activity = Self.liveActivityText(for: step) else { return }
        setLiveActivity(activity, for: threadID)
    }

    private static func liveActivityText(for step: TaskStep) -> String? {
        switch step.kind {
        case .aiThinking:
            return "正在思考…"
        case .toolCall:
            return toolCallActivity(step)
        case .toolResult:
            return step.isFailure ? "工具执行失败，正在处理…" : nil
        case .textOutput:
            return "正在生成回复…"
        case .reviewRequest:
            return "等待审查确认"
        case .error:
            return errorActivity(step)
        case .userInput, .reviewResult:
            return nil
        }
    }

    private static func toolCallActivity(_ step: TaskStep) -> String {
        guard let name = step.toolName else { return "正在调用工具…" }
        return "正在\(Self.friendlyActivityName(name, params: step.toolParams))"
    }

    private static func errorActivity(_ step: TaskStep) -> String {
        step.recoverable ? "遇到错误，尝试恢复…" : ""
    }

    static func friendlyActivityName(_ toolName: String, params: [String: String]?) -> String {
        if toolName == "code.search" || toolName == "web.search" {
            return searchActivityName(params: params, fallback: toolName == "code.search" ? "搜索代码…" : "联网搜索…")
        }
        if toolName == "file.read" {
            return fileActivityName(params: params, verb: "读取", fallback: "读取文件…")
        }
        if ["file.write", "file.edit", "diff.apply"].contains(toolName) {
            return fileActivityName(params: params, verb: "修改", fallback: "写入文件…")
        }
        if toolName == "shell.exec" {
            return params?["command"].map { "执行 \(String($0.prefix(25)))…" } ?? "执行命令…"
        }
        return simpleActivityNames[toolName] ?? "调用 \(toolName)…"
    }

    private static func searchActivityName(params: [String: String]?, fallback: String) -> String {
        guard let query = params?["query"], !query.isEmpty else { return fallback }
        return "搜索「\(String(query.prefix(20)))」…"
    }

    private static func fileActivityName(params: [String: String]?, verb: String, fallback: String) -> String {
        guard let path = params?["path"] ?? params?["fullPath"] else { return fallback }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return "\(verb) \(name)…"
    }
}
