import Foundation
import LaicaiNativeDomain

// MARK: - Thread-safe Project Cache (nonisolated)

private enum ProjectCache {
    private static let lock = NSLock()
    private static var projects: [Project] = []

    static func read() -> [Project] {
        lock.lock()
        defer { lock.unlock() }
        return projects
    }

    static func write(_ value: [Project]) {
        lock.lock()
        projects = value
        lock.unlock()
    }
}

// MARK: - Project Model
// A "Project" is a persistent entity tied to a workspace root.
// It maintains structured context that carries across sessions,
// similar to Claude Cowork / OpenAI Codex project concept.

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var rootPath: String  // absolute workspace path
    public var createdAt: Date
    public var lastOpenedAt: Date

    // Structured project knowledge (auto-maintained)
    public var techStack: [String]  // ["Swift", "SwiftUI", "SQLite"]
    public var architecture: String  // free-form: "MVVM + Clean Architecture"
    public var conventions: [String]  // ["tabs for indentation", "Chinese comments"]
    public var entryPoints: [String]  // key files: ["Sources/App/main.swift"]
    public var buildCommand: String?  // "swift build", "npm run build"
    public var testCommand: String?  // "swift test", "npm test"
    public var setupScript: String?  // Codex-style: runs before each agent task
    public var useWorktree: Bool  // Codex-style: use git worktree for parallel isolation

    // User-maintained project notes
    public var notes: String  // freeform project notes / goals
    public var activeTasks: [ProjectTask]  // ongoing tasks/TODOs

    // Stats
    public var taskCount: Int  // total tasks run in this project
    public var lastTaskSummary: String?  // what was done last time

    // Rolling project memory (cross-session continuity)
    public var recentTaskSummaries: [TaskSummaryEntry]  // last N task findings
    public var discoveredIssues: [String]  // unresolved issues found during tasks

    public init(
        name: String,
        rootPath: String,
        techStack: [String] = [],
        architecture: String = "",
        conventions: [String] = [],
        entryPoints: [String] = [],
        buildCommand: String? = nil,
        testCommand: String? = nil,
        setupScript: String? = nil,
        useWorktree: Bool = false,
        notes: String = "",
        activeTasks: [ProjectTask] = [],
        taskCount: Int = 0,
        lastTaskSummary: String? = nil,
        recentTaskSummaries: [TaskSummaryEntry] = [],
        discoveredIssues: [String] = []
    ) {
        self.id = UUID()
        self.name = name
        self.rootPath = rootPath
        self.createdAt = Date()
        self.lastOpenedAt = Date()
        self.techStack = techStack
        self.architecture = architecture
        self.conventions = conventions
        self.entryPoints = entryPoints
        self.buildCommand = buildCommand
        self.testCommand = testCommand
        self.setupScript = setupScript
        self.useWorktree = useWorktree
        self.notes = notes
        self.activeTasks = activeTasks
        self.taskCount = taskCount
        self.lastTaskSummary = lastTaskSummary
        self.recentTaskSummaries = recentTaskSummaries
        self.discoveredIssues = discoveredIssues
    }
}

public struct TaskSummaryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var title: String
    public var summary: String  // what was done
    public var conclusions: [String]  // key findings
    public var filesModified: [String]

    public init(title: String, summary: String, conclusions: [String] = [], filesModified: [String] = []) {
        self.id = UUID()
        self.date = Date()
        self.title = title
        self.summary = summary
        self.conclusions = conclusions
        self.filesModified = filesModified
    }
}

public struct ProjectTask: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var status: Status
    public var createdAt: Date
    public var completedAt: Date?

    public enum Status: String, Codable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
        case blocked
    }

    public init(title: String, status: Status = .pending) {
        self.id = UUID()
        self.title = title
        self.status = status
        self.createdAt = Date()
    }
}

// MARK: - Project Manager

@MainActor
public final class ProjectManager: ObservableObject {
    public static let shared = ProjectManager()

    @Published public private(set) var projects: [Project] = []
    @Published public var activeProjectID: UUID?

    public var activeProject: Project? {
        projects.first { $0.id == activeProjectID }
    }

    private let storePath: String

    private init() {
        let dir = LaicaiStoragePaths.ensureDirectory(LaicaiStoragePaths.appDirectory)
        storePath = dir.appendingPathComponent("projects.json").path
        load()
    }

    // MARK: - CRUD

    public func createProject(name: String, rootPath: String) -> Project {
        // Check if project already exists for this path
        if let existing = projects.first(where: { $0.rootPath == rootPath }) {
            activeProjectID = existing.id
            return existing
        }

        var project = Project(name: name, rootPath: rootPath)

        // Auto-detect tech stack and build commands
        let detected = ProjectDetector.detect(rootPath: rootPath)
        project.techStack = detected.techStack
        project.buildCommand = detected.buildCommand
        project.testCommand = detected.testCommand
        project.entryPoints = detected.entryPoints
        project.architecture = detected.architecture

        projects.insert(project, at: 0)
        activeProjectID = project.id
        save()

        // Generate initial LAICAI.md
        generateProjectMD(for: project)

        return project
    }

    public func openProject(id: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].lastOpenedAt = Date()
        activeProjectID = id
        save()
    }

    /// Find or create project for a workspace path
    public func ensureProject(for rootPath: String) -> Project {
        if let existing = projects.first(where: { $0.rootPath == rootPath }) {
            if activeProjectID != existing.id {
                openProject(id: existing.id)
            }
            return existing
        }
        let name = URL(fileURLWithPath: rootPath).lastPathComponent
        return createProject(name: name, rootPath: rootPath)
    }

    public func updateProject(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx] = project
        save()
    }

    public func deleteProject(id: UUID) {
        projects.removeAll { $0.id == id }
        if activeProjectID == id {
            activeProjectID = projects.first?.id
        }
        save()
    }

    // MARK: - Task Tracking

    public func addTask(to projectID: UUID, title: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].activeTasks.append(ProjectTask(title: title))
        save()
    }

    public func completeTask(projectID: UUID, taskID: UUID) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
            let tIdx = projects[pIdx].activeTasks.firstIndex(where: { $0.id == taskID })
        else { return }
        projects[pIdx].activeTasks[tIdx].status = .completed
        projects[pIdx].activeTasks[tIdx].completedAt = Date()
        save()
    }

    public func recordTaskRun(projectID: UUID, summary: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].taskCount += 1
        projects[idx].lastTaskSummary = String(summary.prefix(500))
        projects[idx].lastOpenedAt = Date()
        save()
    }

    // MARK: - LAICAI.md Generation

    /// Generate/update the LAICAI.md file in the project root.
    /// This is the project's persistent context file that the agent reads on every task.
    public func generateProjectMD(for project: Project) {
        let mdPath = (project.rootPath as NSString).appendingPathComponent("LAICAI.md")

        var lines: [String] = []
        lines.append("# \(project.name)")
        lines.append("")

        appendTextSection("技术栈", content: project.techStack.joined(separator: ", "), to: &lines)
        appendTextSection("架构", content: project.architecture, to: &lines)
        appendBulletSection("约定", items: project.conventions, to: &lines)
        appendBulletSection("关键文件", items: project.entryPoints.map { "`\($0)`" }, to: &lines)
        appendCommandSection("构建", command: project.buildCommand, to: &lines)
        appendCommandSection("测试", command: project.testCommand, to: &lines)
        appendTextSection("项目备忘", content: project.notes, to: &lines)
        appendActiveTasks(project.activeTasks, to: &lines)
        appendRecentTaskMemory(project, to: &lines)
        appendBulletSection("已知问题", items: Array(project.discoveredIssues.suffix(10)), to: &lines)

        let content = lines.joined(separator: "\n")
        try? content.write(toFile: mdPath, atomically: true, encoding: .utf8)
    }

    private func appendTextSection(_ title: String, content: String, to lines: inout [String]) {
        guard !content.isEmpty else { return }
        lines.append("## \(title)")
        lines.append(content)
        lines.append("")
    }

    private func appendBulletSection(_ title: String, items: [String], to lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines.append("## \(title)")
        for item in items {
            lines.append("- \(item)")
        }
        lines.append("")
    }

    private func appendCommandSection(_ title: String, command: String?, to lines: inout [String]) {
        guard let command else { return }
        lines.append("## \(title)")
        lines.append("```bash")
        lines.append(command)
        lines.append("```")
        lines.append("")
    }

    private func appendActiveTasks(_ tasks: [ProjectTask], to lines: inout [String]) {
        let pending = tasks.filter { $0.status != .completed }
        guard !pending.isEmpty else { return }
        lines.append("## 当前项目事项")
        for task in pending {
            let icon = task.status == .inProgress ? "🔄" : "⬜"
            lines.append("- \(icon) \(task.title)")
        }
        lines.append("")
    }

    private func appendRecentTaskMemory(_ project: Project, to lines: inout [String]) {
        if !project.recentTaskSummaries.isEmpty {
            appendRecentTaskSummaries(project.recentTaskSummaries, to: &lines)
        } else if let last = project.lastTaskSummary {
            appendTextSection("上次会话", content: last, to: &lines)
        }
    }

    private func appendRecentTaskSummaries(_ entries: [TaskSummaryEntry], to lines: inout [String]) {
        lines.append("## 最近会话记忆")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for entry in entries.suffix(5) {
            lines.append("### \(formatter.string(from: entry.date))")
            lines.append(entry.summary)
            for conclusion in entry.conclusions.prefix(3) {
                lines.append("- \(conclusion)")
            }
            lines.append("")
        }
    }

    /// Update project knowledge after a task completes.
    /// Called by the agent loop finalizer.
    public func learnFromTask(rootPath: String, summary: String, filesModified: [String], conclusions: [String]) {
        guard let idx = projects.firstIndex(where: { $0.rootPath == rootPath }) else { return }

        projects[idx].taskCount += 1
        projects[idx].lastTaskSummary = String(summary.prefix(500))
        projects[idx].lastOpenedAt = Date()

        appendTaskMemory(summary: summary, filesModified: filesModified, conclusions: conclusions, to: &projects[idx])
        updateDiscoveredIssues(from: conclusions, in: &projects[idx])
        updateEntryPoints(from: filesModified, in: &projects[idx])
        updateConventions(from: conclusions, in: &projects[idx])

        save()
        generateProjectMD(for: projects[idx])
    }

    private func appendTaskMemory(
        summary: String,
        filesModified: [String],
        conclusions: [String],
        to project: inout Project
    ) {
        let entry = TaskSummaryEntry(
            title: String(summary.prefix(80)),
            summary: String(summary.prefix(300)),
            conclusions: conclusions.map { String($0.prefix(200)) },
            filesModified: Array(filesModified.prefix(20))
        )
        project.recentTaskSummaries.append(entry)
        project.recentTaskSummaries = Array(project.recentTaskSummaries.suffix(10))
    }

    private func updateDiscoveredIssues(from conclusions: [String], in project: inout Project) {
        let issueMarkers = ["bug", "问题", "issue", "todo", "fixme", "待修复", "待解决", "需要", "broken", "失败"]
        appendUniqueConclusionSnippets(
            from: conclusions,
            markers: issueMarkers,
            prefixLength: 150,
            limit: 20,
            to: &project.discoveredIssues
        )
    }

    private func updateEntryPoints(from filesModified: [String], in project: inout Project) {
        let importantExtensions = Set(["swift", "ts", "tsx", "py", "go", "rs", "java", "kt"])
        for file in filesModified where isEntryPointCandidate(file, importantExtensions: importantExtensions) {
            appendUnique(file, limit: 20, to: &project.entryPoints)
        }
    }

    private func updateConventions(from conclusions: [String], in project: inout Project) {
        let conventionMarkers = ["convention", "约定", "规范", "always", "never"]
        appendUniqueConclusionSnippets(
            from: conclusions,
            markers: conventionMarkers,
            prefixLength: 100,
            limit: 15,
            to: &project.conventions
        )
    }

    private func appendUniqueConclusionSnippets(
        from conclusions: [String],
        markers: [String],
        prefixLength: Int,
        limit: Int,
        to values: inout [String]
    ) {
        for conclusion in conclusions where markers.contains(where: { conclusion.lowercased().contains($0) }) {
            appendUnique(String(conclusion.prefix(prefixLength)), limit: limit, to: &values)
        }
    }

    private func isEntryPointCandidate(_ file: String, importantExtensions: Set<String>) -> Bool {
        let ext = (file as NSString).pathExtension
        guard importantExtensions.contains(ext) else { return false }
        let lower = file.lowercased()
        return lower.contains("main") || lower.contains("app.") || lower.contains("index.")
    }

    private func appendUnique(_ value: String, limit: Int, to values: inout [String]) {
        guard !values.contains(value) else { return }
        values.append(value)
        values = Array(values.suffix(limit))
    }

    // MARK: - Context for System Prompt

    /// Build a concise project context string for injection into the system prompt.
    public func projectContext(for rootPath: String) -> String? {
        Self.buildProjectContext(projects: projects, rootPath: rootPath)
    }

    /// Thread-safe static version that can be called from any context.
    /// Pass a snapshot of projects to avoid @MainActor requirement.
    nonisolated public static func buildProjectContext(projects: [Project], rootPath: String) -> String? {
        guard let project = projects.first(where: { $0.rootPath == rootPath }) else { return nil }
        var parts: [String] = []

        appendProjectBasics(project, to: &parts)
        appendProjectMemory(project, to: &parts)
        appendProjectIssues(project, to: &parts)
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    nonisolated private static func appendProjectBasics(_ project: Project, to parts: inout [String]) {
        parts.append("项目：\(project.name)")
        if !project.techStack.isEmpty {
            parts.append("技术栈：\(project.techStack.joined(separator: ", "))")
        }
        if !project.architecture.isEmpty {
            parts.append("架构：\(project.architecture)")
        }
        if let build = project.buildCommand {
            parts.append("构建：`\(build)`")
        }
        if let test = project.testCommand {
            parts.append("测试：`\(test)`")
        }
        if !project.conventions.isEmpty {
            parts.append("约定：\(project.conventions.prefix(5).joined(separator: "；"))")
        }

        let pending = project.activeTasks.filter { $0.status != .completed }
        if !pending.isEmpty {
            parts.append("待办（\(pending.count)项）：\(pending.prefix(3).map(\.title).joined(separator: "、"))")
        }
    }

    nonisolated private static func appendProjectMemory(_ project: Project, to parts: inout [String]) {
        if !project.recentTaskSummaries.isEmpty {
            let recent = project.recentTaskSummaries.suffix(3)
            var historyLines: [String] = ["最近会话记忆："]
            for entry in recent {
                let dateStr = Self.shortDateString(entry.date)
                historyLines.append("  - [\(dateStr)] \(entry.summary)")
                for conclusion in entry.conclusions.prefix(2) {
                    historyLines.append("    → \(conclusion)")
                }
            }
            parts.append(historyLines.joined(separator: "\n"))
        } else if let last = project.lastTaskSummary {
            parts.append("上次：\(String(last.prefix(200)))")
        }
    }

    nonisolated private static func appendProjectIssues(_ project: Project, to parts: inout [String]) {
        if !project.discoveredIssues.isEmpty {
            let issues = project.discoveredIssues.suffix(5)
            parts.append("已知问题（\(issues.count)项）：\(issues.joined(separator: "；"))")
        }
    }

    nonisolated private static func shortDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    public nonisolated static var cachedProjects: [Project] {
        ProjectCache.read()
    }

    private func updateCache() {
        ProjectCache.write(projects)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
        updateCache()
    }

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: storePath)),
            let decoded = try? JSONDecoder().decode([Project].self, from: data)
        else { return }
        projects = decoded
        // Auto-select last opened
        activeProjectID = projects.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt }).first?.id
        updateCache()
    }
}

// MARK: - Project Detector
// Auto-detects tech stack, build commands, and architecture from project files.

public enum ProjectDetector {
    public struct DetectionResult {
        public var techStack: [String]
        public var buildCommand: String?
        public var testCommand: String?
        public var entryPoints: [String]
        public var architecture: String
    }

    public static func detect(rootPath: String) -> DetectionResult {
        var draft = DetectionDraft()
        let exists: (String) -> Bool = { name in
            FileManager.default.fileExists(atPath: (rootPath as NSString).appendingPathComponent(name))
        }
        detectSwift(rootPath: rootPath, exists: exists, draft: &draft)
        detectNode(rootPath: rootPath, exists: exists, draft: &draft)
        detectLanguageAndInfra(exists: exists, draft: &draft)
        detectArchitecture(exists: exists, draft: &draft)
        return DetectionResult(
            techStack: draft.stack,
            buildCommand: draft.buildCommand,
            testCommand: draft.testCommand,
            entryPoints: Array(draft.entries.prefix(15)),
            architecture: draft.architecture
        )
    }

    private struct DetectionDraft {
        var stack: [String] = []
        var buildCommand: String?
        var testCommand: String?
        var entries: [String] = []
        var architecture = ""
    }

    private static func detectSwift(rootPath: String, exists: (String) -> Bool, draft: inout DetectionDraft) {
        if exists("Package.swift") {
            draft.stack.append(contentsOf: ["Swift", "Swift Package Manager"])
            draft.buildCommand = "swift build"
            draft.testCommand = "swift test"
            draft.entries.append("Package.swift")
            draft.entries.append(contentsOf: swiftEntryPoints(rootPath: rootPath))
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: rootPath)) ?? []
        guard contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) else { return }
        if !draft.stack.contains("Swift") { draft.stack.append("Swift") }
        draft.stack.append("Xcode")
        if draft.buildCommand == nil { draft.buildCommand = "xcodebuild" }
    }

    private static func swiftEntryPoints(rootPath: String) -> [String] {
        let sourcesPath = (rootPath as NSString).appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(atPath: sourcesPath) else { return [] }
        var entries: [String] = []
        while let file = enumerator.nextObject() as? String {
            if file.hasSuffix("App.swift") || file.hasSuffix("main.swift") || file.hasSuffix("AppDelegate.swift") {
                entries.append("Sources/\(file)")
                if entries.count > 10 { break }
            }
        }
        return entries
    }

    private static func detectNode(rootPath: String, exists: (String) -> Bool, draft: inout DetectionDraft) {
        guard exists("package.json") else { return }
        draft.stack.append("Node.js")
        let json = packageJSON(rootPath: rootPath)
        appendNodeDependencies(json: json, draft: &draft)
        if let scripts = json?["scripts"] as? [String: String] {
            if scripts["build"] != nil { draft.buildCommand = "npm run build" }
            if scripts["test"] != nil { draft.testCommand = "npm test" }
        }
        if exists("pnpm-lock.yaml") { draft.stack.append("pnpm") } else if exists("yarn.lock") { draft.stack.append("yarn") }
        draft.entries.append("package.json")
    }

    private static func packageJSON(rootPath: String) -> [String: Any]? {
        let path = (rootPath as NSString).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func appendNodeDependencies(json: [String: Any]?, draft: inout DetectionDraft) {
        let deps = json?["dependencies"] as? [String: Any] ?? [:]
        if deps["react"] != nil { draft.stack.append("React") }
        if deps["next"] != nil {
            draft.stack.append("Next.js")
            draft.architecture = "Next.js App"
        }
        if deps["vue"] != nil { draft.stack.append("Vue") }
        if deps["express"] != nil { draft.stack.append("Express") }
        if deps["tailwindcss"] != nil || (json?["devDependencies"] as? [String: Any])?["tailwindcss"] != nil {
            draft.stack.append("Tailwind CSS")
        }
    }

    private static func detectLanguageAndInfra(exists: (String) -> Bool, draft: inout DetectionDraft) {
        if exists("tsconfig.json") {
            draft.stack.append("TypeScript")
            draft.entries.append("tsconfig.json")
        }
        detectPython(exists: exists, draft: &draft)
        if exists("Cargo.toml") {
            draft.stack.append("Rust")
            draft.buildCommand = "cargo build"
            draft.testCommand = "cargo test"
            draft.entries.append("Cargo.toml")
        }
        if exists("go.mod") {
            draft.stack.append("Go")
            draft.buildCommand = "go build ./..."
            draft.testCommand = "go test ./..."
            draft.entries.append("go.mod")
        }
        if exists("Dockerfile") || exists("docker-compose.yml") || exists("docker-compose.yaml") {
            draft.stack.append("Docker")
        }
    }

    private static func detectPython(exists: (String) -> Bool, draft: inout DetectionDraft) {
        guard exists("requirements.txt") || exists("pyproject.toml") || exists("setup.py") else { return }
        draft.stack.append("Python")
        if exists("pyproject.toml") {
            draft.entries.append("pyproject.toml")
            if exists("poetry.lock") { draft.stack.append("Poetry") }
        }
        if draft.testCommand == nil { draft.testCommand = "pytest" }
    }

    private static func detectArchitecture(exists: (String) -> Bool, draft: inout DetectionDraft) {
        guard draft.architecture.isEmpty else { return }
        if exists("src/app") || exists("app") {
            draft.architecture = "App Router"
        } else if exists("src/pages") || exists("pages") {
            draft.architecture = "Pages Router"
        } else if exists("Sources") && exists("Tests") {
            draft.architecture = "Swift Package (Sources/Tests)"
        } else if exists("src") && exists("tests") {
            draft.architecture = "src/tests layout"
        }
    }
}
