import Foundation
import AppKit
import UserNotifications
import LaicaiNativeDomain

// MARK: - Menu Bar Agent

public final class MenuBarAgent: NSObject, ObservableObject {
    public static let shared = MenuBarAgent()
    
    @Published public private(set) var statusItem: NSStatusItem?
    @Published public private(set) var isActive: Bool = true
    
    private var statusBarButton: NSStatusBarButton?
    
    private override init() { super.init() }
    
    public func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "来财"
        item.button?.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        
        let menu = NSMenu()
        menu.addItem(makeItem("打开来财", action: #selector(activateApp)))
        menu.addItem(.separator())
        menu.addItem(makeItem("新建会话", action: #selector(newThread), key: "n"))
        menu.addItem(makeItem("继续最近任务", action: #selector(continueLastTask), key: "r"))
        menu.addItem(.separator())
        let toggleItem = makeItem(isActive ? "暂停后台智能" : "恢复后台智能", action: #selector(toggleActive))
        toggleItem.tag = 100
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("退出来财", action: #selector(quitApp), key: "q"))
        menu.delegate = self
        item.menu = menu
        
        statusItem = item
        statusBarButton = item.button
        updateStatusBar()
    }
    
    public func updateStatusBar() {
        let title = isActive ? "来财" : "来财⏸"
        statusBarButton?.title = title
    }
    
    @objc private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    @objc private func newThread() {
        NotificationCenter.default.post(name: .laicaiNewThread, object: nil)
        activateApp()
    }
    
    @objc private func continueLastTask() {
        NotificationCenter.default.post(name: .laicaiContinueLastTask, object: nil)
        activateApp()
    }
    
    @objc private func toggleActive() {
        isActive.toggle()
        updateStatusBar()
        if let menu = statusItem?.menu, let toggleItem = menu.item(withTag: 100) {
            toggleItem.title = isActive ? "暂停后台智能" : "恢复后台智能"
        }
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func makeItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}

extension MenuBarAgent: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if let toggleItem = menu.item(withTag: 100) {
            toggleItem.title = isActive ? "暂停后台智能" : "恢复后台智能"
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    public static let laicaiNewThread = Notification.Name("laicai.newThread")
    public static let laicaiContinueLastTask = Notification.Name("laicai.continueLastTask")
    public static let laicaiBackgroundTaskCompleted = Notification.Name("laicai.backgroundTaskCompleted")
    public static let laicaiProactiveSuggestion = Notification.Name("laicai.proactiveSuggestion")
    public static let laicaiToggleCommandPalette = Notification.Name("laicai.toggleCommandPalette")
    public static let laicaiToggleSearch = Notification.Name("laicai.toggleSearch")
    public static let laicaiPanelToggled = Notification.Name("laicai.panelToggled")
}

// MARK: - Global Shortcut Manager

public final class GlobalShortcutManager {
    public static let shared = GlobalShortcutManager()
    
    private var eventMonitor: Any?
    
    private init() {}
    
    public func install() {
        // Global shortcut: ⌘+Shift+L to bring to front
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // Cmd+Shift+L
            if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) && event.keyCode == 37 {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.isVisible }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            // Cmd+Shift+N: new thread
            if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) && event.keyCode == 45 {
                NotificationCenter.default.post(name: .laicaiNewThread, object: nil)
            }
        }
    }
    
    public func uninstall() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - Notification Manager

public final class NotificationManager {
    public static let shared = NotificationManager()
    
    private init() {}
    
    public func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    
    public func post(title: String, body: String, identifier: String = UUID().uuidString, threadID: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let threadID {
            content.userInfo = ["threadID": threadID]
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    public func notifyBackgroundTaskCompleted(taskTitle: String, threadID: String) {
        post(title: "后台任务完成", body: taskTitle, threadID: threadID)
        NotificationCenter.default.post(name: .laicaiBackgroundTaskCompleted, object: nil, userInfo: ["threadID": threadID])
    }
}

// MARK: - Background Task Manager

@MainActor
public final class BackgroundTaskManager: ObservableObject {
    public static let shared = BackgroundTaskManager()
    
    @Published public private(set) var runningTasks: [BackgroundTask] = []
    @Published public private(set) var completedTasks: [BackgroundTask] = []
    
    private var timer: Timer?
    
    private init() {}
    
    public struct BackgroundTask: Identifiable, Equatable {
        public let id: UUID
        public var title: String
        public var status: Status
        public var createdAt: Date
        public var completedAt: Date?
        public var result: String?
        
        public enum Status: String, Sendable {
            case running, completed, failed
        }
    }
    
    public func startTask(title: String) -> UUID {
        let task = BackgroundTask(id: UUID(), title: title, status: .running, createdAt: Date())
        runningTasks.append(task)
        return task.id
    }
    
    public func completeTask(id: UUID, result: String? = nil) {
        guard let index = runningTasks.firstIndex(where: { $0.id == id }) else { return }
        var task = runningTasks.remove(at: index)
        task.status = .completed
        task.completedAt = Date()
        task.result = result
        completedTasks.append(task)
        if completedTasks.count > 50 { completedTasks.removeFirst(completedTasks.count - 50) }
        NotificationManager.shared.notifyBackgroundTaskCompleted(taskTitle: task.title, threadID: task.id.uuidString)
    }
    
    public func failTask(id: UUID, error: String) {
        guard let index = runningTasks.firstIndex(where: { $0.id == id }) else { return }
        var task = runningTasks.remove(at: index)
        task.status = .failed
        task.completedAt = Date()
        task.result = error
        completedTasks.append(task)
    }
}

// MARK: - Daily/Weekly Report Generator

public struct ReportGenerator {

    // MARK: - Daily Report

    public static func generateDailyReport(threads: [Thread]) -> String {
        let today = Calendar.current.startOfDay(for: Date())
        let todayThreads = threads.filter { $0.updatedAt >= today }
            .sorted { $0.updatedAt > $1.updatedAt }
        let tasks = todayThreads.filter { $0.source == .task }
        let chats = todayThreads.filter { $0.source == .session }
        let completedTasks = tasks.filter { $0.status == .completed }
        let failedTasks = tasks.filter { $0.status == .failed }
        let runningTasks = tasks.filter { $0.status == .running }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd (EEEE)"
        fmt.locale = Locale(identifier: "zh_CN")

        var lines: [String] = [
            "# 今日报告  \(fmt.string(from: Date()))",
            "",
            "## 概览",
            "",
            "| 指标 | 数量 |",
            "|------|------|",
            "| 活跃会话 | \(todayThreads.count) |",
            "| 任务 | \(tasks.count)（✅ \(completedTasks.count)　❌ \(failedTasks.count)　🔄 \(runningTasks.count)）|",
            "| 会话 | \(chats.count) |",
            "| 工具调用 | \(countToolCalls(todayThreads)) 次 |",
            "| 文件变更 | \(countFileChanges(todayThreads)) 个文件 |",
        ]

        // MARK: Activity Log
        lines += ["", "## 今天做了什么", ""]
        if todayThreads.isEmpty {
            lines.append("_今天还没有活动记录。_")
        } else {
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "HH:mm"
            for thread in todayThreads {
                let icon = thread.source == .task ? (statusIcon(thread.status)) : "💬"
                let time = timeFmt.string(from: thread.createdAt)
                lines.append("### \(icon) \(thread.title)  `\(time)`")
                lines.append("")

                // User inputs
                let userInputs = thread.steps.filter { $0.kind == .userInput }
                if let first = userInputs.first {
                    let preview = String(first.text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                    lines.append("> \(preview)\(first.text.count > 120 ? "…" : "")")
                    lines.append("")
                }

                // Tool calls summary
                let toolCalls = thread.steps.filter { $0.kind == .toolCall }
                if !toolCalls.isEmpty {
                    let toolGroups = Dictionary(grouping: toolCalls, by: { $0.toolName ?? "unknown" })
                    let toolSummary = toolGroups.map { "\($0.key) ×\($0.value.count)" }
                        .sorted()
                        .joined(separator: "、")
                    lines.append("**工具调用**：\(toolSummary)")
                }

                // File changes
                let changedFiles = extractChangedFiles(thread)
                if !changedFiles.isEmpty {
                    lines.append("**文件变更**：\(changedFiles.prefix(5).joined(separator: "、"))\(changedFiles.count > 5 ? " 等 \(changedFiles.count) 个文件" : "")")
                }

                // Key outputs / conclusions
                let outputs = thread.steps.filter { $0.kind == .textOutput && !$0.text.isEmpty }
                if let last = outputs.last {
                    let preview = String(last.text.prefix(150)).replacingOccurrences(of: "\n", with: " ")
                    lines.append("**结论**：\(preview)\(last.text.count > 150 ? "…" : "")")
                }

                // Errors
                let errors = thread.steps.filter { $0.isFailure }
                if !errors.isEmpty {
                    lines.append("**⚠️ 错误**：\(errors.count) 个步骤失败")
                }

                lines.append("")
            }
        }

        // MARK: File Change Summary
        let allChangedFiles = todayThreads.flatMap { extractChangedFiles($0) }
        let uniqueFiles = Array(Set(allChangedFiles)).sorted()
        if !uniqueFiles.isEmpty {
            lines += ["## 文件变更汇总", ""]
            for file in uniqueFiles.prefix(20) {
                lines.append("- `\(file)`")
            }
            if uniqueFiles.count > 20 {
                lines.append("- …共 \(uniqueFiles.count) 个文件")
            }
            lines.append("")
        }

        // MARK: Wiki Suggestions
        let wikiSuggestions = extractWikiSuggestions(todayThreads)
        if !wikiSuggestions.isEmpty {
            lines += ["## 📝 建议存入 Wiki", ""]
            lines.append("以下内容来自今天的会话和任务，可能值得沉淀为知识库条目：")
            lines.append("")
            for suggestion in wikiSuggestions {
                lines.append("### \(suggestion.topic)")
                lines.append("")
                lines.append("\(suggestion.reason)")
                lines.append("")
                if !suggestion.keyContent.isEmpty {
                    lines.append("**关键内容**：")
                    lines.append("")
                    lines.append("> \(suggestion.keyContent)")
                    lines.append("")
                }
                lines.append("**来源**：\(suggestion.sourceThread)")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Weekly Report

    public static func generateWeeklyReport(threads: [Thread]) -> String {
        let cal = Calendar.current
        let weekAgo = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let weekThreads = threads.filter { $0.updatedAt >= weekAgo }
            .sorted { $0.updatedAt > $1.updatedAt }
        let tasks = weekThreads.filter { $0.source == .task }
        let chats = weekThreads.filter { $0.source == .session }
        let completedTasks = tasks.filter { $0.status == .completed }
        let failedTasks = tasks.filter { $0.status == .failed }

        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd"

        var lines: [String] = [
            "# 周报  \(fmt.string(from: weekAgo)) – \(fmt.string(from: Date()))",
            "",
            "## 概览",
            "",
            "| 指标 | 数量 |",
            "|------|------|",
            "| 总会话 | \(weekThreads.count) |",
            "| 完成任务 | \(completedTasks.count) |",
            "| 失败任务 | \(failedTasks.count) |",
            "| 会话 | \(chats.count) |",
            "| 工具调用 | \(countToolCalls(weekThreads)) 次 |",
            "| 文件变更 | \(countFileChanges(weekThreads)) 个文件 |",
        ]

        // Daily breakdown
        lines += ["", "## 每日活动", ""]
        for dayOffset in (0...6).reversed() {
            guard let day = cal.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let dayStart = cal.startOfDay(for: day)
            guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let dayThreads = weekThreads.filter { $0.updatedAt >= dayStart && $0.updatedAt < dayEnd }
            guard !dayThreads.isEmpty else { continue }
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "MM/dd (E)"
            dayFmt.locale = Locale(identifier: "zh_CN")
            let dayTasks = dayThreads.filter { $0.source == .task }
            let dayCompleted = dayTasks.filter { $0.status == .completed }
            lines.append("**\(dayFmt.string(from: day))**：\(dayThreads.count) 会话，\(dayCompleted.count)/\(dayTasks.count) 任务完成")
            for t in dayThreads.prefix(5) {
                let icon = t.source == .task ? statusIcon(t.status) : "💬"
                lines.append("  - \(icon) \(t.title)")
            }
            if dayThreads.count > 5 {
                lines.append("  - …还有 \(dayThreads.count - 5) 项")
            }
            lines.append("")
        }

        // Completed tasks detail
        if !completedTasks.isEmpty {
            lines += ["## 完成的任务", ""]
            for task in completedTasks.prefix(20) {
                let files = extractChangedFiles(task)
                let fileSuffix = files.isEmpty ? "" : "（涉及 \(files.count) 个文件）"
                lines.append("- ✅ **\(task.title)**\(fileSuffix)")
            }
            lines.append("")
        }

        // Failed tasks
        if !failedTasks.isEmpty {
            lines += ["## 失败/需关注", ""]
            for task in failedTasks.prefix(10) {
                let errorSteps = task.steps.filter { $0.isFailure }
                let errorHint = errorSteps.first.map { "：" + String($0.text.prefix(80)) } ?? ""
                lines.append("- ❌ **\(task.title)**\(errorHint)")
            }
            lines.append("")
        }

        // Wiki suggestions for the week
        let wikiSuggestions = extractWikiSuggestions(weekThreads)
        if !wikiSuggestions.isEmpty {
            lines += ["## 📝 建议存入 Wiki", ""]
            for suggestion in wikiSuggestions {
                lines.append("- **\(suggestion.topic)**：\(suggestion.reason)（来自「\(suggestion.sourceThread)」）")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func countToolCalls(_ threads: [Thread]) -> Int {
        threads.reduce(0) { $0 + $1.steps.filter { $0.kind == .toolCall }.count }
    }

    private static func countFileChanges(_ threads: [Thread]) -> Int {
        Set(threads.flatMap { extractChangedFiles($0) }).count
    }

    private static func extractChangedFiles(_ thread: Thread) -> [String] {
        var files: [String] = []
        for step in thread.steps {
            // Files from diff hunks
            if let path = step.diffFilePath, !path.isEmpty {
                files.append(URL(fileURLWithPath: path).lastPathComponent)
            }
            // Files from tool params (file.write, file.read etc.)
            if let params = step.toolParams {
                for (key, value) in params where (key == "path" || key == "file") && !value.isEmpty {
                    files.append(URL(fileURLWithPath: value).lastPathComponent)
                }
            }
        }
        return Array(Set(files)).sorted()
    }

    private static func statusIcon(_ status: TaskStatus) -> String {
        switch status {
        case .completed: return "✅"
        case .failed: return "❌"
        case .running: return "🔄"
        case .queued: return "⏳"
        case .cancelled: return "⛔"
        case .waitingReview: return "👁️"
        }
    }

    // MARK: - Wiki Suggestion Extraction

    struct WikiSuggestion {
        let topic: String
        let reason: String
        let keyContent: String
        let sourceThread: String
    }

    private static func extractWikiSuggestions(_ threads: [Thread]) -> [WikiSuggestion] {
        var suggestions: [WikiSuggestion] = []

        for thread in threads {
            // 1. Threads with substantial AI output (solutions, analysis, architecture)
            let aiOutputs = thread.steps.filter { $0.kind == .textOutput && $0.text.count > 200 }
            let toolCalls = thread.steps.filter { $0.kind == .toolCall }
            let hasCodeChanges = thread.steps.contains { $0.diffFilePath != nil }

            // Debug / fix tasks — document the problem + solution
            if thread.title.containsAny(["调试", "debug", "修复", "fix", "bug", "错误"]) && thread.status == .completed {
                let conclusion = aiOutputs.last?.text ?? ""
                suggestions.append(WikiSuggestion(
                    topic: "问题排查：\(String(thread.title.prefix(30)))",
                    reason: "成功修复的 bug/问题，记录排查过程可避免重复踩坑",
                    keyContent: String(conclusion.prefix(200)),
                    sourceThread: thread.title
                ))
            }

            // Architecture / refactor discussions
            if thread.title.containsAny(["重构", "refactor", "架构", "设计", "design", "优化"]) {
                let content = aiOutputs.map(\.text).joined(separator: " ")
                if content.count > 300 {
                    suggestions.append(WikiSuggestion(
                        topic: "架构决策：\(String(thread.title.prefix(30)))",
                        reason: "包含架构分析或重构方案，值得作为设计决策记录",
                        keyContent: String(content.prefix(200)),
                        sourceThread: thread.title
                    ))
                }
            }

            // Threads with many tool calls (complex investigation)
            if toolCalls.count >= 5 && aiOutputs.count >= 2 {
                let userInput = thread.steps.first { $0.kind == .userInput }?.text ?? ""
                if !suggestions.contains(where: { $0.sourceThread == thread.title }) {
                    suggestions.append(WikiSuggestion(
                        topic: "工作记录：\(String(thread.title.prefix(30)))",
                        reason: "涉及 \(toolCalls.count) 次工具调用的深度工作，包含有价值的分析过程",
                        keyContent: String(userInput.prefix(150)),
                        sourceThread: thread.title
                    ))
                }
            }

            // Code review results
            if thread.workflowName == "code-review" && thread.status == .completed {
                let review = aiOutputs.last?.text ?? ""
                if !review.isEmpty {
                    suggestions.append(WikiSuggestion(
                        topic: "代码审查记录",
                        reason: "代码审查发现的问题和建议，可沉淀为编码规范",
                        keyContent: String(review.prefix(200)),
                        sourceThread: thread.title
                    ))
                }
            }

            // New knowledge from chat sessions (long conversations)
            if thread.source == .session {
                let userSteps = thread.steps.filter { $0.kind == .userInput }
                let aiSteps = thread.steps.filter { $0.kind == .textOutput }
                if userSteps.count >= 3 && aiSteps.count >= 3 {
                    let topics = extractTopicsFromText(userSteps.map(\.text).joined(separator: " "))
                    if !topics.isEmpty {
                        suggestions.append(WikiSuggestion(
                            topic: topics.first ?? "会话知识点",
                            reason: "多轮深度会话，讨论了 \(topics.joined(separator: "、")) 等话题",
                            keyContent: String((aiSteps.last?.text ?? "").prefix(200)),
                            sourceThread: thread.title
                        ))
                    }
                }
            }
        }

        // Deduplicate by topic
        var seen = Set<String>()
        return suggestions.filter { seen.insert($0.topic).inserted }
    }

    private static func extractTopicsFromText(_ text: String) -> [String] {
        let keywords: [(pattern: String, topic: String)] = [
            ("api", "API 设计"),
            ("数据库", "数据库"),
            ("database", "数据库"),
            ("部署", "部署流程"),
            ("deploy", "部署流程"),
            ("测试", "测试策略"),
            ("test", "测试策略"),
            ("性能", "性能优化"),
            ("performance", "性能优化"),
            ("安全", "安全实践"),
            ("security", "安全实践"),
            ("缓存", "缓存策略"),
            ("cache", "缓存策略"),
            ("并发", "并发处理"),
            ("concurren", "并发处理"),
            ("工作流", "工作流设计"),
            ("workflow", "工作流设计"),
            ("ui", "UI/UX 设计"),
            ("ux", "UI/UX 设计"),
            ("架构", "系统架构"),
            ("architecture", "系统架构"),
        ]
        let lower = text.lowercased()
        var found: [String] = []
        for kw in keywords where lower.contains(kw.pattern) {
            if !found.contains(kw.topic) { found.append(kw.topic) }
        }
        return Array(found.prefix(3))
    }
}

private extension String {
    func containsAny(_ terms: [String]) -> Bool {
        let lower = self.lowercased()
        return terms.contains { lower.contains($0.lowercased()) }
    }
}

// MARK: - Project Change Monitor (FSEvents-based)

@MainActor
public final class ProjectChangeMonitor: ObservableObject {
    public static let shared = ProjectChangeMonitor()

    @Published public private(set) var recentChanges: [ProjectChange] = []
    @Published public private(set) var isMonitoring: Bool = false

    private var fsStream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?
    private var monitoredRoot: String = ""
    private static let ignored: Set<String> = [".git", "node_modules", ".build", "DerivedData", "__pycache__", ".DS_Store"]

    public struct ProjectChange: Sendable {
        public let path: String
        public let kind: Kind
        public let timestamp: Date

        public enum Kind: String, Sendable {
            case modified, added, removed
        }
    }

    private init() {}

    public func startMonitoring(workspaceRoot: String) {
        stopMonitoring()
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, FileManager.default.fileExists(atPath: root) else { return }
        monitoredRoot = root
        isMonitoring = true

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let paths = [root] as CFArray
        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes) |
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, numEvents, eventPaths, eventFlags, _ in
                guard let info else { return }
                let monitor = Unmanaged<ProjectChangeMonitor>.fromOpaque(info).takeUnretainedValue()
                guard let cfPaths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
                var changes: [ProjectChange] = []
                for i in 0..<numEvents {
                    let path = cfPaths[i]
                    let name = (path as NSString).lastPathComponent
                    if ProjectChangeMonitor.ignored.contains(name) { continue }
                    let flags = Int(eventFlags[i])
                    let kind: ProjectChange.Kind
                    if flags & kFSEventStreamEventFlagItemRemoved != 0 {
                        kind = .removed
                    } else if flags & kFSEventStreamEventFlagItemCreated != 0 || flags & kFSEventStreamEventFlagItemRenamed != 0 {
                        kind = .added
                    } else {
                        kind = .modified
                    }
                    let relPath = path.hasPrefix(monitor.monitoredRoot)
                        ? String(path.dropFirst(monitor.monitoredRoot.count + 1))
                        : path
                    changes.append(ProjectChange(path: relPath, kind: kind, timestamp: .now))
                }
                if !changes.isEmpty {
                    Task { @MainActor in
                        monitor.handleChanges(changes)
                    }
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.5,
            flags
        ) else {
            isMonitoring = false
            return
        }

        fsStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    public func stopMonitoring() {
        debounceTask?.cancel()
        debounceTask = nil
        if let stream = fsStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsStream = nil
        }
        isMonitoring = false
    }

    private func handleChanges(_ changes: [ProjectChange]) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.recentChanges = Array(changes.prefix(30))
            let summary = changes.count <= 3
                ? changes.map { "\($0.kind.rawValue)：\($0.path)" }.joined(separator: "、")
                : "\(changes.count) 个文件变更"
            NotificationManager.shared.post(title: "项目变更", body: summary)
        }
    }
}

// MARK: - Proactive Suggestion Engine

@MainActor
public final class ProactiveSuggestionEngine: ObservableObject {
    public static let shared = ProactiveSuggestionEngine()
    
    @Published public var isEnabled: Bool = true
    @Published public private(set) var currentSuggestion: Suggestion?
    
    public struct Suggestion: Identifiable {
        public let id = UUID()
        public let title: String
        public let description: String
        public let action: SuggestionAction
    }
    
    public enum SuggestionAction: String {
        case reviewChanges = "review_changes"
        case runTests = "run_tests"
        case commitWork = "commit_work"
        case generateDocs = "generate_docs"
    }
    
    private var checkTimer: Timer?
    
    private init() {}
    
    public func startChecking(workspaceRoot: String) {
        stopChecking()
        guard isEnabled else { return }

        checkTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.checkForSuggestions(workspaceRoot: workspaceRoot)
            }
        }
    }

    public func stopChecking() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    public func dismissSuggestion() {
        currentSuggestion = nil
    }

    private func checkForSuggestions(workspaceRoot: String) async {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }

        // Run git status on a background thread
        let gitDir = (root as NSString).appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitDir) {
            let modifiedCount = await Task.detached(priority: .utility) {
                Self.gitModifiedFileCount(root: root)
            }.value

            if modifiedCount >= 3 {
                currentSuggestion = Suggestion(
                    title: "有 \(modifiedCount) 个未提交变更",
                    description: "当前工作区有较多未提交的文件变更，建议审查并提交。",
                    action: .reviewChanges
                )
                return
            }
        }

        let testDir = (root as NSString).appendingPathComponent("Tests")
        if !FileManager.default.fileExists(atPath: testDir) {
            currentSuggestion = Suggestion(
                title: "项目缺少测试目录",
                description: "当前项目没有测试目录，建议添加单元测试。",
                action: .runTests
            )
            return
        }

        currentSuggestion = nil
    }

    private nonisolated static func gitModifiedFileCount(root: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root, "status", "--porcelain"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }
}
