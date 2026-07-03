import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

struct SchedulesPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var scheduler = SchedulerEngine.shared

    @State private var name = ""
    @State private var message = ""
    @State private var intervalMinutes = 60
    @State private var selectedWorkflowName = ""
    @State private var maxRunsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.medium) {
            overview
            createForm
            taskList
            executionLog
        }
    }

    private var overview: some View {
        let enabledCount = scheduler.tasks.filter(\.enabled).count
        return workbenchHeroCard(
            icon: scheduler.isRunning ? "alarm.waves.left.and.right" : "alarm",
            title: "定时会话",
            subtitle: scheduler.tasks.isEmpty ? "定期触发会话，适合巡检、复盘和固定报告。" : "\(enabledCount)/\(scheduler.tasks.count) 个任务启用",
            tint: Brand.teal
        ) {
            HStack(spacing: AppSpace.extraSmall) {
                scheduleMetric(
                    icon: "power", value: scheduler.isRunning ? "运行中" : "未启动", label: "调度器", tint: scheduler.isRunning ? Semantic.success : TextGrade.ghost)
                scheduleMetric(icon: "alarm", value: "\(scheduler.tasks.count)", label: "任务", tint: Brand.primary)
                scheduleMetric(icon: "clock.arrow.circlepath", value: nextRunSummary, label: "下次", tint: Semantic.warning)
            }
        }
    }

    private var createForm: some View {
        contextSectionCard(title: "新建定时任务", tint: Brand.teal) {
            VStack(alignment: .leading, spacing: AppSpace.small) {
                TextField("任务名，例如：每日项目巡检", text: $name)
                    .textFieldStyle(.plain)
                    .font(AppFont.caption)
                    .padding(.horizontal, AppSpace.medium)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(SurfaceGrade.card.opacity(0.76)))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(SurfaceGrade.hairline.opacity(0.85), lineWidth: 0.7))

                TextEditor(text: $message)
                    .font(AppFont.caption)
                    .foregroundStyle(TextGrade.primary)
                    .frame(minHeight: 74)
                    .scrollContentBackground(.hidden)
                    .padding(AppSpace.small)
                    .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(SurfaceGrade.card.opacity(0.76)))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(SurfaceGrade.hairline.opacity(0.85), lineWidth: 0.7))
                    .overlay(alignment: .topLeading) {
                        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("要定时执行的会话指令…")
                                .font(AppFont.caption)
                                .foregroundStyle(TextGrade.ghost)
                                .padding(.horizontal, AppSpace.medium)
                                .padding(.vertical, AppSpace.medium)
                                .allowsHitTesting(false)
                        }
                    }

                HStack(spacing: AppSpace.small) {
                    Stepper(value: $intervalMinutes, in: 1...1440, step: intervalStep) {
                        HStack(spacing: AppSpace.extraSmall) {
                            Image(systemName: "timer")
                                .font(.system(size: 10, weight: .medium))
                            Text("每 \(intervalMinutes) 分钟")
                                .font(AppFont.captionMedium)
                        }
                        .foregroundStyle(TextGrade.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    TextField("最多次数", text: $maxRunsText)
                        .textFieldStyle(.plain)
                        .font(AppFont.caption)
                        .frame(width: 72)
                        .padding(.horizontal, AppSpace.small)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: AppRadius.small).fill(SurfaceGrade.card.opacity(0.72)))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.small).strokeBorder(SurfaceGrade.hairline.opacity(0.85), lineWidth: 0.6))
                }

                if !workflowOptions.isEmpty {
                    Picker("流程", selection: $selectedWorkflowName) {
                        Text("普通会话").tag("")
                        ForEach(workflowOptions, id: \.self) { wfName in
                            Text(wfName).tag(wfName)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(AppFont.caption)
                }

                Button {
                    createTask()
                } label: {
                    Label("创建定时会话", systemImage: "plus")
                        .font(AppFont.captionMedium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpace.small)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.medium).fill(canCreate ? Brand.teal.opacity(0.14) : SurfaceGrade.elevated.opacity(0.62))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(
                                canCreate ? Brand.teal.opacity(0.22) : SurfaceGrade.hairline, lineWidth: 0.6))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canCreate ? Brand.teal : TextGrade.ghost)
                .disabled(!canCreate)
            }
        }
    }

    @ViewBuilder
    private var taskList: some View {
        if scheduler.tasks.isEmpty {
            workbenchEmptyState(
                icon: "alarm",
                title: "暂无定时会话",
                hint: "创建后会保存在当前工作区的 .laicai/scheduled_tasks.json"
            )
        } else {
            VStack(alignment: .leading, spacing: AppSpace.small) {
                workbenchSectionHeader(title: "任务列表", count: scheduler.tasks.count)
                ForEach(scheduler.tasks) { task in
                    scheduleTaskRow(task)
                }
            }
        }
    }

    @ViewBuilder
    private var executionLog: some View {
        if !scheduler.lastExecutionLog.isEmpty {
            VStack(alignment: .leading, spacing: AppSpace.small) {
                workbenchSectionHeader(title: "最近触发", count: scheduler.lastExecutionLog.count)
                VStack(spacing: AppSpace.extraSmall) {
                    ForEach(scheduler.lastExecutionLog.suffix(6).reversed()) { entry in
                        HStack(spacing: AppSpace.small) {
                            Image(systemName: entry.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(entry.success ? Semantic.success : Semantic.warning)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.taskName)
                                    .font(AppFont.captionMedium)
                                    .foregroundStyle(TextGrade.primary)
                                    .lineLimit(1)
                                Text(entry.result ?? "已触发")
                                    .font(AppFont.tiny)
                                    .foregroundStyle(TextGrade.muted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(RelativeTimeFormatter.string(for: entry.startedAt))
                                .font(AppFont.tiny)
                                .foregroundStyle(TextGrade.ghost)
                        }
                        .padding(AppSpace.small)
                        .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(SurfaceGrade.card.opacity(0.66)))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(SurfaceGrade.hairline.opacity(0.75), lineWidth: 0.6))
                    }
                }
            }
        }
    }

    private func scheduleTaskRow(_ task: ScheduledTask) -> some View {
        HStack(alignment: .top, spacing: AppSpace.small) {
            Button {
                scheduler.toggleTask(id: task.id)
            } label: {
                Image(systemName: task.enabled ? "checkmark.circle.fill" : "pause.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(task.enabled ? Semantic.success : TextGrade.ghost)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(task.enabled ? "暂停任务" : "启用任务")

            VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                HStack(spacing: AppSpace.extraSmall) {
                    Text(task.name)
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                    Text(task.schedule.displayText)
                        .font(AppFont.tiny)
                        .foregroundStyle(Brand.teal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Brand.teal.opacity(0.10)))
                }

                Text(task.message)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(2)

                HStack(spacing: AppSpace.small) {
                    if let workflowName = task.workflowName, !workflowName.isEmpty {
                        scheduleChip(icon: "arrow.triangle.branch", text: workflowName)
                    }
                    scheduleChip(icon: "play.circle", text: "已运行 \(task.runCount) 次")
                    if let nextRun = task.nextRun, task.enabled {
                        scheduleChip(icon: "clock", text: "下次 \(RelativeTimeFormatter.string(for: nextRun))")
                    }
                    if let lastRun = task.lastRun {
                        scheduleChip(icon: "checkmark", text: "上次 \(RelativeTimeFormatter.string(for: lastRun))")
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                scheduler.removeTask(id: task.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TextGrade.ghost)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("删除定时任务")
        }
        .padding(AppSpace.medium)
        .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(SurfaceGrade.card.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(SurfaceGrade.hairline.opacity(0.82), lineWidth: 0.6))
    }

    private func scheduleMetric(icon: String, value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: AppSpace.extraSmall) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(AppFont.micro)
            }
            .foregroundStyle(tint.opacity(0.82))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(TextGrade.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpace.small)
        .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(SurfaceGrade.card.opacity(0.66)))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(SurfaceGrade.hairline.opacity(0.72), lineWidth: 0.6))
    }

    private func scheduleChip(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .medium))
            Text(text)
                .font(AppFont.tiny)
                .lineLimit(1)
        }
        .foregroundStyle(TextGrade.ghost)
    }

    private var canCreate: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var intervalStep: Int {
        intervalMinutes < 10 ? 1 : (intervalMinutes < 60 ? 5 : 15)
    }

    private var workflowOptions: [String] {
        WorkflowLibrary.available(workspaceRoot: store.state.settings.workspacePath)
            .map(\.name)
            .sorted()
    }

    private var nextRunSummary: String {
        let next = scheduler.tasks.compactMap { $0.enabled ? $0.nextRun : nil }.min()
        guard let next else { return "-" }
        return RelativeTimeFormatter.string(for: next)
    }

    private func createTask() {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let runs = Int(maxRunsText.trimmingCharacters(in: .whitespacesAndNewlines))
        let task = ScheduledTask(
            name: trimmedName.isEmpty ? String(trimmedMessage.prefix(30)) : trimmedName,
            message: trimmedMessage,
            schedule: .interval(seconds: intervalMinutes * 60),
            workflowName: selectedWorkflowName.isEmpty ? nil : selectedWorkflowName,
            maxRuns: runs
        )
        scheduler.addTask(task)
        ToastCenter.shared.success("定时会话已创建")
        name = ""
        message = ""
        maxRunsText = ""
        selectedWorkflowName = ""
    }
}
