import Foundation
import LaicaiNativeDomain

enum ToolResultFormatter {
    static func displayText(toolName: String, arguments: [String: String], result: ToolResult) -> String {
        guard result.success else {
            return compact("失败：\(result.error ?? result.output)", limit: 360)
        }

        switch toolName {
        case "file.read":
            let path = result.data?["path"] ?? arguments["path"] ?? "文件"
            let size = result.data?["size"].flatMap(Int.init) ?? result.output.count
            let lines = result.output.components(separatedBy: .newlines).count
            let suffix = result.output.contains("已截断") ? "，内容已截断" : ""
            return "已读取 \(path) · \(lines) 行 · \(size) 字符\(suffix)"

        case "file.extract":
            let path = result.data?["path"] ?? arguments["path"] ?? "文件"
            let size = result.data?["size"].flatMap(Int.init) ?? result.output.count
            let lines = result.output.components(separatedBy: .newlines).count
            return "已提取 \(path) · \(lines) 行 · \(size) 字符"

        case "code.search":
            let query = result.data?["query"] ?? arguments["query"] ?? ""
            let count = result.data?["count"].flatMap(Int.init) ?? nonEmptyLines(result.output).count
            if count == 0 || result.output.hasPrefix("未找到") {
                return query.isEmpty ? "未找到匹配结果" : "未找到匹配结果：\(query)"
            }
            let sample = nonEmptyLines(result.output).prefix(3).joined(separator: "，")
            return sample.isEmpty ? "找到 \(count) 个匹配结果" : "找到 \(count) 个匹配结果：\(sample)"

        case "workspace.index":
            let fileCount = result.data?["fileCount"] ?? "0"
            let directoryCount = result.data?["directoryCount"] ?? "0"
            return "已建立项目索引 · \(fileCount) 个文件 · \(directoryCount) 个目录"

        case "file.edit":
            let path = result.data?["path"] ?? arguments["path"] ?? "文件"
            let applied = result.data?["appliedEdits"] ?? "0"
            let total = result.data?["totalEdits"] ?? applied
            return "已准备精准编辑 · \(path) · \(applied)/\(total) 条变更"

        case "file.write":
            let path = result.data?["path"] ?? arguments["path"] ?? "文件"
            return "已准备文件写入 · \(path)"

        case "verify.build":
            let command = result.data?["command"] ?? arguments["command"] ?? "自动检测"
            let exitCode = result.data?["exitCode"] ?? "0"
            return "验证完成 · 退出码 \(exitCode) · \(command)"

        case "web.search":
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

        case "web.fetch":
            let title = result.data?["title"] ?? "网页"
            let size = result.data?["size"] ?? "\(result.output.count)"
            return "已读取网页：\(title) · \(size) 字符"

        case "wiki.build":
            let topic = result.data?["topic"] ?? arguments["topic"] ?? "主题"
            let path = result.data?["path"] ?? "02 Atomic"
            let count = result.data?["sourceCount"] ?? "0"
            let saved = result.data?["saved"] == "true"
            return saved
                ? "已保存 Wiki：\(topic) → \(path) · \(count) 条来源"
                : "已生成 Wiki 预览：\(topic) → \(path) · \(count) 条来源"

        case "shell.exec":
            let exitCode = result.data?["exitCode"] ?? "0"
            let firstLine = nonEmptyLines(result.output).first ?? "命令已完成"
            return "命令完成 · 退出码 \(exitCode) · \(compact(firstLine, limit: 180))"

        case "git":
            if result.data?["repository"] == "false" {
                return compact(result.output, limit: 220)
            }
            let firstLine = nonEmptyLines(result.output).first ?? "Git 操作已完成"
            return compact(firstLine, limit: 220)

        default:
            return compact(result.output, limit: 360)
        }
    }

    static func modelContent(toolName: String, result: ToolResult, limit: Int) -> String {
        if !result.success {
            var errorContent = compact("Error: \(result.error ?? result.output)", limit: max(500, limit))
            if toolName == "code.search" {
                errorContent += "\n\n提示：本地搜索未找到结果。如果这是一个外部工具、库或概念，请调用 web_search 联网搜索了解它是什么。"
            } else if toolName == "file.read", result.error == "unsupported_binary_file" {
                errorContent += "\n\n提示：这是表格/文档类文件。请立即改用 file_extract 提取文本，不要把这个失败当作任务完成。"
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

        if toolName == "file.read" || toolName == "file.extract" {
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

        ... 省略 \(omitted) 字符 ...

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
    static func callText(toolName: String, arguments: [String: String]) -> String {
        switch toolName {
        case "file.read":
            return "正在读取文件：\(arguments["path"] ?? "目标文件")"
        case "file.extract":
            return "正在提取文件文本：\(arguments["path"] ?? "目标文件")"
        case "code.search":
            let query = arguments["query"] ?? "相关内容"
            let scope = arguments["scope"] == "content" ? "内容" : "文件"
            return "正在搜索项目\(scope)：\(query)"
        case "workspace.index":
            return "正在建立项目索引"
        case "file.edit":
            return "正在精准编辑文件：\(arguments["path"] ?? "目标文件")"
        case "verify.build":
            return "正在验证构建/测试"
        case "shell.exec":
            return "正在执行命令：\(arguments["command"] ?? "命令")"
        case "web.search":
            return "正在联网搜索：\(arguments["query"] ?? "最新信息")"
        case "web.fetch":
            return "正在读取网页：\(arguments["url"] ?? "链接")"
        case "wiki.build":
            return "正在整理 Wiki：\(arguments["topic"] ?? "主题")"
        case "file.write":
            return "准备写入文件：\(arguments["path"] ?? "目标文件")"
        case "git":
            return "正在检查 Git：\(arguments["subcommand"] ?? "status")"
        default:
            return "正在执行工具：\(toolName)"
        }
    }
}
