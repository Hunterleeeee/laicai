import Foundation
import LaicaiNativeDomain

// MARK: - Read File Tool

public struct ReadFileTool: LaicaiTool {
    public var name: String { "file.read" }
    public var description: String { "读取工作区中的文件内容" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "path": FunctionProperty(type: "string", description: "文件路径（相对或绝对路径）"),
                    "offset": FunctionProperty(type: "integer", description: "起始行号（可选，从1开始）"),
                    "limit": FunctionProperty(type: "integer", description: "最大读取行数（可选，默认读取全部）")
                ],
                required: ["path"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var path: String
            var offset: Int?
            var limit: Int?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let path = params.path
        let fullPath: String
        if path.hasPrefix("/") {
            fullPath = path
        } else {
            guard !context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ToolResult(output: "请先设置工作区后再读取文件。", success: false, error: "workspace_missing")
            }
            fullPath = (context.workspaceRoot as NSString).appendingPathComponent(path)
        }

        // Security check - verify path is not sensitive
        if let securityError = await SecurityManager.shared.checkRead(path: fullPath) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
            return ToolResult(output: "文件不存在：\(path)", success: false, error: "file_not_found")
        }

        if isDirectory.boolValue {
            do {
                let entries = try FileManager.default.contentsOfDirectory(atPath: fullPath)
                    .filter { !$0.hasPrefix(".") }
                    .sorted()
                    .prefix(max(1, params.limit ?? 200))
                let lines = entries.map { entry -> String in
                    let child = (fullPath as NSString).appendingPathComponent(entry)
                    var childIsDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: child, isDirectory: &childIsDirectory)
                    return childIsDirectory.boolValue ? "\(entry)/" : entry
                }
                let output = lines.isEmpty
                    ? "目录为空：\(path)"
                    : "目录：\(path)\n" + lines.joined(separator: "\n")

                await AuditLog.shared.record(
                    tool: name,
                    input: argumentsJSON,
                    output: "读取目录 \(path)，\(lines.count) 项",
                    success: true
                )

                return ToolResult(output: output, data: ["path": path, "type": "directory", "count": "\(lines.count)"])
            } catch {
                return ToolResult(output: "读取目录失败：\(error.localizedDescription)", success: false, error: "read_error")
            }
        }

        do {
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")

            // Apply offset and limit
            if let offset = params.offset, offset > 0 {
                let startIdx = max(0, offset - 1)
                lines = Array(lines.dropFirst(startIdx))
            }
            if let limit = params.limit, limit > 0 {
                lines = Array(lines.prefix(limit))
            }

            let resultText = lines.joined(separator: "\n")
            let maxChars: Int
            switch context.contextMode {
            case .economy: maxChars = 10_000
            case .balanced: maxChars = 50_000
            case .deep: maxChars = 200_000
            }
            let truncated = resultText.count > maxChars ? String(resultText.prefix(maxChars)) + "\n... (已截断，当前\(context.contextMode.rawValue)模式)" : resultText

            await AuditLog.shared.record(
                tool: name,
                input: argumentsJSON,
                output: "读取 \(path)，\(resultText.count) 字符",
                success: true
            )

            return ToolResult(output: truncated, data: ["path": path, "size": "\(resultText.count)"])
        } catch {
            return ToolResult(output: "读取文件失败：\(error.localizedDescription)", success: false, error: "read_error")
        }
    }
}
// MARK: - File Edit Tool (precise search/replace)

public struct FileEditTool: LaicaiTool {
    public var name: String { "file.edit" }
    public var description: String { "精准编辑文件：查找并替换指定内容片段，支持多处同时替换。优先使用此工具而非 file.write 全量覆盖。" }
    public var requiresReview: Bool { true }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "path": FunctionProperty(type: "string", description: "文件路径（相对或绝对路径）"),
                    "edits": FunctionProperty(type: "string", description: "JSON 数组，每项含 oldText 和 newText。例：[{\"oldText\":\"foo\",\"newText\":\"bar\"}]"),
                    "batchEdits": FunctionProperty(type: "string", description: "可选，批量编辑 JSON 数组，每项含 path 和 edits。例：[{\"path\":\"a.swift\",\"edits\":[{\"oldText\":\"foo\",\"newText\":\"bar\"}]}]"),
                    "createIfMissing": FunctionProperty(type: "boolean", description: "文件不存在时是否用第一条 edit 的 newText 创建（可选，默认 false）")
                ],
                required: []
            )
        )
    }

    private struct EditOp: Codable {
        var oldText: String
        var newText: String
    }

    private struct BatchEdit: Codable {
        var path: String
        var edits: [EditOp]
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var path: String?
            var edits: String?
            var batchEdits: String?
            var createIfMissing: Bool?
        }

        // Models often send edits/batchEdits as native JSON arrays instead of JSON strings.
        // Normalize them to strings before Codable parsing.
        let normalizedJSON: String
        if let data = argumentsJSON.data(using: .utf8),
           var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // If edits is an array, re-encode as JSON string
            if let editsArr = dict["edits"] as? [[String: Any]] {
                if let reEncoded = try? JSONSerialization.data(withJSONObject: editsArr),
                   let str = String(data: reEncoded, encoding: .utf8) {
                    dict["edits"] = str
                }
            }
            // If batchEdits is an array, re-encode as JSON string
            if let batchArr = dict["batchEdits"] as? [[String: Any]] {
                if let reEncoded = try? JSONSerialization.data(withJSONObject: batchArr),
                   let str = String(data: reEncoded, encoding: .utf8) {
                    dict["batchEdits"] = str
                }
            }
            if let normalized = try? JSONSerialization.data(withJSONObject: dict),
               let str = String(data: normalized, encoding: .utf8) {
                normalizedJSON = str
            } else {
                normalizedJSON = argumentsJSON
            }
        } else {
            normalizedJSON = argumentsJSON
        }

        let params: Params
        do {
            let jsonData = normalizedJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        if let batchEdits = params.batchEdits,
           !batchEdits.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await executeBatch(batchEditsJSON: batchEdits, createIfMissing: params.createIfMissing == true, context: context)
        }

        guard let path = params.path, let editsJSON = params.edits else {
            return ToolResult(output: "参数错误：必须提供 path+edits，或提供 batchEdits。", success: false, error: "invalid_params")
        }

        let edits: [EditOp]
        do {
            let editsData = editsJSON.data(using: .utf8) ?? Data()
            edits = try JSONDecoder().decode([EditOp].self, from: editsData)
        } catch {
            return ToolResult(output: "edits 参数格式错误，需要 JSON 数组 [{\"oldText\":\"...\",\"newText\":\"...\"}]", success: false, error: "invalid_edits")
        }

        guard !edits.isEmpty else {
            return ToolResult(output: "edits 数组为空", success: false, error: "empty_edits")
        }

        return try await executeSingle(path: path, edits: edits, createIfMissing: params.createIfMissing == true, context: context)
    }

    private func executeSingle(path: String, edits: [EditOp], createIfMissing: Bool, context: TaskContext) async throws -> ToolResult {
        let fullPath = try resolveWritePath(path: path, context: context)
        if let securityError = await SecurityManager.shared.checkWrite(path: fullPath) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }
        var content: String
        if FileManager.default.fileExists(atPath: fullPath) {
            content = try String(contentsOfFile: fullPath, encoding: .utf8)
        } else if createIfMissing, let first = edits.first {
            content = first.newText
        } else {
            return ToolResult(output: "文件不存在：\(path)。设置 createIfMissing=true 可以创建新文件。", success: false, error: "file_not_found")
        }

        // File change detection: warn if file was modified externally since last read
        let resolvedPath = path.hasPrefix("/") ? path : (context.workspaceRoot as NSString).appendingPathComponent(path)
        var externalChangeWarning: String?
        if let cachedContent = context.memory.fileContentCache[resolvedPath],
           content != cachedContent {
            externalChangeWarning = "⚠️ 文件 \(path) 自上次读取后已被外部修改（磁盘版本与缓存不同）。编辑基于最新磁盘版本。"
            await AuditLog.shared.record(tool: name, input: path, output: externalChangeWarning!, success: true)
        }

        let oldContent = content
        var appliedCount = 0
        var errors: [String] = []
        var appliedEdits: [EditOp] = []

        for (i, edit) in edits.enumerated() {
            if edit.oldText == edit.newText {
                errors.append("第\(i+1)条编辑：oldText 和 newText 相同，跳过")
                continue
            }

            // Empty oldText = append mode: add newText to end of file
            if edit.oldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let separator = content.hasSuffix("\n") ? "" : "\n"
                content += separator + edit.newText
                appliedCount += 1
                appliedEdits.append(edit)
                continue
            }

            // Try exact match first
            if content.contains(edit.oldText) {
                let occurrences = content.components(separatedBy: edit.oldText).count - 1
                if occurrences > 1 {
                    errors.append("第\(i+1)条编辑：oldText 出现 \(occurrences) 次，需提供更多上下文以唯一标识")
                    continue
                }
                content = content.replacingOccurrences(of: edit.oldText, with: edit.newText)
                appliedCount += 1
                appliedEdits.append(edit)
            } else if let fuzzyResult = Self.fuzzyReplace(in: content, oldText: edit.oldText, newText: edit.newText) {
                // Fuzzy match: whitespace-normalized or indent-aware
                content = fuzzyResult.content
                appliedCount += 1
                appliedEdits.append(edit)
                errors.append("第\(i+1)条编辑：模糊匹配成功（\(fuzzyResult.matchType)）")
            } else {
                errors.append("第\(i+1)条编辑：未找到 oldText（前80字符：\(String(edit.oldText.prefix(80)))）")
                continue
            }
        }

        // Post-edit format hook: normalize trailing newline
        if appliedCount > 0 && !content.hasSuffix("\n") && oldContent.hasSuffix("\n") {
            content += "\n"
        }

        if appliedCount == 0 {
            let hint = oldContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\n💡 该文件为空，无法查找替换。请改用 file.write 的 content 参数直接写入完整内容。"
                : ""
            return ToolResult(
                output: "所有编辑均失败：\n" + errors.joined(separator: "\n") + hint,
                success: false,
                error: "all_edits_failed"
            )
        }

        if let warning = externalChangeWarning {
            errors.insert(warning, at: 0)
        }
        return makeEditResult(path: path, fullPath: fullPath, oldContent: oldContent, newContent: content, appliedEdits: appliedEdits, appliedCount: appliedCount, totalCount: edits.count, errors: errors)
    }

    private func executeBatch(batchEditsJSON: String, createIfMissing: Bool, context: TaskContext) async throws -> ToolResult {
        let batch: [BatchEdit]
        do {
            let data = batchEditsJSON.data(using: .utf8) ?? Data()
            batch = try JSONDecoder().decode([BatchEdit].self, from: data)
        } catch {
            return ToolResult(output: "batchEdits 参数格式错误：\(error.localizedDescription)\n需要 JSON 数组格式：[{\"path\":\"file.py\",\"edits\":[{\"oldText\":\"旧内容\",\"newText\":\"新内容\"}]}]", success: false, error: "invalid_batch_edits")
        }
        guard !batch.isEmpty else {
            return ToolResult(output: "batchEdits 数组为空", success: false, error: "empty_batch_edits")
        }

        var data: [String: String] = ["batchCount": "\(batch.count)"]
        var summaries: [String] = []
        var failures: [String] = []
        for (index, item) in batch.enumerated() {
            let result = try await executeSingle(path: item.path, edits: item.edits, createIfMissing: createIfMissing, context: context)
            if result.success, let itemData = result.data {
                let prefix = "batch\(index)"
                data["\(prefix).path"] = itemData["path"]
                data["\(prefix).fullPath"] = itemData["fullPath"]
                data["\(prefix).diffOld"] = itemData["diffOld"]
                data["\(prefix).diffNew"] = itemData["diffNew"]
                data["\(prefix).addedLines"] = itemData["addedLines"]
                data["\(prefix).removedLines"] = itemData["removedLines"]
                data["\(prefix).appliedEdits"] = itemData["appliedEdits"]
                data["\(prefix).totalEdits"] = itemData["totalEdits"]
                data["\(prefix).createDirectories"] = itemData["createDirectories"]
                data["\(prefix).hunkCount"] = itemData["hunkCount"]
                for hunkIndex in 0..<(Int(itemData["hunkCount"] ?? "0") ?? 0) {
                    data["\(prefix).hunk\(hunkIndex).oldText"] = itemData["hunk\(hunkIndex).oldText"]
                    data["\(prefix).hunk\(hunkIndex).newText"] = itemData["hunk\(hunkIndex).newText"]
                    data["\(prefix).hunk\(hunkIndex).summary"] = itemData["hunk\(hunkIndex).summary"]
                }
                summaries.append(result.output)
            } else {
                failures.append("\(item.path): \(result.error ?? result.output)")
            }
        }
        guard failures.isEmpty else {
            return ToolResult(output: "批量编辑失败，未生成审查：\n" + failures.joined(separator: "\n"), success: false, error: "batch_failed")
        }
        await AuditLog.shared.record(tool: name, input: "batch \(batch.count) files", output: "prepared batch review", success: true)
        return ToolResult(output: "批量编辑已准备，等待审查：\n" + summaries.joined(separator: "\n"), data: data, success: true)
    }

    private struct FuzzyReplaceResult {
        let content: String
        let matchType: String
    }

    private static func fuzzyReplace(in content: String, oldText: String, newText: String) -> FuzzyReplaceResult? {
        let contentLines = content.components(separatedBy: "\n")
        let oldLines = oldText.components(separatedBy: "\n")
        guard !oldLines.isEmpty else { return nil }

        // Strategy 1: Whitespace-trimmed line matching
        let trimmedOld = oldLines.map { $0.trimmingCharacters(in: .whitespaces) }
        for startIdx in 0...(max(0, contentLines.count - oldLines.count)) {
            let slice = contentLines[startIdx..<min(startIdx + oldLines.count, contentLines.count)]
            let trimmedSlice = slice.map { $0.trimmingCharacters(in: .whitespaces) }
            if trimmedSlice == trimmedOld {
                // Found! Detect indent of matched region and apply to newText
                let matchedIndent = detectIndent(Array(slice))
                let oldIndent = detectIndent(oldLines)
                let adjustedNew = reindent(newText, from: oldIndent, to: matchedIndent)
                var result = contentLines
                result.replaceSubrange(startIdx..<(startIdx + oldLines.count), with: adjustedNew.components(separatedBy: "\n"))
                return FuzzyReplaceResult(content: result.joined(separator: "\n"), matchType: "空白标准化")
            }
        }

        // Strategy 2: Indent-stripped matching (ignore all leading whitespace)
        let strippedOld = oldLines.map { $0.trimmingCharacters(in: .init(charactersIn: " \t")) }
        for startIdx in 0...(max(0, contentLines.count - oldLines.count)) {
            let slice = contentLines[startIdx..<min(startIdx + oldLines.count, contentLines.count)]
            let strippedSlice = slice.map { $0.trimmingCharacters(in: .init(charactersIn: " \t")) }
            if strippedSlice == strippedOld {
                let matchedIndent = detectIndent(Array(slice))
                let adjustedNew = reindent(newText, from: 0, to: matchedIndent)
                var result = contentLines
                result.replaceSubrange(startIdx..<(startIdx + oldLines.count), with: adjustedNew.components(separatedBy: "\n"))
                return FuzzyReplaceResult(content: result.joined(separator: "\n"), matchType: "缩进感知")
            }
        }

        return nil
    }

    private static func detectIndent(_ lines: [String]) -> Int {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return 0 }
        return nonEmpty.map { line -> Int in
            var count = 0
            for ch in line {
                if ch == " " { count += 1 }
                else if ch == "\t" { count += 4 }
                else { break }
            }
            return count
        }.min() ?? 0
    }

    private static func reindent(_ text: String, from oldIndent: Int, to newIndent: Int) -> String {
        guard oldIndent != newIndent else { return text }
        let delta = newIndent - oldIndent
        return text.components(separatedBy: "\n").map { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if delta > 0 {
                return String(repeating: " ", count: delta) + line
            } else {
                let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
                let currentIndent = line.count - stripped.count
                let newLineIndent = max(0, currentIndent + delta)
                return String(repeating: " ", count: newLineIndent) + stripped
            }
        }.joined(separator: "\n")
    }

    private func resolveWritePath(path: String, context: TaskContext) throws -> String {
        if path.hasPrefix("/") {
            return path
        }
        guard !context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "FileEditTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先设置工作区。"])
        }
        return (context.workspaceRoot as NSString).appendingPathComponent(path)
    }

    private func makeEditResult(path: String, fullPath: String, oldContent: String, newContent: String, appliedEdits: [EditOp], appliedCount: Int, totalCount: Int, errors: [String]) -> ToolResult {
        let oldLines = oldContent.components(separatedBy: "\n").count
        let newLines = newContent.components(separatedBy: "\n").count

        var summary = "已准备 \(appliedCount)/\(totalCount) 条编辑到 \(path)（\(oldLines)→\(newLines) 行）"
        if !errors.isEmpty {
            summary += "\n部分失败：\n" + errors.joined(separator: "\n")
        }

        var data = [
            "path": path,
            "fullPath": fullPath,
            "diffOld": oldContent,
            "diffNew": newContent,
            "addedLines": "\(max(newLines - oldLines, 0))",
            "removedLines": "\(max(oldLines - newLines, 0))",
            "appliedEdits": "\(appliedCount)",
            "totalEdits": "\(totalCount)",
            "createDirectories": "true",
            "hunkCount": "\(appliedEdits.count)"
        ]
        for (index, edit) in appliedEdits.enumerated() {
            data["hunk\(index).oldText"] = edit.oldText
            data["hunk\(index).newText"] = edit.newText
            data["hunk\(index).summary"] = "Hunk \(index + 1): \(edit.oldText.components(separatedBy: "\n").count)→\(edit.newText.components(separatedBy: "\n").count) 行"
        }

        return ToolResult(
            output: summary,
            data: data,
            success: true
        )
    }
}
