import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

private struct WorkflowNodeTypeOption {
    let type: NodeToolType
    let icon: String
    let label: String
}

// MARK: - Workflow Editor

struct WorkflowEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var category: WorkflowCategory = .custom
    @State private var steps: [EditableStep] = []
    @State private var inputParams: [WorkflowParam] = []
    @State private var selectedStepID: UUID?
    @State private var showAddNode = false
    @State private var showAddParam = false
    @State private var draggedStep: EditableStep?
    @State private var hoveredStepID: UUID?

    /// If editing an existing workflow
    var existingWorkflow: WorkflowDefinition?

    var body: some View {
        HStack(spacing: 0) {
            // Left: node canvas
            nodeCanvas
                .frame(minWidth: 380)

            // Divider
            Rectangle()
                .fill(SurfaceGrade.divider)
                .frame(width: 1)

            // Right: node inspector
            nodeInspector
                .frame(width: 320)
        }
        .frame(minWidth: 740, minHeight: 540)
        .background(SurfaceGrade.base)
        .onAppear { loadExisting() }
    }

    // MARK: - Node Canvas

    private var nodeCanvas: some View {
        VStack(spacing: 0) {
            canvasToolbar
            Rectangle().fill(SurfaceGrade.divider).frame(height: 1)

            ScrollView {
                VStack(spacing: 0) {
                    startNode
                        .padding(.horizontal, AppSpace.extraLarge)
                        .padding(.top, AppSpace.extraLarge)

                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        flowConnector(index: index)
                        stepNode(step, index: index)
                            .padding(.horizontal, AppSpace.extraLarge)
                            .onDrag {
                                draggedStep = step
                                return NSItemProvider(object: step.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: StepDropDelegate(
                                    targetStep: step,
                                    steps: $steps,
                                    draggedStep: $draggedStep
                                ))
                    }

                    flowConnector(index: steps.count)
                    addNodeButton
                        .padding(.horizontal, AppSpace.extraLarge)
                        .padding(.bottom, AppSpace.xxxl)
                }
            }
        }
    }

    private var canvasToolbar: some View {
        HStack(spacing: AppSpace.medium) {
            // Editable name + description
            VStack(alignment: .leading, spacing: 2) {
                TextField("工作流名称", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TextGrade.primary)
                TextField("描述（可选）", text: $description)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(TextGrade.muted)
            }

            Spacer()

            // Category pill
            Menu {
                ForEach([WorkflowCategory.review, .generate, .debug, .refactor, .transform, .product, .project, .custom], id: \.self) {
                    cat in
                    Button {
                        category = cat
                    } label: {
                        Label(cat.rawValue, systemImage: cat.icon)
                    }
                }
            } label: {
                HStack(spacing: AppSpace.extraSmall) {
                    Image(systemName: category.icon)
                        .font(.system(size: 9, weight: .semibold))
                    Text(category.rawValue)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Color(hex: category.tintHex))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color(hex: category.tintHex).opacity(0.1))
                )
                .overlay(Capsule().strokeBorder(Color(hex: category.tintHex).opacity(0.2), lineWidth: 0.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            // Cancel
            Button {
                isPresented = false
            } label: {
                Text("取消")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TextGrade.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .fill(SurfaceGrade.elevated.opacity(0.5))
                    )
            }
            .buttonStyle(.plain)

            // Save
            Button {
                saveWorkflow()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("保存")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(
                            canSave
                                ? Brand.premiumGradient
                                : LinearGradient(colors: [SurfaceGrade.elevated], startPoint: .leading, endPoint: .trailing))
                )
                .shadow(color: canSave ? Brand.primary.opacity(0.3) : .clear, radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
        .padding(.horizontal, AppSpace.large)
        .padding(.vertical, 10)
    }

    // MARK: - Nodes

    private var startNode: some View {
        HStack(spacing: AppSpace.medium) {
            // Animated start icon
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Semantic.success.opacity(0.2), Semantic.success.opacity(0.05)], center: .center, startRadius: 0,
                            endRadius: 20)
                    )
                    .frame(width: 40, height: 40)
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Semantic.success)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("开始")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)
                if !inputParams.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.and.pencil.and.ellipsis")
                            .font(.system(size: 8))
                        Text("\(inputParams.count) 个输入参数")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(TextGrade.muted)
                } else {
                    Text("工作流入口")
                        .font(.system(size: 10))
                        .foregroundStyle(TextGrade.ghost)
                }
            }
            Spacer()
            Button {
                showAddParam = true
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(TextGrade.muted)
            }
            .buttonStyle(.plain)
            .help("添加输入参数")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Semantic.success.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: Semantic.success.opacity(0.08), radius: 12, y: 4)
        .sheet(isPresented: $showAddParam) {
            ParamEditorSheet(params: $inputParams)
        }
    }

    private func stepNode(_ step: EditableStep, index: Int) -> some View {
        let isSelected = selectedStepID == step.id
        let isHovered = hoveredStepID == step.id
        let color = nodeColor(for: step.toolType)

        return HStack(spacing: AppSpace.medium) {
            // Type icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.2), color.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                Image(systemName: nodeIcon(for: step.toolType))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(step.name.isEmpty ? "步骤 \(index + 1)" : step.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                    // Step number badge
                    Text("#\(index + 1)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(TextGrade.ghost)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.5)))
                }
                HStack(spacing: 6) {
                    // Type label
                    Text(nodeTypeName(for: step.toolType))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color)
                    if !step.tool.isEmpty && step.toolType == .tool {
                        Text(step.tool)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(TextGrade.muted)
                    } else if step.tool.isEmpty && (step.toolType == .tool || step.toolType == .http) {
                        Text("未配置")
                            .font(.system(size: 9))
                            .foregroundStyle(TextGrade.ghost)
                    }
                    if let fail = step.onFailure, !fail.isEmpty {
                        Text(fail)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Semantic.warning)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Semantic.warning.opacity(0.12)))
                    }
                }
            }

            Spacer()

            // Delete
            Button {
                withAnimation(AppAnimation.spring) {
                    steps.removeAll { $0.id == step.id }
                    if selectedStepID == step.id { selectedStepID = nil }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(TextGrade.ghost)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(SurfaceGrade.elevated.opacity(isHovered ? 0.8 : 0)))
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(isSelected ? color.opacity(0.06) : SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(
                    isSelected ? color.opacity(0.4) : (isHovered ? SurfaceGrade.border.opacity(0.4) : SurfaceGrade.border.opacity(0.12)),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .shadow(color: isSelected ? color.opacity(0.1) : .clear, radius: 12, y: 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(AppAnimation.quick) { selectedStepID = step.id }
        }
        .onHover { hoveredStepID = $0 ? step.id : nil }
    }

    private func flowConnector(index: Int) -> some View {
        let prevIsCondition = index > 0 && index <= steps.count && steps[index - 1].toolType == .condition
        let branchLabel = prevIsCondition ? (steps[index - 1].condition.flatMap { $0.isEmpty ? nil : $0 } ?? "true") : nil

        return VStack(spacing: 0) {
            // Vertical line with dot
            Circle()
                .fill(prevIsCondition ? Color(hex: "F59E0B").opacity(0.6) : SurfaceGrade.border.opacity(0.4))
                .frame(width: prevIsCondition ? 6 : 4, height: prevIsCondition ? 6 : 4)
            if let label = branchLabel {
                Text(label)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: "F59E0B"))
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Color(hex: "F59E0B").opacity(0.1)))
            }
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            (prevIsCondition ? Color(hex: "F59E0B") : SurfaceGrade.border).opacity(0.3),
                            SurfaceGrade.border.opacity(0.15),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 1.5, height: prevIsCondition ? 18 : 24)
            // Arrow
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(prevIsCondition ? Color(hex: "F59E0B").opacity(0.5) : SurfaceGrade.border.opacity(0.4))
        }
        .frame(height: 40)
    }

    private var addNodeButton: some View {
        Menu {
            Button {
                addStep(toolType: .tool)
            } label: {
                Label("工具节点", systemImage: "wrench")
            }
            Button {
                addStep(toolType: .llm)
            } label: {
                Label("LLM 节点", systemImage: "brain")
            }
            Button {
                addStep(toolType: .code)
            } label: {
                Label("代码节点", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Divider()
            Button {
                addStep(toolType: .condition)
            } label: {
                Label("条件分支", systemImage: "arrow.branch")
            }
            Button {
                addStep(toolType: .humanInput)
            } label: {
                Label("人工确认", systemImage: "person.crop.circle.badge.checkmark")
            }
            Button {
                addStep(toolType: .http)
            } label: {
                Label("HTTP 请求", systemImage: "globe")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                Text("添加节点")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Brand.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                    .fill(Brand.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                    .strokeBorder(Brand.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Node Inspector

    private var nodeInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: AppSpace.small) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.primary)
                Text("节点配置")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)
                Spacer()
            }
            .padding(.horizontal, AppSpace.large)
            .padding(.vertical, 12)

            Rectangle().fill(SurfaceGrade.divider).frame(height: 1)

            if let stepID = selectedStepID, let index = steps.firstIndex(where: { $0.id == stepID }) {
                ScrollView {
                    stepInspectorContent(index: index)
                        .padding(AppSpace.large)
                }
            } else {
                VStack(spacing: AppSpace.large) {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(SurfaceGrade.card)
                            .frame(width: 56, height: 56)
                        Image(systemName: "cursorarrow.click.2")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(TextGrade.ghost)
                    }
                    VStack(spacing: 4) {
                        Text("选择节点")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TextGrade.secondary)
                        Text("点击左侧节点查看和编辑配置")
                            .font(.system(size: 11))
                            .foregroundStyle(TextGrade.ghost)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(SurfaceGrade.panel)
    }

    private func stepInspectorContent(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Selected node header
            let color = nodeColor(for: steps[index].toolType)
            HStack(spacing: AppSpace.small) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(color.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: nodeIcon(for: steps[index].toolType))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text("步骤 \(index + 1)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Text(nodeTypeName(for: steps[index].toolType))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.1)))
            }

            // Name
            inspectorField("名称") {
                TextField("步骤名称", text: $steps[index].name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }

            // Tool type — custom button grid instead of segmented
            inspectorField("类型") {
                nodeTypePicker(
                    selection: Binding(
                        get: { steps[index].toolType },
                        set: { newType in
                            steps[index].toolType = newType
                            switch newType {
                            case .llm: steps[index].tool = "llm"
                            case .humanInput: steps[index].tool = "human_input"
                            case .condition: steps[index].tool = "condition"
                            case .tool, .http, .code:
                                if ["llm", "human_input", "condition"].contains(steps[index].tool) {
                                    steps[index].tool = ""
                                }
                            }
                        }
                    )
                )
            }

            // Tool name
            if steps[index].toolType == .tool || steps[index].toolType == .http {
                inspectorField("工具名") {
                    TextField("例如：file.read, git, code.search", text: $steps[index].tool)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            // Prompt
            if steps[index].toolType == .llm {
                inspectorField("提示词") {
                    TextEditor(
                        text: Binding(
                            get: { steps[index].prompt ?? "" },
                            set: { steps[index].prompt = $0 }
                        )
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .fill(SurfaceGrade.base)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .strokeBorder(SurfaceGrade.border.opacity(0.2), lineWidth: 0.5)
                    )
                }
                Text("变量：{{results}}, {{previous.output}}, {{workspace}}, {{key}}")
                    .font(.system(size: 9))
                    .foregroundStyle(TextGrade.ghost)
                    .padding(.top, -8)
            }

            // Condition
            if steps[index].toolType == .condition {
                inspectorField("条件表达式") {
                    TextField(
                        "previous.success / previous.failure",
                        text: Binding(
                            get: { steps[index].condition ?? "" },
                            set: { steps[index].condition = $0 }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                }
            }

            // Parameters
            if steps[index].toolType == .tool || steps[index].toolType == .http {
                inspectorField("参数") {
                    paramKeyValueEditor(stepIndex: index)
                }
            }

            // On failure — custom button row
            inspectorField("失败策略") {
                failurePolicyPicker(
                    selection: Binding(
                        get: { steps[index].onFailure ?? "continue" },
                        set: { steps[index].onFailure = $0 == "continue" ? nil : $0 }
                    ))
            }
        }
    }

    // MARK: - Custom Pickers

    private func nodeTypePicker(selection: Binding<NodeToolType>) -> some View {
        let types: [WorkflowNodeTypeOption] = [
            WorkflowNodeTypeOption(type: .tool, icon: "wrench", label: "工具"),
            WorkflowNodeTypeOption(type: .llm, icon: "brain", label: "LLM"),
            WorkflowNodeTypeOption(type: .code, icon: "chevron.left.forwardslash.chevron.right", label: "代码"),
            WorkflowNodeTypeOption(type: .condition, icon: "arrow.branch", label: "条件"),
            WorkflowNodeTypeOption(type: .humanInput, icon: "person.crop.circle.badge.checkmark", label: "确认"),
            WorkflowNodeTypeOption(type: .http, icon: "globe", label: "HTTP"),
        ]

        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 6),
                GridItem(.flexible(), spacing: 6),
                GridItem(.flexible(), spacing: 6),
            ], spacing: 6
        ) {
            ForEach(types, id: \.type) { option in
                let isActive = selection.wrappedValue == option.type
                let color = nodeColor(for: option.type)
                Button {
                    withAnimation(AppAnimation.quick) { selection.wrappedValue = option.type }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: option.icon)
                            .font(.system(size: 11, weight: .medium))
                        Text(option.label)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(isActive ? color : TextGrade.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .fill(isActive ? color.opacity(0.1) : SurfaceGrade.base)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .strokeBorder(isActive ? color.opacity(0.3) : SurfaceGrade.border.opacity(0.15), lineWidth: isActive ? 1 : 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func failurePolicyPicker(selection: Binding<String>) -> some View {
        let policies = [
            ("continue", "arrow.right", "继续"),
            ("abort", "xmark.circle", "中止"),
            ("skip", "forward", "跳过"),
            ("retry", "arrow.counterclockwise", "重试"),
        ]

        return HStack(spacing: 6) {
            ForEach(policies, id: \.0) { value, icon, label in
                let isActive = selection.wrappedValue == value
                Button {
                    withAnimation(AppAnimation.quick) { selection.wrappedValue = value }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: icon)
                            .font(.system(size: 9, weight: .medium))
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(isActive ? Brand.primary : TextGrade.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .fill(isActive ? Brand.primary.opacity(0.1) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .strokeBorder(isActive ? Brand.primary.opacity(0.25) : Color.clear, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(SurfaceGrade.base)
        )
    }

    private func inspectorField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TextGrade.ghost)
                .textCase(.uppercase)
            content()
                .padding(AppSpace.small)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(SurfaceGrade.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .strokeBorder(SurfaceGrade.border.opacity(0.15), lineWidth: 0.5)
                )
        }
    }

    private func paramKeyValueEditor(stepIndex: Int) -> some View {
        VStack(spacing: AppSpace.extraSmall) {
            ForEach(Array(steps[stepIndex].paramPairs.enumerated()), id: \.offset) { pairIndex, _ in
                HStack(spacing: AppSpace.extraSmall) {
                    TextField(
                        "key",
                        text: Binding(
                            get: { steps[stepIndex].paramPairs[pairIndex].key },
                            set: { steps[stepIndex].paramPairs[pairIndex].key = $0 }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 80)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(TextGrade.ghost)

                    TextField(
                        "value",
                        text: Binding(
                            get: { steps[stepIndex].paramPairs[pairIndex].value },
                            set: { steps[stepIndex].paramPairs[pairIndex].value = $0 }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))

                    Button {
                        steps[stepIndex].paramPairs.remove(at: pairIndex)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(TextGrade.ghost)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(SurfaceGrade.elevated.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }

            Button {
                steps[stepIndex].paramPairs.append(ParamPair(key: "", value: ""))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                    Text("添加参数")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Brand.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(Brand.primary.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func nodeTypeName(for type: NodeToolType) -> String {
        switch type {
        case .tool: return "工具"
        case .llm: return "LLM"
        case .code: return "代码"
        case .condition: return "条件"
        case .humanInput: return "确认"
        case .http: return "HTTP"
        }
    }

    private func addStep(toolType: NodeToolType) {
        let step = EditableStep(
            name: "",
            tool: toolType == .llm ? "llm" : (toolType == .humanInput ? "human_input" : ""),
            toolType: toolType
        )
        withAnimation(AppAnimation.quick) {
            steps.append(step)
            selectedStepID = step.id
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !steps.isEmpty
    }

    private func loadExisting() {
        guard let workflow = existingWorkflow else { return }
        name = workflow.name
        description = workflow.description
        category = workflow.category
        inputParams = workflow.inputParams
        steps = workflow.steps.map { step in
            var editable = EditableStep(
                name: step.name,
                tool: step.tool,
                toolType: inferToolType(step.tool),
                prompt: step.prompt,
                condition: step.condition,
                onFailure: step.onFailure
            )
            editable.paramPairs = step.params.map { ParamPair(key: $0.key, value: $0.value) }
            return editable
        }
    }

    private func saveWorkflow() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !steps.isEmpty else { return }

        let wfSteps = steps.map { step -> WorkflowStep in
            var params: [String: String] = [:]
            for pair in step.paramPairs where !pair.key.trimmingCharacters(in: .whitespaces).isEmpty {
                params[pair.key.trimmingCharacters(in: .whitespaces)] = pair.value
            }
            return WorkflowStep(
                name: step.name.isEmpty ? step.tool : step.name,
                tool: step.tool,
                params: params,
                condition: step.condition,
                onFailure: step.onFailure,
                prompt: step.prompt
            )
        }

        let definition = WorkflowDefinition(
            name: trimmedName,
            description: description,
            steps: wfSteps,
            isBuiltin: false,
            category: category,
            inputParams: inputParams
        )

        // Save as YAML to .laicai/workflows/
        let yaml = exportYAML(definition)
        let root = store.state.settings.workspacePath
        let dir = (root as NSString).appendingPathComponent(".laicai/workflows")
        let safeName = trimmedName.replacingOccurrences(of: " ", with: "-").lowercased()
        let path = (dir as NSString).appendingPathComponent("\(safeName).yaml")

        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try yaml.write(toFile: path, atomically: true, encoding: .utf8)
            ToastCenter.shared.success("已保存到 .laicai/workflows/\(safeName).yaml")
            isPresented = false
        } catch {
            ToastCenter.shared.error("保存失败：\(error.localizedDescription)")
        }
    }

    private func exportYAML(_ workflow: WorkflowDefinition) -> String {
        var lines: [String] = []
        lines.append("name: \(workflow.name)")
        if !workflow.description.isEmpty {
            lines.append("description: \(workflow.description)")
        }
        lines.append("category: \(workflow.category.rawValue)")
        lines.append("")

        for step in workflow.steps {
            lines.append("- step: \(step.name)")
            lines.append("  tool: \(step.tool)")
            if let condition = step.condition {
                lines.append("  condition: \(condition)")
            }
            if let onFailure = step.onFailure {
                lines.append("  on_failure: \(onFailure)")
            }
            if !step.params.isEmpty {
                lines.append("  params:")
                for (key, value) in step.params.sorted(by: { $0.key < $1.key }) {
                    lines.append("    \(key): \(value)")
                }
            }
            if let prompt = step.prompt, !prompt.isEmpty {
                lines.append("  prompt: |")
                for line in prompt.components(separatedBy: "\n") {
                    lines.append("    \(line)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func nodeColor(for type: NodeToolType) -> Color {
        switch type {
        case .tool: return Brand.primary
        case .llm: return Color(hex: "8B5CF6")
        case .code: return Color(hex: "10B981")
        case .condition: return Color(hex: "F59E0B")
        case .humanInput: return Color(hex: "3B82F6")
        case .http: return Color(hex: "06B6D4")
        }
    }

    private func nodeIcon(for type: NodeToolType) -> String {
        switch type {
        case .tool: return "wrench"
        case .llm: return "brain"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .condition: return "arrow.branch"
        case .humanInput: return "person.crop.circle.badge.checkmark"
        case .http: return "globe"
        }
    }

    private func inferToolType(_ tool: String) -> NodeToolType {
        switch tool {
        case "llm": return .llm
        case "human_input": return .humanInput
        case "condition": return .condition
        default:
            if tool.hasPrefix("http") { return .http }
            return .tool
        }
    }
}

// MARK: - Data Models

enum NodeToolType: String, Codable, Hashable {
    case tool
    case llm
    case code
    case condition
    case humanInput
    case http
}

struct EditableStep: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var tool: String
    var toolType: NodeToolType
    var prompt: String?
    var condition: String?
    var onFailure: String?
    var paramPairs: [ParamPair] = []

    static func == (lhs: EditableStep, rhs: EditableStep) -> Bool {
        lhs.id == rhs.id
    }
}

struct ParamPair: Equatable {
    var key: String
    var value: String
}

struct NodeEdge: Identifiable, Equatable {
    let id = UUID()
    var fromStepID: UUID
    var toStepID: UUID
    var label: String  // "success", "failure", "always"
}

struct DAGLayoutPosition {
    let id: UUID
    let col: Int
    let row: Int
}

// MARK: - DAG Layout Helpers

enum DAGLayout {
    /// Compute column assignments for steps based on condition branches.
    /// Returns (stepID → column, stepID → row) for 2D positioning.
    static func layout(steps: [EditableStep], edges: [NodeEdge]) -> [DAGLayoutPosition] {
        guard !steps.isEmpty else { return [] }
        var result: [DAGLayoutPosition] = []
        var row = 0
        var index = 0
        while index < steps.count {
            let step = steps[index]
            if step.toolType == .condition {
                // Condition node at center
                result.append(DAGLayoutPosition(id: step.id, col: 1, row: row))
                row += 1
                // Next two steps are branches (success / failure) if available
                let branchCount = min(2, steps.count - index - 1)
                for branchIndex in 0..<branchCount {
                    result.append(
                        DAGLayoutPosition(
                            id: steps[index + 1 + branchIndex].id,
                            col: branchIndex * 2,
                            row: row
                        ))
                }
                index += 1 + branchCount
                row += 1
            } else {
                result.append(DAGLayoutPosition(id: step.id, col: 1, row: row))
                index += 1
                row += 1
            }
        }
        return result
    }
}

// MARK: - Drag & Drop

struct StepDropDelegate: DropDelegate {
    let targetStep: EditableStep
    @Binding var steps: [EditableStep]
    @Binding var draggedStep: EditableStep?

    func performDrop(info: DropInfo) -> Bool {
        draggedStep = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedStep,
            dragged.id != targetStep.id,
            let fromIndex = steps.firstIndex(where: { $0.id == dragged.id }),
            let toIndex = steps.firstIndex(where: { $0.id == targetStep.id })
        else { return }
        withAnimation(AppAnimation.quick) {
            steps.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }
}

// MARK: - Param Editor Sheet

struct ParamEditorSheet: View {
    @Binding var params: [WorkflowParam]
    @Environment(\.dismiss) private var dismiss
    @State private var newKey = ""
    @State private var newLabel = ""
    @State private var newKind: WorkflowParam.ParamKind = .text
    @State private var newRequired = true

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.medium) {
            Text("输入参数")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(TextGrade.primary)

            // Existing params
            ForEach(Array(params.enumerated()), id: \.element.id) { index, param in
                HStack(spacing: AppSpace.small) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(param.label)
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.primary)
                        Text("\(param.key) · \(param.kind.rawValue)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(TextGrade.ghost)
                    }
                    Spacer()
                    if param.required {
                        Text("必填")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Semantic.error)
                    }
                    Button {
                        params.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(TextGrade.ghost)
                    }
                    .buttonStyle(.plain)
                }
                .padding(AppSpace.small)
                .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(SurfaceGrade.card))
            }

            Divider().opacity(0.2)

            // Add new param
            HStack(spacing: AppSpace.small) {
                TextField("变量名", text: $newKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 80)
                TextField("显示名称", text: $newLabel)
                    .textFieldStyle(.plain)
                    .font(AppFont.caption)
                Picker("", selection: $newKind) {
                    Text("文本").tag(WorkflowParam.ParamKind.text)
                    Text("文件").tag(WorkflowParam.ParamKind.filePath)
                    Text("文件夹").tag(WorkflowParam.ParamKind.directoryPath)
                    Text("选项").tag(WorkflowParam.ParamKind.choice)
                }
                .pickerStyle(.menu)
                .frame(width: 60)
                Toggle("必填", isOn: $newRequired)
                    .toggleStyle(.checkbox)
                    .font(AppFont.tiny)
            }
            .padding(AppSpace.small)
            .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(SurfaceGrade.base))

            HStack {
                Spacer()
                Button {
                    guard !newKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    params.append(
                        WorkflowParam(
                            key: newKey.trimmingCharacters(in: .whitespaces),
                            label: newLabel.isEmpty ? newKey : newLabel,
                            kind: newKind,
                            required: newRequired
                        ))
                    newKey = ""
                    newLabel = ""
                } label: {
                    HStack(spacing: AppSpace.extraSmall) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("添加")
                            .font(AppFont.captionMedium)
                    }
                    .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                } label: {
                    Text("完成")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppSpace.medium)
                        .padding(.vertical, AppSpace.extraSmall)
                        .background(Capsule().fill(Brand.premiumGradient))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppSpace.large)
        .frame(width: 420)
        .frame(minHeight: 300)
        .background(SurfaceGrade.panel)
    }
}
