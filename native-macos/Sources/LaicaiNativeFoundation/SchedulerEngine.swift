import Foundation
import LaicaiNativeDomain

// MARK: - Scheduled Task Definition

public struct ScheduledTask: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var message: String
    public var schedule: Schedule
    public var workflowName: String?
    public var enabled: Bool
    public var lastRun: Date?
    public var nextRun: Date?
    public var runCount: Int
    public var maxRuns: Int?
    public var createdAt: Date

    public enum Schedule: Codable, Sendable, Equatable {
        case interval(seconds: Int)
        case daily(hour: Int, minute: Int)
        case weekly(dayOfWeek: Int, hour: Int, minute: Int)
        case cron(expression: String)

        public var displayText: String {
            switch self {
            case .interval(let seconds):
                if seconds >= 3600 { return "每 \(seconds / 3600) 小时" }
                if seconds >= 60 { return "每 \(seconds / 60) 分钟" }
                return "每 \(seconds) 秒"
            case .daily(let hour, let minute):
                return "每天 \(String(format: "%02d:%02d", hour, minute))"
            case .weekly(let day, let hour, let minute):
                let dayNames = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
                let dayStr = day >= 1 && day <= 7 ? dayNames[day] : "周\(day)"
                return "\(dayStr) \(String(format: "%02d:%02d", hour, minute))"
            case .cron(let expr):
                return "cron: \(expr)"
            }
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        message: String,
        schedule: Schedule,
        workflowName: String? = nil,
        enabled: Bool = true,
        lastRun: Date? = nil,
        nextRun: Date? = nil,
        runCount: Int = 0,
        maxRuns: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.message = message
        self.schedule = schedule
        self.workflowName = workflowName
        self.enabled = enabled
        self.lastRun = lastRun
        self.nextRun = nextRun
        self.runCount = runCount
        self.maxRuns = maxRuns
        self.createdAt = createdAt
    }
}

// MARK: - Scheduler Engine

@MainActor
public final class SchedulerEngine: ObservableObject {
    public static let shared = SchedulerEngine()

    @Published public private(set) var tasks: [ScheduledTask] = []
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var lastExecutionLog: [ScheduleExecutionEntry] = []

    public struct ScheduleExecutionEntry: Identifiable {
        public let id = UUID()
        public let taskName: String
        public let startedAt: Date
        public var completedAt: Date?
        public var success: Bool
        public var result: String?
    }

    /// Callback to execute a task message through the main app
    public var onExecuteTask: ((String, String?) async -> String)? // (message, workflowName) -> result

    private var timer: Timer?
    private var persistPath: String = ""

    private init() {}

    // MARK: - Lifecycle

    public func start(workspaceRoot: String) {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = root.isEmpty
            ? ((FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()) as NSString).appendingPathComponent("Laicai")
            : (root as NSString).appendingPathComponent(".laicai")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        persistPath = (dir as NSString).appendingPathComponent("scheduled_tasks.json")

        loadTasks()
        computeNextRuns()

        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.tick()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    // MARK: - Task Management

    public func addTask(_ task: ScheduledTask) {
        var t = task
        t.nextRun = computeNextRun(for: t.schedule)
        tasks.append(t)
        persist()
    }

    public func removeTask(id: UUID) {
        tasks.removeAll { $0.id == id }
        persist()
    }

    public func toggleTask(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].enabled.toggle()
        if tasks[index].enabled {
            tasks[index].nextRun = computeNextRun(for: tasks[index].schedule)
        }
        persist()
    }

    // MARK: - Tick (check and execute due tasks)

    private func tick() async {
        let now = Date()
        for i in tasks.indices {
            guard tasks[i].enabled else { continue }
            guard let nextRun = tasks[i].nextRun, nextRun <= now else { continue }

            // Check max runs
            if let maxRuns = tasks[i].maxRuns, tasks[i].runCount >= maxRuns {
                tasks[i].enabled = false
                continue
            }

            // Execute
            let taskName = tasks[i].name
            let message = tasks[i].message
            let workflowName = tasks[i].workflowName

            var entry = ScheduleExecutionEntry(taskName: taskName, startedAt: now, success: false)

            if let executor = onExecuteTask {
                let result = await executor(message, workflowName)
                entry.completedAt = Date()
                entry.success = true
                entry.result = String(result.prefix(200))
            } else {
                entry.completedAt = Date()
                entry.result = "未配置执行器"
            }

            lastExecutionLog.append(entry)
            if lastExecutionLog.count > 100 { lastExecutionLog.removeFirst(lastExecutionLog.count - 100) }

            tasks[i].lastRun = now
            tasks[i].runCount += 1
            tasks[i].nextRun = computeNextRun(for: tasks[i].schedule, after: now)

            NotificationManager.shared.post(
                title: "定时任务完成",
                body: "\(taskName)：\(entry.result ?? "完成")"
            )
        }
        persist()
    }

    // MARK: - Schedule Computation

    private func computeNextRuns() {
        let now = Date()
        for i in tasks.indices where tasks[i].enabled {
            if tasks[i].nextRun == nil || tasks[i].nextRun! < now {
                tasks[i].nextRun = computeNextRun(for: tasks[i].schedule, after: now)
            }
        }
    }

    private func computeNextRun(for schedule: ScheduledTask.Schedule, after: Date = Date()) -> Date {
        let cal = Calendar.current
        switch schedule {
        case .interval(let seconds):
            return after.addingTimeInterval(Double(seconds))

        case .daily(let hour, let minute):
            var components = cal.dateComponents([.year, .month, .day], from: after)
            components.hour = hour
            components.minute = minute
            components.second = 0
            if let date = cal.date(from: components), date > after {
                return date
            }
            return cal.date(byAdding: .day, value: 1, to: cal.date(from: components) ?? after) ?? after.addingTimeInterval(86400)

        case .weekly(let dayOfWeek, let hour, let minute):
            var components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: after)
            components.weekday = dayOfWeek == 7 ? 1 : dayOfWeek + 1 // Convert Mon=1 to Calendar weekday
            components.hour = hour
            components.minute = minute
            components.second = 0
            if let date = cal.date(from: components), date > after {
                return date
            }
            return cal.date(byAdding: .weekOfYear, value: 1, to: cal.date(from: components) ?? after) ?? after.addingTimeInterval(604800)

        case .cron(let expression):
            return CronParser.nextFire(expression: expression, after: after) ?? after.addingTimeInterval(3600)
        }
    }

    // MARK: - Cron Expression Parser

    private enum CronParser {
        /// Parse standard 5-field cron: minute hour day month weekday
        /// Supports: *, N, */N, N-M, comma-separated lists
        static func nextFire(expression: String, after: Date) -> Date? {
            let fields = expression.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard fields.count >= 5 else { return nil }

            let cal = Calendar.current
            var candidate = cal.date(byAdding: .minute, value: 1, to: after)!
            // Zero out seconds
            var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: candidate)
            comps.second = 0
            candidate = cal.date(from: comps) ?? candidate

            // Try up to 1 year of minutes (525600)
            for _ in 0..<525600 {
                let c = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
                let minute = c.minute!, hour = c.hour!, day = c.day!, month = c.month!
                let weekday = c.weekday! // 1=Sun, 2=Mon, ..., 7=Sat

                if matches(field: fields[0], value: minute, range: 0...59) &&
                   matches(field: fields[1], value: hour, range: 0...23) &&
                   matches(field: fields[2], value: day, range: 1...31) &&
                   matches(field: fields[3], value: month, range: 1...12) &&
                   matches(field: fields[4], value: weekday == 1 ? 0 : weekday - 1, range: 0...6) {
                    return candidate
                }
                candidate = cal.date(byAdding: .minute, value: 1, to: candidate)!
            }
            return nil
        }

        private static func matches(field: String, value: Int, range: ClosedRange<Int>) -> Bool {
            if field == "*" { return true }

            // Step: */N
            if field.hasPrefix("*/"), let step = Int(field.dropFirst(2)), step > 0 {
                return (value - range.lowerBound) % step == 0
            }

            // Comma-separated list
            let parts = field.components(separatedBy: ",")
            for part in parts {
                // Range: N-M
                if part.contains("-") {
                    let bounds = part.components(separatedBy: "-")
                    if bounds.count == 2, let lo = Int(bounds[0]), let hi = Int(bounds[1]) {
                        if value >= lo && value <= hi { return true }
                    }
                } else if let exact = Int(part) {
                    if exact == value { return true }
                }
            }
            return false
        }
    }

    // MARK: - Persistence

    private func loadTasks() {
        guard !persistPath.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: persistPath)),
              let loaded = try? JSONDecoder().decode([ScheduledTask].self, from: data) else { return }
        tasks = loaded
    }

    private func persist() {
        guard !persistPath.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(tasks) else { return }
        try? data.write(to: URL(fileURLWithPath: persistPath), options: .atomic)
    }
}
