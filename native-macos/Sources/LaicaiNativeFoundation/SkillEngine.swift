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
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(skill.name).json")
        guard let data = try? JSONEncoder().encode(skill) else { return false }
        try? data.write(to: url, options: .atomic)
        return true
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
            (root as NSString).appendingPathComponent("skills")
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
                    let name = raw["name"] as? String {
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
                    let parsed = Self.skillFromMarkdown(markdown, url: url) {
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
            let requiredTools = requires["tools"] as? [String] {
            values = requiredTools
        }
        if values.isEmpty,
            let steps = raw["steps"] as? [[String: Any]] {
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
            "元技能": "meta", "meta": "meta"
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
            return connectors.first(where: { $0.kind.contains("ollama") || $0.modelName.contains("mini") || $0.modelName.contains("flash") })
        case .code:
            return connectors.first(where: { $0.modelName.contains("code") || $0.modelName.contains("coder") || $0.modelName.contains("deepseek") })
        case .strong:
            return connectors.first(where: {
                $0.modelName.contains("gpt-4") || $0.modelName.contains("claude") || $0.modelName.contains("opus") || $0.modelName.contains("max")
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
            "文件", "内容", "数据", "工具", "使用", "生成", "创建", "写", "读", "分析", "文档", "格式", "方案", "设计", "管理"
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
            SkillKeywordPattern(keywords: ["创建技能", "新技能", "封装技能"], skillName: "技能创建", boost: 0.5)
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

// MARK: - Built-in Skills

private let builtinSkills: [SkillDefinition] = [

    // ── 工作流 Skills ──

    SkillDefinition(
        name: "代码审查",
        description: "审查代码变更，发现潜在问题、安全漏洞和风格问题",
        tools: ["git", "file.read", "code.search"],
        workflowName: "code-review",
        modelPreference: .strong,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "生成测试",
        description: "为指定代码生成单元测试，覆盖边界情况",
        tools: ["file.read", "code.search", "file.write"],
        workflowName: "test-gen",
        modelPreference: .code,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "调试",
        description: "根据错误信息搜索代码、定位问题并分析根因",
        tools: ["code.search", "git", "shell.exec"],
        workflowName: "debug",
        modelPreference: .strong,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "重构",
        description: "分析代码结构，给出重构方案并自动执行",
        tools: ["file.read", "code.search", "file.write", "file.edit"],
        workflowName: "refactor",
        modelPreference: .code,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "生成文档",
        description: "为代码生成文档注释和 README",
        tools: ["file.read", "code.search", "file.write"],
        workflowName: "doc-gen",
        modelPreference: .default,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "翻译",
        description: "将代码注释或文档翻译为目标语言",
        tools: ["file.read", "file.write"],
        workflowName: "translate",
        modelPreference: .fast,
        isBuiltin: true
    ),

    // ── 分析 Skills ──

    SkillDefinition(
        name: "搜索代码",
        description: "在工作区中搜索文件或内容，支持正则",
        tools: ["code.search", "file.read"],
        modelPreference: .fast,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "读取文件",
        description: "读取工作区中的文件内容",
        tools: ["file.read"],
        modelPreference: .fast,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "项目概览",
        description: "索引项目结构、技术栈、入口文件和关键模块",
        tools: ["workspace.index", "file.read", "code.search"],
        modelPreference: .fast,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "Git 分析",
        description: "查看 Git 历史、分支状态、变更差异",
        tools: ["git", "file.read"],
        modelPreference: .fast,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "依赖分析",
        description: "分析项目依赖关系、版本冲突和安全漏洞",
        tools: ["file.read", "code.search", "shell.exec"],
        modelPreference: .strong,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "性能分析",
        description: "审查代码性能瓶颈，提出优化建议",
        tools: ["code.search", "file.read"],
        modelPreference: .strong,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "安全审计",
        description: "检查代码中的安全漏洞、敏感信息泄露和不安全模式",
        tools: ["code.search", "file.read", "git"],
        modelPreference: .strong,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "架构分析",
        description: "分析项目架构设计、模块边界和依赖方向",
        tools: ["workspace.index", "code.search", "file.read"],
        modelPreference: .strong,
        isBuiltin: true
    ),

    // ── 编辑 Skills ──

    SkillDefinition(
        name: "修改文件",
        description: "修改文件内容（生成 diff 需审查确认）",
        tools: ["file.write", "file.edit"],
        modelPreference: .code,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "批量重命名",
        description: "跨文件重命名变量、函数或类名",
        tools: ["code.search", "file.edit", "batch.apply"],
        modelPreference: .code,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "代码格式化",
        description: "统一代码风格，修复缩进、空格和换行",
        tools: ["file.read", "file.edit"],
        modelPreference: .fast,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "添加类型注解",
        description: "为 Python/TS/JS 代码添加类型注解和接口定义",
        tools: ["file.read", "file.edit", "code.search"],
        modelPreference: .code,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "API 接口生成",
        description: "根据数据模型生成 CRUD 接口代码",
        tools: ["file.read", "file.write", "code.search"],
        modelPreference: .code,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "数据模型生成",
        description: "根据 JSON/SQL/描述生成数据模型和 ORM 代码",
        tools: ["file.write", "code.search"],
        modelPreference: .code,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "配置文件生成",
        description: "生成 Docker、CI/CD、环境配置等基础设施文件",
        tools: ["file.write", "file.read"],
        modelPreference: .code,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "错误处理增强",
        description: "为代码添加完善的错误处理、日志记录和重试逻辑",
        tools: ["file.read", "file.edit", "code.search"],
        modelPreference: .code,
        isBuiltin: true
    ),

    // ── 执行 Skills ──

    SkillDefinition(
        name: "执行命令",
        description: "运行终端命令（白名单限制）",
        tools: ["shell.exec"],
        modelPreference: .fast,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "构建验证",
        description: "执行构建/测试命令，分析错误并自动修复",
        tools: ["verify.build", "file.edit", "code.search"],
        modelPreference: .code,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "环境检查",
        description: "检查开发环境、依赖版本、端口占用等",
        tools: ["shell.exec"],
        modelPreference: .fast,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "Git 提交",
        description: "暂存变更、生成 commit message 并提交",
        tools: ["git", "file.read"],
        modelPreference: .fast,
        isBuiltin: true
    ),

    // ── 研究 Skills ──

    SkillDefinition(
        name: "网页搜索",
        description: "搜索网页获取最新信息和技术方案",
        tools: ["web.search", "web.fetch"],
        modelPreference: .fast,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "技术调研",
        description: "深度调研技术方案，对比优劣并给出推荐",
        tools: ["web.search", "web.fetch", "file.write"],
        modelPreference: .strong,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "知识图谱构建",
        description: "将资料整理为知识图谱：拆分概念为原子笔记，自动添加双链，生成 MOC 索引页",
        tools: ["wiki.build", "web.search", "web.fetch", "file.read", "workspace.index"],
        modelPreference: .strong,
        isBuiltin: true,
        systemHint: """
            你是知识图谱构建专家。用户会提供资料来源（文件夹、链接、文本），你需要将其整理为 Obsidian 知识图谱。

            ## 工作流程
            1. **分析来源**：读取用户提供的资料，提取所有独立概念/实体/产品
            2. **拆分概念**：每个概念必须独立成一个原子笔记，不要把多个概念塞进一个文件
               - 例："万旅会员CRM与营销体系" → 拆为 "会员CRM体系"、"万旅CRM实施方案"、"竞盛SCRM平台" 三个原子笔记
            3. **逐个创建**：对每个概念调用 wiki_build(topic="概念名", mode="atomic", save=true)
               - 系统会自动在已有相关页面添加 [[反向链接]]
            4. **创建索引**：所有原子笔记创建完后，调用 wiki_build(topic="领域名", mode="moc", save=true) 创建索引页
            5. **验证覆盖率**：确保源资料中的所有重要概念都被覆盖

            ## 命名规范
            - 用概念本身命名，不用来源命名：✅ "会员CRM体系" ❌ "万旅会员CRM与营销体系文档"
            - 通用概念和特定实施分开：✅ "酒店直销平台" + "万旅直销平台方案" ❌ "万旅酒店直销平台"
            - 中文命名，简洁明确

            ## 质量标准
            - 每个原子笔记只讲一个概念
            - 必须包含 [[双链]] 指向相关概念
            - 内容精炼，信息密度高
            - MOC 索引页按子主题分组，每个条目一句话概括
            """,
        category: "knowledge"
    ),
    SkillDefinition(
        name: "API 文档查阅",
        description: "查阅 API 文档，提取用法示例和参数说明",
        tools: ["web.search", "web.fetch"],
        modelPreference: .fast,
        isBuiltin: true
    ),

    // ── 研究 Skills（续）──

    SkillDefinition(
        name: "链接内容总结",
        description: "读取微信公众号、小红书、抖音、B站等链接内容，自动提取正文并生成结构化总结",
        tools: ["web.fetch", "web.search"],
        modelPreference: .strong,
        isBuiltin: true,
        systemHint: """
            用户会提供一个或多个链接（微信公众号、小红书、抖音、B站、知乎、微博等）。
            执行步骤：
            1. 用 web.fetch 抓取链接内容
            2. 如果页面需要动态渲染导致内容为空，尝试用 web.search 搜索该链接标题获取缓存/摘要
            3. 提取正文，忽略广告、导航、推荐等无关内容
            4. 输出结构化总结：
               📌 标题：
               👤 作者/来源：
               📅 发布时间（如果可获取）：
               📝 核心内容（3-5个要点）：
               💡 关键观点/结论：
               🏷️ 标签/话题：
            5. 如果是视频类内容（抖音/B站），尽量提取描述、评论摘要
            6. 多个链接时逐一总结，最后给出对比或综合分析
            """
    ),
    SkillDefinition(
        name: "竞品分析",
        description: "搜索竞品信息，对比功能、定价、技术栈，生成分析报告",
        tools: ["web.search", "web.fetch", "file.write"],
        modelPreference: .strong,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "论文速读",
        description: "读取论文链接或 PDF 内容，提取核心贡献、方法和结论",
        tools: ["web.fetch", "web.search"],
        modelPreference: .strong,
        isBuiltin: true
    ),

    // ── 通用 Skills ──

    SkillDefinition(
        name: "解释代码",
        description: "逐行解释代码逻辑，适合学习和交接",
        tools: ["file.read", "code.search"],
        modelPreference: .default,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "需求分析",
        description: "分析需求描述，拆解任务并估算工作量",
        tools: [],
        modelPreference: .strong,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "代码转换",
        description: "在不同编程语言之间转换代码实现",
        tools: ["file.read", "file.write"],
        modelPreference: .code,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "正则编写",
        description: "根据描述生成正则表达式，附带测试用例",
        tools: [],
        modelPreference: .fast,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "SQL 编写",
        description: "根据需求编写 SQL 查询、建表和数据迁移脚本",
        tools: ["file.read", "file.write"],
        modelPreference: .code,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "Prompt 优化",
        description: "优化 AI 提示词，提升输出质量和一致性",
        tools: [],
        modelPreference: .strong,
        isBuiltin: true
    ),

    // ── Git 自动化 Skills（市场热门）──

    SkillDefinition(
        name: "Commit Message 生成",
        description: "根据 git diff 自动生成规范的 commit message（Conventional Commits）",
        tools: ["git", "file.read"],
        modelPreference: .fast,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "PR 描述生成",
        description: "根据分支差异自动生成 PR/MR 描述，含变更摘要和影响分析",
        tools: ["git", "file.read", "code.search"],
        modelPreference: .strong,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "Changelog 生成",
        description: "从 Git 历史自动生成 CHANGELOG，按 feat/fix/refactor 分类",
        tools: ["git", "file.read", "file.write"],
        modelPreference: .fast,
        isBuiltin: true
    ),

    // ── DevOps / 部署 Skills（市场热门）──

    SkillDefinition(
        name: "CI/CD 调试",
        description: "分析 CI/CD 构建日志，定位失败原因并给出修复方案",
        tools: ["file.read", "shell.exec", "web.fetch"],
        modelPreference: .strong,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "迁移指南生成",
        description: "生成框架/库版本升级迁移指南，含 breaking changes 和修改步骤",
        tools: ["file.read", "code.search", "web.search", "file.write"],
        modelPreference: .strong,
        isBuiltin: true
    ),

    // ── 生产力 Skills（市场热门）──

    SkillDefinition(
        name: "README 生成",
        description: "分析项目结构自动生成专业 README，含安装、用法、API 文档",
        tools: ["workspace.index", "file.read", "file.write"],
        modelPreference: .default,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "代码问答",
        description: "基于项目代码回答问题，免去手动翻代码",
        tools: ["code.search", "file.read", "workspace.index"],
        modelPreference: .fast,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "学习路径规划",
        description: "根据目标技术栈规划学习路线、推荐资源和实践项目",
        tools: ["web.search"],
        modelPreference: .strong,
        isBuiltin: true
    ),
    SkillDefinition(
        name: "面试准备",
        description: "根据岗位和技术栈生成面试题库、考点解析和模拟问答",
        tools: ["web.search"],
        modelPreference: .strong,
        isBuiltin: true
    ),

    // ══════════════════════════════════════════════════
    // 非开发行业技能
    // ══════════════════════════════════════════════════

    // ── 营销 Marketing ──

    SkillDefinition(
        name: "营销文案",
        description: "生成品牌推广、产品介绍、活动宣传等营销文案，支持多种调性",
        tools: [],
        modelPreference: .strong,
        isBuiltin: true,
        category: "marketing"
    ),
    SkillDefinition(
        name: "小红书笔记",
        description: "生成小红书风格种草笔记，含标题、正文、标签和封面建议",
        tools: [],
        modelPreference: .strong,
        isBuiltin: true,
        systemHint: """
            生成小红书风格笔记，要求：
            1. 标题：用数字+emoji+痛点/解决方案，如「❗️5个被忽略的XXX技巧」
            2. 正文：口语化、分段短句、多emoji、穿插个人体验
            3. 标签：5-10个相关话题标签
            4. 封面文案建议：适合做图片封面的关键词
            5. 语气自然真诚，避免过度营销感
            """,
        category: "marketing"
    ),
    SkillDefinition(
        name: "公众号文章",
        description: "生成微信公众号长文，含标题、摘要、正文和排版建议",
        tools: [],
        modelPreference: .strong,
        isBuiltin: true,
        systemHint: """
            生成微信公众号文章，要求：
            1. 标题：吸引点击但不标题党，可提供2-3个备选
            2. 摘要：30字以内，激发阅读欲望
            3. 正文：结构清晰，段落分明，适当使用小标题
            4. 金句：在关键位置插入可被转发的金句
            5. 结尾：引导关注/转发/留言互动
            6. 排版建议：推荐字号、颜色、配图位置
            """,
        category: "marketing"
    ),
    SkillDefinition(
        name: "短视频脚本",
        description: "生成抖音/快手/视频号短视频脚本，含镜头、台词和时间线",
        tools: [],
        modelPreference: .strong,
        isBuiltin: true,
        systemHint: """
            生成短视频脚本，格式：
            时间 | 画面 | 台词/旁白 | 字幕/特效
            要求：
            - 前3秒抓眼球（hook）
            - 总时长控制在15-60秒
            - 节奏紧凑，信息密度高
            - 适合竖屏拍摄
            - 结尾设置互动引导（点赞/评论/关注）
            """,
        category: "marketing"
    ),
    SkillDefinition(
        name: "SEO 优化",
        description: "分析内容的 SEO 表现，优化标题、描述、关键词和结构",
        tools: ["web.search"],
        modelPreference: .strong,
        isBuiltin: true,
        category: "marketing"
    ),
    SkillDefinition(
        name: "广告投放文案",
        description: "为信息流广告、搜索广告生成多组测试文案",
        tools: [],
        modelPreference: .strong,
        isBuiltin: true,
        category: "marketing"
    ),
    SkillDefinition(
        name: "用户评价回复",
        description: "批量生成电商/外卖/App Store 用户评价的专业回复",
        tools: [],
        modelPreference: .fast,
        isBuiltin: true,
        category: "marketing"
    ),

    // ── 产品 Product ──

    SkillDefinition(
        name: "PRD 编写",
        description: "根据需求描述生成产品需求文档，含背景、目标、功能列表、用户故事",
        tools: ["file.write"],
        modelPreference: .strong,
        isBuiltin: true,
        category: "product"
    ),
    SkillDefinition(
        name: "用户故事",
        description: "将模糊需求转化为标准用户故事（As a...I want...So that...）和验收标准",
        tools: [],
        modelPreference: .default,
        isBuiltin: true,
        category: "product"
    ),
    SkillDefinition(
        name: "功能优先级排序",
        description: "用 RICE/MoSCoW/Kano 模型评估功能优先级，输出排序建议",
        tools: [],
        modelPreference: .strong,
        isBuiltin: true,
        category: "product"
    ),
    SkillDefinition(
        name: "用户调研问卷",
        description: "设计用户调研问卷，含筛选题、核心题和开放题",
        tools: [],
        modelPreference: .default,
        isBuiltin: true,
        category: "product"
    ),
    SkillDefinition(
        name: "产品发布计划",
        description: "生成产品上线 checklist 和发布计划，含灰度策略和回滚方案",
        tools: [],
        modelPreference: .strong,
        isBuiltin: true,
        category: "product"
    ),

    // ── 内容 Content ──

    SkillDefinition(
        name: "长文写作",
        description: "生成深度长文，含大纲、正文、参考资料，支持多种风格",
        tools: ["web.search"],
        modelPreference: .strong,
        isBuiltin: true,
        category: "content"
    ),
    SkillDefinition(
        name: "周报/日报",
        description: "根据工作描述生成规范的日报/周报，突出成果和进展",
        tools: [],
        modelPreference: .fast,
        isBuiltin: true,
        systemHint: """
            生成工作周报/日报，格式：
            一、本周完成
            - 【项目名】完成内容（量化成果）
            二、进行中
            - 【项目名】进展说明（完成百分比）
            三、下周计划
            - 计划事项和预期产出
            四、需要协助
            - 阻塞项和需要的支持
            要求：语言专业简练，突出数据和结果
            """,
        category: "content"
    ),
    SkillDefinition(
        name: "邮件撰写",
        description: "生成商务邮件，支持英文/中文，多种场景（邀请、感谢、催促、道歉等）",
        tools: [],
        modelPreference: .default,
        isBuiltin: true,
        category: "content"
    ),
    SkillDefinition(
        name: "会议纪要",
        description: "将会议录音/笔记整理为结构化纪要，含决议、待办和负责人",
        tools: [],
        modelPreference: .fast,
        isBuiltin: true,
        category: "content"
    ),
    SkillDefinition(
        name: "演示文稿制作",
        description: "生成专业演示文稿全套方案：结构布局、页面内容、视觉设计、演讲者备注",
        tools: ["web.search", "file.write"],
        modelPreference: .strong,
        isBuiltin: true,
        systemHint: """
            你是一位顶尖演示文稿设计顾问，精通 McKinsey/BCG 风格的专业 PPT 制作。

            收到用户主题后，输出完整的演示文稿方案：

            ## 1. 整体策略
            - 核心叙事线：问题 → 洞察 → 方案 → 价值 → 行动
            - 受众分析：谁在看、关心什么、决策因素
            - 时长建议和节奏控制

            ## 2. 每页内容（逐页输出）
            每一页包含：
            - 【页标题】简洁有力，一句话传递核心信息
            - 【布局类型】全出血/左右分栏/三栏/数据卡片/时间线/对比图/引用页
            - 【核心观点】这一页要传递的唯一核心信息
            - 【要素布局】具体包含哪些元素（标题/副标题/正文/图表/图片/图标/数据卡片）
            - 【视觉建议】配色、字体大小、图表类型、配图建议
            - 【演讲者备注】讲到这页说什么，用什么过渡，健谈时间
            - 【动画建议】元素出现顺序和动画效果

            ## 3. 视觉设计规范
            - 主色/辅助色/强调色 Hex 值
            - 字体树：标题/副标题/正文/数据的字体字号
            - 图表风格统一规范
            - 留白和对齐原则

            ## 4. 输出格式要求
            - 使用 Markdown 表格展示每页结构
            - 如果用户要求，可生成 Marp/Slidev/reveal.js 格式的 Markdown PPT
            - 可提供可复制的设计关键词（用于配图搜索）

            ## 5. 质量标准
            - 每页只传递一个核心信息（one message per slide）
            - 文字精炼，绝不堆砌文字墙
            - 数据可视化优先于文字描述
            - 每个图表都有清晰的 insight 标注
            - 开头抽眼尾记得住，中间节奏紧凑
            """,
        category: "design"
    ),
    SkillDefinition(
        name: "多语言翻译",
        description: "翻译文档/文案，保持原文语气和风格，支持中英日韩法德等",
        tools: [],
        modelPreference: .strong,
        isBuiltin: true,
        category: "content"
    ),
    SkillDefinition(
        name: "文风改写",
        description: "将同一内容改写为不同风格：正式/口语/学术/幽默/种草等",
        tools: [],
        modelPreference: .default,
        isBuiltin: true,
        category: "content"
    ),

    // ── 设计 Design ──

    SkillDefinition(
        name: "UI 设计方案",
        description: "生成完整的 UI 设计规范：组件库、页面结构、交互流程、响应式适配",
        tools: ["web.search", "file.write"],
        modelPreference: .strong,
        isBuiltin: true,
        systemHint: """
            你是一位资深 UI/UX 设计师，精通 Apple HIG、Material Design、以及现代 Web 设计系统。

            收到设计需求后，输出专业的 UI 设计方案：

            ## 1. 设计策略
            - 目标用户画像和使用场景
            - 设计原则：简洁/高效/可访问/一致性
            - 参考竞品和设计趋势

            ## 2. 设计系统 Tokens
            - 色彩体系：主色/辅色/语义色/中性色（含 Hex、亮暗主题变体）
            - 字体树：字体家族/字号梯度/字重/行高
            - 间距系统：4px 基数的间距梯度
            - 圆角梯度：小/中/大/全圆
            - 阴影梯度：浅/中/深
            - 动画规范：时长/缓动曲线

            ## 3. 组件库设计
            每个组件包含：
            - 【组件名称】和用途
            - 【变体】尺寸(sm/md/lg)、状态(default/hover/active/disabled/focus)
            - 【结构】包含哪些子元素
            - 【尺寸规范】宽高/内边距/外边距
            - 【代码示例】SwiftUI/React/CSS 示例（根据用户技术栈）

            核心组件清单：
            Button, Input, Card, Modal, Toast, Badge, Avatar, Tab, Sidebar, NavBar,
            Table, Dropdown, Toggle, Slider, Progress, Tooltip, Alert

            ## 4. 页面设计
            每个页面包含：
            - 【页面名】和核心任务
            - 【布局结构】栅格系统、模块划分
            - 【线框图】用 ASCII art 或结构化描述展示布局
            - 【交互流程】用户操作 → 反馈 → 状态转换
            - 【响应式适配】桌面/平板/手机的布局差异
            - 【动效设计】转场/进入/反馈动效

            ## 5. 输出标准
            - 可以直接交付给开发团队实现的精确规范
            - 含尺寸、颜色、间距的确切数值
            - 可复制的 CSS 变量 / SwiftUI 扩展 / Tailwind 配置
            - 若用户指定框架，直接输出可运行的组件代码
            """,
        category: "design"
    ),
    SkillDefinition(
        name: "品牌视觉设计",
        description: "生成品牌视觉识别系统：Logo 概念、色彩方案、字体组合、应用场景",
        tools: ["web.search"],
        modelPreference: .strong,
        isBuiltin: true,
        systemHint: """
            你是一位品牌视觉设计顾问，精通品牌识别系统和视觉传达。

            ## 1. 品牌分析
            - 品牌定位、受众、价值观
            - 竞品视觉语言分析
            - 情绪版关键词：专业/活泼/科技/温暖…

            ## 2. Logo 概念
            - 提供 3-5 个方向，每个包含：
              - 创意说明和含义
              - 结构描述（几何/文字/图形组合）
              - AI 生图提示词（可直接喜用 Midjourney/DALL-E）
              - 适用场景和尺寸变体

            ## 3. 色彩方案
            - 主色 + 辅助色 + 点缀色（含 Hex/RGB/HSL）
            - 亮/暗主题变体
            - 渐变色规范
            - 无障碍对比度检查

            ## 4. 字体组合
            - 主字体/辅助字体推荐（含中英文搭配）
            - 字体梯度规范
            - 使用场景示例

            ## 5. 应用场景示例
            - 名片、信纸抬头、邮件签名
            - 社交媒体头像、封面模板
            - 网站/App 方案概览
            - 周边/印刷品建议
            """,
        category: "design"
    ),

    // ── 数据 Data ──

    SkillDefinition(
        name: "数据分析报告",
        description: "分析数据指标趋势，生成分析报告含图表建议和改进方案",
        tools: ["file.read"],
        modelPreference: .strong,
        isBuiltin: true,
        category: "data"
    ),
    SkillDefinition(
        name: "Excel 公式",
        description: "根据需求生成 Excel/Google Sheets 公式和 VBA 宏",
        tools: [],
        modelPreference: .code,
        isBuiltin: true,
        category: "data"
    ),
    SkillDefinition(
        name: "数据可视化建议",
        description: "根据数据类型推荐最佳图表类型和配色方案",
        tools: [],
        modelPreference: .default,
        isBuiltin: true,
        category: "data"
    ),
    SkillDefinition(
        name: "问卷数据分析",
        description: "分析问卷调查结果，生成交叉分析和关键发现",
        tools: ["file.read"],
        modelPreference: .strong,
        isBuiltin: true,
        category: "data"
    ),

    // ── 商业 Business ──

    SkillDefinition(
        name: "商业计划书",
        description: "生成 BP 大纲和核心章节：市场分析、商业模式、财务预测",
        tools: ["web.search"],
        modelPreference: .strong,
        isBuiltin: true,
        category: "business"
    ),
    SkillDefinition(
        name: "合同审查",
        description: "审查合同条款，标注风险点和不合理条款，给出修改建议",
        tools: [],
        modelPreference: .strong,
        isBuiltin: true,
        systemHint: """
            审查合同时注意：
            1. 标注每个风险条款的风险等级（高/中/低）
            2. 说明不合理之处和可能后果
            3. 给出修改建议和替代条款
            4. 检查：违约责任、知识产权、竞业限制、保密义务、管辖法院
            5. 输出格式：逐条分析 + 整体风险评估
            注意：仅供参考，不构成法律意见
            """,
        category: "business"
    ),
    SkillDefinition(
        name: "JD 编写",
        description: "根据岗位和团队情况生成规范的招聘 JD，含职责和任职要求",
        tools: [],
        modelPreference: .default,
        isBuiltin: true,
        category: "business"
    ),
    SkillDefinition(
        name: "OKR 制定",
        description: "帮助制定 OKR，分解目标为可量化的关键结果",
        tools: [],
        modelPreference: .strong,
        isBuiltin: true,
        category: "business"
    ),
    SkillDefinition(
        name: "客户方案书",
        description: "生成客户提案/方案书，含问题分析、解决方案、报价和时间表",
        tools: [],
        modelPreference: .strong,
        isBuiltin: true,
        category: "business"
    ),
    SkillDefinition(
        name: "SWOT 分析",
        description: "对产品/项目/公司进行 SWOT 分析，输出结构化的战略建议",
        tools: ["web.search"],
        modelPreference: .strong,
        isBuiltin: true,
        category: "business"
    ),

    // ── 元技能 Meta ──

    SkillDefinition(
        name: "技能创建",
        description: "创建新的可复用技能。描述你想要的技能，我会用 skill.manage 工具自动生成并保存。",
        tools: ["skill.manage"],
        modelPreference: .strong,
        isBuiltin: true,
        systemHint: """
            你是技能工厂。用户会描述一个需要反复使用的工作流程，你要将其封装为一个可复用的技能。

            ## 创建流程
            1. **理解需求**：明确技能要解决什么问题、输入是什么、输出是什么
            2. **设计技能**：
               - name：简洁中文名（2-6字），如 "代码审查"、"知识图谱构建"
               - description：一句话说明（30字内）
               - tools：需要用到的工具（从 file.read, file.write, file.edit, code.search, web.search,
                 web.fetch, wiki.build, shell.exec, git, verify.build, workspace.index 中选）
               - instructions：详细的分步执行说明，写清楚每一步做什么、用什么工具、注意什么
               - trigger：可选，自动触发的关键词
            3. **调用创建**：用 skill.manage(action="create", ...) 保存技能
            4. **确认结果**：告知用户技能已创建，说明如何触发使用

            ## 质量标准
            - instructions 必须足够具体，让任何模型都能按步骤执行
            - 工具列表只包含真正需要的工具，不要多选
            - 触发词要具体，避免误触发
            - 如果用户描述模糊，先追问再创建

            ## 示例
            用户说："帮我做一个能自动整理会议纪要的技能"
            你应该创建：
            - name: "会议纪要整理"
            - description: "将会议录音/笔记整理为结构化纪要，含决议和待办"
            - tools: "file.read,file.write"
            - instructions: "1. 读取用户提供的会议记录文件...2. 提取关键信息...3. 输出标准格式..."
            - trigger: "会议纪要,整理会议,meeting notes"
            """,
        category: "meta"
    )
]
