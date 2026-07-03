import Darwin
import Foundation
import LaicaiNativeDomain

// MARK: - Read File Tool

public struct ReadFileTool: LaicaiTool {
    public var name: String { "file.read" }
    public var description: String { "读取工作区中的文本文件或目录清单。xlsx/docx/pdf 等文档请改用 file_extract。" }

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
        let workspaceRoot = context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceRoot.isEmpty else {
            return ToolResult(output: "请先设置工作区后再读取文件。", success: false, error: "workspace_missing")
        }
        let fullPath = Self.fullPath(for: path, workspaceRoot: workspaceRoot)

        // Security check - verify path is not sensitive
        if let securityError = await SecurityManager.shared.checkRead(path: fullPath, workspaceRoot: workspaceRoot) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
            return ToolResult(output: "文件不存在：\(path)", success: false, error: "file_not_found")
        }

        if isDirectory.boolValue {
            return await Self.readDirectory(path: path, fullPath: fullPath, limit: params.limit, argumentsJSON: argumentsJSON, toolName: name)
        }

        let ext = (fullPath as NSString).pathExtension.lowercased()
        if Self.extractOnlyExtensions.contains(ext) {
            return ToolResult(
                output: "这是 \(ext.uppercased()) 文档/表格，不适合用 file.read 按文本读取。请改用 file_extract 提取文本后再整理；如果目标是整理到 Wiki，提取后继续调用 wiki_build(save=true)。",
                data: ["path": path, "extension": ext, "recommendedTool": "file.extract"],
                success: false,
                error: "unsupported_binary_file"
            )
        }

        return await Self.readTextFile(
            ReadTextFileRequest(
                path: path,
                fullPath: fullPath,
                offset: params.offset,
                limit: params.limit,
                argumentsJSON: argumentsJSON,
                contextMode: context.contextMode,
                toolName: name
            ))
    }

    private static let extractOnlyExtensions: Set<String> = [
        "xlsx", "xlsm", "xls", "csv", "tsv", "docx", "doc", "pptx", "ppt", "pdf", "numbers", "pages", "key"
    ]

    private struct ReadTextFileRequest {
        let path: String
        let fullPath: String
        let offset: Int?
        let limit: Int?
        let argumentsJSON: String
        let contextMode: ContextMode
        let toolName: String
    }

    private static func fullPath(for path: String, workspaceRoot: String) -> String {
        path.hasPrefix("/") ? path : (workspaceRoot as NSString).appendingPathComponent(path)
    }

    private static func readDirectory(
        path: String,
        fullPath: String,
        limit: Int?,
        argumentsJSON: String,
        toolName: String
    ) async -> ToolResult {
        let maxEntries = max(1, min(limit ?? 300, 1_000))
        let lines = Self.directoryListing(root: fullPath, maxEntries: maxEntries)
        let output = Self.directoryOutput(path: path, lines: lines, maxEntries: maxEntries)

        await AuditLog.shared.record(
            tool: toolName,
            input: argumentsJSON,
            output: "读取目录 \(path)，\(lines.count) 项",
            success: true
        )

        return ToolResult(
            output: output,
            data: ["path": path, "type": "directory", "count": "\(lines.count)", "recursive": "true"]
        )
    }

    private static func directoryOutput(path: String, lines: [String], maxEntries: Int) -> String {
        guard !lines.isEmpty else { return "目录为空：\(path)" }
        let suffix = lines.count >= maxEntries ? "\n...（目录较大，已截断；可增大 limit 或读取更具体的子目录）" : ""
        return "目录：\(path)\n" + lines.joined(separator: "\n") + suffix
    }

    private static func readTextFile(_ request: ReadTextFileRequest) async -> ToolResult {
        do {
            let content = try String(contentsOfFile: request.fullPath, encoding: .utf8)
            let resultText = windowedText(content, offset: request.offset, limit: request.limit)
            let truncated = truncatedText(resultText, contextMode: request.contextMode)
            await AuditLog.shared.record(
                tool: request.toolName,
                input: request.argumentsJSON,
                output: "读取 \(request.path)，\(resultText.count) 字符",
                success: true
            )
            return ToolResult(output: truncated, data: ["path": request.path, "size": "\(resultText.count)"])
        } catch {
            return ToolResult(output: "读取文件失败：\(error.localizedDescription)", success: false, error: "read_error")
        }
    }

    private static func windowedText(_ content: String, offset: Int?, limit: Int?) -> String {
        var lines = content.components(separatedBy: "\n")
        if let offset, offset > 0 {
            lines = Array(lines.dropFirst(max(0, offset - 1)))
        }
        if let limit, limit > 0 {
            lines = Array(lines.prefix(limit))
        }
        return lines.joined(separator: "\n")
    }

    private static func truncatedText(_ text: String, contextMode: ContextMode) -> String {
        let maxChars = maxCharacters(for: contextMode)
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars)) + "\n... (已截断，当前\(contextMode.rawValue)模式)"
    }

    private static func maxCharacters(for contextMode: ContextMode) -> Int {
        switch contextMode {
        case .economy: return 10_000
        case .balanced: return 50_000
        case .deep: return 200_000
        }
    }

    private static func directoryListing(root: String, maxEntries: Int) -> [String] {
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return [] }

        var lines: [String] = []
        for case let url as URL in enumerator {
            guard lines.count < maxEntries else { break }
            let relative = String(url.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            lines.append(isDirectory ? "\(relative)/" : relative)
        }
        return lines.sorted()
    }
}

// MARK: - Extract File Tool

public struct ExtractFileTool: LaicaiTool {
    public var name: String { "file.extract" }
    public var description: String { "从表格/文档中提取可供模型阅读的文本。支持 xlsx/xlsm/pptx/csv/tsv；普通文本也可读取。" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "path": FunctionProperty(type: "string", description: "文件路径（相对或绝对路径）"),
                    "limit": FunctionProperty(type: "integer", description: "最大输出字符数（可选，默认 50000）")
                ],
                required: ["path"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var path: String
            var limit: Int?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let workspaceRoot = context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceRoot.isEmpty else {
            return ToolResult(output: "请先设置工作区后再提取文件。", success: false, error: "workspace_missing")
        }
        let fullPath = Self.fullPath(for: params.path, workspaceRoot: workspaceRoot)

        if let securityError = await SecurityManager.shared.checkRead(path: fullPath, workspaceRoot: workspaceRoot) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return ToolResult(output: "文件不存在或不是普通文件：\(params.path)", success: false, error: "file_not_found")
        }

        let ext = (fullPath as NSString).pathExtension.lowercased()
        let limit = max(1_000, min(params.limit ?? 50_000, 200_000))
        do {
            guard let extracted = try Self.extractText(path: fullPath, extensionName: ext, limit: limit) else {
                return Self.unsupportedExtractResult(path: params.path, extensionName: ext)
            }
            let output = Self.truncatedExtractOutput(extracted, limit: limit)
            await AuditLog.shared.record(
                tool: name,
                input: argumentsJSON,
                output: "提取 \(params.path)，\(output.count) 字符",
                success: true
            )
            return ToolResult(output: output, data: ["path": params.path, "extension": ext, "size": "\(extracted.count)"])
        } catch {
            return ToolResult(output: "提取文件失败：\(error.localizedDescription)", success: false, error: "extract_error")
        }
    }

    private static let plainTextExtractExtensions: Set<String> = [
        "txt", "markdown", "json", "yaml", "yml", "xml", "html", "htm", "log"
    ]

    private static func fullPath(for path: String, workspaceRoot: String) -> String {
        path.hasPrefix("/") ? path : (workspaceRoot as NSString).appendingPathComponent(path)
    }

    private static func extractText(path: String, extensionName: String, limit: Int) throws -> String? {
        switch extensionName {
        case "xlsx", "xlsm":
            return try Self.extractXLSX(path: path, limit: limit)
        case "pptx":
            return try Self.extractPPTX(path: path, limit: limit)
        case "csv", "tsv":
            return try Self.extractDelimited(path: path, separator: extensionName == "tsv" ? "\t" : ",", limit: limit)
        default:
            guard plainTextExtractExtensions.contains(extensionName) else { return nil }
            return try String(contentsOfFile: path, encoding: .utf8)
        }
    }

    private static func unsupportedExtractResult(path: String, extensionName: String) -> ToolResult {
        ToolResult(
            output: "暂不支持提取 .\(extensionName.isEmpty ? "unknown" : extensionName) 文件。可尝试用系统工具转换为 txt/csv/xlsx 后再读取。",
            data: ["path": path, "extension": extensionName],
            success: false,
            error: "unsupported_file_type"
        )
    }

    private static func truncatedExtractOutput(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n...（已截断，共 \(text.count) 字符）" : text
    }

    private static func extractDelimited(path: String, separator: String, limit: Int) throws -> String {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let rows = content.components(separatedBy: .newlines).prefix(300)
        return rows.map { line in
            line.components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " | ")
        }.joined(separator: "\n").prefixString(limit)
    }

    private static func extractXLSX(path: String, limit: Int) throws -> String {
        let script = """
            import sys, zipfile, re, html, xml.etree.ElementTree as ET
            path = sys.argv[1]
            nsString = {'a': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
            with zipfile.ZipFile(path) as z:
                shared = []
                if 'xl/sharedStrings.xml' in z.namelist():
                    root = ET.fromstring(z.read('xl/sharedStrings.xml'))
                    for si in root.findall('a:si', nsString):
                        texts = [t.text or '' for t in si.findall('.//a:t', nsString)]
                        shared.append(''.join(texts))
                sheets = sorted([n for n in z.namelist() if re.match(r'xl/worksheets/sheet\\d+\\.xml$', n)])
                out = []
                for sheet_index, name in enumerate(sheets[:8], 1):
                    out.append(f'## Sheet {sheet_index}')
                    root = ET.fromstring(z.read(name))
                    for row in root.findall('.//a:sheetData/a:row', nsString):
                        cells = []
                        for c in row.findall('a:c', nsString):
                            v = c.find('a:v', nsString)
                            if v is None:
                                cells.append('')
                                continue
                            text = v.text or ''
                            if c.attrib.get('t') == 's':
                                try:
                                    text = shared[int(text)]
                                except Exception:
                                    pass
                            cells.append(html.unescape(text))
                        if any(cell.strip() for cell in cells):
                            out.append(' | '.join(cells))
                print('\\n'.join(out))
            """
        return try runPython(script: script, arguments: [path]).prefixString(limit)
    }

    private static func extractPPTX(path: String, limit: Int) throws -> String {
        let script = """
            import sys, zipfile, re, html, xml.etree.ElementTree as ET
            path = sys.argv[1]
            limit = int(sys.argv[2])

            def index_for(name):
                m = re.search(r'(?:slide|notesSlide)(\\d+)\\.xml$', name)
                return int(m.group(1)) if m else 0

            def text_runs(data):
                try:
                    root = ET.fromstring(data)
                except Exception:
                    return []
                runs = []
                for node in root.iter():
                    if node.tag.endswith('}t') or node.tag == 't':
                        text = (node.text or '').strip()
                        if text:
                            runs.append(html.unescape(text))
                return runs

            with zipfile.ZipFile(path) as z:
                names = z.namelist()
                slides = sorted(
                    [n for n in names if re.match(r'ppt/slides/slide\\d+\\.xml$', n)],
                    key=index_for
                )
                notes = sorted(
                    [n for n in names if re.match(r'ppt/notesSlides/notesSlide\\d+\\.xml$', n)],
                    key=index_for
                )
                media = [n for n in names if n.startswith('ppt/media/')]
                out = [
                    f'PPTX 可编辑文本提取：{len(slides)} 页，{len(media)} 个媒体文件',
                    '注意：本工具提取可编辑文本和备注，不包含图片中文字 OCR。若用户要求处理图片中文字，必须另行使用 OCR/视觉识别，不能声称已完成图片文字处理。',
                    ''
                ]
                for name in slides:
                    runs = text_runs(z.read(name))
                    if not runs:
                        continue
                    out.append(f'## Slide {index_for(name)}')
                    out.extend(runs)
                    out.append('')
                for name in notes:
                    runs = text_runs(z.read(name))
                    if not runs:
                        continue
                    out.append(f'## Notes {index_for(name)}')
                    out.extend(runs)
                    out.append('')
                result = '\\n'.join(out)
                sys.stdout.write(result[:limit])
            """
        return try runPython(script: script, arguments: [path, "\(limit)"]).prefixString(limit)
    }

    private static func runPython(script: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        guard waitForExit(process, timeoutSeconds: 60) else {
            process.terminate()
            if !waitForExit(process, timeoutSeconds: 2) {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = waitForExit(process, timeoutSeconds: 1)
            }
            throw NSError(domain: "ExtractFileTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "python3 提取超时"])
        }
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ExtractFileTool", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "python3 提取失败" : err])
        }
        return out
    }

    private static func waitForExit(_ process: Process, timeoutSeconds: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if !process.isRunning { return true }
        let result = semaphore.wait(timeout: .now() + timeoutSeconds)
        process.terminationHandler = nil
        return result == .success || !process.isRunning
    }
}

extension String {
    fileprivate func prefixString(_ limit: Int) -> String {
        count > limit ? String(prefix(limit)) : self
    }
}
// MARK: - File Edit Tool (precise search/replace)

public struct FileEditTool: LaicaiTool {
    public var name: String { "file.edit" }
    public var description: String { "精准编辑文件：查找并替换指定内容片段，支持多处同时替换。优先使用此工具而非 file.write 全量覆盖。" }
    public var requiresReview: Bool { true }
    public var executionPolicy: ToolExecutionPolicy { .fileChangeReview }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "path": FunctionProperty(type: "string", description: "文件路径（相对或绝对路径）"),
                    "edits": FunctionProperty(type: "string", description: "JSON 数组，每项含 oldText 和 newText。例：[{\"oldText\":\"foo\",\"newText\":\"bar\"}]"),
                    "batchEdits": FunctionProperty(
                        type: "string",
                        description: "可选，批量编辑 JSON 数组，每项含 path 和 edits。例：[{\"path\":\"a.swift\",\"edits\":[{\"oldText\":\"foo\",\"newText\":\"bar\"}]}]"),
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

    private struct EditResultRequest {
        let path: String
        let fullPath: String
        let oldContent: String
        let newContent: String
        let appliedEdits: [EditOp]
        let appliedCount: Int
        let totalCount: Int
        let errors: [String]
    }

    private struct EditApplicationState {
        var content: String
        var appliedCount = 0
        var errors: [String] = []
        var appliedEdits: [EditOp] = []
    }

    private struct Params: Codable {
        var path: String?
        var edits: String?
        var batchEdits: String?
        var createIfMissing: Bool?
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        // Models often send edits/batchEdits as native JSON arrays instead of JSON strings.
        // Normalize them to strings before Codable parsing.
        let normalizedJSON = Self.normalizedArgumentsJSON(argumentsJSON)

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
            // Auto-repair: try common JSON format mistakes before giving up
            if let repaired = Self.repairEditsJSON(editsJSON) {
                edits = repaired
            } else {
                return ToolResult(output: "edits 参数格式错误，需要 JSON 数组 [{\"oldText\":\"...\",\"newText\":\"...\"}]", success: false, error: "invalid_edits")
            }
        }

        guard !edits.isEmpty else {
            return ToolResult(output: "edits 数组为空", success: false, error: "empty_edits")
        }

        return try await executeSingle(path: path, edits: edits, createIfMissing: params.createIfMissing == true, context: context)
    }

    private static func normalizedArgumentsJSON(_ argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
            var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return argumentsJSON
        }
        normalizeJSONArray(key: "edits", in: &dict)
        normalizeJSONArray(key: "batchEdits", in: &dict)
        guard let normalized = try? JSONSerialization.data(withJSONObject: dict),
            let str = String(data: normalized, encoding: .utf8)
        else {
            return argumentsJSON
        }
        return str
    }

    private static func normalizeJSONArray(key: String, in dict: inout [String: Any]) {
        guard let array = dict[key] as? [[String: Any]],
            let reEncoded = try? JSONSerialization.data(withJSONObject: array),
            let str = String(data: reEncoded, encoding: .utf8)
        else { return }
        dict[key] = str
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
        if let dangerousError = DangerousOperationGuard.writeViolation(path: fullPath, oldContent: content, context: context) {
            return ToolResult(output: dangerousError, success: false, error: "dangerous_operation")
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
        var editState = EditApplicationState(content: content)

        for (index, edit) in edits.enumerated() {
            Self.apply(edit, index: index, to: &editState)
        }

        // Post-edit format hook: normalize trailing newline
        if editState.appliedCount > 0 && !editState.content.hasSuffix("\n") && oldContent.hasSuffix("\n") {
            editState.content += "\n"
        }

        if editState.appliedCount == 0 {
            let hint =
                oldContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\n💡 该文件为空，无法查找替换。请改用 file.write 的 content 参数直接写入完整内容。"
                : ""
            return ToolResult(
                output: "所有编辑均失败：\n" + editState.errors.joined(separator: "\n") + hint,
                success: false,
                error: "all_edits_failed"
            )
        }

        if let warning = externalChangeWarning {
            editState.errors.insert(warning, at: 0)
        }
        return makeEditResult(
            EditResultRequest(
                path: path,
                fullPath: fullPath,
                oldContent: oldContent,
                newContent: editState.content,
                appliedEdits: editState.appliedEdits,
                appliedCount: editState.appliedCount,
                totalCount: edits.count,
                errors: editState.errors
            ))
    }

    private static func apply(_ edit: EditOp, index: Int, to state: inout EditApplicationState) {
        if edit.oldText == edit.newText {
            state.errors.append("第\(index + 1)条编辑：oldText 和 newText 相同，跳过")
            return
        }
        if edit.oldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendEdit(edit, to: &state)
            return
        }
        if applyExactEdit(edit, index: index, to: &state) {
            return
        }
        if let fuzzyResult = Self.fuzzyReplace(in: state.content, oldText: edit.oldText, newText: edit.newText) {
            state.content = fuzzyResult.content
            state.appliedCount += 1
            state.appliedEdits.append(edit)
            state.errors.append("第\(index + 1)条编辑：模糊匹配成功（\(fuzzyResult.matchType)）")
            return
        }
        appendMissingOldTextError(edit: edit, index: index, content: state.content, errors: &state.errors)
    }

    private static func appendEdit(_ edit: EditOp, to state: inout EditApplicationState) {
        let separator = state.content.hasSuffix("\n") ? "" : "\n"
        state.content += separator + edit.newText
        state.appliedCount += 1
        state.appliedEdits.append(edit)
    }

    private static func applyExactEdit(_ edit: EditOp, index: Int, to state: inout EditApplicationState) -> Bool {
        guard state.content.contains(edit.oldText) else { return false }
        let occurrences = state.content.components(separatedBy: edit.oldText).count - 1
        guard occurrences == 1 else {
            state.errors.append("第\(index + 1)条编辑：oldText 出现 \(occurrences) 次，需提供更多上下文以唯一标识")
            return true
        }
        state.content = state.content.replacingOccurrences(of: edit.oldText, with: edit.newText)
        state.appliedCount += 1
        state.appliedEdits.append(edit)
        return true
    }

    private static func appendMissingOldTextError(
        edit: EditOp,
        index: Int,
        content: String,
        errors: inout [String]
    ) {
        let preview = String(edit.oldText.prefix(80))
        let similar = Self.findSimilarLines(in: content, target: edit.oldText, maxResults: 3)
        guard !similar.isEmpty else {
            errors.append("第\(index + 1)条编辑：未找到 oldText（前80字符：\(preview)）。建议先用 file_read 重新读取文件，确认目标内容是否存在。")
            return
        }
        let hint = similar.enumerated().map { idx, line in
            "    [\(idx+1)] \(line)"
        }.joined(separator: "\n")
        errors.append("第\(index + 1)条编辑：未找到 oldText（前80字符：\(preview)）\n  最相似行：\n\(hint)\n  建议：复制其中一行作为新的 oldText 重试，注意空格和缩进必须完全一致。")
    }

    private func executeBatch(batchEditsJSON: String, createIfMissing: Bool, context: TaskContext) async throws -> ToolResult {
        let batch: [BatchEdit]
        do {
            let data = batchEditsJSON.data(using: .utf8) ?? Data()
            batch = try JSONDecoder().decode([BatchEdit].self, from: data)
        } catch {
            return ToolResult(
                output: """
                    batchEdits 参数格式错误：\(error.localizedDescription)
                    需要 JSON 数组格式：[{\"path\":\"file.py\",\"edits\":[{\"oldText\":\"旧内容\",\"newText\":\"新内容\"}]}]
                    """,
                success: false,
                error: "invalid_batch_edits"
            )
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

    /// Auto-repair common JSON format mistakes in the edits parameter.
    /// Models frequently produce malformed edits JSON — this rescues those cases.
    private static func repairEditsJSON(_ raw: String) -> [EditOp]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strategy 1: Single object instead of array → wrap in array
        // e.g. {"oldText":"foo","newText":"bar"} instead of [{"oldText":"foo","newText":"bar"}]
        if trimmed.hasPrefix("{") && !trimmed.hasPrefix("[") {
            let wrapped = "[\(trimmed)]"
            if let data = wrapped.data(using: .utf8),
                let ops = try? JSONDecoder().decode([EditOp].self, from: data), !ops.isEmpty {
                return ops
            }
        }

        // Strategy 2: Escaped JSON string (double-encoded) → unescape first
        // e.g. "[{\"oldText\":\"foo\",\"newText\":\"bar\"}]" as a string value
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") {
            let inner = String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
                .replacingOccurrences(of: "\\/", with: "/")
            if let data = inner.data(using: .utf8),
                let ops = try? JSONDecoder().decode([EditOp].self, from: data), !ops.isEmpty {
                return ops
            }
        }

        // Strategy 3: Markdown code fence wrapping → strip fences
        // e.g. ```json\n[...]\n```
        var stripped = trimmed
        if stripped.hasPrefix("```") {
            let lines = stripped.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.hasPrefix("```") }
            stripped = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = stripped.data(using: .utf8),
                let ops = try? JSONDecoder().decode([EditOp].self, from: data), !ops.isEmpty {
                return ops
            }
        }

        // Strategy 4: Unescaped newlines/tabs inside JSON strings → escape them
        let escaped =
            trimmed
            .replacingOccurrences(of: "\t", with: "\\t")
        // Replace actual newlines between quotes (crude but effective)
        if let data = escaped.data(using: .utf8),
            let ops = try? JSONDecoder().decode([EditOp].self, from: data), !ops.isEmpty {
            return ops
        }

        // Strategy 5: Alternative key names (old_text/new_text, old/new, before/after)
        if let data = trimmed.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let ops: [EditOp] = arr.compactMap { dict in
                let old =
                    dict["oldText"] as? String
                    ?? dict["old_text"] as? String
                    ?? dict["old"] as? String
                    ?? dict["before"] as? String
                    ?? dict["search"] as? String
                    ?? ""
                let new =
                    dict["newText"] as? String
                    ?? dict["new_text"] as? String
                    ?? dict["new"] as? String
                    ?? dict["after"] as? String
                    ?? dict["replace"] as? String
                guard new != nil else { return nil }
                return EditOp(oldText: old, newText: new!)
            }
            if !ops.isEmpty { return ops }
        }

        return nil
    }

    /// Find lines in content most similar to target's first non-empty line.
    /// Used to give the model recovery hints when its oldText didn't match exactly.
    static func findSimilarLines(in content: String, target: String, maxResults: Int = 3) -> [String] {
        let firstTargetLine =
            target.components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? target.trimmingCharacters(in: .whitespaces)
        guard !firstTargetLine.isEmpty else { return [] }
        let normalizedTarget = firstTargetLine.lowercased()

        // Score each non-empty line by character overlap (cheap Jaccard-ish)
        let targetChars = Set(normalizedTarget)
        let lines = content.components(separatedBy: "\n")
        var scored: [(score: Double, line: String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let lower = trimmed.lowercased()
            // Exact substring or substring-of are highest-value
            if lower.contains(normalizedTarget) || normalizedTarget.contains(lower) {
                scored.append((1.0, trimmed))
                continue
            }
            let lineChars = Set(lower)
            let intersection = targetChars.intersection(lineChars).count
            let unionCount = targetChars.union(lineChars).count
            guard unionCount > 0 else { continue }
            let score = Double(intersection) / Double(unionCount)
            if score > 0.4 {
                scored.append((score, trimmed))
            }
        }
        return scored.sorted { $0.score > $1.score }
            .prefix(maxResults)
            .map { String($0.line.prefix(120)) }
    }

    private static func fuzzyReplace(in content: String, oldText: String, newText: String) -> FuzzyReplaceResult? {
        let contentLines = content.components(separatedBy: "\n")
        let oldLines = oldText.components(separatedBy: "\n")
        guard !oldLines.isEmpty else { return nil }
        return whitespaceTrimmedFuzzyReplace(contentLines: contentLines, oldLines: oldLines, newText: newText)
            ?? indentStrippedFuzzyReplace(contentLines: contentLines, oldLines: oldLines, newText: newText)
            ?? widthNormalizedFuzzyReplace(contentLines: contentLines, oldLines: oldLines, newText: newText)
            ?? anchorFuzzyReplace(contentLines: contentLines, oldLines: oldLines, newText: newText)
    }

    private static func whitespaceTrimmedFuzzyReplace(
        contentLines: [String],
        oldLines: [String],
        newText: String
    ) -> FuzzyReplaceResult? {
        let trimmedOld = oldLines.map { $0.trimmingCharacters(in: .whitespaces) }
        for startIdx in 0...(max(0, contentLines.count - oldLines.count)) {
            let slice = contentLines[startIdx..<min(startIdx + oldLines.count, contentLines.count)]
            let trimmedSlice = slice.map { $0.trimmingCharacters(in: .whitespaces) }
            if trimmedSlice == trimmedOld {
                let matchedIndent = detectIndent(Array(slice))
                let oldIndent = detectIndent(oldLines)
                let adjustedNew = reindent(newText, from: oldIndent, to: matchedIndent)
                return replacedLines(
                    contentLines: contentLines,
                    startIdx: startIdx,
                    oldLineCount: oldLines.count,
                    adjustedNew: adjustedNew,
                    matchType: "空白标准化"
                )
            }
        }
        return nil
    }

    private static func indentStrippedFuzzyReplace(
        contentLines: [String],
        oldLines: [String],
        newText: String
    ) -> FuzzyReplaceResult? {
        let strippedOld = oldLines.map { $0.trimmingCharacters(in: horizontalWhitespace) }
        for startIdx in 0...(max(0, contentLines.count - oldLines.count)) {
            let slice = contentLines[startIdx..<min(startIdx + oldLines.count, contentLines.count)]
            let strippedSlice = slice.map { $0.trimmingCharacters(in: horizontalWhitespace) }
            if strippedSlice == strippedOld {
                let matchedIndent = detectIndent(Array(slice))
                let adjustedNew = reindent(newText, from: 0, to: matchedIndent)
                return replacedLines(
                    contentLines: contentLines,
                    startIdx: startIdx,
                    oldLineCount: oldLines.count,
                    adjustedNew: adjustedNew,
                    matchType: "缩进感知"
                )
            }
        }
        return nil
    }

    private static func widthNormalizedFuzzyReplace(
        contentLines: [String],
        oldLines: [String],
        newText: String
    ) -> FuzzyReplaceResult? {
        let normalizedOld = oldLines.map { normalizeWidth($0.trimmingCharacters(in: horizontalWhitespace)) }
        for startIdx in 0...(max(0, contentLines.count - oldLines.count)) {
            let slice = contentLines[startIdx..<min(startIdx + oldLines.count, contentLines.count)]
            let normalizedSlice = slice.map { normalizeWidth($0.trimmingCharacters(in: horizontalWhitespace)) }
            if normalizedSlice == normalizedOld {
                let matchedIndent = detectIndent(Array(slice))
                let adjustedNew = reindent(newText, from: 0, to: matchedIndent)
                return replacedLines(
                    contentLines: contentLines,
                    startIdx: startIdx,
                    oldLineCount: oldLines.count,
                    adjustedNew: adjustedNew,
                    matchType: "全角标准化"
                )
            }
        }
        return nil
    }

    private static func anchorFuzzyReplace(
        contentLines: [String],
        oldLines: [String],
        newText: String
    ) -> FuzzyReplaceResult? {
        let nonEmptyOld = oldLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmptyOld.count >= 5 else { return nil }
        let firstAnchor = nonEmptyOld.prefix(2).map { $0.trimmingCharacters(in: horizontalWhitespace) }
        let lastAnchor = nonEmptyOld.suffix(2).map { $0.trimmingCharacters(in: horizontalWhitespace) }
        for startIdx in 0...(max(0, contentLines.count - oldLines.count)) {
            let candidateSlice = Array(contentLines[startIdx..<min(startIdx + oldLines.count, contentLines.count)])
            if matchesAnchors(candidateSlice: candidateSlice, firstAnchor: Array(firstAnchor), lastAnchor: Array(lastAnchor)) {
                let matchedIndent = detectIndent(candidateSlice)
                let adjustedNew = reindent(newText, from: 0, to: matchedIndent)
                return replacedLines(
                    contentLines: contentLines,
                    startIdx: startIdx,
                    oldLineCount: oldLines.count,
                    adjustedNew: adjustedNew,
                    matchType: "锚点匹配"
                )
            }
        }
        return nil
    }

    private static let horizontalWhitespace = CharacterSet(charactersIn: " \t")
    private static let widthNormalizationPairs: [(String, String)] = [
        ("（", "("), ("）", ")"), ("：", ":"), ("；", ";"),
        ("，", ","), ("。", "."), ("！", "!"), ("？", "?"),
        ("【", "["), ("】", "]"), ("「", "\""), ("」", "\""),
        ("\u{3000}", " ")
    ]

    private static func normalizeWidth(_ string: String) -> String {
        var normalized = string
        for (fullWidth, halfWidth) in widthNormalizationPairs {
            normalized = normalized.replacingOccurrences(of: fullWidth, with: halfWidth)
        }
        return normalized
    }

    private static func matchesAnchors(candidateSlice: [String], firstAnchor: [String], lastAnchor: [String]) -> Bool {
        let nonEmptyCandidate = candidateSlice.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmptyCandidate.count >= 5 else { return false }
        let candidateFirst = nonEmptyCandidate.prefix(2).map { $0.trimmingCharacters(in: horizontalWhitespace) }
        let candidateLast = nonEmptyCandidate.suffix(2).map { $0.trimmingCharacters(in: horizontalWhitespace) }
        return Array(candidateFirst) == firstAnchor && Array(candidateLast) == lastAnchor
    }

    private static func replacedLines(
        contentLines: [String],
        startIdx: Int,
        oldLineCount: Int,
        adjustedNew: String,
        matchType: String
    ) -> FuzzyReplaceResult {
        var result = contentLines
        result.replaceSubrange(startIdx..<(startIdx + oldLineCount), with: adjustedNew.components(separatedBy: "\n"))
        return FuzzyReplaceResult(content: result.joined(separator: "\n"), matchType: matchType)
    }

    private static func detectIndent(_ lines: [String]) -> Int {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return 0 }
        return nonEmpty.map { line -> Int in
            var count = 0
            for character in line {
                if character == " " { count += 1 } else if character == "\t" { count += 4 } else { break }
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

    private func makeEditResult(_ request: EditResultRequest) -> ToolResult {
        let path = request.path
        let fullPath = request.fullPath
        let oldContent = request.oldContent
        let newContent = request.newContent
        let appliedEdits = request.appliedEdits
        let appliedCount = request.appliedCount
        let totalCount = request.totalCount
        let errors = request.errors
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
            data["hunk\(index).summary"] =
                "Hunk \(index + 1): \(edit.oldText.components(separatedBy: "\n").count)→\(edit.newText.components(separatedBy: "\n").count) 行"
        }

        return ToolResult(
            output: summary,
            data: data,
            success: true
        )
    }
}
