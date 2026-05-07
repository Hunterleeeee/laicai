import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Workflows Panel

struct WorkflowsPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedWorkflow: WorkflowDefinition?
    @State private var showEditor = false
    @State private var searchText = ""
    @ObservedObject private var chainRegistry = WorkflowChainRegistry.shared

    var body: some View {
        let allWorkflows = WorkflowLibrary.available(workspaceRoot: store.state.settings.workspacePath)
        let workflows = searchText.isEmpty ? allWorkflows : allWorkflows.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
        let loadErrors = WorkflowLibrary.shared.lastLoadErrors

        VStack(alignment: .leading, spacing: AppSpace.md) {
            // Header
            HStack(spacing: AppSpace.sm) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.primary)
                Text("工作流")
                    .font(AppFont.subheadline)
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Button { showEditor = true } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)
                .help("创建自定义工作流")
            }

            // Search
            if allWorkflows.count > 3 {
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(TextGrade.ghost)
                    TextField("搜索工作流…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(AppFont.caption)
                }
                .padding(AppSpace.sm)
                .background(RoundedRectangle(cornerRadius: AppRadius.sm).fill(SurfaceGrade.card))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).strokeBorder(SurfaceGrade.hairline, lineWidth: 0.5))
            }

            // Workflows list
            if workflows.isEmpty {
                VStack(spacing: AppSpace.md) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Brand.primary.opacity(0.4))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Brand.primary.opacity(0.06)))
                    VStack(spacing: AppSpace.xs) {
                        Text(searchText.isEmpty ? "暂无工作流" : "无匹配结果")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.secondary)
                        Text(searchText.isEmpty ? "创建 YAML 工作流或点击 + 新建" : "尝试其他关键词")
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.muted)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpace.lg)
            } else {
                ForEach(workflows) { wf in
                    WorkflowRow(workflow: wf) {
                        selectedWorkflow = wf
                    }
                }
            }

            // Load errors
            if !loadErrors.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    HStack(spacing: AppSpace.xs) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                            .foregroundStyle(Semantic.warning)
                        Text("\(loadErrors.count) 个加载错误")
                            .font(AppFont.tiny)
                            .foregroundStyle(Semantic.warning)
                    }
                    ForEach(loadErrors, id: \.self) { error in
                        Text(error)
                            .font(AppFont.codeSmall)
                            .foregroundStyle(TextGrade.muted)
                            .lineLimit(2)
                    }
                }
                .padding(AppSpace.sm)
                .background(RoundedRectangle(cornerRadius: AppRadius.sm).fill(Semantic.warningMuted.opacity(0.5)))
            }

            // Workflow chains
            if !chainRegistry.chains.isEmpty {
                HStack {
                    Text("工作流链")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.secondary)
                    Spacer()
                    Text("\(chainRegistry.chains.count) 条")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                }
                ForEach(chainRegistry.chains) { chain in
                    HStack(spacing: AppSpace.sm) {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                            .foregroundStyle(Brand.purple)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chain.name)
                                .font(AppFont.captionMedium)
                                .foregroundStyle(TextGrade.primary)
                                .lineLimit(1)
                            Text(chain.workflowNames.joined(separator: " → "))
                                .font(AppFont.tiny)
                                .foregroundStyle(TextGrade.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            chainRegistry.removeChain(id: chain.id)
                            chainRegistry.save(workspaceRoot: store.state.settings.workspacePath)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(TextGrade.ghost)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(AppSpace.sm)
                    .background(RoundedRectangle(cornerRadius: AppRadius.sm).fill(SurfaceGrade.card.opacity(0.5)))
                }
            }

            // Run history
            if !store.state.workflowRuns.isEmpty {
                HStack {
                    Text("运行记录")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.secondary)
                    Spacer()
                    Text("\(store.state.workflowRuns.count) 次")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                }

                ForEach(store.state.workflowRuns) { run in
                    WorkflowRunRow(run: run)
                }
            }
        }
        .sheet(item: $selectedWorkflow) { wf in
            WorkflowLaunchSheet(workflow: wf) {
                selectedWorkflow = nil
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showEditor) {
            WorkflowEditorView(isPresented: $showEditor)
                .environmentObject(store)
        }
    }

}

private struct WorkflowRow: View {
    let workflow: WorkflowDefinition
    let action: () -> Void
    @State private var isHovered = false

    private var categoryColor: Color {
        Color(hex: workflow.category.tintHex)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpace.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.sm)
                        .fill(categoryColor.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: workflow.category.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(categoryColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: AppSpace.xs) {
                        Text(workflow.name)
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.primary)
                        if !workflow.inputParams.isEmpty {
                            Text("\(workflow.inputParams.count) 参数")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(TextGrade.ghost)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(SurfaceGrade.base.opacity(0.5)))
                        }
                    }
                    Text(workflow.description)
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.muted)
                        .lineLimit(2)
                }

                Spacer()

                HStack(spacing: AppSpace.xs) {
                    Text("\(workflow.steps.count) 步")
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isHovered ? categoryColor : TextGrade.ghost)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(isHovered ? SurfaceGrade.hover : SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(isHovered ? categoryColor.opacity(0.2) : Color.clear, lineWidth: 0.6)
        )
        .onHover { isHovered = $0 }
    }
}

private struct WorkflowRunRow: View {
    let run: WorkflowRun

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.name)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                Text(run.statusLine)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(1)
            }

            Spacer()

            Text(RelativeTimeFormatter.string(for: run.updatedAt))
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.ghost)
        }
        .padding(.vertical, AppSpace.xs)
    }
}

// MARK: - Skills Panel

struct SkillsPanel: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var registry = SkillRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack {
                Text("技能")
                    .font(AppFont.subheadline)
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Button {
                    registry.refresh(workspaceRoot: store.state.settings.workspacePath)
                    ToastCenter.shared.success("已刷新技能")
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("刷新本地技能（读取 .laicai/skills 和 skills/*/skill.json）")

                Button {
                    createDraftSkill()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("从当前输入创建技能草稿")

                Text("\(registry.skills.count) 个")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
            }

            if registry.skills.isEmpty {
                VStack(spacing: AppSpace.sm) {
                    Image(systemName: "star")
                        .font(.system(size: 24, weight: .ultraLight))
                        .foregroundStyle(TextGrade.ghost)
                    Text("暂无技能")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpace.xl)
            } else {
                Text("来源：内置技能、.laicai/skills/*.json、skills/*/skill.json")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                ForEach(registry.skills) { skill in
                    SkillRow(skill: skill) {
                        store.useSkill(skill)
                    }
                }
            }
        }
        .onAppear {
            registry.refresh(workspaceRoot: store.state.settings.workspacePath)
        }
        .onChange(of: store.state.settings.workspacePath) { newValue in
            registry.refresh(workspaceRoot: newValue)
        }
    }

    private func createDraftSkill() {
        let draft = store.state.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = draft.isEmpty ? "新技能 \(shortTimestamp())" : String(draft.prefix(18))
        let description = draft.isEmpty ? "本地技能草稿，可在 .laicai/skills 中继续编辑。" : draft

        do {
            _ = try registry.createDraft(
                name: name,
                description: description,
                tools: ["code.search", "file.read"],
                workspaceRoot: store.state.settings.workspacePath
            )
            ToastCenter.shared.success("已创建技能草稿")
        } catch {
            ToastCenter.shared.error(error.localizedDescription)
        }
    }

    private func shortTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: Date())
    }
}

private struct SkillRow: View {
    let skill: SkillDefinition
    let action: () -> Void
    @EnvironmentObject private var store: AppStore
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            Button(action: action) {
                HStack(spacing: AppSpace.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.sm)
                            .fill(Semantic.warningMuted)
                            .frame(width: 28, height: 28)
                        Image(systemName: skill.modelPreference.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(Semantic.warning)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: AppSpace.xs) {
                            Text(skill.name)
                                .font(AppFont.captionMedium)
                                .foregroundStyle(TextGrade.primary)
                            if skill.isPublished {
                                Text("已发布")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(Semantic.success)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Semantic.success.opacity(0.10)))
                            }
                        }
                        Text(skill.description)
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.muted)
                            .lineLimit(2)
                    }

                    Spacer()

                    Image(systemName: skill.workflowName == nil ? "plus" : "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isHovered ? Brand.primary : TextGrade.ghost)
                }
            }
            .buttonStyle(.plain)

            if !skill.isBuiltin && !skill.isPublished {
                Button {
                    let didPublish = SkillRegistry.shared.publish(skillID: skill.id, workspaceRoot: store.state.settings.workspacePath)
                    if didPublish {
                        ToastCenter.shared.success("已发布「\(skill.name)」")
                    }
                } label: {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(TextGrade.muted)
                }
                .buttonStyle(.plain)
                .help("发布技能")
            }
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(isHovered ? SurfaceGrade.hover : SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(isHovered ? Brand.primary.opacity(0.15) : Color.clear, lineWidth: 0.6)
        )
        .onHover { isHovered = $0 }
    }
}
