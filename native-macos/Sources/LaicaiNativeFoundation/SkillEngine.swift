import Foundation
import LaicaiNativeDomain

// MARK: - Skill Definition

public struct SkillDefinition: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var description: String
    public var tools: [String]
    public var workflowName: String?
    public var modelPreference: ModelPreference
    public var isBuiltin: Bool
    public var isPublished: Bool
    public var systemHint: String?
    public var category: String?

    public init(
        id: UUID = UUID(),
        name: String,
        description: String,
        tools: [String] = [],
        workflowName: String? = nil,
        modelPreference: ModelPreference = .default,
        isBuiltin: Bool = false,
        isPublished: Bool = false,
        systemHint: String? = nil,
        category: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.tools = tools
        self.workflowName = workflowName
        self.modelPreference = modelPreference
        self.isBuiltin = isBuiltin
        self.isPublished = isPublished
        self.systemHint = systemHint
        self.category = category
    }
}

public enum ModelPreference: String, Codable, Sendable, CaseIterable {
    case `default` = "default"
    case fast = "fast"
    case strong = "strong"
    case code = "code"

    public var title: String {
        switch self {
        case .default: return "默认"
        case .fast: return "快速"
        case .strong: return "强力"
        case .code: return "代码"
        }
    }

    public var icon: String {
        switch self {
        case .default: return "cpu"
        case .fast: return "bolt"
        case .strong: return "brain"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - Skill Registry

@MainActor
public final class SkillRegistry: ObservableObject {
    public static let shared = SkillRegistry()

    @Published public private(set) var skills: [SkillDefinition] = builtinSkills

    private init() {}

    /// Non-isolated accessor for builtin skills array
    public nonisolated static func loadBuiltinSkills() -> [SkillDefinition] {
        builtinSkills
    }

    /// Non-isolated summary of builtin skills for injection into system prompt
    public nonisolated static func skillSummary() -> String {
        let all = builtinSkills
        guard !all.isEmpty else { return "" }
        var catCounts: [String: Int] = [:]
        for skill in all { catCounts[skill.category ?? "通用/开发", default: 0] += 1 }
        let breakdown = catCounts.sorted(by: { $0.value > $1.value }).map { "\($0.key) \($0.value)" }.joined(separator: "、")
        return "共 \(all.count) 个技能（\(breakdown)）"
    }

    public func refresh(workspaceRoot: String) {
        var next = builtinSkills
        for skill in Self.loadLocalSkills(workspaceRoot: workspaceRoot)
        where !next.contains(where: { $0.name == skill.name }) {
            next.append(skill)
        }
        skills = next
    }

    public func register(_ skill: SkillDefinition) {
        if !skills.contains(where: { $0.name == skill.name }) {
            skills.append(skill)
        }
    }

    /// Publish a skill: marks it as published and persists it to .laicai/skills/
    public func publish(skillID: UUID, workspaceRoot: String) -> Bool {
        guard let index = skills.firstIndex(where: { $0.id == skillID }) else { return false }
        skills[index].isPublished = true
        let skill = skills[index]
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return true }
        let dir = (root as NSString).appendingPathComponent(".laicai/skills")
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(skill.name).json")
            let data = try JSONEncoder().encode(skill)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            LaicaiLog.error("技能发布失败：\(error.localizedDescription)")
            return false
        }
    }

    public func skill(named name: String) -> SkillDefinition? {
        skills.first(where: { $0.name == name })
    }

    public func skillsForIntent(_ intent: UserIntent) -> [SkillDefinition] {
        switch intent {
        case .chat:
            return skills.filter { $0.tools.isEmpty && $0.workflowName == nil }
        case .research:
            return skills.filter { $0.tools.contains("web.search") || $0.tools.contains("web.fetch") }
        case .task:
            return skills.filter { !$0.tools.isEmpty || $0.workflowName != nil }
        case .workflow(let name):
            return skills.filter { $0.workflowName == name }
        }
    }

    @discardableResult
    public func createDraft(
        name: String,
        description: String,
        tools: [String],
        workflowName: String? = nil,
        category: String? = nil,
        workspaceRoot: String
    ) throws -> SkillDefinition {
        let skill = SkillDefinition(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            tools: tools,
            workflowName: workflowName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            modelPreference: tools.contains("file.write") ? .code : .default,
            isBuiltin: false,
            category: category
        )

        let dir = (workspaceRoot as NSString).appendingPathComponent(".laicai/skills")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let filename = Self.slug(skill.name).isEmpty ? skill.id.uuidString : Self.slug(skill.name)
        let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("\(filename).json"))
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SkillRegistryError.alreadyExists(skill.name)
        }
        let data = try JSONEncoder.pretty.encode(skill)
        try data.write(to: url, options: .atomic)
        register(skill)
        return skill
    }

    public nonisolated static func loadLocalSkills(workspaceRoot: String) -> [SkillDefinition] {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return [] }

        let dirs = [
            (root as NSString).appendingPathComponent(".laicai/skills"),
            (root as NSString).appendingPathComponent("skills"),
        ]
        let urls = dirs.flatMap { dir in
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        return
            urls
            .flatMap { url -> [URL] in
                if url.pathExtension.lowercased() == "json" { return [url] }
                if url.pathExtension.lowercased() == "md" { return [url] }
                let nested = url.appendingPathComponent("skill.json")
                return FileManager.default.fileExists(atPath: nested.path) ? [nested] : []
            }
            .compactMap { url -> SkillDefinition? in
                guard let data = try? Data(contentsOf: url) else {
                    return nil
                }
                var skill: SkillDefinition
                if let decoded = try? JSONDecoder().decode(SkillDefinition.self, from: data) {
                    skill = decoded
                } else if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let name = raw["name"] as? String
                {
                    let description = raw["description"] as? String ?? "本地 skill：\(name)"
                    let tools = Self.normalizedTools(from: raw)
                    let prompt = Self.loadPromptHint(for: url)
                    skill = SkillDefinition(
                        name: name,
                        description: description,
                        tools: tools,
                        isBuiltin: false,
                        isPublished: true,
                        systemHint: prompt
                    )
                } else if url.pathExtension.lowercased() == "md",
                    let markdown = String(data: data, encoding: .utf8),
                    let parsed = Self.skillFromMarkdown(markdown, url: url)
                {
                    skill = parsed
                } else {
                    return nil
                }
                skill.isBuiltin = false
                skill.isPublished = true
                return skill
            }
            .sorted { $0.name < $1.name }
    }

    private nonisolated static func normalizedTools(from raw: [String: Any]) -> [String] {
        var values = raw["tools"] as? [String] ?? []
        if values.isEmpty,
            let requires = raw["requires"] as? [String: Any],
            let requiredTools = requires["tools"] as? [String]
        {
            values = requiredTools
        }
        if values.isEmpty,
            let steps = raw["steps"] as? [[String: Any]]
        {
            values = steps.compactMap { step in
                switch step["kind"] as? String {
                case "web_fetch": return "web.fetch"
                case "vault_context": return "vault.search"
                case "save_note": return "vault.capture"
                default: return nil
                }
            }
        }
        return Array(Set(values.map(ToolNameCodec.canonicalName))).sorted()
    }

    private nonisolated static func skillFromMarkdown(_ markdown: String, url: URL) -> SkillDefinition? {
        let frontmatter = parseFrontmatter(markdown)
        let rawName = frontmatter["name"] ?? headingName(in: markdown)
        guard let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        let description = (frontmatter["description"] ?? firstBodyParagraph(in: markdown) ?? "本地 skill：\(name)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tools = normalizedTools(fromFrontmatterValue: frontmatter["tools"])
        let category = normalizeSkillCategory(frontmatter["category"])
        let hint = markdown.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { String($0.prefix(4000)) }
        return SkillDefinition(
            name: name,
            description: description.isEmpty ? "本地 skill：\(name)" : description,
            tools: tools,
            workflowName: frontmatter["workflowName"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            modelPreference: tools.contains("file.write") ? .code : .default,
            isBuiltin: false,
            isPublished: true,
            systemHint: hint,
            category: category
        )
    }

    private nonisolated static func parseFrontmatter(_ markdown: String) -> [String: String] {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                break
            }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private nonisolated static func normalizedTools(fromFrontmatterValue value: String?) -> [String] {
        guard let value else { return [] }
        let cleaned =
            value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let tools =
            cleaned
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
            .map(ToolNameCodec.canonicalName)
        return Array(Set(tools)).sorted()
    }

    private nonisolated static func headingName(in markdown: String) -> String? {
        markdown.components(separatedBy: .newlines).first { $0.hasPrefix("# ") }?
            .dropFirst(2)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func firstBodyParagraph(in markdown: String) -> String? {
        var inFrontmatter = markdown.hasPrefix("---")
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" {
                inFrontmatter.toggle()
                continue
            }
            guard !inFrontmatter else { continue }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            return trimmed
        }
        return nil
    }

    public nonisolated static func normalizeSkillCategory(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        let aliases: [String: String] = [
            "通用": "general", "通用/开发": "general", "默认": "general", "general": "general",
            "知识": "knowledge", "知识库": "knowledge", "knowledge": "knowledge",
            "营销": "marketing", "marketing": "marketing",
            "产品": "product", "product": "product",
            "内容": "content", "写作": "content", "content": "content",
            "设计": "design", "design": "design",
            "数据": "data", "data": "data",
            "商业": "business", "business": "business",
            "分析": "analysis", "analysis": "analysis",
            "编辑": "editing", "editing": "editing",
            "执行": "execution", "execution": "execution",
            "研究": "research", "research": "research",
            "流程": "workflow", "workflow": "workflow",
            "元技能": "meta", "meta": "meta",
        ]
        return aliases[raw] ?? aliases[lower] ?? lower
    }

    private nonisolated static func loadPromptHint(for manifestURL: URL) -> String? {
        let promptURL = manifestURL.deletingLastPathComponent().appendingPathComponent("prompt.md")
        guard let prompt = try? String(contentsOf: promptURL, encoding: .utf8) else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(4000))
    }

    private static func slug(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\u{4e00}-\u{9fa5}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public enum SkillRegistryError: LocalizedError {
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let name): return "技能已存在：\(name)"
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension JSONEncoder {
    fileprivate static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

// MARK: - Model Router

public struct ModelRouter {

    // ── Public API ────────────────────────────────────────────────────────

    /// Route by skill preference (fast/strong/code/default).
    public static func selectModel(
        for skill: SkillDefinition,
        connectors: [ConnectorProfile],
        activeConnectorID: UUID?
    ) -> ConnectorProfile? {
        switch skill.modelPreference {
        case .default:
            return connectors.first(where: { $0.id == activeConnectorID }) ?? connectors.first
        case .fast:
            return findByRole(.fast, in: connectors)
                ?? findByNameHeuristic(.fast, in: connectors)
                ?? connectors.first(where: { $0.id == activeConnectorID })
                ?? connectors.first
        case .strong:
            return findByRole(.strong, in: connectors)
                ?? findByNameHeuristic(.strong, in: connectors)
                ?? connectors.first(where: { $0.id == activeConnectorID })
                ?? connectors.first
        case .code:
            return findByRole(.code, in: connectors)
                ?? findByNameHeuristic(.code, in: connectors)
                ?? connectors.first(where: { $0.id == activeConnectorID })
                ?? connectors.first
        }
    }

    /// Route by user intent: chat→fast, research→strong, task→code, workflow→default.
    public static func selectModel(
        forIntent intent: UserIntent,
        connectors: [ConnectorProfile],
        activeConnectorID: UUID?
    ) -> ConnectorProfile? {
        let active = connectors.first(where: { $0.id == activeConnectorID }) ?? connectors.first
        guard connectors.count > 1 else { return active }
        guard let role = roleForIntent(intent) else { return active }
        return findByRole(role, in: connectors)
            ?? findByNameHeuristic(role, in: connectors)
            ?? active
    }

    /// Route by task phase: explore→fast, execute→code, verify→strong, summarize→default.
    public static func selectModel(
        forPhase phase: TaskPhase,
        connectors: [ConnectorProfile],
        activeConnectorID: UUID?
    ) -> ConnectorProfile? {
        let active = connectors.first(where: { $0.id == activeConnectorID }) ?? connectors.first
        guard connectors.count > 1 else { return active }
        guard let role = roleForPhase(phase) else { return active }
        return findByRole(role, in: connectors)
            ?? findByNameHeuristic(role, in: connectors)
            ?? active
    }

    // ── Private helpers ───────────────────────────────────────────────────

    /// Find a connector whose explicit `role` matches. Skips unhealthy connectors.
    private static func findByRole(_ role: ConnectorRole, in connectors: [ConnectorProfile]) -> ConnectorProfile? {
        connectors.first(where: { $0.role == role && $0.health != .offline })
    }

    /// Legacy fallback: guess role from model name / kind strings.
    /// Used only when no connector has an explicit role set.
    private static func findByNameHeuristic(_ role: ConnectorRole, in connectors: [ConnectorProfile]) -> ConnectorProfile? {
        switch role {
        case .fast:
            return connectors.first(where: { $0.kind.contains("ollama") || $0.modelName.contains("mini") || $0.modelName.contains("flash") }
            )
        case .code:
            return connectors.first(where: {
                $0.modelName.contains("code") || $0.modelName.contains("coder") || $0.modelName.contains("deepseek")
            })
        case .strong:
            return connectors.first(where: {
                $0.modelName.contains("gpt-4") || $0.modelName.contains("claude") || $0.modelName.contains("opus")
                    || $0.modelName.contains("max")
            })
        }
    }

    private static func roleForIntent(_ intent: UserIntent) -> ConnectorRole? {
        switch intent {
        case .chat: return .fast
        case .research: return .strong
        case .task: return .code
        case .workflow: return nil
        }
    }

    private static func roleForPhase(_ phase: TaskPhase) -> ConnectorRole? {
        switch phase {
        case .explore: return .fast
        case .execute: return .code
        case .verify: return .strong
        case .summarize: return nil
        }
    }
}

// MARK: - Skill Matcher (Auto-routing)

public struct SkillMatchResult: Sendable {
    public let skill: SkillDefinition
    public let score: Double
    public let reason: String
}

private struct SkillCandidate {
    let skill: SkillDefinition
    let score: Double
    let reason: String
}

private struct SkillKeywordPattern {
    let keywords: [String]
    let skillName: String
    let boost: Double
}

public struct SkillMatcher {
    /// Minimum score threshold to consider a skill match valid
    private static let threshold: Double = 0.50

    /// Match user input to the best skill from the registry.
    /// Returns nil if no skill scores above threshold.
    @MainActor
    public static func match(input: String, intent: UserIntent = .task) -> SkillMatchResult? {
        let skills = SkillRegistry.shared.skills
        let lower = input.lowercased()
        let tokens = lower.split { !$0.isLetter && !$0.isNumber && $0 != "." }
            .map(String.init)
            .filter { $0.count > 1 }

        var best: SkillCandidate?

        for skill in skills {
            let score = computeScore(input: lower, tokens: tokens, skill: skill, intent: intent)
            if score > (best?.score ?? 0) {
                let reason = describeMatch(skill: skill, score: score)
                best = SkillCandidate(skill: skill, score: score, reason: reason)
            }
        }

        guard let match = best, match.score >= threshold else { return nil }
        return SkillMatchResult(skill: match.skill, score: match.score, reason: match.reason)
    }

    private static func computeScore(input: String, tokens: [String], skill: SkillDefinition, intent: UserIntent) -> Double {
        var score: Double = 0

        // Short inputs are too ambiguous for skill matching
        if input.count < 8 { return 0 }

        // 1. Keyword synonyms / patterns — primary matching signal
        let kwBoost = keywordBoost(input: input, skill: skill)
        score += kwBoost

        // 2. Exact skill name in input (only for longer, specific names ≥ 3 chars)
        let nameLower = skill.name.lowercased()
        if nameLower.count >= 3 && input.contains(nameLower) {
            score += 0.4
        }

        // 3. Token overlap — minor signal only, avoid matching on common words
        let stopWords: Set<String> = [
            "的", "是", "在", "了", "和", "与", "用", "为", "一", "个", "不", "有", "这", "到", "上", "中", "大", "可以", "请", "帮", "我", "你", "把",
            "the", "a", "an", "is", "in", "to", "of", "for", "and", "or", "with", "by", "from", "on", "at",
            "文件", "内容", "数据", "工具", "使用", "生成", "创建", "写", "读", "分析", "文档", "格式", "方案", "设计", "管理",
        ]
        let skillNameTokens = Set(
            skill.name.lowercased().split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 1 && !stopWords.contains($0) })
        let inputTokenSet = Set(tokens.filter { !stopWords.contains($0) })
        let overlap = inputTokenSet.intersection(skillNameTokens)
        if !skillNameTokens.isEmpty && overlap.count >= 2 {
            score += 0.15
        }

        // 4. Penalize workflow skills (they have their own routing)
        if skill.workflowName != nil {
            score -= 0.15
        }

        return min(score, 1.0)
    }

    /// Boost score for common synonyms and patterns that map to specific skills
    private static func keywordBoost(input: String, skill: SkillDefinition) -> Double {
        let patterns: [SkillKeywordPattern] = [
            // Marketing
            SkillKeywordPattern(keywords: ["小红书", "种草", "笔记"], skillName: "小红书笔记", boost: 0.5),
            SkillKeywordPattern(keywords: ["公众号", "微信文章"], skillName: "公众号文章", boost: 0.5),
            SkillKeywordPattern(keywords: ["短视频", "抖音", "脚本", "视频号"], skillName: "短视频脚本", boost: 0.5),
            SkillKeywordPattern(keywords: ["seo", "搜索优化"], skillName: "SEO 优化", boost: 0.4),
            SkillKeywordPattern(keywords: ["广告文案", "投放文案", "信息流"], skillName: "广告投放文案", boost: 0.4),
            SkillKeywordPattern(keywords: ["营销", "推广", "宣传"], skillName: "营销文案", boost: 0.3),
            SkillKeywordPattern(keywords: ["评价回复", "好评回复", "差评回复"], skillName: "用户评价回复", boost: 0.4),
            // Product
            SkillKeywordPattern(keywords: ["prd", "需求文档", "产品需求"], skillName: "PRD 编写", boost: 0.5),
            SkillKeywordPattern(keywords: ["用户故事", "user story"], skillName: "用户故事", boost: 0.4),
            SkillKeywordPattern(keywords: ["okr", "目标管理"], skillName: "OKR 制定", boost: 0.4),
            SkillKeywordPattern(keywords: ["排期", "优先级"], skillName: "功能优先级排序", boost: 0.3),
            SkillKeywordPattern(keywords: ["发布计划", "上线"], skillName: "产品发布计划", boost: 0.3),
            // Content
            SkillKeywordPattern(keywords: ["周报", "日报"], skillName: "周报/日报", boost: 0.5),
            SkillKeywordPattern(keywords: ["邮件", "email"], skillName: "邮件撰写", boost: 0.4),
            SkillKeywordPattern(keywords: ["会议纪要", "会议记录"], skillName: "会议纪要", boost: 0.5),
            SkillKeywordPattern(keywords: ["长文", "深度文章"], skillName: "长文写作", boost: 0.3),
            SkillKeywordPattern(keywords: ["改写", "文风"], skillName: "文风改写", boost: 0.4),
            SkillKeywordPattern(keywords: ["翻译", "translate"], skillName: "多语言翻译", boost: 0.4),
            // Design
            SkillKeywordPattern(keywords: ["ppt", "演示", "汇报", "presentation", "slide"], skillName: "演示文稿制作", boost: 0.5),
            SkillKeywordPattern(keywords: ["ui设计", "ui方案", "界面设计", "ux"], skillName: "UI 设计方案", boost: 0.5),
            SkillKeywordPattern(keywords: ["品牌", "logo", "vi", "视觉识别"], skillName: "品牌视觉设计", boost: 0.5),
            // Data
            SkillKeywordPattern(keywords: ["excel", "公式", "表格"], skillName: "Excel 公式", boost: 0.4),
            SkillKeywordPattern(keywords: ["数据分析", "指标"], skillName: "数据分析报告", boost: 0.3),
            SkillKeywordPattern(keywords: ["图表", "可视化"], skillName: "数据可视化建议", boost: 0.3),
            // Business
            SkillKeywordPattern(keywords: ["bp", "商业计划", "融资"], skillName: "商业计划书", boost: 0.4),
            SkillKeywordPattern(keywords: ["合同", "条款审查"], skillName: "合同审查", boost: 0.5),
            SkillKeywordPattern(keywords: ["jd", "招聘", "岗位描述"], skillName: "JD 编写", boost: 0.4),
            SkillKeywordPattern(keywords: ["swot"], skillName: "SWOT 分析", boost: 0.5),
            SkillKeywordPattern(keywords: ["方案书", "客户提案", "报价"], skillName: "客户方案书", boost: 0.4),
            // Dev
            SkillKeywordPattern(keywords: ["commit message", "提交信息"], skillName: "Commit Message 生成", boost: 0.5),
            SkillKeywordPattern(keywords: ["pr描述", "merge request"], skillName: "PR 描述生成", boost: 0.4),
            SkillKeywordPattern(keywords: ["changelog", "变更日志"], skillName: "Changelog 生成", boost: 0.5),
            SkillKeywordPattern(keywords: ["正则", "regex"], skillName: "正则编写", boost: 0.5),
            SkillKeywordPattern(keywords: ["sql", "查询语句"], skillName: "SQL 编写", boost: 0.4),
            SkillKeywordPattern(keywords: ["prompt", "提示词"], skillName: "Prompt 优化", boost: 0.4),
            SkillKeywordPattern(keywords: ["代码审查", "code review", "review"], skillName: "代码审查", boost: 0.4),
            SkillKeywordPattern(keywords: ["单元测试", "写测试"], skillName: "生成测试", boost: 0.4),
            SkillKeywordPattern(keywords: ["重构"], skillName: "重构", boost: 0.4),
            SkillKeywordPattern(keywords: ["readme"], skillName: "README 生成", boost: 0.5),
            SkillKeywordPattern(keywords: ["ci", "cd", "流水线"], skillName: "CI/CD 调试", boost: 0.3),
            SkillKeywordPattern(keywords: ["迁移", "升级"], skillName: "迁移指南生成", boost: 0.3),
            // Research
            SkillKeywordPattern(keywords: ["竞品", "竞争对手"], skillName: "竞品分析", boost: 0.4),
            SkillKeywordPattern(keywords: ["论文", "paper"], skillName: "论文速读", boost: 0.4),
            SkillKeywordPattern(keywords: ["调研", "技术选型"], skillName: "技术调研", boost: 0.3),
            SkillKeywordPattern(keywords: ["链接", "总结链接", "文章总结"], skillName: "链接内容总结", boost: 0.3),
            // Knowledge
            SkillKeywordPattern(keywords: ["知识图谱", "wiki", "整理笔记", "知识库"], skillName: "知识图谱构建", boost: 0.4),
            // Meta
            SkillKeywordPattern(keywords: ["创建技能", "新技能", "封装技能"], skillName: "技能创建", boost: 0.5),
        ]

        let nameLower = skill.name.lowercased()
        for pattern in patterns {
            guard nameLower.contains(pattern.skillName.lowercased()) || skill.name == pattern.skillName else { continue }
            // Count how many keywords from this pattern match the input
            let hits = pattern.keywords.filter { input.contains($0.lowercased()) }
            if hits.count >= 2 {
                return pattern.boost  // Strong match: 2+ keywords
            } else if hits.count == 1 {
                // Single keyword match: only boost if keyword is specific enough (≥ 3 chars)
                guard let keyword = hits.first else { continue }
                if keyword.count >= 3 {
                    return min(pattern.boost, 0.35)  // Capped: single keyword can't exceed threshold alone
                }
            }
        }
        return 0
    }

    private static func describeMatch(skill: SkillDefinition, score: Double) -> String {
        let pct = Int(score * 100)
        return "匹配技能「\(skill.name)」（置信度 \(pct)%）"
    }
}
