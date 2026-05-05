import Foundation
import LaicaiNativeDomain

public struct WikiSource: Equatable, Sendable {
    public var path: String
    public var title: String
    public var preview: String
    public var kind: String
}

public struct WikiBuildResult: Sendable, Identifiable {
    public let id: UUID = UUID()
    public var topic: String
    public var notePath: String
    public var renderedMarkdown: String
    public var previousMarkdown: String?
    public var sources: [WikiSource]
    public var saved: Bool

    public static func == (lhs: WikiBuildResult, rhs: WikiBuildResult) -> Bool {
        lhs.topic == rhs.topic && lhs.notePath == rhs.notePath && lhs.saved == rhs.saved
    }

    public var diffSummary: String {
        guard let previousMarkdown else { return "新建主题页" }
        let oldLines = previousMarkdown.components(separatedBy: .newlines).count
        let newLines = renderedMarkdown.components(separatedBy: .newlines).count
        return "更新主题页（原 \(oldLines) 行，新 \(newLines) 行）"
    }
}

public enum WikiEngine {
    /// Recent wiki build results, persisted in memory for the session
    public private(set) static var recentResults: [WikiBuildResult] = []

    /// Build a wiki topic using LLM synthesis with streaming output.
    /// Falls back to template rendering when no connector/runtime is provided.
    public static func buildTopic(
        topic: String,
        vaultRoot: String,
        save: Bool,
        useWeb: Bool = false,
        topK: Int = 8,
        connector: ConnectorProfile? = nil,
        runtime: (any ChatRuntimeClient)? = nil,
        onChunk: (@Sendable @MainActor (String) -> Void)? = nil
    ) async -> WikiBuildResult {
        let cleanTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = URL(fileURLWithPath: vaultRoot)
        let noteURL = root
            .appendingPathComponent("03 Topics", isDirectory: true)
            .appendingPathComponent(slug(cleanTopic) + ".md")
        let previous = try? String(contentsOf: noteURL, encoding: .utf8)
        var sources = collectVaultSources(topic: cleanTopic, vaultRoot: root, limit: topK)

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
                connector: connector,
                runtime: runtime,
                onChunk: onChunk
            )
        } else {
            rendered = render(topic: cleanTopic, sources: sources)
        }

        if save {
            do {
                try FileManager.default.createDirectory(at: noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try rendered.write(to: noteURL, atomically: true, encoding: .utf8)
            } catch {
                // Save failures are represented by the caller via a ToolResult.
            }
        }

        let result = WikiBuildResult(
            topic: cleanTopic,
            notePath: relativePath(noteURL, root: root),
            renderedMarkdown: rendered,
            previousMarkdown: previous,
            sources: sources,
            saved: save
        )
        recentResults.append(result)
        if recentResults.count > 20 { recentResults.removeFirst(recentResults.count - 20) }
        return result
    }

    /// Use the LLM to synthesize a coherent wiki article from collected sources.
    private static func synthesizeWithLLM(
        topic: String,
        sources: [WikiSource],
        previous: String?,
        connector: ConnectorProfile,
        runtime: any ChatRuntimeClient,
        onChunk: (@Sendable @MainActor (String) -> Void)?
    ) async -> String {
        let sourceMaterial = sources.prefix(10).enumerated().map { i, s in
            "[\(i+1)] \(s.title)\n\(s.preview)"
        }.joined(separator: "\n\n")

        let existingNote = previous.map { "\n\n已有内容（请在此基础上更新而非重写）：\n\($0.prefix(3000))" } ?? ""

        let systemPrompt = """
        你是知识库写作助手。根据用户提供的主题和参考材料，写一篇结构清晰、信息密度高的中文 Wiki 文章。
        要求：
        - 用 Markdown 格式，包含标题、小标题、要点列表
        - 内容简洁准确，不废话
        - 如果有已有内容，在其基础上补充更新而非完全重写
        - 不要输出 frontmatter，系统会自动添加
        - 直接输出文章内容，不要包裹在代码块中
        """

        let userPrompt = """
        主题：\(topic)

        参考材料：
        \(sourceMaterial.isEmpty ? "暂无参考材料，请根据你的知识写作。" : sourceMaterial)\(existingNote)
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
            type: "topic"
            topic: "\(topic)"
            updated: "\(now)"
            source_count: "\(sources.count)"
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

    private static func render(topic: String, sources: [WikiSource]) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let vaultSources = sources.filter { $0.kind == "vault" }
        let webSources = sources.filter { $0.kind == "web" }
        var lines: [String] = [
            "---",
            #"type: "topic""#,
            #"topic: "\#(topic)""#,
            #"updated: "\#(now)""#,
            #"source_count: "\#(sources.count)""#,
            #"web_source_count: "\#(webSources.count)""#,
            "---",
            "",
            "# \(topic)",
            "",
            "## Summary",
            "这是关于 **\(topic)** 的初始 Wiki 草稿，由本地 Vault 笔记和可选网页来源整理而来。"
        ]

        if sources.isEmpty {
            lines += ["", "## Notes", "- 暂未找到相关来源，可以先把关键笔记或网页资料加入 Vault 后再次生成。"]
        } else {
            lines += ["", "## Key Points"]
            for source in sources.prefix(6) {
                lines.append("- \(source.preview)")
            }
        }

        if !vaultSources.isEmpty {
            lines += ["", "## Related Notes"]
            for source in vaultSources {
                let link = source.path.hasSuffix(".md") ? String(source.path.dropLast(3)) : source.path
                lines.append("- [[\(link)]]")
            }
        }

        if !webSources.isEmpty {
            lines += ["", "## Web References"]
            for source in webSources {
                lines.append("- [\(source.title)](\(source.path))")
            }
        }

        lines += ["", "## Open Questions", "- 还需要补充哪些证据、实验或反例？", ""]
        return lines.joined(separator: "\n")
    }

    private static func slug(_ text: String) -> String {
        let cleaned = text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\u{4e00}-\u{9fff}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "untitled" : cleaned
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
    public var description: String { "生成或保存 Obsidian 风格的长期主题 Wiki 页" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "topic": FunctionProperty(type: "string", description: "主题名称"),
                    "vaultPath": FunctionProperty(type: "string", description: "Vault 根目录，默认使用当前工作区"),
                    "save": FunctionProperty(type: "boolean", description: "是否写入 Vault；false 只生成预览"),
                    "useWeb": FunctionProperty(type: "boolean", description: "是否补充网页来源"),
                    "topK": FunctionProperty(type: "integer", description: "最多使用的本地笔记数量")
                ],
                required: ["topic"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var topic: String
            var vaultPath: String?
            var save: Bool?
            var useWeb: Bool?
            var topK: Int?
        }

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

        let root = (params.vaultPath?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? context.vaultRoot
            ?? (context.workspaceRoot.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : context.workspaceRoot)
        let result = await WikiEngine.buildTopic(
            topic: topic,
            vaultRoot: root,
            save: params.save ?? false,
            useWeb: params.useWeb ?? false,
            topK: max(1, min(params.topK ?? 8, 20))
        )

        let sourceLines = result.sources.prefix(8).map { source in
            source.kind == "web"
                ? "- [\(source.title)](\(source.path))"
                : "- [[\(source.path.hasSuffix(".md") ? String(source.path.dropLast(3)) : source.path)]]"
        }.joined(separator: "\n")
        let action = result.saved ? "已保存" : "已生成预览"
        let recentLines = WikiEngine.recentResults.suffix(5).map { r in
            "- \(r.topic)（\(r.saved ? "已保存" : "预览")，\(r.sources.count) 来源）"
        }.joined(separator: "\n")
        let output = """
        \(action)：\(result.notePath)
        \(result.diffSummary)

        来源：
        \(sourceLines.isEmpty ? "- 暂无来源" : sourceLines)

        最近生成：
        \(recentLines.isEmpty ? "- 这是本次会话的第一个知识页" : recentLines)

        \(result.renderedMarkdown)
        """

        await AuditLog.shared.record(
            tool: name,
            input: topic,
            output: "\(action) \(result.notePath)，来源 \(result.sources.count) 条",
            success: true
        )

        return ToolResult(
            output: output,
            data: [
                "topic": result.topic,
                "path": result.notePath,
                "sourceCount": "\(result.sources.count)",
                "saved": result.saved ? "true" : "false",
                "diffSummary": result.diffSummary
            ]
        )
    }
}
