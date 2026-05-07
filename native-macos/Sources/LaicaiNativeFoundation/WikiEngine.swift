import Foundation
import LaicaiNativeDomain

public struct WikiSource: Equatable, Sendable {
    public var path: String
    public var title: String
    public var preview: String
    public var kind: String
}

public enum WikiMode: String, Codable, Sendable {
    case atomic  // One concept per file → 02 Atomic/
    case moc     // Map of Content index → 03 MOC/
    case topic   // Legacy: big overview page → 03 MOC/ (backward compat)
}

public struct WikiBuildResult: Sendable, Identifiable {
    public let id: UUID = UUID()
    public var topic: String
    public var notePath: String
    public var renderedMarkdown: String
    public var previousMarkdown: String?
    public var sources: [WikiSource]
    public var saved: Bool
    public var mode: WikiMode
    public var backlinksAdded: [String] = []
    public var mocUpdated: String?
    public var saveError: String?

    public static func == (lhs: WikiBuildResult, rhs: WikiBuildResult) -> Bool {
        lhs.topic == rhs.topic && lhs.notePath == rhs.notePath && lhs.saved == rhs.saved
    }

    public var diffSummary: String {
        guard let previousMarkdown else { return mode == .atomic ? "新建原子笔记" : "新建索引页" }
        let oldLines = previousMarkdown.components(separatedBy: .newlines).count
        let newLines = renderedMarkdown.components(separatedBy: .newlines).count
        return "更新（原 \(oldLines) 行 → 新 \(newLines) 行）"
    }
}

public enum WikiEngine {
    /// Recent wiki build results, persisted in memory for the session
    public private(set) static var recentResults: [WikiBuildResult] = []

    /// Build a wiki note using LLM synthesis with knowledge-graph approach.
    /// mode=.atomic → concept-per-file in 02 Atomic/
    /// mode=.moc → index page in 03 MOC/
    public static func buildTopic(
        topic: String,
        vaultRoot: String,
        save: Bool,
        mode: WikiMode = .atomic,
        useWeb: Bool = false,
        topK: Int = 8,
        connector: ConnectorProfile? = nil,
        runtime: (any ChatRuntimeClient)? = nil,
        onChunk: (@Sendable @MainActor (String) -> Void)? = nil
    ) async -> WikiBuildResult {
        let cleanTopic = sanitizedTopic(topic)
        let root = URL(fileURLWithPath: vaultRoot)

        // Determine target directory based on mode
        let subdir: String
        switch mode {
        case .atomic: subdir = "02 Atomic"
        case .moc, .topic: subdir = "03 MOC"
        }
        let noteURL = root
            .appendingPathComponent(subdir, isDirectory: true)
            .appendingPathComponent(cleanTopic + ".md")
        let previous = try? String(contentsOf: noteURL, encoding: .utf8)
        var sources = collectVaultSources(topic: cleanTopic, vaultRoot: root, limit: topK)

        // Scan vault for existing pages to build backlinks
        let existingPages = scanVaultPages(root: root)

        if useWeb {
            let web = try? await WebSearchTool().execute(
                argumentsJSON: #"{"query":"\#(cleanTopic) 最新","maxResults":3}"#,
                context: TaskContext(workspaceRoot: vaultRoot)
            )
            if let web, web.success {
                sources.append(contentsOf: parseWebSources(web.output))
            }
        }

        let rendered: String
        if let connector, let runtime {
            rendered = await synthesizeWithLLM(
                topic: cleanTopic,
                sources: sources,
                previous: previous,
                existingPages: existingPages,
                mode: mode,
                connector: connector,
                runtime: runtime,
                onChunk: onChunk
            )
        } else {
            rendered = render(topic: cleanTopic, sources: sources, existingPages: existingPages, mode: mode)
        }

        var didSave = false
        var backlinksAdded: [String] = []
        var mocUpdated: String? = nil
        var saveError: String?

        if save {
            let securityError = await SecurityManager.shared.checkWrite(path: noteURL.path)
            if securityError == nil {
                do {
                    try FileManager.default.createDirectory(at: noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try rendered.write(to: noteURL, atomically: true, encoding: .utf8)
                    didSave = true

                    // Auto-add backlinks to related existing pages
                    if mode == .atomic {
                        backlinksAdded = addBacklinks(topic: cleanTopic, noteURL: noteURL, root: root, existingPages: existingPages)
                    }

                    // Auto-update MOC when creating atomic notes
                    if mode == .atomic {
                        mocUpdated = updateMOC(topic: cleanTopic, root: root, existingPages: existingPages)
                    }
                } catch {
                    saveError = error.localizedDescription
                }
            } else {
                saveError = securityError
            }
        }

        let result = WikiBuildResult(
            topic: cleanTopic,
            notePath: relativePath(noteURL, root: root),
            renderedMarkdown: rendered,
            previousMarkdown: previous,
            sources: sources,
            saved: didSave,
            mode: mode,
            backlinksAdded: backlinksAdded,
            mocUpdated: mocUpdated,
            saveError: saveError
        )
        recentResults.append(result)
        if recentResults.count > 20 { recentResults.removeFirst(recentResults.count - 20) }
        return result
    }

    /// Use the LLM to synthesize a wiki note with knowledge-graph approach.
    private static func synthesizeWithLLM(
        topic: String,
        sources: [WikiSource],
        previous: String?,
        existingPages: [VaultPage],
        mode: WikiMode,
        connector: ConnectorProfile,
        runtime: any ChatRuntimeClient,
        onChunk: (@Sendable @MainActor (String) -> Void)?
    ) async -> String {
        let sourceMaterial = sources.prefix(10).enumerated().map { i, s in
            "[\(i+1)] \(s.title)\n\(s.preview)"
        }.joined(separator: "\n\n")

        let existingNote = previous.map { "\n\n已有内容（请在此基础上更新而非重写）：\n\($0.prefix(3000))" } ?? ""

        // Build backlink context: show existing pages that can be linked
        let relatedPages = existingPages
            .filter { $0.title.lowercased() != topic.lowercased() }
            .prefix(30)
            .map { "- [\($0.title)](\($0.relativePath))" }
            .joined(separator: "\n")

        let systemPrompt: String
        if mode == .atomic {
            systemPrompt = """
            你是知识图谱写作助手。写一篇关于单一概念的**原子笔记**。

            ## 规则
            - 一个文件只讲一个概念/实体/产品，不要把多个概念混在一起
            - 用 Markdown 格式：# 标题 → ## 定义 → ## 核心要点 → ## 关联概念 → ## 来源
            - **必须使用 [[双链]]** 引用已有知识库中的相关页面
            - 内容精炼，信息密度高，每个要点用 1-2 句话
            - 如果有已有内容，在其基础上补充更新而非完全重写
            - 不要输出 frontmatter，系统会自动添加
            - 直接输出文章内容，不要包裹在代码块中
            """
        } else {
            systemPrompt = """
            你是知识图谱写作助手。写一篇**索引页（MOC）**，汇总某个领域下所有相关概念。

            ## 规则
            - 用 [[双链]] 列出该领域下所有相关原子笔记
            - 按子主题分组，每组用 ## 小标题
            - 每个条目用一句话概括，后跟 [[页面名]]
            - 不写具体内容，只做导航和索引
            - 不要输出 frontmatter，系统会自动添加
            - 直接输出文章内容，不要包裹在代码块中
            """
        }

        let backlinkHint = relatedPages.isEmpty ? "" : "\n\n知识库中已有的页面（请在文中用 [[页面名]] 引用相关项）：\n\(relatedPages)"

        let userPrompt = """
        主题：\(topic)

        参考材料：
        \(sourceMaterial.isEmpty ? "暂无参考材料，请根据你的知识写作。" : sourceMaterial)\(existingNote)\(backlinkHint)
        """

        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]
        let request = SendMessageRequest(
            sessionID: UUID(),
            message: userPrompt,
            connector: connector,
            modeLabel: "Wiki",
            systemPrompt: systemPrompt,
            tools: [],
            messages: messages,
            maxOutputTokens: 4096
        )

        do {
            let response: SendMessageResponse
            if let onChunk {
                response = try await runtime.sendMessageStream(request, onChunk: onChunk)
            } else {
                response = try await runtime.sendMessage(request)
            }
            let text = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return render(topic: topic, sources: sources) }

            // Prepend frontmatter
            let now = ISO8601DateFormatter().string(from: Date())
            let frontmatter = """
            ---
            type: "\(mode == .atomic ? "atomic" : "moc")"
            topic: "\(frontmatterValue(topic))"
            updated: "\(now)"
            source_count: "\(sources.count)"
            mode: "\(mode.rawValue)"
            ---
            """
            return frontmatter + "\n" + text
        } catch {
            // Fallback to template on LLM failure
            return render(topic: topic, sources: sources)
        }
    }

    private static func collectVaultSources(topic: String, vaultRoot: URL, limit: Int) -> [WikiSource] {
        guard FileManager.default.fileExists(atPath: vaultRoot.path) else { return [] }
        let terms = topic
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard !terms.isEmpty else { return [] }

        var ranked: [(score: Int, source: WikiSource)] = []
        guard let enumerator = FileManager.default.enumerator(atPath: vaultRoot.path) else { return [] }
        while let file = enumerator.nextObject() as? String {
            if file.contains("/.git/") || file.contains("/.obsidian/") || file.contains("/.laicai-cache/") {
                enumerator.skipDescendants()
                continue
            }
            guard file.hasSuffix(".md") else { continue }
            let full = vaultRoot.appendingPathComponent(file)
            guard let text = try? String(contentsOf: full, encoding: .utf8) else { continue }
            let lower = (file + "\n" + text).lowercased()
            let score = terms.reduce(0) { partial, term in
                partial + (lower.contains(term) ? 1 : 0)
            }
            guard score > 0 else { continue }
            ranked.append((
                score,
                WikiSource(path: file, title: extractTitle(text, fallback: full.deletingPathExtension().lastPathComponent), preview: snippet(text, terms: terms), kind: "vault")
            ))
        }
        return ranked
            .sorted { $0.score == $1.score ? $0.source.path < $1.source.path : $0.score > $1.score }
            .prefix(limit)
            .map(\.source)
    }

    private static func parseWebSources(_ output: String) -> [WikiSource] {
        let blocks = output.components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard lines.count >= 2 else { return nil }
            let title = lines[0].replacingOccurrences(of: #"^\d+\. "#, with: "", options: .regularExpression)
            return WikiSource(path: lines[1], title: title, preview: lines.dropFirst(2).joined(separator: " "), kind: "web")
        }
    }

    private static func sanitizedTopic(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed
            .replacingOccurrences(of: #"[/:\\]+"#, with: " - ", options: .regularExpression)
            .replacingOccurrences(of: #"[?%*|\"<>]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let fallback = normalized.isEmpty ? "Untitled" : normalized
        return String(fallback.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    private static func frontmatterValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    fileprivate static func wikilinkTarget(for source: WikiSource) -> String {
        let withoutExt = source.path.hasSuffix(".md") ? String(source.path.dropLast(3)) : source.path
        return withoutExt.components(separatedBy: "/").last ?? withoutExt
    }

    // MARK: - Vault Page Scanning

    struct VaultPage {
        var title: String
        var relativePath: String
    }

    /// Scan vault for all .md pages (for backlink discovery)
    private static func scanVaultPages(root: URL) -> [VaultPage] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var pages: [VaultPage] = []
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        while let file = enumerator.nextObject() as? String {
            let name = (file as NSString).lastPathComponent
            if name.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            guard file.hasSuffix(".md") else { continue }
            let title = (name as NSString).deletingPathExtension
            pages.append(VaultPage(title: title, relativePath: file))
        }
        return pages
    }

    /// Add backlinks: find existing pages that mention this topic and add [[link]] to them
    private static func addBacklinks(topic: String, noteURL: URL, root: URL, existingPages: [VaultPage]) -> [String] {
        var updated: [String] = []
        let topicLower = topic.lowercased()
        for page in existingPages {
            guard page.title.lowercased() != topicLower else { continue }
            guard page.relativePath.hasPrefix("02 Atomic/") || page.relativePath.hasPrefix("03 MOC/") else { continue }
            let fullPath = root.appendingPathComponent(page.relativePath)
            guard let content = try? String(contentsOf: fullPath, encoding: .utf8) else { continue }
            let lower = content.lowercased()
            // If the page mentions this topic but doesn't already have a [[link]] to it
            if lower.contains(topicLower) && !content.contains("[[\(topic)]]") {
                let newContent = appendRelatedConceptLink(to: content, topic: topic)
                try? newContent.write(to: fullPath, atomically: true, encoding: .utf8)
                updated.append(page.title)
            }
        }
        return Array(updated.prefix(10))
    }

    /// Auto-update or create MOC page when adding an atomic note
    @discardableResult
    private static func updateMOC(topic: String, root: URL, existingPages: [VaultPage]) -> String? {
        // Find the best MOC to update: look for existing MOC pages that mention related terms
        let mocDir = root.appendingPathComponent("03 MOC", isDirectory: true)
        try? FileManager.default.createDirectory(at: mocDir, withIntermediateDirectories: true)

        // Check if any existing MOC already references this topic
        let mocPages = existingPages.filter { $0.relativePath.hasPrefix("03 MOC/") }
        for moc in mocPages {
            let fullPath = root.appendingPathComponent(moc.relativePath)
            guard let content = try? String(contentsOf: fullPath, encoding: .utf8) else { continue }
            if content.lowercased().contains(topic.lowercased()) && !content.contains("[[\(topic)]]") {
                // Add link to existing MOC
                let updated = content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n- [[\(topic)]]\n"
                try? updated.write(to: fullPath, atomically: true, encoding: .utf8)
                return moc.title
            }
        }
        // No matching MOC found — don't force-create one
        return nil
    }

    private static func appendRelatedConceptLink(to content: String, topic: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkLine = "- [[\(topic)]]"
        if trimmed.localizedCaseInsensitiveContains("## 关联概念") {
            return trimmed + "\n\(linkLine)\n"
        }
        if trimmed.localizedCaseInsensitiveContains("## Related") {
            return trimmed + "\n\(linkLine)\n"
        }
        return trimmed + "\n\n## 关联概念\n\(linkLine)\n"
    }

    private static func render(topic: String, sources: [WikiSource], existingPages: [VaultPage] = [], mode: WikiMode = .atomic) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let vaultSources = sources.filter { $0.kind == "vault" }
        let webSources = sources.filter { $0.kind == "web" }
        let isAtomic = mode == .atomic
        var lines: [String] = [
            "---",
            #"type: "\#(isAtomic ? "atomic" : "moc")""#,
            #"topic: "\#(frontmatterValue(topic))""#,
            #"updated: "\#(now)""#,
            #"mode: "\#(mode.rawValue)""#,
            #"source_count: "\#(sources.count)""#,
            #"web_source_count: "\#(webSources.count)""#,
            "---",
            "",
            "# \(topic)",
            "",
            "## Summary",
            isAtomic
                ? "这是关于 **\(topic)** 的原子笔记草稿，由本地 Vault 笔记和可选网页来源整理而来。"
                : "这是 **\(topic)** 的 MOC 索引草稿，用于连接相关原子笔记和来源。"
        ]

        if sources.isEmpty {
            lines += ["", "## Notes", "- 暂未找到相关来源，可以先把关键笔记或网页资料加入 Vault 后再次生成。"]
        } else {
            lines += ["", "## Key Points"]
            for source in sources.prefix(6) {
                let sourceLabel = source.kind == "web" ? source.title : "[[\(wikilinkTarget(for: source))]]"
                lines.append("- \(source.preview)（来源：\(sourceLabel)）")
            }
        }

        if !vaultSources.isEmpty {
            lines += ["", "## Related Notes"]
            for source in vaultSources {
                let link = wikilinkTarget(for: source)
                lines.append("- [[\(link)]]")
            }
        }

        if !webSources.isEmpty {
            lines += ["", "## Web References"]
            for source in webSources {
                lines.append("- [\(source.title)](\(source.path))")
            }
        }

        // Add backlinks to related existing pages
        let related = existingPages.filter { page in
            let lower = page.title.lowercased()
            let topicLower = topic.lowercased()
            return lower != topicLower && (lower.contains(topicLower) || topicLower.contains(lower))
        }.prefix(10)
        if !related.isEmpty {
            lines += ["", "## 关联概念"]
            for page in related {
                lines.append("- [[\(page.title)]]")
            }
        }

        lines += ["", ""]
        return lines.joined(separator: "\n")
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func extractTitle(_ text: String, fallback: String) -> String {
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("# ") {
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return fallback
    }

    private static func snippet(_ text: String, terms: [String]) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("---") && !$0.hasPrefix("#") }
        if let hit = lines.first(where: { line in
            let lower = line.lowercased()
            return terms.contains(where: { lower.contains($0) })
        }) {
            return String(hit.prefix(220))
        }
        return String((lines.first ?? "相关笔记").prefix(220))
    }
}

public struct WikiBuildTool: LaicaiTool {
    public var name: String { "wiki.build" }
    public var description: String { "生成知识图谱风格的 Obsidian 笔记。mode=atomic 创建原子笔记（一个概念一个文件），mode=moc 创建索引页（MOC）。自动添加双链和更新 MOC。" }

    private struct Params: Codable {
        var topic: String
        var mode: String?
        var vaultPath: String?
        var save: Bool?
        var useWeb: Bool?
        var topK: Int?
        var sourceTitle: String?
        var sourcePath: String?
        var sourceText: String?
    }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "topic": FunctionProperty(type: "string", description: "概念/实体/主题名称（一个笔记只对应一个概念）"),
                    "mode": FunctionProperty(type: "string", description: "atomic=原子笔记（默认，一个概念一个文件存入 02 Atomic/）；moc=索引页（存入 03 MOC/）"),
                    "vaultPath": FunctionProperty(type: "string", description: "Vault 根目录，默认使用当前工作区"),
                    "save": FunctionProperty(type: "boolean", description: "是否写入 Vault；false 只生成预览"),
                    "useWeb": FunctionProperty(type: "boolean", description: "是否补充网页来源"),
                    "topK": FunctionProperty(type: "integer", description: "最多使用的本地笔记数量"),
                    "sourceTitle": FunctionProperty(type: "string", description: "可选：当前任务已读取或提取的来源标题"),
                    "sourcePath": FunctionProperty(type: "string", description: "可选：当前任务已读取或提取的来源路径"),
                    "sourceText": FunctionProperty(type: "string", description: "可选：当前任务已读取或提取的正文材料，优先用于生成笔记")
                ],
                required: ["topic"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let topic = params.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else {
            return ToolResult(output: "主题不能为空。", success: false, error: "empty_topic")
        }

        let mode: WikiMode
        switch params.mode?.lowercased() {
        case "moc", "topic": mode = .moc
        default: mode = .atomic
        }

        let root = (params.vaultPath?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? context.vaultRoot
            ?? (context.workspaceRoot.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : context.workspaceRoot)
        if !root.isEmpty, !WorkspaceSandbox.isOverlyBroadWorkspace(root) {
            await WorkspaceSandbox.shared.addAllowedPath(root)
        }
        var result = await WikiEngine.buildTopic(
            topic: topic,
            vaultRoot: root,
            save: params.save ?? false,
            mode: mode,
            useWeb: params.useWeb ?? false,
            topK: max(1, min(params.topK ?? 8, 20))
        )
        if let providedSource = Self.providedSource(from: params) {
            result.sources.insert(providedSource, at: 0)
            let rendered = Self.renderProvidedSourceNote(
                topic: result.topic,
                mode: mode,
                sources: result.sources,
                existingMarkdown: result.renderedMarkdown
            )
            result.renderedMarkdown = rendered
            if params.save ?? false {
                let target = URL(fileURLWithPath: root).appendingPathComponent(result.notePath)
                if let securityError = await SecurityManager.shared.checkWrite(path: target.path) {
                    result.saved = false
                    result.saveError = securityError
                } else {
                    do {
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try rendered.write(to: target, atomically: true, encoding: .utf8)
                        result.saved = true
                        result.saveError = nil
                    } catch {
                        result.saved = false
                        result.saveError = error.localizedDescription
                    }
                }
            }
        }

        let sourceLines = result.sources.prefix(8).map { source in
            switch source.kind {
            case "web":
                return "- [\(source.title)](\(source.path))"
            case "task":
                return "- \(source.title)：\(source.path)"
            default:
                return "- [[\(WikiEngine.wikilinkTarget(for: source))]]"
            }
        }.joined(separator: "\n")
        let wantedSave = params.save ?? false
        let action: String
        if result.saved {
            action = "已保存"
        } else if wantedSave {
            action = "保存失败（\(result.saveError ?? "路径可能超出工作区范围或权限不足")），仅生成预览"
        } else {
            action = "已生成预览"
        }
        // Only include summary in tool result — full content is in the Wiki panel.
        let preview = String(result.renderedMarkdown.prefix(500))
        let truncated = result.renderedMarkdown.count > 500 ? "\n\n... （共 \(result.renderedMarkdown.count) 字，完整内容见 Wiki 面板）" : ""
        var extraInfo = ""
        if !result.backlinksAdded.isEmpty {
            extraInfo += "\n\n自动双链：已在 \(result.backlinksAdded.count) 个页面添加了指向 [[\(topic)]] 的反向链接"
            extraInfo += "\n（\(result.backlinksAdded.prefix(5).joined(separator: "、"))）"
        }
        if let moc = result.mocUpdated {
            extraInfo += "\n\nMOC 更新：已将 [[\(topic)]] 添加到索引页「\(moc)」"
        }
        let output = """
        \(action)：\(result.notePath)（\(mode == .atomic ? "原子笔记" : "索引页")）
        \(result.diffSummary)

        来源：
        \(sourceLines.isEmpty ? "- 暂无来源" : sourceLines)\(extraInfo)

        预览：
        \(preview)\(truncated)
        """

        let success = !wantedSave || result.saved
        await AuditLog.shared.record(
            tool: name,
            input: "\(topic) [\(mode.rawValue)]",
            output: "\(action) \(result.notePath)，来源 \(result.sources.count) 条，双链 \(result.backlinksAdded.count) 个",
            success: success
        )

        return ToolResult(
            output: output,
            data: [
                "topic": result.topic,
                "path": result.notePath,
                "mode": mode.rawValue,
                "sourceCount": "\(result.sources.count)",
                "saved": result.saved ? "true" : "false",
                "diffSummary": result.diffSummary,
                "backlinksAdded": "\(result.backlinksAdded.count)",
                "mocUpdated": result.mocUpdated ?? "",
                "saveError": result.saveError ?? ""
            ],
            success: success,
            error: success ? nil : "wiki_save_failed"
        )
    }

    private static func providedSource(from params: Params) -> WikiSource? {
        guard let sourceText = params.sourceText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceText.isEmpty else {
            return nil
        }
        let path = params.sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = params.sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WikiSource(
            path: path?.isEmpty == false ? path! : "当前任务材料",
            title: title?.isEmpty == false ? title! : "当前任务材料",
            preview: sourceText,
            kind: "task"
        )
    }

    private static func renderProvidedSourceNote(
        topic: String,
        mode: WikiMode,
        sources: [WikiSource],
        existingMarkdown: String
    ) -> String {
        let provided = sources.first(where: { $0.kind == "task" })?.preview.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !provided.isEmpty else { return existingMarkdown }

        let now = ISO8601DateFormatter().string(from: Date())
        let heading = mode == .atomic ? "# \(topic)" : "# \(topic) MOC"
        let points = provided
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(24)
            .map { "- \(String($0.prefix(220)))" }
            .joined(separator: "\n")
        let source = sources.first(where: { $0.kind == "task" })
        let sourceLine = source.map { "- \($0.title)：\($0.path)" } ?? "- 当前任务材料"

        return """
        ---
        type: "\(mode == .atomic ? "atomic" : "moc")"
        topic: "\(frontmatterString(topic))"
        updated: "\(now)"
        mode: "\(mode.rawValue)"
        source_count: "\(sources.count)"
        ---

        \(heading)

        ## Summary
        这篇笔记由当前任务读取/提取的真实材料整理而来，用于沉淀到本地 Wiki。

        ## Key Points
        \(points.isEmpty ? "- 已读取材料，但未提取到可展示的行级要点。" : points)

        ## Source
        \(sourceLine)

        ## Raw Material
        ```text
        \(String(provided.prefix(12000)))
        ```

        ## Related Notes
        \(sources.filter { $0.kind != "task" }.prefix(8).map { "- [[\(WikiEngine.wikilinkTarget(for: $0))]]" }.joined(separator: "\n"))

        """
    }

    private static func frontmatterString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
