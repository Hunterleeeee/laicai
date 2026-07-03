import Darwin
import Foundation
import LaicaiNativeDomain

// MARK: - Document Transform Tool

private struct DocumentTransformParams: Codable {
    var action: String?
    var sourcePath: String?
    var path: String?
    var outputPath: String?
    var workflowPath: String?
    var renderDir: String?
    var translationsJSON: String?
    var replacementsJSON: String?
    var chunkIndex: Int?
    var chunkSize: Int?
    var onlyChinese: Bool?
    var granularity: String?
}

private struct DocumentTransformRequest {
    var action: String
    var sourcePath: String
    var sourceForRead: String
    var outputPath: String
    var workflowPath: String
    var renderDir: String
    var extensionName: String
    var granularity: String
    var translationsJSON: String
    var chunkIndex: Int
    var chunkSize: Int
    var onlyChinese: Bool
}

public struct DocumentTransformTool: LaicaiTool {
    public var name: String { "document.transform" }
    public var description: String {
        "对 Office 文档执行可落盘交付。支持 pptx/docx/xlsx/xlsm 的项目化工作区、可编辑文本检查、分块提取、按 id 累积写回、复制、渲染和验证产物。图片中文字需要渲染/OCR 后单独处理。"
    }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "action": FunctionProperty(
                        type: "string",
                        description: """
                            操作：workspace/inspect/prepare/apply/copy/verify/render。workspace 创建交付工作区；prepare 分块返回可编辑文本；\
                            apply 累积写回 translationsJSON；render 用 LibreOffice 导出 PDF；verify 检查输出文件。
                            """,
                        enumValues: ["workspace", "inspect", "prepare", "apply", "copy", "verify", "render"]
                    ),
                    "sourcePath": FunctionProperty(type: "string", description: "源文档路径，支持绝对路径或相对工作区路径。"),
                    "path": FunctionProperty(type: "string", description: "sourcePath 的兼容别名。"),
                    "outputPath": FunctionProperty(type: "string", description: "输出文档路径。apply/copy 时可选；不提供则在源文件旁生成 _Laicai 副本。"),
                    "workflowPath": FunctionProperty(type: "string", description: "workspace/render 使用的交付工作区路径；不提供则在当前工作区 .laicai/document-workflows 下创建。"),
                    "renderDir": FunctionProperty(type: "string", description: "render 输出目录；不提供则使用 workflowPath/rendered。"),
                    "translationsJSON": FunctionProperty(
                        type: "string",
                        description: "apply 时使用的 JSON。支持对象 {\"part::index\":\"新文本\"} 或数组 [{\"id\":\"part::index\",\"text\":\"新文本\"}]；也支持用原文作为 key。"),
                    "replacementsJSON": FunctionProperty(type: "string", description: "translationsJSON 的兼容别名。"),
                    "chunkIndex": FunctionProperty(type: "integer", description: "prepare 时返回第几个分块，从 0 开始。"),
                    "chunkSize": FunctionProperty(type: "integer", description: "prepare 每块最多文本条数，默认 80，最大 300。"),
                    "onlyChinese": FunctionProperty(type: "boolean", description: "prepare 是否只返回含中文/CJK 的文本，默认 true。"),
                    "granularity": FunctionProperty(
                        type: "string", description: "文本粒度：paragraph/text。pptx/docx 默认 paragraph，xlsx/xlsm 默认 text。", enumValues: ["paragraph", "text"])
                ],
                required: ["action"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        let params: Params
        do {
            params = try Self.decodeParams(argumentsJSON)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let action = (params.action ?? "prepare").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.allowedActions.contains(action) else {
            return ToolResult(output: "参数错误：action 必须是 workspace/inspect/prepare/apply/copy/verify/render。", success: false, error: "invalid_action")
        }

        guard let rawSource = Self.rawSource(from: params) else {
            return ToolResult(output: "参数错误：必须提供 sourcePath。", success: false, error: "invalid_params")
        }

        let sourcePath = Self.resolvedPath(rawSource, workspaceRoot: context.workspaceRoot)
        if let failure = await Self.validateSource(path: sourcePath, rawSource: rawSource) {
            return failure
        }
        let result = await Self.makeRequest(params: params, action: action, sourcePath: sourcePath, context: context)
        if let failure = result.failure {
            return failure
        }
        guard let request = result.value else {
            return ToolResult(output: "文档转换请求构造失败。", success: false, error: "invalid_params")
        }
        if let failure = await Self.validateWriteAccess(for: request, context: context) {
            return failure
        }

        do {
            let json = try Self.runPython(script: Self.pythonScript, input: Self.payload(from: request))
            let summary = Self.summary(from: json, fallbackAction: request.action, outputPath: request.outputPath)
            let data = Self.resultData(
                from: json,
                sourcePath: request.sourceForRead,
                outputPath: request.outputPath,
                action: request.action
            )

            await AuditLog.shared.record(
                tool: name,
                input: "\(request.action) \(request.sourcePath)",
                output: summary,
                success: true
            )

            return ToolResult(output: json, data: data, success: true)
        } catch {
            return ToolResult(output: "文档转换失败：\(error.localizedDescription)", success: false, error: "transform_error")
        }
    }

    public func validate(result: ToolResult) -> Bool {
        guard result.success else { return false }
        let action = result.data?["action"] ?? ""
        if ["apply", "copy"].contains(action) {
            guard let outputPath = result.data?["outputPath"] else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: outputPath, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        return true
    }

    private typealias Params = DocumentTransformParams
    private typealias Request = DocumentTransformRequest

    private static let allowedActions: Set<String> = ["workspace", "inspect", "prepare", "apply", "copy", "verify", "render"]
    private static let supportedExtensions: Set<String> = ["pptx", "docx", "xlsx", "xlsm"]
    private static let textGranularities: Set<String> = ["paragraph", "text"]
    private static let existingOutputActions: Set<String> = ["apply", "verify", "render"]
    private static let documentOutputActions: Set<String> = ["apply", "copy"]

    private static func decodeParams(_ argumentsJSON: String) throws -> Params {
        let normalizedJSON = Self.normalizedArgumentsJSON(argumentsJSON)
        let data = normalizedJSON.data(using: .utf8) ?? Data()
        return try JSONDecoder().decode(Params.self, from: data)
    }

    private static func rawSource(from params: Params) -> String? {
        let rawSource = (params.sourcePath ?? params.path)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawSource?.isEmpty == false ? rawSource : nil
    }

    private static func validateSource(path: String, rawSource: String) async -> ToolResult? {
        if let securityError = await SecurityManager.shared.checkRead(path: path) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return ToolResult(output: "源文档不存在或不是普通文件：\(rawSource)", success: false, error: "file_not_found")
        }
        return nil
    }

    private static func makeRequest(
        params: Params,
        action: String,
        sourcePath: String,
        context: TaskContext
    ) async -> (value: Request?, failure: ToolResult?) {
        let outputPath = outputPath(from: params, sourcePath: sourcePath, context: context)
        let sourceForRead = sourceForRead(action: action, sourcePath: sourcePath, outputPath: outputPath)
        if sourceForRead != sourcePath,
            let securityError = await SecurityManager.shared.checkRead(path: sourceForRead) {
            return (nil, ToolResult(output: securityError, success: false, error: "security_denied"))
        }
        let ext = (sourceForRead as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            return (nil, unsupportedFileType(path: sourcePath, extensionName: ext))
        }
        let workflowPath = workflowPath(from: params, sourceForRead: sourceForRead, context: context)
        let renderDir = renderDir(from: params, workflowPath: workflowPath, context: context)
        return (
            Request(
                action: action,
                sourcePath: sourcePath,
                sourceForRead: sourceForRead,
                outputPath: outputPath,
                workflowPath: workflowPath,
                renderDir: renderDir,
                extensionName: ext,
                granularity: granularity(from: params, extensionName: ext),
                translationsJSON: params.translationsJSON ?? params.replacementsJSON ?? "",
                chunkIndex: max(0, params.chunkIndex ?? 0),
                chunkSize: max(1, min(params.chunkSize ?? 80, 300)),
                onlyChinese: params.onlyChinese ?? true
            ), nil
        )
    }

    private static func outputPath(from params: Params, sourcePath: String, context: TaskContext) -> String {
        let rawOutput = params.outputPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawOutput.flatMap { $0.isEmpty ? nil : Self.resolvedPath($0, workspaceRoot: context.workspaceRoot) }
            ?? Self.defaultOutputPath(for: sourcePath)
    }

    private static func sourceForRead(action: String, sourcePath: String, outputPath: String) -> String {
        let readsExistingOutput =
            existingOutputActions.contains(action)
            && FileManager.default.fileExists(atPath: outputPath)
        return readsExistingOutput ? outputPath : sourcePath
    }

    private static func unsupportedFileType(path: String, extensionName: String) -> ToolResult {
        ToolResult(
            output: "document.transform 暂不支持 .\(extensionName.isEmpty ? "unknown" : extensionName)。目前支持 pptx/docx/xlsx/xlsm。",
            data: ["sourcePath": path, "extension": extensionName],
            success: false,
            error: "unsupported_file_type"
        )
    }

    private static func workflowPath(from params: Params, sourceForRead: String, context: TaskContext) -> String {
        let rawWorkflowPath = params.workflowPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawWorkflowPath.flatMap { $0.isEmpty ? nil : Self.resolvedPath($0, workspaceRoot: context.workspaceRoot) }
            ?? Self.defaultWorkflowPath(for: sourceForRead, workspaceRoot: context.workspaceRoot)
    }

    private static func renderDir(from params: Params, workflowPath: String, context: TaskContext) -> String {
        let rawRenderDir = params.renderDir?.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawRenderDir.flatMap { $0.isEmpty ? nil : Self.resolvedPath($0, workspaceRoot: context.workspaceRoot) }
            ?? (workflowPath as NSString).appendingPathComponent("rendered")
    }

    private static func granularity(from params: Params, extensionName: String) -> String {
        let requested = (params.granularity ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !textGranularities.contains(requested) else { return requested }
        return ["pptx", "docx"].contains(extensionName) ? "paragraph" : "text"
    }

    private static func validateWriteAccess(for request: Request, context: TaskContext) async -> ToolResult? {
        if documentOutputActions.contains(request.action) {
            return await writeAccessFailure(path: request.outputPath, context: context)
        }
        if request.action == "workspace" {
            return await writeAccessFailure(path: request.workflowPath, context: context)
        }
        if request.action == "render" {
            return await writeAccessFailure(path: request.renderDir, context: context)
        }
        return nil
    }

    private static func writeAccessFailure(path: String, context: TaskContext) async -> ToolResult? {
        if let securityError = await SecurityManager.shared.checkWrite(path: path) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }
        if let dangerousError = DangerousOperationGuard.documentWriteViolation(path: path, context: context) {
            return ToolResult(output: dangerousError, success: false, error: "dangerous_operation")
        }
        return nil
    }

    private static func payload(from request: Request) -> [String: Any] {
        [
            "action": request.action,
            "sourcePath": request.sourceForRead,
            "outputPath": request.outputPath,
            "originalSourcePath": request.sourcePath,
            "workflowPath": request.workflowPath,
            "renderDir": request.renderDir,
            "translationsJSON": request.translationsJSON,
            "chunkIndex": request.chunkIndex,
            "chunkSize": request.chunkSize,
            "onlyChinese": request.onlyChinese,
            "granularity": request.granularity
        ]
    }

    private static func normalizedArgumentsJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
            var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return json
        }
        for key in ["translationsJSON", "replacementsJSON"] {
            if let value = dict[key], !(value is String),
                let encoded = try? JSONSerialization.data(withJSONObject: value),
                let string = String(data: encoded, encoding: .utf8) {
                dict[key] = string
            }
        }
        guard let normalized = try? JSONSerialization.data(withJSONObject: dict),
            let normalizedString = String(data: normalized, encoding: .utf8)
        else {
            return json
        }
        return normalizedString
    }

    private static func resolvedPath(_ path: String, workspaceRoot: String) -> String {
        path.hasPrefix("/") ? path : (workspaceRoot as NSString).appendingPathComponent(path)
    }

    private static func defaultOutputPath(for sourcePath: String) -> String {
        let url = URL(fileURLWithPath: sourcePath)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent("\(base)_Laicai.\(ext)").path
    }

    private static func defaultWorkflowPath(for sourcePath: String, workspaceRoot: String) -> String {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceDir = sourceURL.deletingLastPathComponent().path
        let baseRoot = (!root.isEmpty && sourcePath.hasPrefix(root + "/")) ? root : sourceDir
        let safeBase = sourceURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let name = safeBase.isEmpty ? "document" : safeBase
        return (baseRoot as NSString).appendingPathComponent(".laicai/document-workflows/\(name)")
    }

    private static func runPython(script: String, input: [String: Any]) throws -> String {
        let inputData = try JSONSerialization.data(withJSONObject: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(inputData)
        try? stdin.fileHandleForWriting.close()
        guard waitForExit(process, timeoutSeconds: 240) else {
            process.terminate()
            if !waitForExit(process, timeoutSeconds: 2) {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = waitForExit(process, timeoutSeconds: 1)
            }
            throw NSError(domain: "DocumentTransformTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "python3 转换超时"])
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "DocumentTransformTool",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "python3 文档转换失败" : err]
            )
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

    private static func summary(from json: String, fallbackAction: String, outputPath: String) -> String {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "\(fallbackAction) \(outputPath)"
        }
        let action = obj["action"] as? String ?? fallbackAction
        let format = obj["format"] as? String ?? "document"
        let total = obj["totalTextRuns"] as? Int ?? 0
        let cjk = obj["cjkTextRuns"] as? Int ?? 0
        if action == "workspace" {
            let workflow = obj["workflowPath"] as? String ?? outputPath
            return "\(format) workspace：已创建文档交付工作区 \(workflow)"
        }
        if action == "render" {
            let pdf = obj["pdfPath"] as? String ?? outputPath
            let pages = obj["renderedPages"] as? Int ?? 0
            return "\(format) render：已导出 PDF/页面 \(pages) 页 \(pdf)"
        }
        let applied = obj["appliedReplacements"] as? Int
        if let applied {
            let remaining = obj["remainingCJK"] as? Int ?? cjk
            return "\(format) \(action)：写回 \(applied) 条，剩余中文 \(remaining) 条"
        }
        return "\(format) \(action)：\(total) 条可编辑文本，\(cjk) 条含中文"
    }

    private static func resultData(from json: String, sourcePath: String, outputPath: String, action: String) -> [String: String] {
        var result: [String: String] = [
            "action": action,
            "sourcePath": sourcePath,
            "outputPath": outputPath,
            "path": outputPath
        ]
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return result
        }
        for key in [
            "format", "granularity", "workflowPath", "workingCopyPath", "manifestPath",
            "scriptsPath", "verifyScriptPath", "renderDir", "pdfPath", "renderedPages",
            "totalTextRuns", "cjkTextRuns", "chunkIndex", "chunkSize", "totalChunks",
            "returnedEntries", "appliedReplacements", "remainingCJK", "mediaCount"
        ] {
            if let value = obj[key] {
                result[key] = "\(value)"
            }
        }
        if let complete = obj["complete"] as? Bool {
            result["complete"] = complete ? "true" : "false"
        }
        if let warnings = obj["warnings"] as? [String], !warnings.isEmpty {
            result["warnings"] = warnings.joined(separator: "；")
        }
        return result
    }

    private static let pythonScript = #"""
        import copy
        import datetime
        import html
        import json
        import math
        import os
        import re
        import shutil
        import subprocess
        import sys
        import tempfile
        import zipfile
        import xml.etree.ElementTree as ET

        params = json.load(sys.stdin)
        action = params.get('action', 'prepare')
        source_path = params['sourcePath']
        original_source_path = params.get('originalSourcePath') or source_path
        output_path = params.get('outputPath') or source_path
        if action == 'verify' and output_path and os.path.exists(output_path):
            source_path = output_path
        workflow_path = params.get('workflowPath') or ''
        render_dir = params.get('renderDir') or ''
        translations_json = params.get('translationsJSON') or ''
        chunk_index = max(0, int(params.get('chunkIndex') or 0))
        chunk_size = max(1, min(int(params.get('chunkSize') or 80), 300))
        only_chinese = bool(params.get('onlyChinese', True))
        ext = os.path.splitext(source_path)[1].lower().lstrip('.')
        granularity = (params.get('granularity') or ('paragraph' if ext in ('pptx', 'docx') else 'text')).lower()
        if granularity not in ('paragraph', 'text'):
            granularity = 'text'
        cjk_re = re.compile(r'[\u3400-\u9fff\uf900-\ufaff]')

        def natural_index(name):
            match = re.search(r'(\d+)\.xml$', name)
            return int(match.group(1)) if match else 0

        def supported_parts(names):
            if ext == 'pptx':
                slide_parts = sorted(
                    [n for n in names if re.match(r'ppt/slides/slide\d+\.xml$', n)],
                    key=natural_index
                )
                note_parts = sorted(
                    [n for n in names if re.match(r'ppt/notesSlides/notesSlide\d+\.xml$', n)],
                    key=natural_index
                )
                return slide_parts + note_parts
            if ext == 'docx':
                wanted = []
                exact = {
                    'word/document.xml',
                    'word/footnotes.xml',
                    'word/endnotes.xml',
                    'word/comments.xml'
                }
                for name in names:
                    if name in exact or re.match(r'word/(header|footer)\d+\.xml$', name):
                        wanted.append(name)
                return sorted(wanted, key=lambda n: (0 if n == 'word/document.xml' else 1, n))
            if ext in ('xlsx', 'xlsm'):
                shared = ['xl/sharedStrings.xml'] if 'xl/sharedStrings.xml' in names else []
                sheets = sorted(
                    [n for n in names if re.match(r'xl/worksheets/sheet\d+\.xml$', n)],
                    key=natural_index
                )
                return shared + sheets
            return []

        def is_text_node(node):
            return node.tag.endswith('}t') or node.tag == 't'

        def is_paragraph_node(node):
            return node.tag.endswith('}p') or node.tag == 'p'

        def text_nodes_under(node):
            return [child for child in node.iter() if is_text_node(child)]

        def node_text(node):
            return html.unescape(node.text or '')

        def paragraph_text(node):
            return ''.join(node_text(t) for t in text_nodes_under(node))

        def set_paragraph_text(node, text):
            nodes = text_nodes_under(node)
            if not nodes:
                return False
            nodes[0].text = text
            for extra in nodes[1:]:
                extra.text = ''
            return True

        def read_entries(zip_obj):
            names = zip_obj.namelist()
            parts = supported_parts(names)
            entries = []
            part_stats = {}
            for part in parts:
                try:
                    root = ET.fromstring(zip_obj.read(part))
                except Exception:
                    continue
                local_index = 0
                if granularity == 'paragraph' and ext in ('pptx', 'docx'):
                    for node in root.iter():
                        if not is_paragraph_node(node):
                            continue
                        text = paragraph_text(node)
                        entry_id = f'{part}::p{local_index}'
                        local_index += 1
                        if not text.strip():
                            continue
                        has_cjk = bool(cjk_re.search(text))
                        entries.append({
                            'id': entry_id,
                            'part': part,
                            'index': local_index - 1,
                            'granularity': 'paragraph',
                            'text': text,
                            'hasCJK': has_cjk
                        })
                else:
                    for node in root.iter():
                        if not is_text_node(node):
                            continue
                        text = node_text(node)
                        entry_id = f'{part}::{local_index}'
                        local_index += 1
                        if not text.strip():
                            continue
                        has_cjk = bool(cjk_re.search(text))
                        entries.append({
                            'id': entry_id,
                            'part': part,
                            'index': local_index - 1,
                            'granularity': 'text',
                            'text': text,
                            'hasCJK': has_cjk
                        })
                part_stats[part] = local_index
            media_count = len([n for n in names if n.startswith('ppt/media/') or n.startswith('word/media/') or n.startswith('xl/media/')])
            return entries, part_stats, media_count

        def parse_replacements(raw):
            id_map = {}
            text_map = {}
            if not raw:
                return id_map, text_map
            parsed = raw if isinstance(raw, (dict, list)) else json.loads(raw)
            if isinstance(parsed, dict):
                items = parsed.items()
                for key, value in items:
                    if value is None:
                        continue
                    value = str(value)
                    if '::' in str(key):
                        id_map[str(key)] = value
                    else:
                        text_map[str(key)] = value
                return id_map, text_map
            if isinstance(parsed, list):
                for item in parsed:
                    if not isinstance(item, dict):
                        continue
                    value = item.get('text', item.get('translation', item.get('newText', item.get('replacement'))))
                    if value is None:
                        continue
                    value = str(value)
                    entry_id = item.get('id')
                    old_text = item.get('sourceText', item.get('oldText', item.get('from')))
                    if entry_id:
                        id_map[str(entry_id)] = value
                    elif old_text:
                        text_map[str(old_text)] = value
                return id_map, text_map
            raise ValueError('translationsJSON 必须是对象或数组')

        def base_result(entries, media_count):
            cjk_count = sum(1 for e in entries if e['hasCJK'])
            warnings = []
            if media_count:
                warnings.append('检测到媒体文件；可编辑文本已覆盖，图片中文字需要 render/OCR 后单独处理。')
            return {
                'success': True,
                'action': action,
                'format': ext,
                'granularity': granularity,
                'sourcePath': source_path,
                'outputPath': output_path,
                'workflowPath': workflow_path,
                'totalTextRuns': len(entries),
                'cjkTextRuns': cjk_count,
                'mediaCount': media_count,
                'warnings': warnings
            }

        def emit(obj):
            sys.stdout.write(json.dumps(obj, ensure_ascii=False, indent=2))

        def copy_if_needed(src, dst):
            os.makedirs(os.path.dirname(dst) or '.', exist_ok=True)
            if os.path.abspath(src) != os.path.abspath(dst):
                shutil.copy2(src, dst)

        def script_text():
            return '''#!/usr/bin/env python3
        import json, os, re, sys, zipfile, xml.etree.ElementTree as ET

        CJK_RE = re.compile(r'[\\u3400-\\u9fff\\uf900-\\ufaff]')

        def is_text_node(node):
            return node.tag.endswith('}t') or node.tag == 't'

        def inspect(path):
            total = 0
            cjk = 0
            samples = []
            with zipfile.ZipFile(path) as z:
                for name in z.namelist():
                    if not name.endswith('.xml'):
                        continue
                    if not (name.startswith('ppt/') or name.startswith('word/') or name.startswith('xl/')):
                        continue
                    try:
                        root = ET.fromstring(z.read(name))
                    except Exception:
                        continue
                    for node in root.iter():
                        if not is_text_node(node):
                            continue
                        text = node.text or ''
                        if not text.strip():
                            continue
                        total += 1
                        if CJK_RE.search(text):
                            cjk += 1
                            if len(samples) < 20:
                                samples.append({'part': name, 'text': text})
            print(json.dumps({'path': path, 'totalTextRuns': total, 'remainingCJK': cjk, 'samples': samples}, ensure_ascii=False, indent=2))

        if __name__ == '__main__':
            if len(sys.argv) != 2:
                raise SystemExit('usage: verify_document.py <office-file>')
            inspect(sys.argv[1])
        '''

        def write_workflow(entries, media_count):
            if not workflow_path:
                raise ValueError('workspace 需要 workflowPath')
            os.makedirs(workflow_path, exist_ok=True)
            work_dir = os.path.join(workflow_path, 'work')
            scripts_dir = os.path.join(workflow_path, 'scripts')
            cache_dir = os.path.join(workflow_path, 'cache')
            rendered_dir = os.path.join(workflow_path, 'rendered')
            for path in (work_dir, scripts_dir, cache_dir, rendered_dir):
                os.makedirs(path, exist_ok=True)

            source_copy = os.path.join(work_dir, 'source' + os.path.splitext(source_path)[1])
            working_copy = os.path.join(work_dir, 'working' + os.path.splitext(source_path)[1])
            copy_if_needed(source_path, source_copy)
            if not os.path.exists(working_copy):
                copy_if_needed(source_path, working_copy)

            manifest = {
                'createdAt': datetime.datetime.utcnow().isoformat(timespec='seconds') + 'Z',
                'sourcePath': original_source_path,
                'sourceCopyPath': source_copy,
                'workingCopyPath': working_copy,
                'outputPath': output_path,
                'workflowPath': workflow_path,
                'format': ext,
                'granularity': granularity,
                'totalTextRuns': len(entries),
                'cjkTextRuns': sum(1 for e in entries if e['hasCJK']),
                'mediaCount': media_count,
                'recommendedLoop': [
                    'document.transform(action=prepare, sourcePath=<source>, outputPath=<target>, chunkIndex=n)',
                    'document.transform(action=apply, sourcePath=<source>, outputPath=<target>, translationsJSON=[...])',
                    'document.transform(action=verify, sourcePath=<target>, outputPath=<target>)',
                    'document.transform(action=render, sourcePath=<target>, outputPath=<target>, workflowPath=<workflow>)'
                ]
            }
            manifest_path = os.path.join(workflow_path, 'manifest.json')
            with open(manifest_path, 'w', encoding='utf-8') as fh:
                json.dump(manifest, fh, ensure_ascii=False, indent=2)

            verify_path = os.path.join(scripts_dir, 'verify_document.py')
            with open(verify_path, 'w', encoding='utf-8') as fh:
                fh.write(script_text())
            try:
                os.chmod(verify_path, 0o755)
            except Exception:
                pass

            readme_path = os.path.join(workflow_path, 'README.md')
            with open(readme_path, 'w', encoding='utf-8') as fh:
                fh.write('# Laicai document workflow\\n\\n')
                fh.write(
                    'This folder records a reproducible document-delivery run: source copy, '
                    'working copy, scripts, cache, rendered output, and manifest.\\n'
                )

            result = base_result(entries, media_count)
            result.update({
                'workflowPath': workflow_path,
                'workingCopyPath': working_copy,
                'manifestPath': manifest_path,
                'scriptsPath': scripts_dir,
                'verifyScriptPath': verify_path,
                'renderDir': rendered_dir,
                'complete': False,
                'nextAction': 'prepare'
            })
            return result

        def count_pdf_pages(path):
            try:
                with open(path, 'rb') as fh:
                    data = fh.read()
                return len(re.findall(rb'/Type\\s*/Page\\b', data))
            except Exception:
                return 0

        def find_soffice():
            candidates = [
                '/Applications/LibreOffice.app/Contents/MacOS/soffice',
                shutil.which('soffice'),
                shutil.which('libreoffice')
            ]
            for candidate in candidates:
                if candidate and os.path.exists(candidate):
                    return candidate
            return None

        def render_document():
            input_path = output_path if os.path.exists(output_path) else source_path
            out_dir = render_dir or os.path.join(workflow_path or os.path.dirname(input_path), 'rendered')
            os.makedirs(out_dir, exist_ok=True)
            soffice = find_soffice()
            if not soffice:
                raise RuntimeError('未找到 LibreOffice，无法渲染 Office 文档。请安装 LibreOffice 后重试，或跳过视觉/OCR 验证。')
            before = set(os.listdir(out_dir))
            proc = subprocess.run(
                [soffice, '--headless', '--convert-to', 'pdf', '--outdir', out_dir, input_path],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=180
            )
            if proc.returncode != 0:
                raise RuntimeError((proc.stderr or proc.stdout or 'LibreOffice render failed').strip())
            pdf_name = os.path.splitext(os.path.basename(input_path))[0] + '.pdf'
            pdf_path = os.path.join(out_dir, pdf_name)
            if not os.path.exists(pdf_path):
                created = [name for name in os.listdir(out_dir) if name not in before and name.lower().endswith('.pdf')]
                if created:
                    pdf_path = os.path.join(out_dir, created[0])
            if not os.path.exists(pdf_path):
                raise RuntimeError('LibreOffice 已运行但没有找到 PDF 输出。')
            result = {
                'success': True,
                'action': 'render',
                'format': ext,
                'sourcePath': source_path,
                'outputPath': input_path,
                'workflowPath': workflow_path,
                'renderDir': out_dir,
                'pdfPath': pdf_path,
                'renderedPages': count_pdf_pages(pdf_path),
                'complete': True,
                'stdout': proc.stdout.strip()[-1200:]
            }
            return result

        if action == 'render':
            emit(render_document())
            sys.exit(0)

        if action == 'copy':
            copy_if_needed(source_path, output_path)
            with zipfile.ZipFile(output_path) as z:
                entries, _, media_count = read_entries(z)
            result = base_result(entries, media_count)
            result['complete'] = True
            emit(result)
            sys.exit(0)

        with zipfile.ZipFile(source_path, 'r') as z:
            entries, part_stats, media_count = read_entries(z)
            result = base_result(entries, media_count)

            if action == 'workspace':
                emit(write_workflow(entries, media_count))
                sys.exit(0)

            if action in ('inspect', 'verify'):
                result['complete'] = result['cjkTextRuns'] == 0
                result['remainingCJK'] = result['cjkTextRuns']
                if action == 'inspect':
                    result['sampleEntries'] = entries[:20]
                emit(result)
                sys.exit(0)

            if action == 'prepare':
                filtered = [e for e in entries if (e['hasCJK'] or not only_chinese)]
                total_chunks = int(math.ceil(len(filtered) / float(chunk_size))) if filtered else 0
                start = chunk_index * chunk_size
                selected = filtered[start:start + chunk_size]
                result['chunkIndex'] = chunk_index
                result['chunkSize'] = chunk_size
                result['totalChunks'] = total_chunks
                result['returnedEntries'] = len(selected)
                result['entries'] = selected
                result['nextChunkIndex'] = chunk_index + 1 if chunk_index + 1 < total_chunks else None
                result['complete'] = len(filtered) == 0
                emit(result)
                sys.exit(0)

            if action != 'apply':
                raise ValueError(f'未知 action: {action}')

            id_map, text_map = parse_replacements(translations_json)
            if not id_map and not text_map:
                raise ValueError('apply 需要 translationsJSON/replacementsJSON')

            replacements_applied = 0
            changed_parts = {}
            remaining_cjk = 0
            base_path = output_path if os.path.exists(output_path) else source_path
            with zipfile.ZipFile(base_path, 'r') as base_z:
                parts = supported_parts(base_z.namelist())
                for part in parts:
                    try:
                        root = ET.fromstring(base_z.read(part))
                    except Exception:
                        continue
                    changed = False
                    if granularity == 'paragraph' and ext in ('pptx', 'docx'):
                        local_index = 0
                        for node in root.iter():
                            if not is_paragraph_node(node):
                                continue
                            original = paragraph_text(node)
                            entry_id = f'{part}::p{local_index}'
                            local_index += 1
                            replacement = id_map.get(entry_id)
                            if replacement is None:
                                replacement = text_map.get(original)
                            if replacement is not None:
                                if set_paragraph_text(node, replacement):
                                    original = replacement
                                    replacements_applied += 1
                                    changed = True
                            if original.strip() and cjk_re.search(original):
                                remaining_cjk += 1
                    else:
                        local_index = 0
                        for node in root.iter():
                            if not is_text_node(node):
                                continue
                            original = node_text(node)
                            entry_id = f'{part}::{local_index}'
                            local_index += 1
                            replacement = id_map.get(entry_id)
                            if replacement is None:
                                replacement = text_map.get(original)
                            if replacement is not None:
                                node.text = replacement
                                original = replacement
                                replacements_applied += 1
                                changed = True
                            if original.strip() and cjk_re.search(original):
                                remaining_cjk += 1
                    if changed:
                        changed_parts[part] = ET.tostring(root, encoding='utf-8', xml_declaration=True)

            os.makedirs(os.path.dirname(output_path) or '.', exist_ok=True)
            fd, temp_path = tempfile.mkstemp(prefix='laicai_doc_', suffix='.' + ext)
            os.close(fd)
            try:
                with zipfile.ZipFile(base_path, 'r') as zin, zipfile.ZipFile(temp_path, 'w', compression=zipfile.ZIP_DEFLATED) as zout:
                    for info in zin.infolist():
                        data = changed_parts.get(info.filename)
                        if data is None:
                            data = zin.read(info.filename)
                        zi = copy.copy(info)
                        zi.file_size = len(data)
                        zi.CRC = 0
                        zout.writestr(zi, data)
                if os.path.abspath(source_path) == os.path.abspath(output_path):
                    os.replace(temp_path, output_path)
                else:
                    shutil.move(temp_path, output_path)
            finally:
                if os.path.exists(temp_path):
                    os.remove(temp_path)

            result['appliedReplacements'] = replacements_applied
            result['remainingCJK'] = remaining_cjk
            result['changedParts'] = len(changed_parts)
            result['complete'] = remaining_cjk == 0
            emit(result)
        """#
}
