import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

// MARK: - Workflow Launch Sheet

struct WorkflowLaunchSheet: View {
    @EnvironmentObject private var store: AppStore
    let workflow: WorkflowDefinition
    let onDismiss: () -> Void

    @State private var paramValues: [String: String] = [:]
    @State private var goalText: String = ""
    @State private var showSteps = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.horizontal, AppSpace.large)
                .padding(.top, AppSpace.large)
                .padding(.bottom, AppSpace.medium)

            Divider().opacity(0.2)

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpace.large) {
                    // Step preview
                    stepPreview

                    // Input params (if any)
                    if !workflow.inputParams.isEmpty {
                        paramInputs
                    }

                    // Goal / note
                    goalInput
                }
                .padding(AppSpace.large)
            }

            Divider().opacity(0.2)

            // Footer actions
            footer
                .padding(AppSpace.large)
        }
        .frame(width: 480)
        .frame(minHeight: 400, maxHeight: 600)
        .background(SurfaceGrade.panel)
        .onAppear {
            // Pre-fill defaults
            for param in workflow.inputParams {
                if !param.defaultValue.isEmpty && param.kind != .choice {
                    paramValues[param.key] = param.defaultValue
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AppSpace.medium) {
            // Category icon
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(categoryColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: workflow.category.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(categoryColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TextGrade.primary)
                Text(workflow.description)
                    .font(AppFont.caption)
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(TextGrade.muted)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(SurfaceGrade.hover))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Step Preview

    private var stepPreview: some View {
        VStack(alignment: .leading, spacing: AppSpace.small) {
            Button {
                withAnimation(AppAnimation.quick) { showSteps.toggle() }
            } label: {
                HStack(spacing: AppSpace.extraSmall) {
                    Image(systemName: showSteps ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("执行步骤")
                        .font(AppFont.captionMedium)
                    Text("\(workflow.steps.count) 步")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                    Spacer()
                }
                .foregroundStyle(TextGrade.secondary)
            }
            .buttonStyle(.plain)

            if showSteps {
                VStack(spacing: 0) {
                    ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(spacing: AppSpace.small) {
                            // Step number
                            ZStack {
                                Circle()
                                    .fill(step.tool == "llm" ? Brand.primary.opacity(0.15) : SurfaceGrade.card)
                                    .frame(width: 24, height: 24)
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(step.tool == "llm" ? Brand.primary : TextGrade.muted)
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.name)
                                    .font(AppFont.captionMedium)
                                    .foregroundStyle(TextGrade.primary)
                                HStack(spacing: AppSpace.extraSmall) {
                                    Text(step.tool)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(TextGrade.ghost)
                                    if let onFail = step.onFailure {
                                        Text("失败：\(onFail)")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Semantic.warning.opacity(0.8))
                                    }
                                    if step.condition != nil {
                                        Image(systemName: "arrow.branch")
                                            .font(.system(size: 8))
                                            .foregroundStyle(TextGrade.ghost)
                                    }
                                }
                            }

                            Spacer()
                        }
                        .padding(.vertical, AppSpace.extraSmall + 1)

                        if index < workflow.steps.count - 1 {
                            // Connector line
                            HStack {
                                Rectangle()
                                    .fill(SurfaceGrade.border.opacity(0.3))
                                    .frame(width: 1, height: 8)
                                    .padding(.leading, 11.5)
                                Spacer()
                            }
                        }
                    }
                }
                .padding(AppSpace.small)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(SurfaceGrade.base.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .strokeBorder(SurfaceGrade.border.opacity(0.2), lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Parameter Inputs

    private var paramInputs: some View {
        VStack(alignment: .leading, spacing: AppSpace.medium) {
            Text("参数配置")
                .font(AppFont.captionMedium)
                .foregroundStyle(TextGrade.secondary)

            ForEach(workflow.inputParams) { param in
                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    HStack(spacing: AppSpace.extraSmall) {
                        Text(param.label)
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.primary)
                        if param.required {
                            Text("*")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Semantic.error)
                        }
                        if !param.required {
                            Text("可选")
                                .font(AppFont.tiny)
                                .foregroundStyle(TextGrade.ghost)
                        }
                    }

                    switch param.kind {
                    case .text:
                        TextField(param.placeholder, text: bindingFor(param))
                            .textFieldStyle(.plain)
                            .font(AppFont.body)
                            .padding(AppSpace.small)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                    .fill(SurfaceGrade.base)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                    .strokeBorder(SurfaceGrade.border.opacity(0.3), lineWidth: 0.5)
                            )

                    case .filePath:
                        filePathPicker(param: param)

                    case .directoryPath:
                        directoryPathPicker(param: param)

                    case .choice:
                        choicePicker(param: param)
                    }
                }
            }
        }
    }

    private func filePathPicker(param: WorkflowParam) -> some View {
        HStack(spacing: AppSpace.small) {
            let value = paramValues[param.key] ?? ""
            if value.isEmpty {
                Text(param.placeholder)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.ghost)
            } else {
                HStack(spacing: AppSpace.extraSmall) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.primary)
                    Text(URL(fileURLWithPath: value).lastPathComponent)
                        .font(AppFont.body)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.title = param.label
                panel.prompt = "选择"
                if !store.state.settings.workspacePath.isEmpty {
                    panel.directoryURL = URL(fileURLWithPath: store.state.settings.workspacePath)
                }
                if panel.runModal() == .OK, let url = panel.url {
                    paramValues[param.key] = url.path
                }
            } label: {
                Text("选择文件")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(Brand.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpace.small)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(SurfaceGrade.base)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(SurfaceGrade.border.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func directoryPathPicker(param: WorkflowParam) -> some View {
        HStack(spacing: AppSpace.small) {
            let value = paramValues[param.key] ?? ""
            if value.isEmpty {
                Text(param.placeholder)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.ghost)
            } else {
                HStack(spacing: AppSpace.extraSmall) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.primary)
                    Text(URL(fileURLWithPath: value).lastPathComponent)
                        .font(AppFont.body)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.title = param.label
                panel.prompt = "选择"
                if panel.runModal() == .OK, let url = panel.url {
                    paramValues[param.key] = url.path
                }
            } label: {
                Text("选择文件夹")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(Brand.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpace.small)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(SurfaceGrade.base)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(SurfaceGrade.border.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func choicePicker(param: WorkflowParam) -> some View {
        let options = param.defaultValue.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return Menu {
            ForEach(options, id: \.self) { option in
                Button(option) {
                    paramValues[param.key] = option
                }
            }
        } label: {
            HStack {
                Text(paramValues[param.key] ?? (options.first ?? param.placeholder))
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(TextGrade.ghost)
            }
            .padding(AppSpace.small)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(SurfaceGrade.base)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(SurfaceGrade.border.opacity(0.3), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Goal Input

    private var goalInput: some View {
        VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
            Text("补充说明")
                .font(AppFont.captionMedium)
                .foregroundStyle(TextGrade.secondary)
            TextField("可选：描述具体目标或约束…", text: $goalText)
                .textFieldStyle(.plain)
                .font(AppFont.body)
                .padding(AppSpace.small)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(SurfaceGrade.base)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .strokeBorder(SurfaceGrade.border.opacity(0.3), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            // Missing params warning
            if !missingRequiredParams.isEmpty {
                HStack(spacing: AppSpace.extraSmall) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text("请填写：\(missingRequiredParams.joined(separator: "、"))")
                        .font(AppFont.tiny)
                }
                .foregroundStyle(Semantic.warning)
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Text("取消")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.muted)
                    .padding(.horizontal, AppSpace.large)
                    .padding(.vertical, AppSpace.small)
            }
            .buttonStyle(.plain)

            Button {
                launch()
            } label: {
                HStack(spacing: AppSpace.extraSmall) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("运行")
                        .font(AppFont.captionMedium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, AppSpace.large)
                .padding(.vertical, AppSpace.small)
                .background(
                    Capsule()
                        .fill(
                            canLaunch
                                ? Brand.premiumGradient
                                : LinearGradient(colors: [TextGrade.ghost], startPoint: .leading, endPoint: .trailing))
                )
                .shadow(color: canLaunch ? Brand.primary.opacity(0.3) : .clear, radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(!canLaunch)
        }
    }

    // MARK: - Helpers

    private var categoryColor: Color {
        Color(hex: workflow.category.tintHex)
    }

    private var missingRequiredParams: [String] {
        workflow.inputParams
            .filter { $0.required && (paramValues[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.label)
    }

    private var canLaunch: Bool {
        missingRequiredParams.isEmpty
    }

    private func bindingFor(_ param: WorkflowParam) -> Binding<String> {
        Binding(
            get: { paramValues[param.key] ?? "" },
            set: { paramValues[param.key] = $0 }
        )
    }

    private func launch() {
        // Set choice defaults if user hasn't picked
        for param in workflow.inputParams where param.kind == .choice {
            if paramValues[param.key] == nil {
                let options = param.defaultValue.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                paramValues[param.key] = options.first ?? ""
            }
        }
        store.startWorkflow(
            named: workflow.name,
            goal: goalText.isEmpty ? nil : goalText,
            userParams: paramValues
        )
        onDismiss()
    }
}
