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
    public var rootPath: String               // absolute workspace path
    public var createdAt: Date
    public var lastOpenedAt: Date

    // Structured project knowledge (auto-maintained)
    public var techStack: [String]            // ["Swift", "SwiftUI", "SQLite"]
    public var architecture: String           // free-form: "MVVM + Clean Architecture"
    public var conventions: [String]          // ["tabs for indentation", "Chinese comments"]
    public var entryPoints: [String]          // key files: ["Sources/App/main.swift"]
    public var buildCommand: String?          // "swift build", "npm run build"
    public var testCommand: String?           // "swift test", "npm test"
    public var setupScript: String?           // Codex-style: runs before each agent task
    public var useWorktree: Bool              // Codex-style: use git worktree for parallel isolation

    // User-maintained project notes
    public var notes: String                  // freeform project notes / goals
    public var activeTasks: [ProjectTask]     // ongoing tasks/TODOs

    // Stats
    public var taskCount: Int                 // total tasks run in this project
    public var lastTaskSummary: String?       // what was done last time

    // Rolling project memory (cross-session continuity)
    public var recentTaskSummaries: [TaskSummaryEntry]  // last N task findings
    public var discoveredIssues: [String]               // unresolved issues found during tasks

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
    public var summary: String       // what was done
    public var conclusions: [String] // key findings
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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Laicai", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
              let tIdx = projects[pIdx].activeTasks.firstIndex(where: { $0.id == taskID }) else { return }
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

        if !project.techStack.isEmpty {
            lines.append("## 技术栈")
            lines.append(project.techStack.joined(separator: ", "))
            lines.append("")
        }

        if !project.architecture.isEmpty {
            lines.append("## 架构")
            lines.append(project.architecture)
            lines.append("")
        }

        if !project.conventions.isEmpty {
            lines.append("## 约定")
            for c in project.conventions {
                lines.append("- \(c)")
            }
            lines.append("")
        }

        if !project.entryPoints.isEmpty {
            lines.append("## 关键文件")
            for e in project.entryPoints {
                lines.append("- `\(e)`")
            }
            lines.append("")
        }

        if let build = project.buildCommand {
            lines.append("## 构建")
            lines.append("```bash")
            lines.append(build)
            lines.append("```")
            lines.append("")
        }

        if let test = project.testCommand {
            lines.append("## 测试")
            lines.append("```bash")
            lines.append(test)
            lines.append("```")
            lines.append("")
        }

        if !project.notes.isEmpty {
            lines.append("## 项目备忘")
            lines.append(project.notes)
            lines.append("")
        }

        let pending = project.activeTasks.filter { $0.status != .completed }
        if !pending.isEmpty {
            lines.append("## 当前任务")
            for task in pending {
                let icon = task.status == .inProgress ? "🔄" : "⬜"
                lines.append("- \(icon) \(task.title)")
            }
            lines.append("")
        }

        // Rolling memory: recent task summaries
        if !project.recentTaskSummaries.isEmpty {
            lines.append("## 最近任务记忆")
            for entry in project.recentTaskSummaries.suffix(5) {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm"
                lines.append("### \(f.string(from: entry.date))")
                lines.append(entry.summary)
                if !entry.conclusions.isEmpty {
                    for c in entry.conclusions.prefix(3) {
                        lines.append("- \(c)")
                    }
                }
                lines.append("")
            }
        } else if let last = project.lastTaskSummary {
            lines.append("## 上次会话")
            lines.append(last)
            lines.append("")
        }

        if !project.discoveredIssues.isEmpty {
            lines.append("## 已知问题")
            for issue in project.discoveredIssues.suffix(10) {
                lines.append("- \(issue)")
            }
            lines.append("")
        }

        let content = lines.joined(separator: "\n")
        try? content.write(toFile: mdPath, atomically: true, encoding: .utf8)
    }

    /// Update project knowledge after a task completes.
    /// Called by the agent loop finalizer.
    public func learnFromTask(rootPath: String, summary: String, filesModified: [String], conclusions: [String]) {
        guard let idx = projects.firstIndex(where: { $0.rootPath == rootPath }) else { return }

        projects[idx].taskCount += 1
        projects[idx].lastTaskSummary = String(summary.prefix(500))
        projects[idx].lastOpenedAt = Date()

        // Rolling task memory: keep last 10 task summaries for cross-session continuity
        let entry = TaskSummaryEntry(
            title: String(summary.prefix(80)),
            summary: String(summary.prefix(300)),
            conclusions: conclusions.map { String($0.prefix(200)) },
            filesModified: Array(filesModified.prefix(20))
        )
        projects[idx].recentTaskSummaries.append(entry)
        if projects[idx].recentTaskSummaries.count > 10 {
            projects[idx].recentTaskSummaries = Array(projects[idx].recentTaskSummaries.suffix(10))
        }

        // Extract discovered issues from conclusions
        let issueMarkers = ["bug", "问题", "issue", "todo", "fixme", "待修复", "待解决", "需要", "broken", "失败"]
        for conclusion in conclusions {
            let lower = conclusion.lowercased()
            if issueMarkers.contains(where: { lower.contains($0) }) {
                let short = String(conclusion.prefix(150))
                if !projects[idx].discoveredIssues.contains(short) {
                    projects[idx].discoveredIssues.append(short)
                    if projects[idx].discoveredIssues.count > 20 {
                        projects[idx].discoveredIssues = Array(projects[idx].discoveredIssues.suffix(20))
                    }
                }
            }
        }

        // Auto-update entry points if important files were modified
        let importantExtensions = Set(["swift", "ts", "tsx", "py", "go", "rs", "java", "kt"])
        for file in filesModified {
            let ext = (file as NSString).pathExtension
            guard importantExtensions.contains(ext) else { continue }
            let lower = file.lowercased()
            if lower.contains("main") || lower.contains("app.") || lower.contains("index.") {
                if !projects[idx].entryPoints.contains(file) {
                    projects[idx].entryPoints.append(file)
                    if projects[idx].entryPoints.count > 20 {
                        projects[idx].entryPoints = Array(projects[idx].entryPoints.suffix(20))
                    }
                }
            }
        }

        // Extract conventions from conclusions
        for conclusion in conclusions {
            let lower = conclusion.lowercased()
            if lower.contains("convention") || lower.contains("约定") || lower.contains("规范") || lower.contains("always") || lower.contains("never") {
                let short = String(conclusion.prefix(100))
                if !projects[idx].conventions.contains(short) {
                    projects[idx].conventions.append(short)
                    if projects[idx].conventions.count > 15 {
                        projects[idx].conventions = Array(projects[idx].conventions.suffix(15))
                    }
                }
            }
        }

        save()
        generateProjectMD(for: projects[idx])
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
        // Rolling task memory: inject recent task summaries for cross-session continuity
        if !project.recentTaskSummaries.isEmpty {
            let recent = project.recentTaskSummaries.suffix(3)
            var historyLines: [String] = ["最近任务记忆："]
            for entry in recent {
                let dateStr = Self.shortDateString(entry.date)
                historyLines.append("  - [\(dateStr)] \(entry.summary)")
                for c in entry.conclusions.prefix(2) {
                    historyLines.append("    → \(c)")
                }
            }
            parts.append(historyLines.joined(separator: "\n"))
        } else if let last = project.lastTaskSummary {
            parts.append("上次：\(String(last.prefix(200)))")
        }

        // Unresolved issues discovered during previous tasks
        if !project.discoveredIssues.isEmpty {
            let issues = project.discoveredIssues.suffix(5)
            parts.append("已知问题（\(issues.count)项）：\(issues.joined(separator: "；"))")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    nonisolated private static func shortDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
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
              let decoded = try? JSONDecoder().decode([Project].self, from: data) else { return }
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
        let fm = FileManager.default
        var stack: [String] = []
        var buildCmd: String?
        var testCmd: String?
        var entries: [String] = []
        var arch = ""

        let exists: (String) -> Bool = { name in
            fm.fileExists(atPath: (rootPath as NSString).appendingPathComponent(name))
        }

        // Swift
        if exists("Package.swift") {
            stack.append("Swift")
            stack.append("Swift Package Manager")
            buildCmd = "swift build"
            testCmd = "swift test"
            entries.append("Package.swift")
            if exists("Sources") {
                // Find main entry points
                if let enumerator = fm.enumerator(atPath: (rootPath as NSString).appendingPathComponent("Sources")) {
                    while let file = enumerator.nextObject() as? String {
                        if file.hasSuffix("App.swift") || file.hasSuffix("main.swift") || file.hasSuffix("AppDelegate.swift") {
                            entries.append("Sources/\(file)")
                            if entries.count > 10 { break }
                        }
                    }
                }
            }
        }

        // Xcode
        if let contents = try? fm.contentsOfDirectory(atPath: rootPath),
           contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            if !stack.contains("Swift") { stack.append("Swift") }
            stack.append("Xcode")
            if buildCmd == nil { buildCmd = "xcodebuild" }
        }

        // Node.js
        if exists("package.json") {
            stack.append("Node.js")
            if let data = try? Data(contentsOf: URL(fileURLWithPath: (rootPath as NSString).appendingPathComponent("package.json"))),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let deps = json["dependencies"] as? [String: Any] {
                    if deps["react"] != nil { stack.append("React") }
                    if deps["next"] != nil { stack.append("Next.js"); arch = "Next.js App" }
                    if deps["vue"] != nil { stack.append("Vue") }
                    if deps["express"] != nil { stack.append("Express") }
                    if deps["tailwindcss"] != nil || (json["devDependencies"] as? [String: Any])?["tailwindcss"] != nil {
                        stack.append("Tailwind CSS")
                    }
                }
                if let scripts = json["scripts"] as? [String: String] {
                    if scripts["build"] != nil { buildCmd = "npm run build" }
                    if scripts["test"] != nil { testCmd = "npm test" }
                }
            }
            if exists("pnpm-lock.yaml") { stack.append("pnpm") }
            else if exists("yarn.lock") { stack.append("yarn") }
            entries.append("package.json")
        }

        // TypeScript
        if exists("tsconfig.json") {
            stack.append("TypeScript")
            entries.append("tsconfig.json")
        }

        // Python
        if exists("requirements.txt") || exists("pyproject.toml") || exists("setup.py") {
            stack.append("Python")
            if exists("pyproject.toml") {
                entries.append("pyproject.toml")
                if exists("poetry.lock") { stack.append("Poetry") }
            }
            if testCmd == nil { testCmd = "pytest" }
        }

        // Rust
        if exists("Cargo.toml") {
            stack.append("Rust")
            buildCmd = "cargo build"
            testCmd = "cargo test"
            entries.append("Cargo.toml")
        }

        // Go
        if exists("go.mod") {
            stack.append("Go")
            buildCmd = "go build ./..."
            testCmd = "go test ./..."
            entries.append("go.mod")
        }

        // Docker
        if exists("Dockerfile") || exists("docker-compose.yml") || exists("docker-compose.yaml") {
            stack.append("Docker")
        }

        // Git
        if exists(".git") {
            // not a "tech" but useful context
        }

        // Architecture hints from directory structure
        if arch.isEmpty {
            if exists("src/app") || exists("app") { arch = "App Router" }
            else if exists("src/pages") || exists("pages") { arch = "Pages Router" }
            else if exists("Sources") && exists("Tests") { arch = "Swift Package (Sources/Tests)" }
            else if exists("src") && exists("tests") { arch = "src/tests layout" }
        }

        return DetectionResult(
            techStack: stack,
            buildCommand: buildCmd,
            testCommand: testCmd,
            entryPoints: Array(entries.prefix(15)),
            architecture: arch
        )
    }
}
