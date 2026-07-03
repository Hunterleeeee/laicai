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

        VStack(alignment: .leading, spacing: AppSpace.large) {
            workflowOverview(total: allWorkflows.count, visible: workflows.count, loadErrorCount: loadErrors.count)

            // Search
            if allWorkflows.count > 3 {
                workbenchSearchField(text: $searchText, placeholder: "搜索流程…")
            }

            // Workflows list
            if workflows.isEmpty {
                VStack(spacing: AppSpace.medium) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Brand.primary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Brand.primary.opacity(0.10)))
                    VStack(spacing: AppSpace.extraSmall) {
                        Text(searchText.isEmpty ? "暂无流程" : "无匹配结果")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.secondary)
                        Text(searchText.isEmpty ? "把常做的事保存成流程，下次直接运行" : "换个关键词试试")
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.muted)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpace.large)
                .background(RoundedRectangle(cornerRadius: AppRadius.large).fill(SurfaceGrade.card.opacity(0.62)))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.large).strokeBorder(SurfaceGrade.hairline.opacity(0.75), lineWidth: 0.6))
            } else {
                VStack(alignment: .leading, spacing: AppSpace.small) {
                    workbenchSectionHeader(title: searchText.isEmpty ? "可用流程" : "匹配结果", count: workflows.count)
                    ForEach(workflows) { workflow in
                        WorkflowRow(workflow: workflow) {
                            selectedWorkflow = workflow
                        }
                    }
                }
            }

            // Load errors
            if !loadErrors.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    HStack(spacing: AppSpace.extraSmall) {
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
                .padding(AppSpace.small)
                .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(Semantic.warningMuted.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(Semantic.warning.opacity(0.16), lineWidth: 0.6))
            }

            // Workflow chains
            if !chainRegistry.chains.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.small) {
                    workbenchSectionHeader(title: "流程链", count: chainRegistry.chains.count)
                    ForEach(chainRegistry.chains) { chain in
                        HStack(spacing: AppSpace.small) {
                            Image(systemName: "link")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Brand.purple)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Brand.purple.opacity(0.10)))
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
                        .padding(AppSpace.small)
                        .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(SurfaceGrade.card.opacity(0.66)))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(SurfaceGrade.hairline.opacity(0.75), lineWidth: 0.6))
                    }
                }
            }

            // Run history
            if !store.state.workflowRuns.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.small) {
                    workbenchSectionHeader(title: "最近运行", count: store.state.workflowRuns.count)
                    VStack(spacing: AppSpace.extraSmall) {
                        ForEach(store.state.workflowRuns.prefix(6)) { run in
                            WorkflowRunRow(run: run)
                        }
                    }
                    .padding(AppSpace.medium)
                    .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(SurfaceGrade.card.opacity(0.66)))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(SurfaceGrade.hairline.opacity(0.75), lineWidth: 0.6))
                }
            }
        }
        .sheet(item: $selectedWorkflow) { workflow in
            WorkflowLaunchSheet(workflow: workflow) {
                selectedWorkflow = nil
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showEditor) {
            WorkflowEditorView(isPresented: $showEditor)
                .environmentObject(store)
        }
    }

    private func workflowOverview(total: Int, visible: Int, loadErrorCount: Int) -> some View {
        VStack(alignment: .leading, spacing: AppSpace.medium) {
            HStack(alignment: .top, spacing: AppSpace.small) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.teal)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Brand.teal.opacity(0.10)))
                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    Text("流程")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                    Text(total == 0 ? "把重复目标沉成可复用流程。" : "\(visible)/\(total) 个可用 · 点击即可配置并启动")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                        .lineLimit(2)
                }
                Spacer()
            }

            HStack(spacing: AppSpace.extraSmall) {
                workflowMetric(icon: "rectangle.stack", value: "\(total)", label: "流程", tint: Brand.primary)
                workflowMetric(icon: "link", value: "\(chainRegistry.chains.count)", label: "流程链", tint: Brand.purple)
                workflowMetric(
                    icon: loadErrorCount > 0 ? "exclamationmark.triangle" : "checkmark.seal",
                    value: loadErrorCount > 0 ? "\(loadErrorCount)" : "OK",
                    label: "状态",
                    tint: loadErrorCount > 0 ? Semantic.warning : Semantic.success
                )
            }

            Button { showEditor = true } label: {
                Label("新建流程", systemImage: "plus")
                    .font(AppFont.captionMedium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpace.small)
                    .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(Brand.teal.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(Brand.teal.opacity(0.18), lineWidth: 0.6))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.teal)
        }
        .padding(AppSpace.large)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(LinearGradient(colors: [SurfaceGrade.card, SurfaceGrade.elevated.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(SurfaceGrade.hairline.opacity(0.9), lineWidth: 0.7)
        )
        .shadow(color: AppShadow.small.color, radius: AppShadow.small.radius, y: AppShadow.small.verticalOffset)
    }

    private func workflowMetric(icon: String, value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: AppSpace.extraSmall) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(AppFont.micro)
            }
            .foregroundStyle(tint.opacity(0.82))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(TextGrade.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpace.small)
        .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(SurfaceGrade.card.opacity(0.66)))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(SurfaceGrade.hairline.opacity(0.72), lineWidth: 0.6))
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
            HStack(spacing: AppSpace.small) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.small)
                        .fill(categoryColor.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: workflow.category.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(categoryColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: AppSpace.extraSmall) {
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

                HStack(spacing: AppSpace.extraSmall) {
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
        .padding(AppSpace.medium)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(isHovered ? SurfaceGrade.hover.opacity(0.92) : SurfaceGrade.card.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(isHovered ? categoryColor.opacity(0.24) : SurfaceGrade.hairline.opacity(0.72), lineWidth: 0.7)
        )
        .shadow(color: isHovered ? AppShadow.small.color : .clear, radius: AppShadow.small.radius, y: AppShadow.small.verticalOffset)
        .onHover { isHovered = $0 }
    }
}

private struct WorkflowRunRow: View {
    let run: WorkflowRun

    var body: some View {
        HStack(spacing: AppSpace.small) {
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
        .padding(.vertical, AppSpace.extraSmall)
    }
}

// MARK: - Skills Panel

struct SkillsPanel: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var registry = SkillRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.medium) {
            skillsOverview

            if registry.skills.isEmpty {
                workbenchEmptyState(icon: "sparkles", title: "暂无技能", hint: "把常用能力保存下来，之后一键调用")
            } else {
                workbenchSectionHeader(title: "可用技能", count: registry.skills.count)
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
        .onChange(of: store.state.settings.workspacePath) { _, newValue in
            registry.refresh(workspaceRoot: newValue)
        }
    }

    private var skillsOverview: some View {
        workbenchHeroCard(
            icon: "sparkles",
            title: "技能",
            subtitle: registry.skills.isEmpty ? "沉淀常用能力，之后直接调用。" : "\(registry.skills.count) 个可用 · 选择一个技能带入当前会话",
            tint: Brand.purple
        ) {
            HStack(spacing: AppSpace.extraSmall) {
                Button {
                    registry.refresh(workspaceRoot: store.state.settings.workspacePath)
                    ToastCenter.shared.success("已刷新技能")
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(AppFont.captionMedium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.purple)
                .padding(.vertical, AppSpace.small)
                .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(SurfaceGrade.card.opacity(0.62)))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(SurfaceGrade.hairline.opacity(0.8), lineWidth: 0.6))
                .help("刷新技能")

                Button {
                    createDraftSkill()
                } label: {
                    Label("新建", systemImage: "plus")
                        .font(AppFont.captionMedium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.purple)
                .padding(.vertical, AppSpace.small)
                .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(Brand.purple.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(Brand.purple.opacity(0.18), lineWidth: 0.6))
                .help("从当前输入创建技能草稿")
            }
        }
    }

    private func createDraftSkill() {
        let draft = store.state.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = draft.isEmpty ? "新技能 \(shortTimestamp())" : String(draft.prefix(18))
        let description = draft.isEmpty ? "本地技能草稿，可继续补充说明和可用动作。" : draft

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
        HStack(spacing: AppSpace.small) {
            Button(action: action) {
                HStack(spacing: AppSpace.small) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.small)
                            .fill(Semantic.warningMuted)
                            .frame(width: 28, height: 28)
                        Image(systemName: skill.modelPreference.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(Semantic.warning)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: AppSpace.extraSmall) {
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
        .padding(AppSpace.small)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .fill(isHovered ? SurfaceGrade.hover : SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(isHovered ? Brand.primary.opacity(0.15) : Color.clear, lineWidth: 0.6)
        )
        .onHover { isHovered = $0 }
    }
}
