import Foundation
import LaicaiNativeDomain

// MARK: - G3: LSP Tool (sourcekit-lsp go-to-definition / find-references)

public struct LSPTool: LaicaiTool {
    public var name: String { "lsp.query" }
    public var description: String { "语义级代码查询：跳转到定义、查找引用、符号搜索。依赖 sourcekit-lsp（Swift）或其他 LSP 服务。" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "action": FunctionProperty(type: "string", description: "操作：definition（跳转到定义）、references（查找引用）、symbols（符号搜索）"),
                    "file": FunctionProperty(type: "string", description: "文件路径"),
                    "line": FunctionProperty(type: "integer", description: "行号（1-based）"),
                    "column": FunctionProperty(type: "integer", description: "列号（1-based）"),
                    "symbol": FunctionProperty(type: "string", description: "符号名称（symbols 模式用）")
                ],
                required: ["action"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var action: String
            var file: String?
            var line: Int?
            var column: Int?
            var symbol: String?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败", success: false, error: "invalid_params")
        }

        let root = context.workspaceRoot

        switch params.action {
        case "definition":
            guard let file = params.file, let line = params.line, let col = params.column else {
                return ToolResult(output: "definition 需要 file, line, column 参数", success: false, error: "missing_params")
            }
            let fullPath = file.hasPrefix("/") ? file : (root as NSString).appendingPathComponent(file)
            return await gotoDefinition(file: fullPath, line: line, column: col, root: root)

        case "references":
            guard let file = params.file, let line = params.line, let col = params.column else {
                return ToolResult(output: "references 需要 file, line, column 参数", success: false, error: "missing_params")
            }
            let fullPath = file.hasPrefix("/") ? file : (root as NSString).appendingPathComponent(file)
            return await findReferences(file: fullPath, line: line, column: col, root: root)

        case "symbols":
            let query = params.symbol ?? ""
            return await symbolSearch(query: query, root: root)

        default:
            return ToolResult(output: "未知 action：\(params.action)。支持：definition, references, symbols", success: false, error: "unknown_action")
        }
    }

    private func gotoDefinition(file: String, line: Int, column: Int, root: String) async -> ToolResult {
        // Use sourcekit-lsp via its LSP protocol over a simple shell invocation
        // Fall back to grep-based heuristic if sourcekit-lsp is not available
        let ext = (file as NSString).pathExtension.lowercased()

        if ["swift"].contains(ext) {
            // Try sourcekit-lsp cursor-info
            let cmd = "xcrun sourcekit-lsp 2>/dev/null && echo 'available' || echo 'unavailable'"
            let available = Self.runShell(cmd, cwd: root)
            if available.contains("available") {
                // Use swift-ide-test as a simpler alternative for definition lookup
                let symbolResult = Self.extractSymbolAtLocation(file: file, line: line, column: column)
                if !symbolResult.isEmpty {
                    let grepResult = Self.runShell("cd \(Self.shellEscape(root)) && rg -n 'func \\b\(symbolResult)\\b|class \\b\(symbolResult)\\b|struct \\b\(symbolResult)\\b|protocol \\b\(symbolResult)\\b|enum \\b\(symbolResult)\\b' --max-count 5 --glob '*.swift' 2>/dev/null", cwd: root)
                    if !grepResult.isEmpty {
                        return ToolResult(output: "符号 '\(symbolResult)' 的定义位置：\n\(grepResult)", data: ["symbol": symbolResult])
                    }
                }
            }
        }

        // Generic fallback: extract symbol at position and grep
        let symbolAtPos = Self.extractSymbolAtLocation(file: file, line: line, column: column)
        if symbolAtPos.isEmpty {
            return ToolResult(output: "无法识别位置 \(file):\(line):\(column) 的符号", success: false, error: "no_symbol")
        }

        let defPatterns = "func \\b\(symbolAtPos)\\b|class \\b\(symbolAtPos)\\b|struct \\b\(symbolAtPos)\\b|def \\b\(symbolAtPos)\\b|interface \\b\(symbolAtPos)\\b|type \\b\(symbolAtPos)\\b"
        let result = Self.runShell("cd \(Self.shellEscape(root)) && rg -n '\(defPatterns)' --max-count 10 --max-filesize 1M --glob '!**/.git/**' --glob '!**/node_modules/**' 2>/dev/null", cwd: root)

        return result.isEmpty
            ? ToolResult(output: "未找到 '\(symbolAtPos)' 的定义", data: ["symbol": symbolAtPos])
            : ToolResult(output: "符号 '\(symbolAtPos)' 的定义位置：\n\(String(result.prefix(5000)))", data: ["symbol": symbolAtPos])
    }

    private func findReferences(file: String, line: Int, column: Int, root: String) async -> ToolResult {
        let symbol = Self.extractSymbolAtLocation(file: file, line: line, column: column)
        if symbol.isEmpty {
            return ToolResult(output: "无法识别位置 \(file):\(line):\(column) 的符号", success: false, error: "no_symbol")
        }

        let result = Self.runShell("cd \(Self.shellEscape(root)) && rg -n '\\b\(symbol)\\b' --max-count 30 --max-filesize 1M --glob '!**/.git/**' --glob '!**/node_modules/**' --glob '!**/.build/**' 2>/dev/null", cwd: root)

        return result.isEmpty
            ? ToolResult(output: "未找到 '\(symbol)' 的引用", data: ["symbol": symbol])
            : ToolResult(output: "符号 '\(symbol)' 的引用（\(result.components(separatedBy: "\n").filter { !$0.isEmpty }.count) 处）：\n\(String(result.prefix(8000)))", data: ["symbol": symbol])
    }

    private func symbolSearch(query: String, root: String) async -> ToolResult {
        guard !query.isEmpty else {
            return ToolResult(output: "请提供 symbol 参数", success: false, error: "missing_symbol")
        }

        let patterns = "func \\b\(query)|class \\b\(query)|struct \\b\(query)|protocol \\b\(query)|enum \\b\(query)|def \\b\(query)|interface \\b\(query)|type \\b\(query)|export.*\\b\(query)"
        let result = Self.runShell("cd \(Self.shellEscape(root)) && rg -n '\(patterns)' --max-count 30 --max-filesize 1M --glob '!**/.git/**' --glob '!**/node_modules/**' --glob '!**/.build/**' 2>/dev/null", cwd: root)

        return result.isEmpty
            ? ToolResult(output: "未找到符号 '\(query)'", data: ["query": query])
            : ToolResult(output: "符号搜索 '\(query)' 结果：\n\(String(result.prefix(8000)))", data: ["query": query])
    }

    static func extractSymbolAtLocation(file: String, line: Int, column: Int) -> String {
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { return "" }
        let lines = content.components(separatedBy: "\n")
        guard line > 0 && line <= lines.count else { return "" }
        let lineStr = lines[line - 1]
        let col = max(0, min(column - 1, lineStr.count - 1))
        let chars = Array(lineStr)
        guard col < chars.count else { return "" }

        var start = col
        while start > 0 && (chars[start - 1].isLetter || chars[start - 1].isNumber || chars[start - 1] == "_") { start -= 1 }
        var end = col
        while end < chars.count - 1 && (chars[end + 1].isLetter || chars[end + 1].isNumber || chars[end + 1] == "_") { end += 1 }

        let symbol = String(chars[start...end])
        return symbol.count >= 2 ? symbol : ""
    }

    static func runShell(_ command: String, cwd: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        if !cwd.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - G11: Unified Diff Apply Tool

public struct DiffApplyTool: LaicaiTool {
    public var name: String { "diff.apply" }
    public var description: String { "应用 unified diff 格式的补丁到文件。比 file.edit 更适合多处修改。" }
    public var requiresReview: Bool { true }
    public var executionPolicy: ToolExecutionPolicy { .fileChangeReview }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "path": FunctionProperty(type: "string", description: "文件路径"),
                    "diff": FunctionProperty(type: "string", description: "unified diff 格式的补丁内容（以 --- 和 +++ 开头）")
                ],
                required: ["path", "diff"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var path: String
            var diff: String
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败", success: false, error: "invalid_params")
        }

        let fullPath = params.path.hasPrefix("/") ? params.path : (context.workspaceRoot as NSString).appendingPathComponent(params.path)

        // Security check
        if let securityError = await SecurityManager.shared.checkWrite(path: fullPath) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }

        guard FileManager.default.fileExists(atPath: fullPath) else {
            return ToolResult(output: "文件不存在：\(params.path)", success: false, error: "file_not_found")
        }

        let oldContent: String
        do {
            oldContent = try String(contentsOfFile: fullPath, encoding: .utf8)
        } catch {
            return ToolResult(output: "读取文件失败：\(error.localizedDescription)", success: false, error: "read_error")
        }
        if let dangerousError = DangerousOperationGuard.writeViolation(path: fullPath, oldContent: oldContent, context: context) {
            return ToolResult(output: dangerousError, success: false, error: "dangerous_operation")
        }

        // Apply unified diff
        let result = applyUnifiedDiff(original: oldContent, diff: params.diff)
        guard let newContent = result.content else {
            return ToolResult(output: "Diff 应用失败：\(result.error ?? "格式错误")", success: false, error: "diff_failed")
        }

        let addedLines = newContent.components(separatedBy: "\n").count - oldContent.components(separatedBy: "\n").count
        let summary = addedLines >= 0 ? "+\(addedLines) 行" : "\(addedLines) 行"

        return ToolResult(
            output: "Diff 已准备，等待审查：\(params.path)（\(summary)）",
            data: [
                "path": params.path,
                "fullPath": fullPath,
                "diffOld": oldContent,
                "diffNew": newContent,
                "addedLines": "\(max(0, addedLines))",
                "removedLines": "\(max(0, -addedLines))",
                "createDirectories": "false"
            ],
            success: true
        )
    }

    private struct DiffResult {
        var content: String?
        var error: String?
    }

    private func applyUnifiedDiff(original: String, diff: String) -> DiffResult {
        var lines = original.components(separatedBy: "\n")
        let diffLines = diff.components(separatedBy: "\n")
        var offset = 0

        // Parse hunks: @@ -start,count +start,count @@
        let hunkPattern = #"^@@\s+-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s+@@"#
        guard let hunkRegex = try? NSRegularExpression(pattern: hunkPattern) else {
            return DiffResult(error: "正则编译失败")
        }

        var i = 0
        while i < diffLines.count {
            let line = diffLines[i]
            let ns = line as NSString
            if let match = hunkRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let startLine = Int(ns.substring(with: match.range(at: 1))) ?? 1
                var lineIndex = startLine - 1 + offset
                i += 1

                while i < diffLines.count {
                    let dl = diffLines[i]
                    if dl.hasPrefix("@@") || dl.hasPrefix("diff ") || dl.hasPrefix("---") || dl.hasPrefix("+++") { break }
                    if dl.hasPrefix("-") {
                        // Remove line
                        if lineIndex >= 0 && lineIndex < lines.count {
                            lines.remove(at: lineIndex)
                            offset -= 1
                        }
                    } else if dl.hasPrefix("+") {
                        // Add line
                        let newLine = String(dl.dropFirst())
                        if lineIndex >= lines.count {
                            lines.append(newLine)
                        } else {
                            lines.insert(newLine, at: lineIndex)
                        }
                        lineIndex += 1
                        offset += 1
                    } else {
                        // Context line — advance
                        lineIndex += 1
                    }
                    i += 1
                }
            } else {
                i += 1
            }
        }

        return DiffResult(content: lines.joined(separator: "\n"))
    }
}

// MARK: - Skill Manage Tool (Agent self-creates skills)

public struct SkillManageTool: LaicaiTool {
    public var name: String { "skill.manage" }
    public var description: String { "管理技能：创建、更新、删除、列出可复用的技能。当你发现一个非平凡的工作流程值得复用时，用这个工具保存为技能。" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "action": FunctionProperty(type: "string", description: "操作类型：create / update / delete / list", enumValues: ["create", "update", "delete", "list"]),
                    "name": FunctionProperty(type: "string", description: "技能名称（create/update/delete 必填）"),
                    "description": FunctionProperty(type: "string", description: "技能描述（create/update 时使用）"),
                    "tools": FunctionProperty(type: "string", description: "逗号分隔的工具列表，如 file.read,code.search,file.write"),
                    "instructions": FunctionProperty(type: "string", description: "详细的执行步骤说明（SKILL.md 内容）"),
                    "trigger": FunctionProperty(type: "string", description: "自动触发的关键词模式（可选）"),
                    "category": FunctionProperty(type: "string", description: "技能分类，可用中文或英文：通用/general、知识/knowledge、营销/marketing、产品/product、内容/content、设计/design、数据/data、商业/business、分析/analysis、编辑/editing、执行/execution、研究/research、流程/workflow、元技能/meta")
                ],
                required: ["action"]
            )
        )
    }

    private struct SkillParams: Codable {
        var action: String
        var name: String?
        var description: String?
        var tools: String?
        var instructions: String?
        var trigger: String?
        var category: String?
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        let params: SkillParams
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(SkillParams.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let root = context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let skillDir = root.isEmpty
            ? ((FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()) as NSString).appendingPathComponent("Laicai/skills")
            : (root as NSString).appendingPathComponent(".laicai/skills")
        try? FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)

        switch params.action {
        case "create":
            return try await createSkill(params: params, skillDir: skillDir)
        case "update":
            return try updateSkill(params: params, skillDir: skillDir)
        case "delete":
            return try deleteSkill(params: params, skillDir: skillDir)
        case "list":
            return listSkills(skillDir: skillDir)
        default:
            return ToolResult(output: "未知操作：\(params.action)。支持 create/update/delete/list。", success: false, error: "invalid_params")
        }
    }

    private func createSkill(params: SkillParams, skillDir: String) async throws -> ToolResult {
        guard let name = params.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return ToolResult(output: "创建技能需要 name 参数", success: false, error: "invalid_params")
        }
        let slug = name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\u{4e00}-\u{9fa5}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let filename = slug.isEmpty ? UUID().uuidString : slug
        let mdPath = (skillDir as NSString).appendingPathComponent("\(filename).md")

        guard !FileManager.default.fileExists(atPath: mdPath) else {
            return ToolResult(output: "技能已存在：\(name)。使用 update 操作更新。", success: false, error: "already_exists")
        }

        let tools = params.tools?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        let desc = params.description ?? name
        let instructions = params.instructions ?? "（待补充执行步骤）"
        let trigger = params.trigger ?? ""
        let category = SkillRegistry.normalizeSkillCategory(params.category) ?? "general"

        var md = "---\nname: \(name)\ndescription: \(desc)\ncategory: \(category)\ntools: [\(tools.joined(separator: ", "))]"
        if !trigger.isEmpty {
            md += "\ntrigger: \(trigger)"
        }
        md += "\n---\n\n# \(name)\n\n\(desc)\n\n## 执行步骤\n\n\(instructions)\n"

        try md.write(toFile: mdPath, atomically: true, encoding: .utf8)

        let skill = SkillDefinition(name: name, description: desc, tools: tools, isBuiltin: false, isPublished: true, category: category)
        await SkillRegistry.shared.register(skill)

        return ToolResult(
            output: "技能已创建：\(name)\n分类：\(categoryDisplayName(category))\n路径：\(mdPath)\n工具：\(tools.joined(separator: ", "))\n已写入结构化分类，Skill Hub 刷新后会显示在对应分类。",
            data: ["action": "create", "path": mdPath, "name": name, "category": category]
        )
    }

    private func updateSkill(params: SkillParams, skillDir: String) throws -> ToolResult {
        guard let name = params.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return ToolResult(output: "更新技能需要 name 参数", success: false, error: "invalid_params")
        }

        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: skillDir)) ?? []
        guard let existing = files.first(where: { file in
            guard file.hasSuffix(".md") else { return false }
            let content = (try? String(contentsOfFile: (skillDir as NSString).appendingPathComponent(file), encoding: .utf8)) ?? ""
            return content.contains("name: \(name)")
        }) else {
            return ToolResult(output: "未找到技能：\(name)", success: false, error: "not_found")
        }

        let path = (skillDir as NSString).appendingPathComponent(existing)
        var content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        if let desc = params.description {
            content = content.replacingOccurrences(of: #"description: .*"#, with: "description: \(desc)", options: .regularExpression)
        }
        if let tools = params.tools {
            content = content.replacingOccurrences(of: #"tools: \[.*\]"#, with: "tools: [\(tools)]", options: .regularExpression)
        }
        if let category = SkillRegistry.normalizeSkillCategory(params.category) {
            if content.range(of: #"(?m)^category:\s*.*$"#, options: .regularExpression) != nil {
                content = content.replacingOccurrences(of: #"(?m)^category:\s*.*$"#, with: "category: \(category)", options: .regularExpression)
            } else if let range = content.range(of: "---\n", options: [], range: content.index(after: content.startIndex)..<content.endIndex) {
                content.insert(contentsOf: "category: \(category)\n", at: range.lowerBound)
            }
        }
        if let instructions = params.instructions {
            if let range = content.range(of: "## 执行步骤") {
                content = String(content[content.startIndex..<range.lowerBound]) + "## 执行步骤\n\n\(instructions)\n"
            }
        }

        try content.write(toFile: path, atomically: true, encoding: .utf8)
        var data = ["action": "update", "path": path, "name": name]
        if let category = SkillRegistry.normalizeSkillCategory(params.category) {
            data["category"] = category
        }
        return ToolResult(output: "技能已更新：\(name)", data: data)
    }

    private func deleteSkill(params: SkillParams, skillDir: String) throws -> ToolResult {
        guard let name = params.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return ToolResult(output: "删除技能需要 name 参数", success: false, error: "invalid_params")
        }

        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: skillDir)) ?? []
        guard let existing = files.first(where: { file in
            let content = (try? String(contentsOfFile: (skillDir as NSString).appendingPathComponent(file), encoding: .utf8)) ?? ""
            return content.contains("name: \(name)") || file.contains(name.lowercased())
        }) else {
            return ToolResult(output: "未找到技能：\(name)", success: false, error: "not_found")
        }

        try fm.removeItem(atPath: (skillDir as NSString).appendingPathComponent(existing))
        return ToolResult(output: "技能已删除：\(name)", data: ["action": "delete", "name": name])
    }

    private func listSkills(skillDir: String) -> ToolResult {
        // 1. Builtin + custom skills (avoid MainActor-isolated SkillRegistry.shared.skills)
        var allSkills = SkillRegistry.loadBuiltinSkills()
        let workspaceRoot = Self.workspaceRoot(fromSkillDir: skillDir)
        let localSkills = SkillRegistry.loadLocalSkills(workspaceRoot: workspaceRoot)
        for s in localSkills where !allSkills.contains(where: { $0.name == s.name }) {
            allSkills.append(s)
        }
        let builtinCount = allSkills.filter { $0.isBuiltin }.count
        let customSkills = allSkills.filter { !$0.isBuiltin }

        // Group all skills by category, including local markdown/json skills.
        var categoryGroups: [String: [String]] = [:]
        for skill in allSkills {
            let cat = SkillRegistry.normalizeSkillCategory(skill.category) ?? "general"
            categoryGroups[cat, default: []].append(skill.name)
        }

        var lines: [String] = ["共 \(allSkills.count) 个技能（\(builtinCount) 内置 + \(customSkills.count) 自定义）："]

        let categoryOrder = ["general", "marketing", "product", "content", "design", "data", "business", "knowledge", "meta"]
        let categoryNames: [String: String] = [
            "general": "通用/开发", "marketing": "营销", "product": "产品",
            "content": "内容", "design": "设计", "data": "数据",
            "business": "商业", "knowledge": "知识", "meta": "元技能"
        ]
        for cat in categoryOrder {
            guard let names = categoryGroups[cat], !names.isEmpty else { continue }
            lines.append("\n【\(categoryNames[cat] ?? cat)】\(names.joined(separator: "、"))")
        }
        // Any remaining categories
        for (cat, names) in categoryGroups where !categoryOrder.contains(cat) {
            lines.append("\n【\(cat)】\(names.joined(separator: "、"))")
        }

        if !customSkills.isEmpty {
            lines.append("\n【自定义技能】")
            for skill in customSkills {
                lines.append("- \(skill.name)：\(skill.description)")
            }
        }

        let learned = SkillEvolutionEngine.shared.allSkills(limit: 5)
        if !learned.isEmpty {
            lines.append("\n已学习技能（Q值排序，前5）：")
            for s in learned {
                lines.append("- \(s.name) (Q=\(String(format: "%.2f", s.qValue)), 用\(s.usageCount)次, 成功率\(String(format: "%.0f%%", s.successRate * 100)))")
            }
        }

        return ToolResult(output: lines.joined(separator: "\n"), data: ["count": "\(allSkills.count)"])
    }

    private func categoryDisplayName(_ category: String) -> String {
        [
            "general": "通用",
            "knowledge": "知识",
            "marketing": "营销",
            "product": "产品",
            "content": "内容",
            "design": "设计",
            "data": "数据",
            "business": "商业",
            "analysis": "分析",
            "editing": "编辑",
            "execution": "执行",
            "research": "研究",
            "workflow": "流程",
            "meta": "元技能"
        ][category] ?? category
    }

    private static func workspaceRoot(fromSkillDir skillDir: String) -> String {
        let ns = skillDir as NSString
        if ns.lastPathComponent == "skills" {
            let parent = ns.deletingLastPathComponent as NSString
            if parent.lastPathComponent == ".laicai" {
                return parent.deletingLastPathComponent
            }
        }
        return ns.deletingLastPathComponent
    }
}
