import Foundation
import LaicaiNativeDomain

// MARK: - Git Tool

public struct GitTool: LaicaiTool {
    public var name: String { "git" }
    public var description: String { "执行 git 操作（diff, status, log, branch, add, commit 等）" }

    private static let readOnlySubcommands = ["diff", "status", "log", "branch", "show", "stash list", "remote", "tag"]
    private static let safeWriteSubcommands = ["add", "commit", "commit-auto", "checkout", "switch", "branch-create", "pr-desc"]
    private static let dangerousPatterns = ["push --force", "reset --hard", "clean -fd", "clean -xdf", "rebase", "push -f"]

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "subcommand": FunctionProperty(
                        type: "string",
                        description: "git 子命令（diff, status, log, add, commit, commit-auto, checkout, branch-create, pr-desc 等）"
                    ),
                    "args": FunctionProperty(
                        type: "string",
                        description: "子命令参数。commit 时传 -m \"message\"；commit-auto 留空自动生成信息；branch-create 传分支名；pr-desc 自动生成 PR 描述"
                    )
                ],
                required: ["subcommand"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var subcommand: String
            var args: String?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let subcommand = params.subcommand
        let args = params.args ?? ""
        let fullCommand = "git \(subcommand) \(args)".trimmingCharacters(in: .whitespaces)
        let root = context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)

        if Self.requiresRepository(subcommand), !Self.isGitRepository(root) {
            let message = root.isEmpty
                ? "当前没有设置工作区，无法执行 git \(subcommand)。"
                : "当前工作区不是 git 仓库：\(root)。可以继续用文件搜索和读取工具完成任务。"
            await AuditLog.shared.record(
                tool: name,
                input: fullCommand,
                output: message,
                success: true
            )
            return ToolResult(
                output: message,
                data: ["command": fullCommand, "repository": "false"],
                success: true
            )
        }

        // Dangerous command guard
        let fullCmd = "git \(subcommand) \(args)"
        if Self.dangerousPatterns.contains(where: { fullCmd.contains($0) })
            || DangerousOperationGuard.shellViolation(command: fullCmd) != nil {
            return ToolResult(
                output: "安全拦截：\(fullCmd) 是破坏性操作，不允许自动执行。请手动确认后再处理。",
                data: ["command": fullCmd, "blocked": "true"],
                success: false,
                error: "dangerous_command"
            )
        }

        if subcommand == "commit-auto" {
            return try await Self.commitAuto(messageHint: args, context: context)
        }

        if subcommand == "branch-create" {
            return try await Self.branchCreate(name: args, context: context)
        }

        if subcommand == "pr-desc" {
            return try await Self.generatePRDescription(context: context)
        }

        if Self.isSafeWrite(subcommand) {
            // Safe writes (add, commit) execute directly
            let shellParams = ["command": fullCommand, "timeout": "30"]
            return try await ShellTool().execute(params: shellParams, context: context)
        }

        if !Self.isReadOnly(subcommand) {
            // Other write operations need review
            return ToolResult(
                output: "写操作需审查：\(fullCommand)",
                data: ["command": fullCommand, "needsReview": "true"],
                success: true
            )
        }

        let shellParams = ["command": fullCommand, "timeout": "15"]
        return try await ShellTool().execute(params: shellParams, context: context)
    }

    private static func isReadOnly(_ subcommand: String) -> Bool {
        readOnlySubcommands.contains { subcommand.hasPrefix($0) }
    }

    private static func isSafeWrite(_ subcommand: String) -> Bool {
        safeWriteSubcommands.contains { subcommand.hasPrefix($0) }
    }

    private static func requiresRepository(_ subcommand: String) -> Bool {
        let clean = subcommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["diff", "status", "log", "branch", "show", "stash", "remote", "tag", "add", "commit", "commit-auto", "checkout"]
            .contains { clean.hasPrefix($0) }
    }

    private static func commitAuto(messageHint: String, context: TaskContext) async throws -> ToolResult {
        let statusResult = try await ShellTool().execute(params: ["command": "git status --short", "timeout": "15"], context: context)
        guard statusResult.success else { return statusResult }
        let statusLines = statusResult.output.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !statusLines.isEmpty else {
            return ToolResult(output: "没有可提交的变更。", data: ["exitCode": "0"], success: true)
        }
        let message = messageHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.generateCommitMessage(fromStatusLines: statusLines)
            : messageHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedMessage = message.replacingOccurrences(of: "\"", with: "\\\"")
        let changedFiles = statusLines.compactMap(Self.pathFromStatusLine)
        guard !changedFiles.isEmpty else {
            return ToolResult(output: "没有可提交的文件路径。", data: ["exitCode": "0"], success: true)
        }
        let files = changedFiles.map(Self.shellEscape).joined(separator: " ")
        let command = "git add -- \(files) && git commit -m \"\(escapedMessage)\""
        let result = try await ShellTool().execute(params: ["command": command, "timeout": "60"], context: context)
        var data = result.data ?? [:]
        data["message"] = message
        return ToolResult(output: result.output, data: data, success: result.success, error: result.error)
    }

    static func pathFromStatusLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 3 else { return nil }
        let rawPath = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        let path = rawPath.components(separatedBy: " -> ").last ?? rawPath
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPath.isEmpty ? nil : trimmedPath
    }

    private static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func generateCommitMessage(fromStatusLines lines: [String]) -> String {
        let changedFiles = lines.compactMap(pathFromStatusLine)
        let lower = changedFiles.joined(separator: " ").lowercased()
        let scope: String
        if lower.contains("test") {
            scope = "test"
        } else if lower.contains("ui") || lower.contains("view") {
            scope = "ui"
        } else if lower.contains("tool") || lower.contains("agent") {
            scope = "agent"
        } else {
            scope = "app"
        }
        let verb = lines.contains { $0.hasPrefix("A ") || $0.hasPrefix("??") } ? "add" : "update"
        return "\(verb)(\(scope)): refine \(changedFiles.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))"
    }

    private static func branchCreate(name: String, context: TaskContext) async throws -> ToolResult {
        let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branchName.isEmpty else {
            return ToolResult(output: "请提供分支名称", success: false, error: "missing_branch_name")
        }
        // Sanitize branch name
        let sanitized = branchName.replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "-_/.")).inverted)
            .joined()
        let command = "git checkout -b \(sanitized)"
        let result = try await ShellTool().execute(params: ["command": command, "timeout": "15"], context: context)
        var data = result.data ?? [:]
        data["branch"] = sanitized
        return ToolResult(output: result.output, data: data, success: result.success, error: result.error)
    }

    private static func generatePRDescription(context: TaskContext) async throws -> ToolResult {
        // Get diff against main/master
        let branchResult = try await ShellTool().execute(params: ["command": "git rev-parse --abbrev-ref HEAD", "timeout": "10"], context: context)
        let currentBranch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try main, then master as base
        var base = "main"
        let checkMain = try await ShellTool().execute(params: ["command": "git rev-parse --verify main 2>/dev/null", "timeout": "10"], context: context)
        if !checkMain.success {
            base = "master"
        }

        let diffResult = try await ShellTool().execute(params: ["command": "git log \(base)..HEAD --oneline", "timeout": "15"], context: context)
        let commits = diffResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        let statResult = try await ShellTool().execute(params: ["command": "git diff \(base)..HEAD --stat", "timeout": "15"], context: context)
        let stat = statResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Get changed file list for categorization
        let filesResult = try await ShellTool().execute(params: ["command": "git diff \(base)..HEAD --name-only", "timeout": "15"], context: context)
        let changedFiles = filesResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").filter { !$0.isEmpty }

        // Categorize changed files
        var sourceFiles: [String] = []
        var testFiles: [String] = []
        var configFiles: [String] = []
        var otherFiles: [String] = []
        for file in changedFiles {
            let lower = file.lowercased()
            let isTestFile = lower.contains("/test")
                || lower.contains("/tests/")
                || lower.hasSuffix("test.swift")
                || lower.hasSuffix(".test.ts")
                || lower.hasSuffix(".spec.ts")
                || lower.hasSuffix("_test.go")
                || lower.hasSuffix("_test.py")
            let isSourceFile = lower.hasSuffix(".swift")
                || lower.hasSuffix(".py")
                || lower.hasSuffix(".ts")
                || lower.hasSuffix(".js")
                || lower.hasSuffix(".go")
                || lower.hasSuffix(".rs")
            let isConfigFile = lower.hasSuffix(".json")
                || lower.hasSuffix(".toml")
                || lower.hasSuffix(".yaml")
                || lower.hasSuffix(".yml")
                || lower.hasSuffix(".xml")
                || (lower.hasSuffix(".swift") && lower.contains("package"))
                || lower.contains("package.")
                || lower.contains("tsconfig")
                || lower.contains(".env")
                || lower.contains("dockerfile")
                || lower.contains("makefile")
            if isTestFile {
                testFiles.append(file)
            } else if isSourceFile {
                sourceFiles.append(file)
            } else if isConfigFile {
                configFiles.append(file)
            } else {
                otherFiles.append(file)
            }
        }

        // Detect potential breaking changes
        var breakingChangeHints: [String] = []
        let diffContentResult = try await ShellTool().execute(params: ["command": "git diff \(base)..HEAD -- '*.swift' '*.py' '*.ts' '*.js' '*.go' | head -200", "timeout": "15"], context: context)
        let diffContent = diffContentResult.output
        if diffContent.contains("-public ") && !diffContent.contains("+public ") {
            breakingChangeHints.append("移除了 public API")
        }
        if diffContent.contains("-protocol ") || diffContent.contains("-interface ") {
            breakingChangeHints.append("移除了协议/接口定义")
        }
        if diffContent.contains("-func ") && diffContent.contains("+func ") {
            breakingChangeHints.append("函数签名可能变更")
        }

        let title = currentBranch.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        var description = "## \(title)\n\n"
        description += "### 变更概览\n\(stat)\n\n"

        if !sourceFiles.isEmpty {
            description += "### 源文件变更（\(sourceFiles.count)）\n"
            for file in sourceFiles.prefix(20) { description += "- `\(file)`\n" }
            description += "\n"
        }
        if !testFiles.isEmpty {
            description += "### 测试文件变更（\(testFiles.count)）\n"
            for file in testFiles.prefix(10) { description += "- `\(file)`\n" }
            description += "\n"
        }
        if !configFiles.isEmpty {
            description += "### 配置文件变更（\(configFiles.count)）\n"
            for file in configFiles.prefix(10) { description += "- `\(file)`\n" }
            description += "\n"
        }

        if !breakingChangeHints.isEmpty {
            description += "### ⚠️ 潜在破坏性变更\n"
            for hint in breakingChangeHints { description += "- \(hint)\n" }
            description += "\n"
        }

        description += "### 提交记录\n\(commits)\n"
        let commitCount = commits.components(separatedBy: "\n").filter { !$0.isEmpty }.count

        return ToolResult(
            output: description,
            data: [
                "branch": currentBranch,
                "base": base,
                "commitCount": "\(commitCount)",
                "sourceFileCount": "\(sourceFiles.count)",
                "testFileCount": "\(testFiles.count)",
                "configFileCount": "\(configFiles.count)",
                "hasBreakingChanges": "\(breakingChangeHints.isEmpty ? "false" : "true")"
            ],
            success: true
        )
    }

    public static func isGitRepository(_ workspaceRoot: String) -> Bool {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, FileManager.default.fileExists(atPath: root) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--is-inside-work-tree"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - ComfyUI Image Generation Tool

public struct ComfyUITool: LaicaiTool {
    private let session: URLSession
    private let prefersCurlTransport: Bool

    public init(session: URLSession = NetworkDefaults.imageSession, prefersCurlTransport: Bool = true) {
        self.session = session
        self.prefersCurlTransport = prefersCurlTransport
    }

    public var name: String { "image.generate" }
    public var description: String { "根据文字描述生成图片。优先使用当前图片模型连接器，否则使用本地 ComfyUI。" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "prompt": FunctionProperty(type: "string", description: "图片的文字描述，尽量详细，包括风格、构图、色彩等"),
                    "negativePrompt": FunctionProperty(type: "string", description: "不想出现的内容描述（可选）"),
                    "width": FunctionProperty(type: "integer", description: "图片宽度（可选，默认 1024）"),
                    "height": FunctionProperty(type: "integer", description: "图片高度（可选，默认 1024）"),
                    "steps": FunctionProperty(type: "integer", description: "采样步数（可选，默认 20）"),
                    "seed": FunctionProperty(type: "integer", description: "随机种子（可选，默认 -1 随机）")
                ],
                required: ["prompt"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        let params: ImageGenerationParams
        do {
            params = try Self.decodeImageGenerationParams(argumentsJSON)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let width = max(256, min(params.width ?? 1024, 2048))
        let height = max(256, min(params.height ?? 1024, 2048))
        let imageModel = (context.imageGenerationModelName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let imageEndpoint = (context.imageGenerationEndpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if ConnectorCapabilityProfile.isImageOnlyModel(imageModel), !imageEndpoint.isEmpty {
            do {
                let imagePath = try await generateOpenAICompatibleImage(
                    endpoint: imageEndpoint,
                    apiKey: context.imageGenerationAPIKey ?? "",
                    modelName: imageModel,
                    prompt: params.prompt,
                    size: params.size ?? Self.openAIImageSize(width: width, height: height),
                    outputDir: context.workspaceRoot
                )

                await AuditLog.shared.record(
                    tool: name,
                    input: params.prompt,
                    output: "生成图片：\(imagePath)",
                    success: true
                )

                return ToolResult(
                    output: "图片已生成：\(imagePath)",
                    data: ["imagePath": imagePath, "prompt": params.prompt, "provider": "images_api", "model": imageModel],
                    success: true
                )
            } catch {
                return ToolResult(
                    output: "图片生成失败：\(Self.friendlyImageError(error))",
                    success: false,
                    error: "images_api_error"
                )
            }
        }

        let serverURL = context.comfyUIServerURL ?? "http://127.0.0.1:8188"
        let modelName = context.comfyUIModelName ?? ""
        guard await isServerReachable(serverURL) else {
            return ToolResult(
                output: "没有可用的图片生成服务。请选择图片模型连接器，或启动 ComfyUI（默认地址 \(serverURL)）后再生成图片。",
                success: false,
                error: "image_backend_missing"
            )
        }

        if modelName.isEmpty {
            return ToolResult(
                output: "未配置 ComfyUI 模型。请先在设置中填写模型名称（checkpoint 文件名）。",
                success: false,
                error: "comfyui_model_missing"
            )
        }

        do {
            let comfyRequest = ComfyImageGenerationRequest(
                serverURL: serverURL,
                modelName: modelName,
                prompt: params.prompt,
                negativePrompt: params.negativePrompt ?? "",
                width: width,
                height: height,
                steps: max(1, min(params.steps ?? 20, 50)),
                seed: params.seed ?? -1,
                outputDir: context.workspaceRoot
            )
            let imagePath = try await generateImage(comfyRequest)

            await AuditLog.shared.record(
                tool: name,
                input: params.prompt,
                output: "生成图片：\(imagePath)",
                success: true
            )

            return ToolResult(
                output: "图片已生成：\(imagePath)",
                data: ["imagePath": imagePath, "prompt": params.prompt],
                success: true
            )
        } catch {
            return ToolResult(
                output: "图片生成失败：\(error.localizedDescription)",
                success: false,
                error: "comfyui_error"
            )
        }
    }

    private func isServerReachable(_ url: String) async -> Bool {
        guard let url = URL(string: "\(url)/system_stats") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkDefaults.quickProbe
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private struct ImagesAPIRequest: Encodable {
        var model: String
        var prompt: String
        var count: Int
        var size: String
        var responseFormat: String?
        var returnBase64: Bool?

        enum CodingKeys: String, CodingKey {
            case model
            case prompt
            case count = "n"
            case size
            case responseFormat = "response_format"
            case returnBase64 = "return_base64"
        }
    }

    private struct ImagesAPIResponse: Decodable {
        struct Item: Decodable {
            var base64JSON: String?
            var url: String?

            enum CodingKeys: String, CodingKey {
                case base64JSON = "b64_json"
                case url
            }
        }
        var data: [Item]
    }

    private struct ImageGenerationParams {
        var prompt: String
        var negativePrompt: String?
        var width: Int?
        var height: Int?
        var steps: Int?
        var seed: Int?
        var size: String?
    }

    private static func decodeImageGenerationParams(_ argumentsJSON: String) throws -> ImageGenerationParams {
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw NSError(domain: "ImageGenerateParams", code: 1, userInfo: [NSLocalizedDescriptionKey: "参数必须是 JSON 对象"])
        }
        guard let prompt = stringValue(dict["prompt"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            throw NSError(domain: "ImageGenerateParams", code: 2, userInfo: [NSLocalizedDescriptionKey: "缺少 prompt"])
        }
        return ImageGenerationParams(
            prompt: prompt,
            negativePrompt: stringValue(dict["negativePrompt"]),
            width: intValue(dict["width"]),
            height: intValue(dict["height"]),
            steps: intValue(dict["steps"]),
            seed: intValue(dict["seed"]),
            size: stringValue(dict["size"])
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private func generateOpenAICompatibleImage(
        endpoint: String,
        apiKey: String,
        modelName: String,
        prompt: String,
        size: String,
        outputDir: String
    ) async throws -> String {
        let url = try Self.imagesGenerationURL(from: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let usesAgnesImageAPI = Self.usesAgnesImageAPI(modelName: modelName)
        let body = ImagesAPIRequest(
            model: modelName,
            prompt: prompt,
            count: 1,
            size: size,
            responseFormat: usesAgnesImageAPI ? nil : "b64_json",
            returnBase64: usesAgnesImageAPI ? true : nil
        )
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = NetworkDefaults.imageRequest

        let (data, response): (Data, URLResponse)
        if prefersCurlTransport, Self.canUseCurlTransport(for: url) {
            data = try await performImagesAPICurlRequest(
                url: url,
                apiKey: apiKey,
                body: request.httpBody ?? Data()
            )
            response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-Laicai-Transport": "curl"]
            ) ?? URLResponse(url: url, mimeType: "application/json", expectedContentLength: data.count, textEncodingName: "utf-8")
        } else {
            (data, response) = try await performImagesAPIRequest(request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "ImagesAPI",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: Self.serverMessage(from: body, fallback: "图片服务返回 HTTP \(status)")]
            )
        }

        let decoded = try JSONDecoder().decode(ImagesAPIResponse.self, from: data)
        guard let first = decoded.data.first else {
            throw NSError(domain: "ImagesAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "图片服务没有返回图片"])
        }

        let imageData: Data
        if let base64JSON = first.base64JSON, let decodedData = Data(base64Encoded: base64JSON) {
            imageData = decodedData
        } else if let urlString = first.url, let url = URL(string: urlString) {
            let (downloaded, downloadResponse) = try await session.data(from: url)
            if let status = (downloadResponse as? HTTPURLResponse)?.statusCode,
               !(200...299).contains(status) {
                throw NSError(domain: "ImagesAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "图片下载失败"])
            }
            imageData = downloaded
        } else {
            throw NSError(domain: "ImagesAPI", code: 3, userInfo: [NSLocalizedDescriptionKey: "图片服务返回格式不兼容"])
        }

        return try Self.saveImageData(imageData, outputDir: outputDir, prefix: "laicai_image_api")
    }

    private static func imagesGenerationURL(from endpoint: String) throws -> URL {
        let cleaned = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleaned), url.host != nil else { throw URLError(.badURL) }
        let originalPath = url.path
        var path = originalPath
        if path.hasSuffix("/chat/completions") {
            path = String(path.dropLast("/chat/completions".count))
        }
        if path.hasSuffix("/responses") {
            path = String(path.dropLast("/responses".count))
        }
        if path.hasSuffix("/images/generations") {
            return url
        }
        if path.isEmpty || path == "/" {
            path = "/v1"
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = cleaned.hasSuffix("/") ? String(cleaned.dropLast()) : cleaned
        let baseWithoutKnownPath: String
        if let range = base.range(of: originalPath, options: .backwards), !originalPath.isEmpty {
            baseWithoutKnownPath = String(base[..<range.lowerBound])
        } else {
            baseWithoutKnownPath = base
        }
        let joinedPath = path.hasSuffix("v1") ? "\(path)/images/generations" : "v1/images/generations"
        guard let finalURL = URL(string: "\(baseWithoutKnownPath)/\(joinedPath)") else { throw URLError(.badURL) }
        return finalURL
    }

    private static func openAIImageSize(width: Int, height: Int) -> String {
        if width == height { return "1024x1024" }
        return width > height ? "1536x1024" : "1024x1536"
    }

    private static func usesAgnesImageAPI(modelName: String) -> Bool {
        modelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .hasPrefix("agnes-image")
    }

    private func performImagesAPIRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            guard Self.shouldRetryImagesAPIRequest(after: error) else { throw error }
            try await Task.sleep(for: .seconds(2))
            return try await session.data(for: request)
        }
    }

    private func performImagesAPICurlRequest(url: URL, apiKey: String, body: Data) async throws -> Data {
        let result = try await Self.runCurlImagesRequest(url: url, apiKey: apiKey, body: body)
        guard result.exitCode == 0 else {
            let message = result.stderr.isEmpty ? "curl 退出码 \(result.exitCode)" : result.stderr
            throw NSError(domain: "ImagesAPICurl", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard (200...299).contains(result.statusCode) else {
            throw NSError(
                domain: "ImagesAPI",
                code: result.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: Self.serverMessage(
                        from: String(data: result.data, encoding: .utf8) ?? "",
                        fallback: "图片服务返回 HTTP \(result.statusCode)"
                    )
                ]
            )
        }
        return result.data
    }

    private static func canUseCurlTransport(for url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return FileManager.default.isExecutableFile(atPath: "/usr/bin/curl")
    }

    private struct CurlImagesResponse {
        let data: Data
        let statusCode: Int
        let stderr: String
        let exitCode: Int32
    }

    private static func runCurlImagesRequest(url: URL, apiKey: String, body: Data) async throws -> CurlImagesResponse {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("laicai-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bodyURL = tempRoot.appendingPathComponent("request.json")
        let configURL = tempRoot.appendingPathComponent("curl.conf")
        let responseURL = tempRoot.appendingPathComponent("response.json")
        try body.write(to: bodyURL, options: .atomic)
        let config = curlConfig(
            url: url,
            apiKey: apiKey,
            bodyPath: bodyURL.path,
            responsePath: responseURL.path
        )
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--config", configURL.path]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        let timedOut = await waitForCurlExit(process, timeoutSeconds: Int(NetworkDefaults.imageRequest) + 10)
        if timedOut {
            process.terminate()
            process.waitUntilExit()
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if timedOut {
            throw NSError(domain: "ImagesAPICurl", code: Int(NSURLErrorTimedOut), userInfo: [NSLocalizedDescriptionKey: "curl 图片请求超时"])
        }

        let codeText = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let responseData = (try? Data(contentsOf: responseURL)) ?? Data()
        return CurlImagesResponse(
            data: responseData,
            statusCode: Int(codeText) ?? 0,
            stderr: stderr,
            exitCode: process.terminationStatus
        )
    }

    private static func curlConfig(url: URL, apiKey: String, bodyPath: String, responsePath: String) -> String {
        var lines = [
            "silent",
            "show-error",
            "http1.1",
            "connect-timeout = \"15\"",
            "max-time = \"\(Int(NetworkDefaults.imageRequest))\"",
            "request = \"POST\"",
            "header = \"Content-Type: application/json\""
        ]
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            lines.append("header = \"Authorization: Bearer \(curlConfigEscape(trimmedKey))\"")
        }
        lines += [
            "data-binary = \"@\(curlConfigEscape(bodyPath))\"",
            "output = \"\(curlConfigEscape(responsePath))\"",
            "write-out = \"%{http_code}\"",
            "url = \"\(curlConfigEscape(url.absoluteString))\""
        ]
        return lines.joined(separator: "\n")
    }

    private static func curlConfigEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func waitForCurlExit(_ process: Process, timeoutSeconds: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let finished = Locked(false)
            process.terminationHandler = { _ in
                let shouldResume = finished.withValue { value in
                    guard !value else { return false }
                    value = true
                    return true
                }
                if shouldResume {
                    continuation.resume(returning: false)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                let shouldResume = finished.withValue { value in
                    guard !value else { return false }
                    value = true
                    return true
                }
                if shouldResume {
                    continuation.resume(returning: true)
                }
            }
        }
    }

    private static func saveImageData(_ data: Data, outputDir: String, prefix: String) throws -> String {
        let root = outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = root.isEmpty ? FileManager.default.temporaryDirectory.path : root
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let filename = "\(prefix)_\(Self.timestampString()).png"
        let path = (directory as NSString).appendingPathComponent(filename)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func serverMessage(from body: String, fallback: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return body.isEmpty ? fallback : "\(fallback)：\(String(body.prefix(300)))"
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = json["message"] as? String {
            return message
        }
        return fallback
    }

    private static func friendlyImageError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return "图片服务响应超时。已等待 \(Int(NetworkDefaults.imageRequest)) 秒并自动重试；如果仍失败，通常是上游图片网关排队太久或暂时不可用。"
        }
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNetworkConnectionLost {
            return "图片服务连接中途断开。请求已正确发送到图片接口，但上游网关在生成过程中断开了连接；来财已自动重试一次，仍失败时请稍后重试或更换图片网关。"
        }
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCannotConnectToHost {
            return "无法连接图片服务。请检查图片连接器端点、代理或当前网络后重试。"
        }
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet {
            return "当前网络不可用，无法连接图片服务。"
        }
        return error.localizedDescription
    }

    private static func shouldRetryImagesAPIRequest(after error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed
        ].contains(nsError.code)
    }

    private struct ComfyImageGenerationRequest {
        let serverURL: String
        let modelName: String
        let prompt: String
        let negativePrompt: String
        let width: Int
        let height: Int
        let steps: Int
        let seed: Int
        let outputDir: String
    }

    private func generateImage(_ request: ComfyImageGenerationRequest) async throws -> String {
        let serverURL = request.serverURL
        let modelName = request.modelName
        let prompt = request.prompt
        let negativePrompt = request.negativePrompt
        let width = request.width
        let height = request.height
        let steps = request.steps
        let seed = request.seed
        let outputDir = request.outputDir
        let clientId = "laicai-\(UUID().uuidString.prefix(8))"

        // Build a basic text-to-image workflow
        let workflow: [String: [String: Any]] = [
            "3": [
                "class_type": "KSampler",
                "inputs": [
                    "cfg": 7,
                    "denoise": 1,
                    "latent_image": ["5", 0] as [Any],
                    "model": ["4", 0] as [Any],
                    "negative": ["7", 0] as [Any],
                    "positive": ["6", 0] as [Any],
                    "sampler_name": "euler",
                    "scheduler": "normal",
                    "seed": seed == -1 ? Int.random(in: 0...Int.max) : seed,
                    "steps": steps
                ] as [String: Any]
            ],
            "4": [
                "class_type": "CheckpointLoaderSimple",
                "inputs": ["ckpt_name": modelName] as [String: Any]
            ],
            "5": [
                "class_type": "EmptyLatentImage",
                "inputs": ["batch_size": 1, "height": height, "width": width] as [String: Any]
            ],
            "6": [
                "class_type": "CLIPTextEncode",
                "inputs": [
                    "clip": ["4", 1] as [Any],
                    "text": prompt
                ] as [String: Any]
            ],
            "7": [
                "class_type": "CLIPTextEncode",
                "inputs": [
                    "clip": ["4", 1] as [Any],
                    "text": negativePrompt
                ] as [String: Any]
            ],
            "8": [
                "class_type": "VAEDecode",
                "inputs": [
                    "samples": ["3", 0] as [Any],
                    "vae": ["4", 2] as [Any]
                ] as [String: Any]
            ],
            "9": [
                "class_type": "SaveImage",
                "inputs": [
                    "filename_prefix": "Laicai",
                    "images": ["8", 0] as [Any]
                ] as [String: Any]
            ]
        ]

        // Submit prompt
        let promptData = try JSONSerialization.data(withJSONObject: [
            "prompt": workflow,
            "client_id": clientId
        ] as [String: Any])
        guard let promptURL = URL(string: "\(serverURL)/prompt") else {
            throw URLError(.badURL)
        }
        var submitRequest = URLRequest(url: promptURL)
        submitRequest.httpMethod = "POST"
        submitRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submitRequest.httpBody = promptData
        submitRequest.timeoutInterval = NetworkDefaults.imageRequest

        let (submitData, submitResponse) = try await session.data(for: submitRequest)
        guard (submitResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "ComfyUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "提交失败"])
        }
        guard let submitJSON = try JSONSerialization.jsonObject(with: submitData) as? [String: Any],
              let promptId = submitJSON["prompt_id"] as? String else {
            throw NSError(domain: "ComfyUI", code: 2, userInfo: [NSLocalizedDescriptionKey: "未获取到 prompt_id"])
        }

        // Poll for completion
        var imageFilename: String?
        let historyURL = URL(string: "\(serverURL)/history/\(promptId)")!
        let start = Date()
        while Date().timeIntervalSince(start) < 300 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            var pollRequest = URLRequest(url: historyURL)
            pollRequest.timeoutInterval = 10
            let historyResult: (Data, URLResponse)?
            do {
                historyResult = try await session.data(for: pollRequest)
            } catch {
                continue
            }
            guard let (historyData, _) = historyResult,
                  let historyJSON = try? JSONSerialization.jsonObject(with: historyData) as? [String: Any],
                  let entry = historyJSON[promptId] as? [String: Any] else { continue }

            if let outputs = entry["outputs"] as? [String: Any],
               let saveImage = outputs["9"] as? [String: Any],
               let images = saveImage["images"] as? [[String: Any]],
               let first = images.first,
               let filename = first["filename"] as? String {
                imageFilename = filename
                break
            }

            if let status = entry["status"] as? [String: Any],
               let completed = status["completed"] as? Bool,
               completed,
               status["execution_error"] != nil {
                throw NSError(domain: "ComfyUI", code: 3, userInfo: [NSLocalizedDescriptionKey: "生成过程中发生错误"])
            }
        }

        guard let filename = imageFilename else {
            throw NSError(domain: "ComfyUI", code: 4, userInfo: [NSLocalizedDescriptionKey: "生成超时或失败"])
        }

        // Download image
        let viewURL = URL(string: "\(serverURL)/view?filename=\(filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename)&type=output")!
        var viewRequest = URLRequest(url: viewURL)
        viewRequest.timeoutInterval = NetworkDefaults.imageRequest
        let (imageData, viewResponse) = try await session.data(for: viewRequest)
        guard (viewResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "ComfyUI", code: 5, userInfo: [NSLocalizedDescriptionKey: "下载图片失败"])
        }

        // Save to workspace
        let outputPath = (outputDir as NSString).appendingPathComponent("laicai_generated_\(filename)")
        try imageData.write(to: URL(fileURLWithPath: outputPath))
        return outputPath
    }
}
