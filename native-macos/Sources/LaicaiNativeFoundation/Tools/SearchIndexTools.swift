import Foundation
import LaicaiNativeDomain

// MARK: - Search Tool

public struct SearchTool: LaicaiTool {
    public var name: String { "code.search" }
    public var description: String { "在工作区中搜索文件或内容" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "query": FunctionProperty(type: "string", description: "搜索关键词"),
                    "scope": FunctionProperty(
                        type: "string",
                        description: "搜索范围：files（文件名）或 content（文件内容）",
                        enumValues: ["files", "content"]
                    ),
                    "maxResults": FunctionProperty(type: "integer", description: "最大结果数（可选，默认50）")
                ],
                required: ["query"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var query: String
            var scope: String?
            var maxResults: Int?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = params.scope ?? "content"
        let maxResults = params.maxResults ?? 50

        // Reject obviously non-code queries (natural language sentences)
        if query.count > 8 && Self.isLikelyNaturalLanguage(query) {
            return ToolResult(
                output: "搜索词是自然语言，不是有效关键词。请勿把用户原话当搜索词。\n"
                    + "正确用法示例：scope=files query=\"SKILL.md\" 或 scope=content query=\"万达\"\n"
                    + "如果用户在追问之前的结果，直接根据会话上下文回答即可，不需要再次搜索。\n"
                    + "无效查询：\(query)",
                success: false,
                error: "invalid_query"
            )
        }

        let root = context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            return ToolResult(output: "请先设置工作区后再搜索项目。", success: false, error: "workspace_missing")
        }
        guard FileManager.default.fileExists(atPath: root) else {
            return ToolResult(output: "工作区不存在：\(root)", success: false, error: "workspace_not_found")
        }

        if scope == "files" {
            return try searchFiles(query: query, root: root, maxResults: maxResults, contextMode: context.contextMode)
        } else {
            return try await searchContent(query: query, root: root, maxResults: maxResults, contextMode: context.contextMode)
        }
    }

    /// Heuristic: detect natural language sentences (not code identifiers)
    private static func isLikelyNaturalLanguage(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Chinese conversational patterns
        let zhConversational = ["你", "我", "吗", "吧", "呢", "啊", "了", "的", "是", "请", "帮", "能不能", "怎么", "为什么", "什么"]
        let zhMatches = zhConversational.filter { lower.contains($0) }.count
        if zhMatches >= 3 { return true }
        // English conversational patterns
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if words.count >= 5 {
            let commonWords: Set<String> = ["the", "a", "an", "is", "are", "was", "were", "i", "you", "we", "they", "it",
                                             "do", "does", "did", "can", "could", "would", "should", "please", "help", "want"]
            let commonCount = words.filter { commonWords.contains($0.lowercased()) }.count
            if commonCount >= 3 { return true }
        }
        return false
    }

    private func searchFiles(query: String, root: String, maxResults: Int, contextMode: ContextMode = .balanced) throws -> ToolResult {
        let fm = FileManager.default
        var results: [String] = []
        let enumerator = fm.enumerator(atPath: root)
        let ignoredDirs: Set<String> = [".git", "node_modules", ".build", "DerivedData", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".venv", "venv"]
        // Short ASCII queries (≤4 chars like "RAG") use word-boundary matching
        // to avoid "RAG" matching "draggable", "LLM" matching "scrolllm", etc.
        let isShortAscii = query.count <= 4 && query.allSatisfy(\.isASCII)
        let wordBoundaryRegex = isShortAscii
            ? try? NSRegularExpression(pattern: "(?:^|[^a-zA-Z])\(NSRegularExpression.escapedPattern(for: query))(?:[^a-zA-Z]|$)", options: .caseInsensitive)
            : nil
        while let file = enumerator?.nextObject() as? String {
            let filename = (file as NSString).lastPathComponent
            if ignoredDirs.contains(filename) {
                enumerator?.skipDescendants()
                continue
            }
            let matched: Bool
            if let regex = wordBoundaryRegex {
                matched = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) != nil
            } else {
                matched = filename.localizedCaseInsensitiveContains(query)
            }
            if matched {
                results.append(file)
                if results.count >= maxResults { break }
            }
        }
        if results.isEmpty {
            return ToolResult(output: "未找到匹配文件：\(query)", success: true)
        }
        return ToolResult(output: results.joined(separator: "\n"), data: ["count": "\(results.count)"])
    }

    private func searchContent(query: String, root: String, maxResults: Int, contextMode: ContextMode = .balanced) async throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Short ASCII queries get -w (whole word) to avoid "RAG" matching "draggable" etc.
        let isShortAscii = query.count <= 4 && query.allSatisfy(\.isASCII)
        var args = ["rg", "--no-heading", "-n", "--max-count", "\(maxResults)",
            "--max-filesize", "1M", "--glob", "!**/.git/**", "--glob", "!**/.build/**",
            "--glob", "!**/node_modules/**", "--glob", "!**/DerivedData/**"]
        if isShortAscii { args.append("-w") }
        args.append(contentsOf: [query, root])
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let timedOut = await waitForExit(process, timeoutSeconds: 8)
        if timedOut {
            process.terminate()
            process.waitUntilExit()
            return ToolResult(output: "搜索超时：\(query)", success: false, error: "search_timeout")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if output.isEmpty {
            return ToolResult(output: "未找到匹配内容：\(query)", success: true)
        }
        let maxChars: Int
        switch contextMode {
        case .economy: maxChars = 3_000
        case .balanced: maxChars = 10_000
        case .deep: maxChars = 50_000
        }
        let truncated = output.count > maxChars ? String(output.prefix(maxChars)) + "\n... (已截断，当前\(contextMode.rawValue)模式)" : output
        let count = output.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        return ToolResult(output: truncated, data: ["query": query, "count": "\(count)"])
    }

    private func waitForExit(_ process: Process, timeoutSeconds: TimeInterval) async -> Bool {
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
                try? await Task.sleep(for: .milliseconds(Int(timeoutSeconds * 1_000)))
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
}

// MARK: - Workspace Index Tool

public struct WorkspaceIndexTool: LaicaiTool {
    public var name: String { "workspace.index" }
    public var description: String { "生成受控的工作区索引，包含文件树摘要、语言分布、关键配置和入口候选。同一会话内不要重复调用。" }

    // Simple dedup: cache last index result per workspace root (5-minute TTL)
    private static var indexCache: [String: (result: ToolResult, at: Date)] = [:]
    private static let cacheTTL: TimeInterval = 300 // 5 minutes

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "maxFiles": FunctionProperty(type: "integer", description: "最多扫描文件数，默认300"),
                    "maxDepth": FunctionProperty(type: "integer", description: "最多目录深度，默认5")
                ],
                required: []
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var maxFiles: Int?
            var maxDepth: Int?
        }

        let params: Params
        do {
            let data = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: data)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let root = context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            return ToolResult(output: "请先设置工作区后再建立项目索引。", success: false, error: "workspace_missing")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ToolResult(output: "工作区不存在：\(root)", success: false, error: "workspace_not_found")
        }

        // Return cached result if indexed recently (prevents wasteful re-scans)
        if let cached = Self.indexCache[root],
           Date().timeIntervalSince(cached.at) < Self.cacheTTL {
            return ToolResult(
                output: "（缓存）" + cached.result.output + "\n\n⚠️ 该工作区在 \(Int(Date().timeIntervalSince(cached.at))) 秒前刚索引过，返回缓存结果。请勿重复调用 workspace.index。",
                data: cached.result.data
            )
        }

        let maxFiles = max(20, min(params.maxFiles ?? 300, 1000))
        let maxDepth = max(1, min(params.maxDepth ?? 5, 10))
        let ignored: Set<String> = [
            ".git", ".build", "DerivedData", "node_modules", "__pycache__", ".pytest_cache",
            ".mypy_cache", ".ruff_cache", ".venv", "venv", "venv3", "dist", "build",
            ".DS_Store"
        ]
        let importantNames: Set<String> = [
            "README.md", "AGENTS.md", "CLAUDE.md", "Package.swift", "pyproject.toml",
            "package.json", "Cargo.toml", "go.mod", "Makefile", "Dockerfile", "ROADMAP.md"
        ]

        var files: [String] = []
        var directories: Set<String> = []
        var languageCounts: [String: Int] = [:]
        var important: [String] = []
        var entryCandidates: [String] = []
        var testCandidates: [String] = []
        var configCandidates: [String] = []
        var riskCandidates: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: root)
        while let item = enumerator?.nextObject() as? String {
            let components = item.split(separator: "/").map(String.init)
            let name = components.last ?? item
            let lowerItem = item.lowercased()
            let lowerName = name.lowercased()
            if ignored.contains(name) || components.contains(where: { ignored.contains($0) }) {
                enumerator?.skipDescendants()
                continue
            }
            guard components.count <= maxDepth else {
                if FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(item), isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    enumerator?.skipDescendants()
                }
                continue
            }

            let full = (root as NSString).appendingPathComponent(item)
            var childIsDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &childIsDirectory)
            if childIsDirectory.boolValue {
                directories.insert(item)
                continue
            }

            files.append(item)
            let ext = (item as NSString).pathExtension.lowercased()
            let language = ext.isEmpty ? name : ext
            languageCounts[language, default: 0] += 1
            if importantNames.contains(name) || item.contains("/Tests/") || item.contains("/tests/") {
                important.append(item)
            }
            if importantNames.contains(name) || ["package.json", "pyproject.toml", "Package.swift", "Cargo.toml", "go.mod", "requirements.txt", "tsconfig.json"].contains(name) {
                configCandidates.append(item)
            }
            if lowerName == "main.swift" || lowerName == "main.py" || lowerName == "app.py" || lowerName == "index.ts" || lowerName == "index.js" || lowerName == "main.ts" || lowerName == "main.js" || lowerItem.hasPrefix("sources/") || lowerItem.contains("/sources/") || lowerItem.hasPrefix("src/") || lowerItem.contains("/src/") {
                entryCandidates.append(item)
            }
            if lowerItem.hasPrefix("test") || lowerItem.contains("/test") || lowerItem.contains("/tests/") || lowerName.hasPrefix("test_") || lowerName.hasSuffix("test.swift") || lowerName.hasSuffix("tests.swift") || lowerName.hasSuffix(".test.ts") || lowerName.hasSuffix(".spec.ts") {
                testCandidates.append(item)
            }
            if lowerItem.contains("todo") || lowerItem.contains("fixme") || lowerItem.contains("security") || lowerItem.contains("secret") || lowerItem.contains("auth") || lowerItem.contains("token") || lowerItem.contains("credential") {
                riskCandidates.append(item)
            }
            if files.count >= maxFiles { break }
        }

        let topDirs = directories.sorted().prefix(40)
        let topFiles = files.prefix(120)
        let languages = languageCounts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.prefix(12)

        // Module boundary detection: group files by top-level source directories
        let moduleBoundaries = Self.detectModuleBoundaries(files: files, directories: directories)

        // Dependency hotspots: files most referenced by import statements
        let dependencyHotspots = Self.detectDependencyHotspots(files: files, root: root)

        // Recent change hotspots: files modified in last 7 days via git
        let recentChanges = Self.detectRecentChangeHotspots(root: root)

        // Call graph: import-based dependency edges between local modules
        let callGraph = Self.detectCallGraph(files: files, root: root)

        // Test coverage: test-to-source mapping by naming convention
        let testCoverage = Self.detectTestCoverage(files: files)

        // Symbol extraction: lightweight regex-based extraction of key symbols from source files
        let symbolIndex = Self.extractSymbols(files: entryCandidates + important, root: root, limit: 40)
        let sourceKitAvailable = Self.commandAvailable("sourcekit-lsp")
        let treeSitterAvailable = Self.commandAvailable("tree-sitter")
        let indexEngine = sourceKitAvailable ? "sourcekit-ready+regex-lightweight" : (treeSitterAvailable ? "tree-sitter-ready+regex-lightweight" : "regex-lightweight")

        let output = """
        工作区：\(root)
        已索引：\(files.count) 个文件，\(directories.count) 个目录（上限 \(maxFiles) 文件，深度 \(maxDepth)）
        索引引擎：\(indexEngine)

        语言/类型分布：
        \(languages.map { "- \($0.key): \($0.value)" }.joined(separator: "\n"))

        关键文件：
        \((important.isEmpty ? Array(topFiles.prefix(20)) : Array(important.prefix(40))).map { "- \($0)" }.joined(separator: "\n"))

        入口候选：
        \(entryCandidates.prefix(30).map { "- \($0)" }.joined(separator: "\n"))

        测试候选：
        \(testCandidates.prefix(30).map { "- \($0)" }.joined(separator: "\n"))

        配置候选：
        \(configCandidates.prefix(30).map { "- \($0)" }.joined(separator: "\n"))

        风险/关注候选：
        \((riskCandidates.isEmpty ? ["- 暂未从路径名发现明显风险文件"] : riskCandidates.prefix(30).map { "- \($0)" }).joined(separator: "\n"))

        模块边界：
        \(moduleBoundaries.isEmpty ? "- 未检测到明显模块分区" : moduleBoundaries.prefix(15).map { "- \($0)" }.joined(separator: "\n"))

        符号索引（关键类型与函数）：
        \(symbolIndex.isEmpty ? "- 未提取到符号" : symbolIndex.prefix(60).map { "- \($0)" }.joined(separator: "\n"))

        依赖热点（被最多文件引用）：
        \(dependencyHotspots.isEmpty ? "- 未检测到明显依赖热点" : dependencyHotspots.prefix(10).map { "- \($0)" }.joined(separator: "\n"))

        最近改动热点（7天内）：
        \(recentChanges.isEmpty ? "- 暂无最近改动记录" : recentChanges.prefix(15).map { "- \($0)" }.joined(separator: "\n"))

        调用图（模块间依赖）：
        \(callGraph.isEmpty ? "- 未检测到模块间调用关系" : callGraph.map { "- \($0)" }.joined(separator: "\n"))

        测试覆盖关系：
        \(testCoverage.isEmpty ? "- 未检测到测试文件" : testCoverage.map { "- \($0)" }.joined(separator: "\n"))

        顶层/重要目录：
        \(topDirs.map { "- \($0)/" }.joined(separator: "\n"))

        文件样例：
        \(topFiles.map { "- \($0)" }.joined(separator: "\n"))
        """

        await AuditLog.shared.record(
            tool: name,
            input: argumentsJSON,
            output: "索引 \(files.count) 个文件，\(directories.count) 个目录",
            success: true
        )

        let result = ToolResult(
            output: output,
            data: [
                "fileCount": "\(files.count)",
                "directoryCount": "\(directories.count)",
                "entryCount": "\(entryCandidates.count)",
                "testCount": "\(testCandidates.count)",
                "configCount": "\(configCandidates.count)",
                "riskCount": "\(riskCandidates.count)",
                "root": root,
                "indexEngine": indexEngine,
                "sourceKitAvailable": "\(sourceKitAvailable)",
                "treeSitterAvailable": "\(treeSitterAvailable)"
            ]
        )
        Self.indexCache[root] = (result, Date())
        return result
    }

    // MARK: - Workspace Analysis Helpers

    private static func commandAvailable(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", command]
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

    /// Detect module boundaries by grouping files under common top-level source directories.
    private static func detectModuleBoundaries(files: [String], directories: Set<String>) -> [String] {
        let sourcePrefixes = ["Sources/", "src/", "lib/", "app/", "pkg/", "internal/", "cmd/", "modules/"]
        var moduleGroups: [String: (count: Int, languages: Set<String>)] = [:]

        for file in files {
            let components = file.components(separatedBy: "/")
            guard components.count >= 2 else { continue }
            // Find the first source-like prefix
            if let sourceIdx = components.firstIndex(where: { sourcePrefixes.contains($0 + "/") }) {
                // Module = the directory right after the source prefix
                let moduleIdx = sourceIdx + 1
                if moduleIdx < components.count {
                    let moduleName = components[moduleIdx]
                    let ext = (file as NSString).pathExtension.lowercased()
                    if !moduleName.isEmpty {
                        if moduleGroups[moduleName] == nil {
                            moduleGroups[moduleName] = (1, [ext])
                        } else {
                            moduleGroups[moduleName]!.count += 1
                            moduleGroups[moduleName]!.languages.insert(ext)
                        }
                    }
                }
            }
        }

        return moduleGroups.sorted { $0.value.count > $1.value.count }.map { module in
            let langs = module.value.languages.sorted().prefix(3).joined(separator: "/")
            return "\(module.key)（\(module.value.count) 文件，\(langs)）"
        }
    }

    /// Detect dependency hotspots by scanning import statements.
    private static func detectDependencyHotspots(files: [String], root: String) -> [String] {
        var importCounts: [String: Int] = [:]
        let importPatterns: [(prefix: String, extract: (String) -> String?)] = [
            // Swift: import Foo or import struct Foo.Bar
            ("import ", { line in
                let parts = line.dropFirst("import ".count).split(separator: " ", maxSplits: 1)
                return parts.first.map { String($0) }
            }),
            // Python: from foo import bar or import foo
            ("from ", { line in
                let parts = line.dropFirst("from ".count).split(separator: " ", maxSplits: 1)
                return parts.first.map { String($0) }
            }),
            ("import ", { line in
                let parts = line.dropFirst("import ".count).split(separator: ",", maxSplits: 1)
                return parts.first.map { String($0).trimmingCharacters(in: .whitespaces) }
            }),
            // JS/TS: import ... from 'foo'
            ("from '", { line in
                if let start = line.range(of: "from '")?.upperBound,
                   let end = line[start...].firstIndex(of: "'") {
                    return String(line[start..<end])
                }
                return nil
            }),
            ("from \"", { line in
                if let start = line.range(of: "from \"")?.upperBound,
                   let end = line[start...].firstIndex(of: "\"") {
                    return String(line[start..<end])
                }
                return nil
            }),
        ]

        for file in files.prefix(80) {
            let fullPath = (root as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: "\n").prefix(60) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for pattern in importPatterns {
                    if trimmed.hasPrefix(pattern.prefix), let module = pattern.extract(trimmed), !module.isEmpty {
                        importCounts[module, default: 0] += 1
                    }
                }
            }
        }

        return importCounts.sorted { $0.value > $1.value }.map { "\($0.key)（被 \($0.value) 个文件引用）" }
    }

    /// Detect recently changed files via `git log --since=7.days`.
    private static func detectRecentChangeHotspots(root: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "log", "--name-only", "--pretty=format:", "--since=7.days", "--no-merges"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let files = output.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var counts: [String: Int] = [:]
            for file in files { counts[file, default: 0] += 1 }
            return counts.sorted { $0.value > $1.value }.map { "\($0.key)（\($0.value) 次改动）" }
        } catch {
            return []
        }
    }

    /// Infer call graph edges from import chains (A imports B → A depends on B).
    private static func detectCallGraph(files: [String], root: String) -> [String] {
        var edges: [String: Set<String>] = [:]  // file → set of imported local modules
        let localPrefixes = files.map { (file: String) -> String in
            let components = file.components(separatedBy: "/")
            return components.count >= 2 ? components[0] : ""
        }
        let uniqueLocalPrefixes = Set(localPrefixes).filter { !$0.isEmpty }

        for file in files.prefix(60) {
            let ext = (file as NSString).pathExtension.lowercased()
            guard ["swift", "py", "js", "ts", "go"].contains(ext) else { continue }
            let fullPath = (root as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            var localImports: Set<String> = []
            for line in content.components(separatedBy: "\n").prefix(40) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Swift: import ModuleName
                if ext == "swift" && trimmed.hasPrefix("import ") {
                    let module = String(trimmed.dropFirst("import ".count).split(separator: " ").first ?? "")
                    if uniqueLocalPrefixes.contains(module) { localImports.insert(module) }
                }
                // Python: from pkg import or import pkg
                if ext == "py" && (trimmed.hasPrefix("from ") || trimmed.hasPrefix("import ")) {
                    let pkg = trimmed.hasPrefix("from ")
                        ? String(trimmed.dropFirst("from ".count).split(separator: " ").first ?? "")
                        : String(trimmed.dropFirst("import ".count).split(separator: ",").first?.split(separator: " ").first ?? "")
                    if uniqueLocalPrefixes.contains(pkg) { localImports.insert(pkg) }
                }
                // Go: import "pkg" or import alias "pkg"
                if ext == "go" && trimmed.contains("import") {
                    if let range = trimmed.range(of: "\""), let endRange = trimmed.range(of: "\"", range: range.upperBound..<trimmed.endIndex) {
                        let pkg = String(trimmed[range.upperBound..<endRange.lowerBound])
                        let leaf = (pkg as NSString).lastPathComponent
                        if uniqueLocalPrefixes.contains(leaf) { localImports.insert(leaf) }
                    }
                }
            }
            if !localImports.isEmpty {
                let fileModule = file.components(separatedBy: "/").first ?? file
                edges[fileModule, default: []].formUnion(localImports)
            }
        }
        return edges.sorted { $0.value.count > $1.value.count }.prefix(12).map { edge in
            let targets = edge.value.sorted().joined(separator: " → ")
            return "\(edge.key) → \(targets)"
        }
    }

    /// Detect test-to-source coverage mapping by naming convention.
    private static func detectTestCoverage(files: [String]) -> [String] {
        let testPatterns = ["Test", "Spec", "test", "spec", "_test", "_spec"]
        let testFiles = files.filter { file in
            let name = (file as NSString).lastPathComponent
            let ext = (file as NSString).pathExtension.lowercased()
            guard ["swift", "py", "js", "ts", "go"].contains(ext) else { return false }
            return testPatterns.contains(where: { name.contains($0) })
        }
        let sourceFiles = files.filter { file in
            let name = (file as NSString).lastPathComponent
            let ext = (file as NSString).pathExtension.lowercased()
            guard ["swift", "py", "js", "ts", "go"].contains(ext) else { return false }
            return !testPatterns.contains(where: { name.contains($0) })
        }

        var coverageMap: [String: [String]] = [:]  // source → [test files]
        for testFile in testFiles {
            let testName = (testFile as NSString).lastPathComponent
            // Strip test suffixes to find matching source
            var baseName = testName
            for suffix in ["Tests.swift", "Test.swift", "Spec.swift", "_test.py", "_spec.py", ".test.js", ".test.ts", ".spec.js", ".spec.ts", "_test.go"] {
                if baseName.hasSuffix(suffix) {
                    baseName = String(baseName.dropLast(suffix.count))
                    break
                }
            }
            // Find matching source files
            for sourceFile in sourceFiles {
                let sourceName = (sourceFile as NSString).lastPathComponent
                let sourceBase = (sourceName as NSString).deletingPathExtension
                if sourceBase == baseName || sourceBase.hasPrefix(baseName) || baseName.hasPrefix(sourceBase) {
                    coverageMap[sourceFile, default: []].append(testFile)
                }
            }
        }

        let covered = coverageMap.count
        let uncovered = sourceFiles.count - covered
        var lines: [String] = []
        if !testFiles.isEmpty {
            lines.append("测试文件 \(testFiles.count) 个，覆盖源文件 \(covered)/\(sourceFiles.count)")
        }
        if uncovered > 0 && uncovered <= sourceFiles.count {
            lines.append("未覆盖源文件 \(uncovered) 个")
        }
        for (source, tests) in coverageMap.sorted(by: { $0.value.count > $1.value.count }).prefix(8) {
            let testNames = tests.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            lines.append("  \((source as NSString).lastPathComponent) ← \(testNames)")
        }
        return lines
    }

    /// Extract key symbols (functions, types, classes, protocols) from source files using regex
    /// and sourcekit-lsp when available for Swift files.
    private static func extractSymbols(files: [String], root: String, limit: Int) -> [String] {
        let sourceKitAvailable = commandAvailable("sourcekit-lsp")
        var result: [String] = []
        let uniqueFiles = Array(Set(files))

        // If sourcekit-lsp is available, use it for Swift files first
        if sourceKitAvailable {
            let swiftFiles = uniqueFiles.filter { (file: String) -> Bool in
                (file as NSString).pathExtension.lowercased() == "swift"
            }.prefix(limit)
            for file in swiftFiles {
                let fullPath = (root as NSString).appendingPathComponent(file)
                let symbols = extractSymbolsViaSourceKit(filePath: fullPath)
                if !symbols.isEmpty {
                    let shortPath = (file as NSString).lastPathComponent
                    result.append("\(shortPath): \(symbols.prefix(10).joined(separator: ", "))")
                }
            }
            let nonSwiftFiles = uniqueFiles.filter { (file: String) -> Bool in
                (file as NSString).pathExtension.lowercased() != "swift"
            }.prefix(max(0, limit - result.count))
            result.append(contentsOf: extractSymbolsViaRegex(files: Array(nonSwiftFiles), root: root, limit: limit - result.count))
        } else {
            result = extractSymbolsViaRegex(files: uniqueFiles, root: root, limit: limit)
        }
        return result
    }

    /// Regex-based symbol extraction (original logic, extracted for reuse)
    private static func extractSymbolsViaRegex(files: [String], root: String, limit: Int) -> [String] {
        let patterns: [(ext: String, pattern: String)] = [
            ("swift", #"(?:public\s+|private\s+|internal\s+|open\s+)?(?:final\s+)?(?:class|struct|enum|protocol|actor)\s+(\w+)"#),
            ("swift", #"(?:public\s+|private\s+|internal\s+|open\s+)?func\s+(\w+)\s*\("#),
            ("py", #"(?:class|def)\s+(\w+)\s*[\(:]"#),
            ("ts", #"(?:export\s+)?(?:class|interface|type|function|const)\s+(\w+)"#),
            ("js", #"(?:export\s+)?(?:class|function|const)\s+(\w+)"#),
            ("go", #"(?:func|type)\s+(\w+)"#),
            ("rs", #"(?:pub\s+)?(?:fn|struct|enum|trait|impl|type)\s+(\w+)"#),
        ]

        var compiled: [String: [NSRegularExpression]] = [:]
        for (ext, pattern) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) {
                compiled[ext, default: []].append(regex)
            }
        }

        var result: [String] = []
        for file in files.prefix(limit) {
            let ext = (file as NSString).pathExtension.lowercased()
            guard let regexes = compiled[ext] else { continue }
            let fullPath = (root as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }

            let linesToScan = content.components(separatedBy: "\n").prefix(200).joined(separator: "\n")
            let nsStr = linesToScan as NSString
            var fileSymbols: [String] = []

            for regex in regexes {
                let matches = regex.matches(in: linesToScan, range: NSRange(location: 0, length: nsStr.length))
                for match in matches {
                    if match.numberOfRanges > 1 {
                        let name = nsStr.substring(with: match.range(at: 1))
                        if name.count >= 2 && !name.hasPrefix("_") {
                            fileSymbols.append(name)
                        }
                    }
                }
            }

            if !fileSymbols.isEmpty {
                let shortPath = (file as NSString).lastPathComponent
                let symbols = Array(Set(fileSymbols)).sorted().prefix(8).joined(separator: ", ")
                result.append("\(shortPath): \(symbols)")
            }
        }
        return result
    }

    /// Use sourcekit-lsp to extract Swift symbols with kind info (class/struct/func/etc.)
    private static func extractSymbolsViaSourceKit(filePath: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sourcekit-lsp", "query", "-file", filePath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        // sourcekit-lsp doesn't have a direct query CLI; fall back to using
        // `swift-ide-test` or regex — use enhanced regex with kind annotation
        // For now, use a richer regex pattern that captures the keyword + name
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: "\n").prefix(300)
        var symbols: [String] = []
        let typePattern = #"^\s*(?:public\s+|private\s+|internal\s+|open\s+)?(?:final\s+)?(class|struct|enum|protocol|actor)\s+(\w+)"#
        let funcPattern = #"^\s*(?:public\s+|private\s+|internal\s+|open\s+|override\s+|static\s+|class\s+)*func\s+(\w+)\s*[\(<]"#
        let varPattern = #"^\s*(?:public\s+|private\s+|internal\s+)?(?:static\s+|class\s+)?(?:let|var)\s+(\w+)\s*[:=]"#

        if let typeRegex = try? NSRegularExpression(pattern: typePattern),
           let funcRegex = try? NSRegularExpression(pattern: funcPattern),
           let varRegex = try? NSRegularExpression(pattern: varPattern) {
            let nsContent = lines.joined(separator: "\n") as NSString
            let fullRange = NSRange(location: 0, length: nsContent.length)

            for match in typeRegex.matches(in: nsContent as String, range: fullRange) {
                if match.numberOfRanges > 2 {
                    let kind = nsContent.substring(with: match.range(at: 1))
                    let name = nsContent.substring(with: match.range(at: 2))
                    if name.count >= 2 && !name.hasPrefix("_") { symbols.append("\(kind) \(name)") }
                }
            }
            for match in funcRegex.matches(in: nsContent as String, range: fullRange) {
                if match.numberOfRanges > 1 {
                    let name = nsContent.substring(with: match.range(at: 1))
                    if name.count >= 2 && !name.hasPrefix("_") { symbols.append("func \(name)") }
                }
            }
            for match in varRegex.matches(in: nsContent as String, range: fullRange) {
                if match.numberOfRanges > 1 {
                    let name = nsContent.substring(with: match.range(at: 1))
                    if name.count >= 2 && !name.hasPrefix("_") { symbols.append("var \(name)") }
                }
            }
        }
        return symbols
    }
}
