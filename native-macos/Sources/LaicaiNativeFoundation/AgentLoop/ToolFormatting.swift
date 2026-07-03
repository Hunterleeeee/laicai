import Foundation
import LaicaiNativeDomain

enum ToolResultFormatter {
    private typealias ResultFormatter = ([String: String], ToolResult) -> String

    private static let successFormatters: [String: ResultFormatter] = [
        "file.read": { arguments, result in readDisplay(arguments: arguments, result: result) },
        "file.extract": { arguments, result in extractDisplay(arguments: arguments, result: result) },
        "document.transform": { arguments, result in documentDisplay(arguments: arguments, result: result) },
        "code.search": { arguments, result in codeSearchDisplay(arguments: arguments, result: result) },
        "workspace.index": { _, result in workspaceIndexDisplay(result: result) },
        "file.edit": { arguments, result in fileEditDisplay(arguments: arguments, result: result) },
        "file.write": { arguments, result in fileWriteDisplay(arguments: arguments, result: result) },
        "diff.apply": { arguments, result in diffApplyDisplay(arguments: arguments, result: result) },
        "verify.build": { arguments, result in verifyBuildDisplay(arguments: arguments, result: result) },
        "web.search": { arguments, result in webSearchDisplay(arguments: arguments, result: result) },
        "web.fetch": { _, result in webFetchDisplay(result: result) },
        "wiki.build": { arguments, result in wikiBuildDisplay(arguments: arguments, result: result) },
        "skill.manage": { arguments, result in skillManageDisplay(arguments: arguments, result: result) },
        "shell.exec": { _, result in shellExecDisplay(result: result) },
        "git": { _, result in gitDisplay(result: result) }
    ]

    static func displayText(toolName: String, arguments: [String: String], result: ToolResult) -> String {
        guard result.success else {
            // Surface BOTH error code and output. The output usually contains the actual
            // diagnostic ("batchEdits 参数格式错误：xxx 需要 JSON 数组格式...") that the
            // model needs to recover. Returning only the error code (e.g. "invalid_batch_edits")
            // leaves the model in the dark and causes repeated identical failures.
            let code = result.error ?? ""
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let combined: String
            if !code.isEmpty && !detail.isEmpty && detail != code {
                combined = "失败 [\(code)]：\(detail)"
            } else if !code.isEmpty {
                combined = "失败：\(code)"
            } else {
                combined = "失败：\(detail.isEmpty ? "未知错误" : detail)"
            }
            return compact(combined, limit: 600)
        }

        return successFormatters[toolName]?(arguments, result) ?? compact(result.output, limit: 360)
    }

    private static func readDisplay(arguments: [String: String], result: ToolResult) -> String {
        let path = result.data?["path"] ?? arguments["path"] ?? "文件"
        let size = result.data?["size"].flatMap(Int.init) ?? result.output.count
        let lines = result.output.components(separatedBy: .newlines).count
        let suffix = result.output.contains("已截断") ? "，内容已截断" : ""
        return "已读取 \(path) · \(lines) 行 · \(size) 字符\(suffix)"
    }

    private static func extractDisplay(arguments: [String: String], result: ToolResult) -> String {
        let path = result.data?["path"] ?? arguments["path"] ?? "文件"
        let size = result.data?["size"].flatMap(Int.init) ?? result.output.count
        let lines = result.output.components(separatedBy: .newlines).count
        return "已提取 \(path) · \(lines) 行 · \(size) 字符"
    }

    private static func documentDisplay(arguments: [String: String], result: ToolResult) -> String {
        let action = result.data?["action"] ?? arguments["action"] ?? "prepare"
        let format = result.data?["format"]?.uppercased() ?? "文档"
        let total = result.data?["totalTextRuns"] ?? "0"
        let cjk = result.data?["cjkTextRuns"] ?? "0"
        switch action {
        case "workspace":
            let workflow = result.data?["workflowPath"] ?? arguments["workflowPath"] ?? "交付工作区"
            let manifest = result.data?["manifestPath"] ?? "manifest"
            return "已创建 \(format) 交付工作区 · \(workflow) · \(manifest)"
        case "apply":
            let path = result.data?["outputPath"] ?? arguments["outputPath"] ?? "输出文件"
            let applied = result.data?["appliedReplacements"] ?? "0"
            let remaining = result.data?["remainingCJK"] ?? cjk
            return "已写回 \(format) 文档 · \(applied) 条替换 · 剩余中文 \(remaining) 条 · \(path)"
        case "copy":
            let path = result.data?["outputPath"] ?? arguments["outputPath"] ?? "输出文件"
            return "已复制 \(format) 文档 · \(path)"
        case "verify":
            let complete = result.data?["complete"] == "true"
            let path = result.data?["outputPath"] ?? arguments["outputPath"] ?? arguments["sourcePath"] ?? "文档"
            let remaining = result.data?["remainingCJK"] ?? cjk
            return complete ? "文档验证通过 · \(path)" : "文档仍需处理 · \(format) · 剩余中文 \(remaining) 条"
        case "render":
            let pdf = result.data?["pdfPath"] ?? "PDF"
            let pages = result.data?["renderedPages"] ?? "0"
            return "已渲染 \(format) 文档 · \(pages) 页 · \(pdf)"
        default:
            return "已检查 \(format) 文档 · \(total) 条可编辑文本 · \(cjk) 条含中文"
        }
    }

    private static func codeSearchDisplay(arguments: [String: String], result: ToolResult) -> String {
        let query = result.data?["query"] ?? arguments["query"] ?? ""
        let count = result.data?["count"].flatMap(Int.init) ?? nonEmptyLines(result.output).count
        if count == 0 || result.output.hasPrefix("未找到") {
            return query.isEmpty ? "未找到匹配结果" : "未找到匹配结果：\(query)"
        }
        let sample = nonEmptyLines(result.output).prefix(3).joined(separator: "，")
        return sample.isEmpty ? "找到 \(count) 个匹配结果" : "找到 \(count) 个匹配结果：\(sample)"
    }

    private static func workspaceIndexDisplay(result: ToolResult) -> String {
        let fileCount = result.data?["fileCount"] ?? "0"
        let directoryCount = result.data?["directoryCount"] ?? "0"
        return "已建立项目索引 · \(fileCount) 个文件 · \(directoryCount) 个目录"
    }

    private static func fileEditDisplay(arguments: [String: String], result: ToolResult) -> String {
        let path = result.data?["path"] ?? arguments["path"] ?? "文件"
        let applied = result.data?["appliedEdits"] ?? "0"
        let total = result.data?["totalEdits"] ?? applied
        return "已准备精准编辑 · \(path) · \(applied)/\(total) 条变更"
    }

    private static func fileWriteDisplay(arguments: [String: String], result: ToolResult) -> String {
        let path = result.data?["path"] ?? arguments["path"] ?? "文件"
        return "已准备文件写入 · \(path)"
    }

    private static func diffApplyDisplay(arguments: [String: String], result: ToolResult) -> String {
        let path = result.data?["path"] ?? arguments["path"] ?? "文件"
        return "已准备补丁应用 · \(path)"
    }

    private static func verifyBuildDisplay(arguments: [String: String], result: ToolResult) -> String {
        let command = result.data?["command"] ?? arguments["command"] ?? "自动检测"
        let exitCode = result.data?["exitCode"] ?? "0"
        return "验证完成 · 退出码 \(exitCode) · \(command)"
    }

    private static func webSearchDisplay(arguments: [String: String], result: ToolResult) -> String {
        let query = result.data?["query"] ?? arguments["query"] ?? ""
        let count = result.data?["count"].flatMap(Int.init) ?? nonEmptyLines(result.output).count
        if count == 0 || result.output.hasPrefix("未找到") {
            return query.isEmpty ? "未找到网页结果" : "未找到网页结果：\(query)"
        }
        let titles = nonEmptyLines(result.output)
            .filter { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }
            .prefix(3)
            .joined(separator: "；")
        return titles.isEmpty
            ? "联网搜索完成 · \(count) 条结果：\(query)"
            : "联网搜索完成 · \(count) 条结果：\(titles)"
    }

    private static func webFetchDisplay(result: ToolResult) -> String {
        let title = result.data?["title"] ?? "网页"
        let size = result.data?["size"] ?? "\(result.output.count)"
        return "已读取网页：\(title) · \(size) 字符"
    }

    private static func wikiBuildDisplay(arguments: [String: String], result: ToolResult) -> String {
        let topic = result.data?["topic"] ?? arguments["topic"] ?? "主题"
        let path = result.data?["path"] ?? "02 Atomic"
        let count = result.data?["sourceCount"] ?? "0"
        let saved = result.data?["saved"] == "true"
        return saved
            ? "已保存 Wiki：\(topic) → \(path) · \(count) 条来源"
            : "已生成 Wiki 预览：\(topic) → \(path) · \(count) 条来源"
    }

    private static func skillManageDisplay(arguments: [String: String], result: ToolResult) -> String {
        let action = result.data?["action"] ?? arguments["action"] ?? "skill"
        let name = result.data?["name"] ?? arguments["name"] ?? "技能"
        if let path = result.data?["path"] {
            return "技能已\(action == "update" ? "更新" : "保存")：\(name) · \(path)"
        }
        return compact(result.output, limit: 220)
    }

    private static func shellExecDisplay(result: ToolResult) -> String {
        let exitCode = result.data?["exitCode"] ?? "0"
        let firstLine = nonEmptyLines(result.output).first ?? "命令已完成"
        return "命令完成 · 退出码 \(exitCode) · \(compact(firstLine, limit: 180))"
    }

    private static func gitDisplay(result: ToolResult) -> String {
        if result.data?["repository"] == "false" {
            return compact(result.output, limit: 220)
        }
        let firstLine = nonEmptyLines(result.output).first ?? "Git 操作已完成"
        return compact(firstLine, limit: 220)
    }

    static func modelContent(toolName: String, result: ToolResult, limit: Int) -> String {
        if !result.success {
            var errorContent = compact("Error: \(result.error ?? result.output)", limit: max(500, limit))
            if toolName == "code.search" {
                errorContent += "\n\n提示：本地搜索未找到结果。如果这是一个外部工具、库或概念，请调用 web_search 联网搜索了解它是什么。"
            } else if toolName == "file.read", result.error == "unsupported_binary_file" {
                errorContent += "\n\n提示：这是表格/文档类文件。若只是阅读请改用 file_extract；若用户要生成、翻译、改写或保存 Office 文档，请改用 document_transform。不要把这个失败当作会话完成。"
            }
            return errorContent
        }

        if toolName == "code.search" && (result.output.hasPrefix("未找到") || result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return (result.output.isEmpty ? "未找到匹配结果。" : result.output) + "\n\n提示：本地搜索未找到结果。如果这是一个外部工具、库或概念，请调用 web_search 联网搜索了解它是什么，不要直接放弃。"
        }

        // Dynamic cap: scale with model's context window. 1M-class models can handle much more.
        let boundedLimit = max(2000, min(limit, 100_000))
        if result.output.count <= boundedLimit {
            return result.output
        }

        if toolName == "file.read" || toolName == "file.extract" || toolName == "document.transform" {
            let smartResult = smartTruncateCode(result.output, limit: boundedLimit)
            if !smartResult.isEmpty { return smartResult }
        }

        if toolName == "shell.exec" || toolName == "verify.build" {
            let lines = result.output.components(separatedBy: "\n")
            let actionableLines = lines.filter { line in
                let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
                return lower.contains("error") || lower.contains("warning") || lower.contains("fail")
                    || lower.contains("cannot") || lower.contains("not found") || lower.contains("undefined")
                    || lower.contains("syntax") || lower.hasPrefix("✅") || lower.hasPrefix("❌")
                    || lower.contains("success") || lower.contains("passed") || lower.contains("完成")
            }
            if !actionableLines.isEmpty && actionableLines.count < lines.count / 2 {
                let summary = actionableLines.prefix(50).joined(separator: "\n")
                let omitted = lines.count - actionableLines.count
                return "（已从 \(lines.count) 行输出中提取 \(actionableLines.count) 条关键信息，省略 \(omitted) 行无关输出）\n\n\(summary)"
            }
        }

        let headCount = max(1000, Int(Double(boundedLimit) * 0.6))
        let tailCount = max(500, Int(Double(boundedLimit) * 0.3))
        let omitted = result.output.count - headCount - tailCount
        let head = result.output.prefix(headCount)
        let tail = result.output.suffix(tailCount)
        return """
        \(head)

        ... 中间内容已省略 \(omitted) 字符 ...

        \(tail)
        """
    }

    /// Smart truncation for code: keep imports, class/struct/func signatures, skip function bodies.
    private static func smartTruncateCode(_ content: String, limit: Int) -> String {
        let lines = content.components(separatedBy: "\n")
        guard lines.count > 80 else { return "" }

        var kept: [String] = []
        var keptChars = 0
        let signaturePatterns = [
            "import ", "func ", "class ", "struct ", "enum ", "protocol ",
            "public ", "private ", "internal ", "extension ", "typealias ",
            "var ", "let ", "case ", "// MARK:", "/// ", "def ", "async ",
            "interface ", "export ", "const ", "type ", "from "
        ]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isSignature = signaturePatterns.contains { trimmed.hasPrefix($0) }
            let isShortLine = line.count < 120

            if isSignature || trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("#") {
                kept.append(line)
                keptChars += line.count + 1
            } else if isShortLine && keptChars < limit / 2 {
                kept.append(line)
                keptChars += line.count + 1
            }

            if keptChars >= limit { break }
        }

        guard kept.count >= 10 else { return "" }
        let result = kept.joined(separator: "\n")
        return "\(result)\n\n[结构摘要：保留了 \(kept.count)/\(lines.count) 行签名和关键代码]"
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(max(0, limit - 1))) + "…"
    }

    private static func nonEmptyLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum ToolStepFormatter {
    private typealias CallFormatter = ([String: String]) -> String

    private static let callFormatters: [String: CallFormatter] = [
        "file.read": { "正在读取文件：\($0["path"] ?? "目标文件")" },
        "file.extract": { "正在提取文件文本：\($0["path"] ?? "目标文件")" },
        "document.transform": { documentTransformCallText(arguments: $0) },
        "code.search": { arguments in
            let query = arguments["query"] ?? "相关内容"
            let scope = arguments["scope"] == "content" ? "内容" : "文件"
            return "正在搜索项目\(scope)：\(query)"
        },
        "workspace.index": { _ in "正在建立项目索引" },
        "file.edit": { "正在精准编辑文件：\($0["path"] ?? "目标文件")" },
        "diff.apply": { "正在应用补丁：\($0["path"] ?? "目标文件")" },
        "verify.build": { _ in "正在验证构建/测试" },
        "shell.exec": { "正在执行命令：\($0["command"] ?? "命令")" },
        "web.search": { "正在联网搜索：\($0["query"] ?? "最新信息")" },
        "web.fetch": { "正在读取网页：\($0["url"] ?? "链接")" },
        "wiki.build": { "正在整理 Wiki：\($0["topic"] ?? "主题")" },
        "skill.manage": { skillManageCallText(arguments: $0) },
        "file.write": { "准备写入文件：\($0["path"] ?? "目标文件")" },
        "git": { "正在检查 Git：\($0["subcommand"] ?? "status")" }
    ]

    static func callText(toolName: String, arguments: [String: String]) -> String {
        callFormatters[toolName]?(arguments) ?? "正在执行工具：\(toolName)"
    }

    private static func documentTransformCallText(arguments: [String: String]) -> String {
        let action = arguments["action"] ?? "prepare"
        let path = arguments["sourcePath"] ?? arguments["path"] ?? arguments["outputPath"] ?? "目标文档"
        switch action {
        case "inspect":
            return "正在检查文档：\(path)"
        case "apply":
            return "正在写回文档：\(arguments["outputPath"] ?? path)"
        case "copy":
            return "正在复制文档：\(arguments["outputPath"] ?? path)"
        case "verify":
            return "正在验证文档产物：\(arguments["outputPath"] ?? path)"
        default:
            return "正在准备文档分块：\(path)"
        }
    }

    private static func skillManageCallText(arguments: [String: String]) -> String {
        let action = arguments["action"] ?? "list"
        let name = arguments["name"] ?? "技能"
        switch action {
        case "create": return "正在沉淀技能：\(name)"
        case "update": return "正在更新技能：\(name)"
        case "delete": return "正在删除技能：\(name)"
        default: return "正在查看技能库"
        }
    }
}
