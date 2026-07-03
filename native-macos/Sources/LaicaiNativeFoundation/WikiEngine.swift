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
    private struct WikiSynthesisRequest {
        let topic: String
        let sources: [WikiSource]
        let previous: String?
        let existingPages: [VaultPage]
        let mode: WikiMode
        let connector: ConnectorProfile
        let runtime: any ChatRuntimeClient
    }

    private struct WikiSaveOutcome {
        var didSave = false
        var backlinksAdded: [String] = []
        var mocUpdated: String?
        var saveError: String?
    }

    private struct WikiRenderRequest {
        let topic: String
        let sources: [WikiSource]
        let previous: String?
        let existingPages: [VaultPage]
        let mode: WikiMode
        let connector: ConnectorProfile?
        let runtime: (any ChatRuntimeClient)?
        let onChunk: (@Sendable @MainActor (String) -> Void)?
    }

    private struct WikiSaveRequest {
        let shouldSave: Bool
        let rendered: String
        let topic: String
        let noteURL: URL
        let root: URL
        let mode: WikiMode
        let existingPages: [VaultPage]
    }

    private struct VaultDocEntry {
        var file: String
        var text: String
        var lower: String
    }

    private static let sourceStopwords: Set<String> = [
        "的", "了", "和", "是", "在", "有", "与", "对", "及", "等",
        "the", "and", "for", "with", "this", "that", "from", "are", "was"
    ]

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
        let noteURL = root
            .appendingPathComponent(noteSubdirectory(for: mode), isDirectory: true)
            .appendingPathComponent(cleanTopic + ".md")
        let previous = try? String(contentsOf: noteURL, encoding: .utf8)
        let localSources = collectVaultSources(topic: cleanTopic, vaultRoot: root, limit: topK)
        let existingPages = scanVaultPages(root: root)
        let sources = await sourcesWithOptionalWeb(
            localSources,
            topic: cleanTopic,
            vaultRoot: vaultRoot,
            useWeb: useWeb
        )
        let rendered = await renderedWikiMarkdown(WikiRenderRequest(
            topic: cleanTopic,
            sources: sources,
            previous: previous,
            existingPages: existingPages,
            mode: mode,
            connector: connector,
            runtime: runtime,
            onChunk: onChunk
        ))
        let saveOutcome = await saveWikiNoteIfNeeded(WikiSaveRequest(
            shouldSave: save,
            rendered: rendered,
            topic: cleanTopic,
            noteURL: noteURL,
            root: root,
            mode: mode,
            existingPages: existingPages
        ))

        let result = WikiBuildResult(
            topic: cleanTopic,
            notePath: relativePath(noteURL, root: root),
            renderedMarkdown: rendered,
            previousMarkdown: previous,
            sources: sources,
            saved: saveOutcome.didSave,
            mode: mode,
            backlinksAdded: saveOutcome.backlinksAdded,
            mocUpdated: saveOutcome.mocUpdated,
            saveError: saveOutcome.saveError
        )
        recordRecentResult(result)
        return result
    }

    private static func noteSubdirectory(for mode: WikiMode) -> String {
        switch mode {
        case .atomic: return "02 Atomic"
        case .moc, .topic: return "03 MOC"
        }
    }

    private static func sourcesWithOptionalWeb(
        _ localSources: [WikiSource],
        topic: String,
        vaultRoot: String,
        useWeb: Bool
    ) async -> [WikiSource] {
        guard useWeb else { return localSources }
        let web = try? await WebSearchTool().execute(
            argumentsJSON: #"{"query":"\#(topic) 最新","maxResults":3}"#,
            context: TaskContext(workspaceRoot: vaultRoot)
        )
        guard let web, web.success else { return localSources }
        return localSources + parseWebSources(web.output)
    }

    private static func renderedWikiMarkdown(_ request: WikiRenderRequest) async -> String {
        guard let connector = request.connector, let runtime = request.runtime else {
            return render(
                topic: request.topic,
                sources: request.sources,
                existingPages: request.existingPages,
                mode: request.mode
            )
        }
        return await synthesizeWithLLM(
            WikiSynthesisRequest(
                topic: request.topic,
                sources: request.sources,
                previous: request.previous,
                existingPages: request.existingPages,
                mode: request.mode,
                connector: connector,
                runtime: runtime
            ),
            onChunk: request.onChunk
        )
    }

    private static func saveWikiNoteIfNeeded(_ request: WikiSaveRequest) async -> WikiSaveOutcome {
        guard request.shouldSave else { return WikiSaveOutcome() }
        if let securityError = await SecurityManager.shared.checkWrite(path: request.noteURL.path) {
            return WikiSaveOutcome(saveError: securityError)
        }
        do {
            try FileManager.default.createDirectory(
                at: request.noteURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try request.rendered.write(to: request.noteURL, atomically: true, encoding: .utf8)
            return savedWikiOutcome(
                topic: request.topic,
                noteURL: request.noteURL,
                root: request.root,
                mode: request.mode,
                existingPages: request.existingPages
            )
        } catch {
            return WikiSaveOutcome(saveError: error.localizedDescription)
        }
    }

    private static func savedWikiOutcome(
        topic: String,
        noteURL: URL,
        root: URL,
        mode: WikiMode,
        existingPages: [VaultPage]
    ) -> WikiSaveOutcome {
        guard mode == .atomic else { return WikiSaveOutcome(didSave: true) }
        return WikiSaveOutcome(
            didSave: true,
            backlinksAdded: addBacklinks(topic: topic, noteURL: noteURL, root: root, existingPages: existingPages),
            mocUpdated: updateMOC(topic: topic, root: root, existingPages: existingPages)
        )
    }

    private static func recordRecentResult(_ result: WikiBuildResult) {
        recentResults.append(result)
        if recentResults.count > 20 {
            recentResults.removeFirst(recentResults.count - 20)
        }
    }

    /// Use the LLM to synthesize a wiki note with knowledge-graph approach.
    private static func synthesizeWithLLM(
        _ request: WikiSynthesisRequest,
        onChunk: (@Sendable @MainActor (String) -> Void)?
    ) async -> String {
        let topic = request.topic
        let mode = request.mode
        let sources = request.sources
        let previous = request.previous
        let sourceMaterial = request.sources.prefix(10).enumerated().map { index, source in
            "[\(index + 1)] \(source.title)\n\(source.preview)"
        }.joined(separator: "\n\n")

        let existingNote = previous.map { "\n\n已有内容（只补充新信息，保留原有要点和结构，不要删除或替换已有内容）：\n\($0.prefix(4000))" } ?? ""

        // Build backlink context: show existing pages that can be linked
        let relatedPages = request.existingPages
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
            - 用 Markdown 格式：# 标题 → ## 定义（一段话精准定义） → ## 核心要点（每条信息密度高，禁止水话） → ## 实际应用/案例 → ## 关联概念 → ## 来源
            - **必须使用 [[双链]]** 引用已有知识库中的相关页面
            - **信息密度要求**：不写"众所周知"、"值得注意的是"等废话；每个要点必须包含具体事实、数字或技术细节
            - **证据溯源**：每个要点尽量标注来源编号 [1][2]，来源不足时标注 [待验证]
            - 如果有已有内容，只补充新信息和修正错误，保留原有结构和已有要点
            - 不要输出 frontmatter，系统会自动添加
            - 直接输出文章内容，不要包裹在代码块中
            """
        } else {
            systemPrompt = """
            你是知识图谱写作助手。写一篇**索引页（MOC）**，汇总某个领域下所有相关概念。

            ## 规则
            - 用 [[双链]] 列出该领域下所有相关原子笔记
            - 按子主题分组，每组用 ## 小标题
            - 每个条目用一句话概括核心价值，后跟 [[页面名]]
            - 条目之间体现逻辑关系（上下游、包含、对比）
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
        let messageRequest = SendMessageRequest(
            sessionID: UUID(),
            message: userPrompt,
            connector: request.connector,
            modeLabel: "Wiki",
            systemPrompt: systemPrompt,
            tools: [],
            messages: messages,
            maxOutputTokens: 4096
        )

        do {
            let response: SendMessageResponse
            if let onChunk {
                response = try await request.runtime.sendMessageStream(messageRequest, onChunk: onChunk)
            } else {
                response = try await request.runtime.sendMessage(messageRequest)
            }
            var text = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return render(topic: topic, sources: sources) }

            // Strip code fences if LLM wrapped in ```markdown ... ```
            if text.hasPrefix("```") {
                let lines = text.components(separatedBy: .newlines)
                if lines.count > 2 {
                    let stripped = lines.dropFirst().dropLast().joined(separator: "\n")
                    if !stripped.isEmpty { text = stripped }
                }
            }

            // Incremental merge: if previous content exists, rescue any sections that were dropped
            if let previous, !previous.isEmpty {
                text = mergeWithPrevious(newText: text, previous: previous)
            }

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
        let terms = sourceTerms(from: topic)
        guard !terms.isEmpty else { return [] }

        let docs = collectVaultDocs(vaultRoot: vaultRoot)
        guard !docs.isEmpty else { return [] }

        let frequency = documentFrequency(terms: terms, docs: docs)
        return rankedVaultSources(topic: topic, terms: terms, docs: docs, documentFrequency: frequency, limit: limit)
    }

    private static func sourceTerms(from topic: String) -> [String] {
        topic
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    private static func collectVaultDocs(vaultRoot: URL) -> [VaultDocEntry] {
        var docs: [VaultDocEntry] = []
        guard let enumerator = FileManager.default.enumerator(atPath: vaultRoot.path) else { return [] }
        while let file = enumerator.nextObject() as? String {
            if shouldSkipVaultPath(file) {
                enumerator.skipDescendants()
                continue
            }
            guard file.hasSuffix(".md") else { continue }
            let full = vaultRoot.appendingPathComponent(file)
            guard let text = try? String(contentsOf: full, encoding: .utf8) else { continue }
            docs.append(VaultDocEntry(file: file, text: text, lower: (file + "\n" + text).lowercased()))
        }
        return docs
    }

    private static func shouldSkipVaultPath(_ file: String) -> Bool {
        (file as NSString).lastPathComponent.hasPrefix(".")
    }

    private static func documentFrequency(terms: [String], docs: [VaultDocEntry]) -> [String: Int] {
        var frequency: [String: Int] = [:]
        for term in terms where !sourceStopwords.contains(term) {
            frequency[term] = docs.filter { $0.lower.contains(term) }.count
        }
        return frequency
    }

    private static func rankedVaultSources(
        topic: String,
        terms: [String],
        docs: [VaultDocEntry],
        documentFrequency: [String: Int],
        limit: Int
    ) -> [WikiSource] {
        let totalDocs = Double(docs.count)
        let ranked = docs.compactMap { doc -> (score: Double, source: WikiSource)? in
            let score = vaultSourceScore(
                doc: doc,
                topic: topic,
                terms: terms,
                documentFrequency: documentFrequency,
                totalDocs: totalDocs
            )
            guard score > 0.1 else { return nil }
            return (score, vaultSource(doc: doc, terms: terms))
        }
        return ranked
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.source)
    }

    private static func vaultSourceScore(
        doc: VaultDocEntry,
        topic: String,
        terms: [String],
        documentFrequency: [String: Int],
        totalDocs: Double
    ) -> Double {
        var score = terms.reduce(0.0) { partial, term in
            partial + vaultTermScore(
                doc: doc,
                term: term,
                termDocumentFrequency: documentFrequency[term] ?? 0,
                totalDocs: totalDocs
            )
        }
        let title = extractTitle(doc.text, fallback: (doc.file as NSString).deletingPathExtension)
        if title.lowercased().contains(topic.lowercased()) {
            score += 10.0
        }
        return score
    }

    private static func vaultTermScore(
        doc: VaultDocEntry,
        term: String,
        termDocumentFrequency: Int,
        totalDocs: Double
    ) -> Double {
        guard !sourceStopwords.contains(term), termDocumentFrequency > 0 else { return 0 }
        let occurrences = doc.lower.components(separatedBy: term).count - 1
        guard occurrences > 0 else { return 0 }
        let termFrequency = Double(occurrences) / max(1, Double(doc.lower.count) / 500.0)
        let idf = log(totalDocs / Double(termDocumentFrequency) + 1)
        let fileName = (doc.file as NSString).lastPathComponent.lowercased()
        return fileName.contains(term) ? termFrequency * idf + idf * 3.0 : termFrequency * idf
    }

    private static func vaultSource(doc: VaultDocEntry, terms: [String]) -> WikiSource {
        let title = extractTitle(doc.text, fallback: (doc.file as NSString).deletingPathExtension)
        return WikiSource(path: doc.file, title: title, preview: snippet(doc.text, terms: terms), kind: "vault")
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
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("# ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fallback
    }

    /// Incremental merge: check if the new LLM output dropped any ## sections from previous content.
    /// If so, append them back at the end to avoid losing information.
    private static func mergeWithPrevious(newText: String, previous: String) -> String {
        // Strip frontmatter from previous
        var prevBody = previous
        if prevBody.hasPrefix("---") {
            let parts = prevBody.components(separatedBy: "---")
            if parts.count >= 3 {
                prevBody = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Extract ## sections from previous
        let prevSections = extractSections(prevBody)
        let newSections = extractSections(newText)
        let newSectionHeaders = Set(newSections.map { $0.header.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })

        // Find sections in previous that are missing from new
        var rescued: [String] = []
        for section in prevSections {
            let headerNorm = section.header.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !headerNorm.isEmpty else { continue }
            if !newSectionHeaders.contains(headerNorm) {
                // This section was dropped — rescue it
                let sectionText = section.header + "\n" + section.body
                rescued.append(sectionText)
            }
        }

        if rescued.isEmpty { return newText }
        return newText.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + rescued.joined(separator: "\n\n")
    }

    private struct MarkdownSection {
        var header: String  // e.g. "## 核心要点"
        var body: String    // content under the header
    }

    private static func extractSections(_ text: String) -> [MarkdownSection] {
        let lines = text.components(separatedBy: .newlines)
        var sections: [MarkdownSection] = []
        var currentHeader = ""
        var currentBody: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if !currentHeader.isEmpty {
                    sections.append(MarkdownSection(header: currentHeader, body: currentBody.joined(separator: "\n")))
                }
                currentHeader = line
                currentBody = []
            } else if !currentHeader.isEmpty {
                currentBody.append(line)
            }
        }
        if !currentHeader.isEmpty {
            sections.append(MarkdownSection(header: currentHeader, body: currentBody.joined(separator: "\n")))
        }
        return sections
    }

    private static func snippet(_ text: String, terms: [String]) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("---") && !$0.hasPrefix("#") }
        // Find the first line containing a search term, return it + 1-2 surrounding lines
        if let hitIdx = lines.firstIndex(where: { line in
            let lower = line.lowercased()
            return terms.contains(where: { lower.contains($0) })
        }) {
            let start = max(0, hitIdx - 1)
            let end = min(lines.count, hitIdx + 3)
            let context = lines[start..<end].joined(separator: " ")
            return String(context.prefix(400))
        }
        // No term hit: return first 2 content lines
        let fallback = lines.prefix(2).joined(separator: " ")
        return String(fallback.isEmpty ? "相关笔记" : fallback.prefix(400))
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

    private struct WikiAuditRequest {
        let tool: String
        let topic: String
        let mode: WikiMode
        let action: String
        let result: WikiBuildResult
        let success: Bool
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
                    "sourceTitle": FunctionProperty(type: "string", description: "可选：当前会话 已读取或提取的来源标题"),
                    "sourcePath": FunctionProperty(type: "string", description: "可选：当前会话 已读取或提取的来源路径"),
                    "sourceText": FunctionProperty(type: "string", description: "可选：当前会话 已读取或提取的正文材料，优先用于生成笔记")
                ],
                required: ["topic"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        let decoded = Self.decodeParams(argumentsJSON)
        guard let params = decoded.params else { return decoded.failure! }
        guard let topic = Self.validTopic(params.topic) else {
            return ToolResult(output: "主题不能为空。", success: false, error: "empty_topic")
        }

        let mode = Self.wikiMode(from: params.mode)
        let root = Self.rootPath(params: params, context: context)
        await Self.allowWikiRootIfSafe(root)

        var result = await Self.buildWikiResult(params: params, topic: topic, root: root, mode: mode)
        result = await Self.resultWithProvidedSource(result, params: params, mode: mode, root: root)
        let wantedSave = params.save ?? false
        let action = Self.actionText(result: result, wantedSave: wantedSave)
        let success = !wantedSave || result.saved
        await Self.recordAudit(WikiAuditRequest(
            tool: name,
            topic: topic,
            mode: mode,
            action: action,
            result: result,
            success: success
        ))

        return ToolResult(
            output: Self.outputText(result: result, mode: mode, topic: topic, action: action),
            data: Self.resultData(result: result, mode: mode),
            success: success,
            error: success ? nil : "wiki_save_failed"
        )
    }

    private static func decodeParams(_ argumentsJSON: String) -> (params: Params?, failure: ToolResult?) {
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            return (try JSONDecoder().decode(Params.self, from: jsonData), nil)
        } catch {
            return (nil, ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params"))
        }
    }

    private static func validTopic(_ topic: String) -> String? {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func wikiMode(from rawMode: String?) -> WikiMode {
        switch rawMode?.lowercased() {
        case "moc", "topic": return .moc
        default: return .atomic
        }
    }

    private static func rootPath(params: Params, context: TaskContext) -> String {
        (params.vaultPath?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? context.vaultRoot
            ?? (context.workspaceRoot.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : context.workspaceRoot)
    }

    private static func allowWikiRootIfSafe(_ root: String) async {
        guard !root.isEmpty, !WorkspaceSandbox.isOverlyBroadWorkspace(root) else { return }
        await WorkspaceSandbox.shared.addAllowedPath(root)
    }

    private static func buildWikiResult(
        params: Params,
        topic: String,
        root: String,
        mode: WikiMode
    ) async -> WikiBuildResult {
        await WikiEngine.buildTopic(
            topic: topic,
            vaultRoot: root,
            save: params.save ?? false,
            mode: mode,
            useWeb: params.useWeb ?? false,
            topK: max(1, min(params.topK ?? 8, 20))
        )
    }

    private static func resultWithProvidedSource(
        _ original: WikiBuildResult,
        params: Params,
        mode: WikiMode,
        root: String
    ) async -> WikiBuildResult {
        guard let providedSource = providedSource(from: params) else { return original }
        var result = original
        result.sources.insert(providedSource, at: 0)
        result.renderedMarkdown = renderProvidedSourceNote(
            topic: result.topic,
            mode: mode,
            sources: result.sources,
            existingMarkdown: result.renderedMarkdown
        )
        guard params.save ?? false else { return result }
        return await saveProvidedSourceResult(result, root: root)
    }

    private static func saveProvidedSourceResult(_ original: WikiBuildResult, root: String) async -> WikiBuildResult {
        var result = original
        let target = URL(fileURLWithPath: root).appendingPathComponent(result.notePath)
        if let securityError = await SecurityManager.shared.checkWrite(path: target.path) {
            result.saved = false
            result.saveError = securityError
            return result
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try result.renderedMarkdown.write(to: target, atomically: true, encoding: .utf8)
            result.saved = true
            result.saveError = nil
        } catch {
            result.saved = false
            result.saveError = error.localizedDescription
        }
        return result
    }

    private static func sourceLines(for result: WikiBuildResult) -> String {
        result.sources.prefix(8).map(sourceLine).joined(separator: "\n")
    }

    private static func sourceLine(_ source: WikiSource) -> String {
        switch source.kind {
        case "web":
            return "- [\(source.title)](\(source.path))"
        case "task":
            return "- \(source.title)：\(source.path)"
        default:
            return "- [[\(WikiEngine.wikilinkTarget(for: source))]]"
        }
    }

    private static func actionText(result: WikiBuildResult, wantedSave: Bool) -> String {
        if result.saved { return "已保存" }
        if wantedSave {
            return "保存失败（\(result.saveError ?? "路径可能超出工作区范围或权限不足")），仅生成预览"
        }
        return "已生成预览"
    }

    private static func outputText(result: WikiBuildResult, mode: WikiMode, topic: String, action: String) -> String {
        let preview = String(result.renderedMarkdown.prefix(500))
        let truncated = result.renderedMarkdown.count > 500 ? "\n\n... （共 \(result.renderedMarkdown.count) 字，完整内容见 Wiki 面板）" : ""
        let sources = sourceLines(for: result)
        return """
        \(action)：\(result.notePath)（\(mode == .atomic ? "原子笔记" : "索引页")）
        \(result.diffSummary)

        来源：
        \(sources.isEmpty ? "- 暂无来源" : sources)\(extraInfo(result: result, topic: topic))

        预览：
        \(preview)\(truncated)
        """
    }

    private static func extraInfo(result: WikiBuildResult, topic: String) -> String {
        var text = ""
        if !result.backlinksAdded.isEmpty {
            text += "\n\n自动双链：已在 \(result.backlinksAdded.count) 个页面添加了指向 [[\(topic)]] 的反向链接"
            text += "\n（\(result.backlinksAdded.prefix(5).joined(separator: "、"))）"
        }
        if let moc = result.mocUpdated {
            text += "\n\nMOC 更新：已将 [[\(topic)]] 添加到索引页「\(moc)」"
        }
        return text
    }

    private static func resultData(result: WikiBuildResult, mode: WikiMode) -> [String: String] {
        [
            "topic": result.topic,
            "path": result.notePath,
            "mode": mode.rawValue,
            "sourceCount": "\(result.sources.count)",
            "saved": result.saved ? "true" : "false",
            "diffSummary": result.diffSummary,
            "backlinksAdded": "\(result.backlinksAdded.count)",
            "mocUpdated": result.mocUpdated ?? "",
            "saveError": result.saveError ?? ""
        ]
    }

    private static func recordAudit(_ request: WikiAuditRequest) async {
        await AuditLog.shared.record(
            tool: request.tool,
            input: "\(request.topic) [\(request.mode.rawValue)]",
            output: "\(request.action) \(request.result.notePath)，来源 \(request.result.sources.count) 条，双链 \(request.result.backlinksAdded.count) 个",
            success: request.success
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
            path: path?.isEmpty == false ? path! : "当前会话 材料",
            title: title?.isEmpty == false ? title! : "当前会话 材料",
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
        let sourceLine = source.map { "- \($0.title)：\($0.path)" } ?? "- 当前会话 材料"

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
        这篇笔记由当前会话 读取/提取的真实材料整理而来，用于沉淀到本地 Wiki。

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
