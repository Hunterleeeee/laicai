import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LaicaiNativeDomain
import LaicaiNativeFoundation

struct ChatDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showingSettings: Bool
    @Binding var showSidebar: Bool
    @Binding var showWorkbench: Bool
    @ObservedObject private var skillRegistry = SkillRegistry.shared

    @State private var composerFocused = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content
            composer
        }
        .background(SurfaceGrade.base)
        .onAppear { PasteImageMonitor.install(store: store) }
        .onReceive(NotificationCenter.default.publisher(for: .laicaiNewThread)) { _ in
            store.selectThread(nil as ThreadRecord?)
            composerFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .laicaiContinueLastTask)) { _ in
            if let lastTask = store.state.threads.filter({ $0.source == .task }).sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                store.selectTask(id: lastTask.id)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: AppSpace.sm) {
            // Left: title/status
            Group {
                if let task = store.state.selectedTask {
                    HStack(spacing: AppSpace.sm) {
                        Circle()
                            .fill(task.status.color)
                            .frame(width: 6, height: 6)
                        Text(TextHelper.compactTitle(task.title))
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(TextGrade.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 300, alignment: .leading)
                        statusBadge(for: task.status)
                    }
                } else if let session = store.state.selectedSession {
                    Text(TextHelper.compactTitle(session.title))
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(TextGrade.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 300, alignment: .leading)
                } else {
                    Text("来财")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TextGrade.secondary)
                }
            }

            Spacer()

            // G5: Cumulative token usage
            if let task = store.state.selectedTask {
                tokenUsageBadge(steps: task.steps)
            }

            // Center/Right: model picker
            modelPicker

            // Actions
            if store.state.isGenerating {
                Button {
                    store.stopGenerating()
                } label: {
                    HStack(spacing: AppSpace.xs) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("停止")
                            .font(AppFont.captionMedium)
                    }
                    .foregroundStyle(Semantic.error)
                    .padding(.horizontal, AppSpace.md)
                    .padding(.vertical, AppSpace.sm - 1)
                    .background(
                        Capsule()
                            .fill(Semantic.errorMuted)
                    )
                }
                .buttonStyle(.plain)
            } else if store.state.selectedTask != nil || store.state.selectedSession?.turns.isEmpty == false {
                ToolbarButton(icon: "arrow.clockwise", tooltip: "重试") {
                    store.retryLastMessage()
                }
                Menu {
                    Button { store.undoLastCheckpoint() } label: {
                        Label("回滚检查点", systemImage: "arrow.uturn.backward")
                    }
                    Divider()
                    Button(role: .destructive) {
                        store.clearSelectedThread()
                    } label: {
                        Label("清空", systemImage: "eraser")
                    }
                } label: {
                    MenuIconLabel(icon: "ellipsis", tooltip: "更多")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            ToolbarButton(icon: "sidebar.right", tooltip: "切换工作台") {
                showWorkbench.toggle()
            }
        }
        .padding(.horizontal, AppSpace.lg)
        .frame(height: LayoutConst.toolbarHeight)
        .background(SurfaceGrade.base.opacity(0.8))
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SurfaceGrade.divider).frame(height: 0.5)
        }
    }

    private func statusBadge(for status: TaskStatus) -> some View {
        Text(status.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, AppSpace.sm)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(status.color.opacity(0.15))
                    .overlay(Capsule().strokeBorder(status.color.opacity(0.25), lineWidth: 0.5))
            )
    }

    // G5: Token usage summary badge
    @ViewBuilder
    private func tokenUsageBadge(steps: [TaskStep]) -> some View {
        let metrics = steps.compactMap(\.metrics)
        let totalIn = metrics.compactMap(\.inputTokens).reduce(0, +)
        let totalOut = metrics.compactMap(\.outputTokens).reduce(0, +)
        if totalIn + totalOut > 0 {
            let costEstimate = Double(totalIn) * 0.003 / 1000.0 + Double(totalOut) * 0.015 / 1000.0  // typical pricing
            HStack(spacing: 3) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 8))
                Text("\(formatTokenCount(totalIn))/\(formatTokenCount(totalOut))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                if costEstimate >= 0.001 {
                    Text("≈$\(String(format: "%.3f", costEstimate))")
                        .font(.system(size: 9, design: .monospaced))
                }
            }
            .foregroundStyle(TextGrade.ghost)
            .padding(.horizontal, AppSpace.sm)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(SurfaceGrade.elevated.opacity(0.55))
            )
            .help("输入 \(totalIn) / 输出 \(totalOut) tokens")
        }
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(String(format: "%.1f", Double(count) / 1_000_000))M" }
        if count >= 1000 { return "\(String(format: "%.1f", Double(count) / 1000))K" }
        return "\(count)"
    }

    @ViewBuilder
    private var modelPicker: some View {
        if let connector = store.state.activeConnector {
            Menu {
                ForEach(store.state.connectors) { c in
                    Button {
                        store.selectConnector(id: c.id)
                    } label: {
                        HStack(alignment: .center, spacing: AppSpace.sm) {
                            Circle()
                                .fill(c.health.color)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name)
                                Text(modelMenuDetail(for: c))
                                    .font(AppFont.tiny)
                                    .foregroundStyle(TextGrade.muted)
                            }
                            if c.id == store.state.activeConnectorID {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button {
                    store.checkConnectorHealth(id: connector.id)
                } label: {
                    Label("测试当前模型", systemImage: "waveform.path.ecg")
                }
                Button { showingSettings = true } label: {
                    Label("管理连接器", systemImage: "gearshape")
                }
            } label: {
                HStack(spacing: AppSpace.sm) {
                    ZStack {
                        Circle()
                            .fill(connector.health.color)
                            .frame(width: 8, height: 8)
                        Circle()
                            .fill(connector.health.color.opacity(0.30))
                            .frame(width: 16, height: 16)
                    }
                    Text(connector.modelName.isEmpty ? connector.name : connector.modelName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(TextGrade.ghost)
                }
                .padding(.horizontal, AppSpace.md + 2)
                .padding(.vertical, AppSpace.sm + 1)
                .background(
                    Capsule()
                        .fill(SurfaceGrade.elevated.opacity(0.6))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        } else {
            Button { showingSettings = true } label: {
                HStack(spacing: AppSpace.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("未配置模型")
                        .font(AppFont.captionMedium)
                }
                .foregroundStyle(Semantic.warning)
                .padding(.horizontal, AppSpace.sm + 2)
                .padding(.vertical, AppSpace.xs + 2)
                .background(
                    Capsule()
                        .fill(Semantic.warningMuted)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func modelMenuDetail(for connector: ConnectorProfile) -> String {
        let profile = ConnectorCapabilityProfile.infer(for: connector, mode: store.state.settings.contextMode)
        let location = profile.isLocal ? "本地" : "API"
        let context = compactTokenCount(profile.contextWindow)
        let tools = profile.supportsToolCalling ? "支持工具调用" : "不支持工具调用"
        let health = connector.health == .ready ? "就绪" : connector.health.title
        return "\(location) · \(context) 上下文 · \(tools) · \(profile.toolCallingSourceDetail) · \(health)"
    }

    private func compactTokenCount(_ value: Int) -> String {
        if value >= 1000 {
            return "\(value / 1000)k"
        }
        return "\(value)"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let thread = store.state.selectedThread, !thread.steps.isEmpty {
            ThreadTimelineView(thread: ThreadRecord(thread: thread, includeEvents: true))
                .id("\(thread.source.rawValue)-\(thread.id)")
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
        } else {
            WelcomeView(showingSettings: $showingSettings)
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.state.draftAttachments.isEmpty {
                attachmentChips
                    .padding(.horizontal, AppSpace.md)
                    .padding(.top, AppSpace.sm)
            }
            if !store.state.draftImages.isEmpty {
                imagePreviewStrip
                    .padding(.horizontal, AppSpace.md)
                    .padding(.top, AppSpace.sm)
            }

            VStack(spacing: 0) {
                ComposerTextView(
                    text: Binding(
                        get: { store.state.isGenerating ? (store.state.pendingFollowUp ?? "") : store.state.draftMessage },
                        set: { newValue in
                            if store.state.isGenerating {
                                store.queueFollowUp(newValue)
                            } else {
                                store.updateDraft(newValue)
                            }
                        }
                    ),
                    placeholder: composerPlaceholder,
                    onSend: {
                        if store.state.isGenerating {
                            store.submitFollowUp()
                        } else {
                            store.sendDraft()
                        }
                    },
                    onImagePaste: { data, mediaType in
                        let idx = store.state.draftImages.count + 1
                        let attachment = ImageAttachment(
                            data: data,
                            mediaType: mediaType,
                            thumbnailName: "图片 \(idx)"
                        )
                        store.addDraftImage(attachment)
                    },
                    isFocused: $composerFocused
                )
                .frame(maxWidth: .infinity, minHeight: 36, idealHeight: 40, maxHeight: 140, alignment: .topLeading)
                .clipped()
                .disabled(store.state.activeConnector == nil)
                .opacity(store.state.activeConnector == nil ? 0.4 : 1)

                HStack(spacing: 0) {
                    // Left: mode + skill
                    HStack(spacing: AppSpace.xs) {
                        executionModeMenu
                        skillPickerMenu
                    }

                    Spacer()

                    // Right: context + attach + send
                    HStack(spacing: AppSpace.sm) {
                        contextBudgetHint
                        attachImageButton
                        attachFileButton
                        if store.state.isGenerating {
                            appendInstructionButton
                        } else {
                            sendButton
                        }
                    }
                }
                .padding(.horizontal, AppSpace.md)
                .padding(.bottom, AppSpace.sm)
                .padding(.top, AppSpace.xs)
            }
            .background(
                RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
                    .fill(SurfaceGrade.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
                    .strokeBorder(
                        composerFocused
                        ? LinearGradient(
                            colors: [Brand.primary.opacity(0.60), Brand.purple.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                          )
                        : LinearGradient(
                            colors: [Color.white.opacity(0.12), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                          ),
                        lineWidth: composerFocused ? 1.5 : 1
                    )
            )
            .shadow(
                color: composerFocused ? Brand.primary.opacity(0.12) : Color.black.opacity(0.20),
                radius: composerFocused ? 20 : 8,
                y: composerFocused ? 4 : 2
            )

            if store.state.activeConnector == nil || store.state.isGenerating {
                composerStatusBar
                    .padding(.top, AppSpace.sm)
            }
        }
        .frame(maxWidth: LayoutConst.composerMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppSpace.xl)
        .padding(.top, AppSpace.sm)
        .padding(.bottom, AppSpace.lg)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var paths: [String] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                    if let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        paths.append(url.path)
                    } else if let url = data as? URL {
                        paths.append(url.path)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                if !paths.isEmpty {
                    store.addDraftAttachments(paths)
                    composerFocused = true
                }
            }
            return true
        }
    }

    private var composerStatusBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpace.sm) {
                if store.state.activeConnector == nil {
                    composerChip(icon: "exclamationmark.triangle", text: "未连接模型", tone: .warning)
                }
                if store.state.isGenerating {
                    composerChip(icon: "sparkles", text: "处理中", tone: .active)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var skillPickerMenu: some View {
        Menu {
            ForEach(skillRegistry.skills.filter { !$0.tools.isEmpty || $0.workflowName != nil }) { skill in
                Button {
                    applySkillTemplate(skill)
                } label: {
                    Label(skill.name, systemImage: skillIcon(for: skill))
                }
            }
            if skillRegistry.skills.filter({ !$0.tools.isEmpty || $0.workflowName != nil }).isEmpty {
                Text("暂无可用技能")
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TextGrade.muted)
                .padding(.horizontal, AppSpace.sm)
                .frame(height: 28)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(SurfaceGrade.border.opacity(0.25), lineWidth: 0.5)
                )
                .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("技能快捷入口")
    }

    private var executionModeMenu: some View {
        Menu {
            ForEach(ExecutionMode.allCases, id: \.self) { mode in
                Button {
                    store.updateExecutionMode(mode)
                } label: {
                    HStack {
                        Label(mode.title, systemImage: mode.icon)
                        Text(mode.subtitle)
                    }
                }
            }
        } label: {
            HStack(spacing: AppSpace.xs) {
                Image(systemName: store.state.executionMode.icon)
                    .font(.system(size: 12, weight: .medium))
                Text(store.state.executionMode.title)
                    .font(AppFont.captionMedium)
            }
            .foregroundStyle(executionModeColor)
            .padding(.horizontal, AppSpace.sm + 2)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(executionModeColor.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(executionModeColor.opacity(0.28), lineWidth: 0.8)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(store.state.executionMode.subtitle)
    }

    private var executionModeColor: Color {
        switch store.state.executionMode {
        case .auto: return TextGrade.muted
        case .ask: return Brand.primary
        case .inspect: return Semantic.success
        case .act: return Semantic.warning
        }
    }

    private func applySkillTemplate(_ skill: SkillDefinition) {
        var template = ""
        if let workflow = skill.workflowName {
            template = "请执行\(workflow)工作流"
        } else if !skill.tools.isEmpty {
            template = "请使用\(skill.tools.joined(separator: "、"))完成以下任务："
        }
        if !template.isEmpty {
            store.updateDraft(template)
            composerFocused = true
        }
    }

    private func skillIcon(for skill: SkillDefinition) -> String {
        switch skill.modelPreference {
        case .fast: return "bolt"
        case .strong: return "brain"
        case .code: return "chevron.left.forwardslash.chevron.right"
        default: return "cpu"
        }
    }

    // MARK: - Image Attach Button

    private var attachImageButton: some View {
        Button {
            chooseImageForDraft()
        } label: {
            Image(systemName: "photo")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TextGrade.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("添加图片（也可直接粘贴 ⌘V）")
    }

    private func chooseImageForDraft() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.title = "选择图片"
        panel.prompt = "添加"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let ext = url.pathExtension.lowercased()
            let mediaType = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/png"
            let name = url.deletingPathExtension().lastPathComponent
            let attachment = ImageAttachment(data: data, mediaType: mediaType, thumbnailName: name)
            store.addDraftImage(attachment)
        }
        composerFocused = true
    }

    // MARK: - Image Preview Strip

    private var imagePreviewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpace.sm) {
                ForEach(store.state.draftImages) { img in
                    ZStack(alignment: .topTrailing) {
                        if let nsImage = NSImage(data: img.data) {
                            SwiftUI.Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 52, height: 52)
                                .overlay(
                                    Image(systemName: "photo")
                                        .foregroundStyle(TextGrade.muted)
                                )
                        }

                        Button {
                            store.removeDraftImage(id: img.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .background(Circle().fill(Color.black.opacity(0.6)).frame(width: 16, height: 16))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
            }
        }
        .frame(height: 56)
    }

    private var attachFileButton: some View {
        Button {
            chooseFileForDraft()
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TextGrade.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("添加附件")
    }

    private var draftTokenBudget: TokenBudget {
        let mode = store.state.settings.contextMode
        return TokenBudget.estimate(
            context: selectedContext ?? TaskContext(workspaceRoot: store.state.settings.workspacePath),
            userInput: draftBudgetInput,
            mode: mode
        )
    }

    private var draftBudgetInput: String {
        guard !store.state.draftAttachments.isEmpty else { return store.state.draftMessage }
        return store.state.draftMessage + "\n" + store.state.draftAttachments.joined(separator: "\n")
    }

    private func composerChip(icon: String, text: String, tone: ComposerChipTone = .neutral) -> some View {
        HStack(spacing: AppSpace.xs) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(AppFont.tiny)
                .lineLimit(1)
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, AppSpace.sm + 1)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(tone.background)
        )
        .overlay(
            Capsule()
                .strokeBorder(tone.border, lineWidth: 0.6)
        )
    }

    private func contextBudgetIcon(for label: String) -> String {
        switch label {
        case "当前输入": return "text.cursor"
        case "项目上下文": return "folder"
        case "任务记忆": return "brain"
        case "工具结果": return "wrench.and.screwdriver"
        case "附件线索": return "paperclip"
        default: return "slider.horizontal.3"
        }
    }

    private var contextBudgetColor: Color {
        if draftTokenBudget.usageRatio > 0.88 { return Semantic.warning }
        if draftTokenBudget.usageRatio > 0.72 { return Brand.primary }
        return TextGrade.muted
    }

    private var contextBudgetHint: some View {
        HStack(spacing: AppSpace.sm) {
            // Agent context: read files
            if let task = store.state.selectedTask {
                let readFiles = task.steps.filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }.count
                if readFiles > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9))
                        Text("\(readFiles)")
                            .font(AppFont.tiny)
                    }
                    .foregroundStyle(TextGrade.secondary)
                    .help("Agent 已读取 \(readFiles) 个文件")
                }

                // Task memory indicator
                let hasMemory = task.steps.contains { $0.kind == .toolResult && $0.toolName == "workspace.index" && !$0.isFailure }
                if hasMemory {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 9))
                        .foregroundStyle(Brand.primary.opacity(0.72))
                        .help("已建立项目索引")
                }
            }

            // Token budget warning
            if draftTokenBudget.usageRatio > 0.72 {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9, weight: .medium))
                    Text("\(Int(draftTokenBudget.usageRatio * 100))%")
                        .font(AppFont.tiny)
                }
                .foregroundStyle(contextBudgetColor)
                .help(draftTokenBudget.compressionSummary)
            }
        }
    }

    private var sendButton: some View {
        Button {
            if store.state.isGenerating {
                store.stopGenerating()
            } else {
                store.sendDraft()
            }
        } label: {
            Group {
                if store.state.isGenerating {
                    ZStack {
                        Circle()
                            .fill(Semantic.error.opacity(0.20))
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle().strokeBorder(Semantic.error.opacity(0.40), lineWidth: 1)
                            )
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Semantic.error)
                    }
                    .shadow(color: Semantic.error.opacity(0.25), radius: 6)
                } else {
                    ZStack {
                        Circle()
                            .fill(
                                canSend
                                ? LinearGradient(colors: [Brand.gradientStart, Brand.gradientEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
                                : LinearGradient(colors: [SurfaceGrade.elevated, SurfaceGrade.elevated], startPoint: .top, endPoint: .bottom)
                            )
                            .frame(width: 30, height: 30)

                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(canSend ? .white : TextGrade.ghost)
                    }
                    .shadow(color: canSend ? Brand.primary.opacity(0.40) : .clear, radius: 8, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!store.state.isGenerating && !canSend)
        .help(store.state.isGenerating ? "停止生成" : (canSend ? "发送 (↵)" : "输入内容后发送"))
    }

    private var canSend: Bool {
        let hasText = !store.state.draftMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return (hasText || !store.state.draftAttachments.isEmpty || !store.state.draftImages.isEmpty) && store.state.activeConnector != nil
    }

    private var hasPendingFollowUp: Bool {
        let text = store.state.pendingFollowUp ?? ""
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var appendInstructionButton: some View {
        Button {
            store.submitFollowUp()
        } label: {
            HStack(spacing: AppSpace.xs) {
                Image(systemName: "plus.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("追加")
                    .font(AppFont.captionMedium)
            }
            .foregroundStyle(hasPendingFollowUp ? .white : TextGrade.ghost)
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.sm)
            .background(
                Capsule()
                    .fill(hasPendingFollowUp ? Brand.primary : SurfaceGrade.sunken)
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasPendingFollowUp)
        .help(hasPendingFollowUp ? "追加指令 (↵)" : "输入要追加的指令")
    }

    private var composerPlaceholder: String {
        if store.state.activeConnector == nil { return "先连接模型…" }
        let defaultPlaceholder: String
        switch store.state.executionMode {
        case .auto:
            defaultPlaceholder = "输入问题或目标，系统会判断是否需要工具…"
        case .ask:
            defaultPlaceholder = "问一问：只回答，不读取项目…"
        case .inspect:
            defaultPlaceholder = "看项目：可读文件和搜索，不写入…"
        case .act:
            defaultPlaceholder = "执行：可完成任务，高风险操作需确认…"
        }
        if let task = store.state.selectedTask {
            switch task.status {
            case .cancelled: return "继续处理，或输入新的处理方式…"
            case .failed: return "描述如何处理失败，或直接重试…"
            case .waitingReview: return "审查完成后继续…"
            case .running: return "补充指令…"
            default: return "继续处理，或输入新的处理方式…"
            }
        }
        if store.state.selectedSession != nil { return "\(defaultPlaceholder)    ⌘K 命令面板" }
        return "\(defaultPlaceholder)    ⌘K 命令面板"
    }

    private func chooseFileForDraft() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "选择要读取的文件或文件夹"
        panel.prompt = "选择"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        store.addDraftAttachments(panel.urls.map(\.path))
        composerFocused = true
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpace.sm) {
                ForEach(store.state.draftAttachments, id: \.self) { path in
                    let isDir = isDirectory(path)
                    HStack(spacing: AppSpace.xs + 1) {
                        Image(systemName: isDir ? "folder.fill" : "doc.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isDir ? Brand.primary : TextGrade.muted)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(TextGrade.primary)
                                .lineLimit(1)
                            if isDir {
                                Text(directoryHint(path))
                                    .font(.system(size: 9))
                                    .foregroundStyle(TextGrade.ghost)
                                    .lineLimit(1)
                            }
                        }
                        Button {
                            store.removeDraftAttachment(path)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(TextGrade.ghost)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, AppSpace.sm)
                    .padding(.trailing, AppSpace.xs + 2)
                    .padding(.vertical, AppSpace.xs + 1)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .fill(SurfaceGrade.card.opacity(0.8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .strokeBorder(isDir ? Brand.primary.opacity(0.2) : SurfaceGrade.border.opacity(0.3), lineWidth: 0.5)
                    )
                    .frame(maxWidth: 200)
                    .help(path)
                }
            }
            .padding(.horizontal, AppSpace.md)
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private func directoryHint(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let count = (try? FileManager.default.contentsOfDirectory(atPath: path).count) ?? 0
        let parent = url.deletingLastPathComponent().lastPathComponent
        return count > 0 ? "\(count) 项 · \(parent)" : parent
    }

    private var workspaceDisplayName: String {
        let last = URL(fileURLWithPath: store.state.settings.workspacePath).lastPathComponent
        return last.isEmpty ? store.state.workspaceName : last
    }

    private var selectedContext: TaskContext? {
        store.state.selectedThread?.context
    }

    private var selectionChipIcon: String {
        store.state.selectedTask == nil ? "text.bubble" : store.state.selectedTask?.status.icon ?? "text.bubble"
    }

    private var selectionChipText: String {
        if let task = store.state.selectedTask {
            return task.status == .running ? "执行中" : task.status.label
        }
        return store.state.selectedSession == nil ? "新线程" : "线程"
    }

}

private enum ComposerChipTone {
    case neutral
    case warning
    case active

    var foreground: Color {
        switch self {
        case .neutral: return TextGrade.muted
        case .warning: return Semantic.warning
        case .active: return Brand.primary
        }
    }

    var background: Color {
        switch self {
        case .neutral: return SurfaceGrade.elevated.opacity(0.68)
        case .warning: return Semantic.warningMuted.opacity(0.8)
        case .active: return Brand.primary.opacity(0.12)
        }
    }

    var border: Color {
        switch self {
        case .neutral: return SurfaceGrade.divider
        case .warning: return Semantic.warning.opacity(0.24)
        case .active: return Brand.primary.opacity(0.22)
        }
    }
}

// MARK: - Toolbar Button

struct ToolbarButton: View {
    let icon: String
    var tooltip: String = ""
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? TextGrade.primary : TextGrade.ghost)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                        .fill(isHovered ? SurfaceGrade.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(AppAnimation.micro) { isHovered = h } }
        .help(tooltip)
    }
}

struct MenuIconLabel: View {
    let icon: String
    var tooltip: String = ""

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(TextGrade.muted)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help(tooltip)
    }
}

// MARK: - Task Stream View

struct ThreadTimelineView: View {
    @EnvironmentObject private var store: AppStore
    let thread: ThreadRecord
    private let bottomID = "thread-bottom-anchor"
    private let compactStepLimit = 72
    @State private var scrollToken = 0
    @State private var showFullHistory = false
    @State private var userScrolledAway = false
    @State private var expandedPhases: Set<String> = []
    @State private var eventMonitor: Any?
    @State private var lastContentWidth: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppSpace.lg) {
                        if let task = thread.task {
                            TaskSummaryCard(task: task)
                            if task.status == .completed || task.status == .failed {
                                TaskCompletionSummaryCard(task: task)
                                TaskRatingBar(threadID: thread.id, currentRating: store.state.threads.first(where: { $0.id == thread.id })?.userRating ?? 0)
                            }
                            if let plan = task.multiAgentPlan {
                                if plan.isEditable {
                                    MultiAgentPlanEditorView(
                                        plan: Binding(
                                            get: { plan },
                                            set: { newPlan in
                                                store.updateMultiAgentPlan(newPlan, for: thread.id)
                                            }
                                        ),
                                        connectors: store.state.connectors,
                                        workspaceRoot: store.state.settings.workspacePath,
                                        onExecute: {
                                            store.executeEditedPlan(threadID: thread.id)
                                        },
                                        onCancel: {
                                            store.cancelMultiAgentPlan(for: thread.id)
                                        }
                                    )
                                } else {
                                    MultiAgentFlowView(plan: plan)
                                    ResumePlanButton(plan: plan) {
                                        store.resumeFailedPlan(threadID: thread.id)
                                    }
                                }
                            }
                        if shouldCompact(task) {
                            TaskHistoryFoldCard(
                                hiddenCount: hiddenStepCount(task),
                                showFullHistory: $showFullHistory
                            )
                        }
                        ForEach(phaseGroups(for: visibleSteps(for: task))) { group in
                            if group.isToolPhase {
                                PhaseGroupCard(
                                    group: group,
                                    taskID: task.id,
                                    isRunning: task.status == .running,
                                    isCollapsed: !expandedPhases.contains(group.id),
                                    onToggle: { withAnimation(.easeInOut(duration: 0.15)) {
                                        if expandedPhases.contains(group.id) {
                                            expandedPhases.remove(group.id)
                                        } else {
                                            expandedPhases.insert(group.id)
                                        }
                                    }}
                                )
                            } else {
                                ForEach(group.steps) { step in
                                    TaskStepCard(
                                        step: step,
                                        taskID: task.id,
                                        isRunning: task.status == .running
                                    )
                                    .id(step.id)
                                }
                            }
                        }
                    } else {
                        ForEach(thread.events) { event in
                            ThreadEventCard(event: event)
                                .id(event.id)
                        }
                    }

                    if store.state.isGenerating {
                        TypingIndicator()
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .frame(maxWidth: LayoutConst.composerMaxWidth + 60, alignment: .leading)
                .padding(.horizontal, AppSpace.xl)
                .padding(.top, AppSpace.md)
                .padding(.bottom, AppSpace.lg)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(SurfaceGrade.base)
            .onAppear {
                scrollToBottom(proxy)
                if eventMonitor == nil {
                    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                        if event.deltaY > 0 { self.userScrolledAway = true }
                        return event
                    }
                }
            }
            .onDisappear {
                if let monitor = eventMonitor {
                    NSEvent.removeMonitor(monitor)
                    eventMonitor = nil
                }
            }
            .onChange(of: thread.events.count) { _ in scheduleScrollToBottom(proxy) }
            .onChange(of: thread.task?.status) { newStatus in
                if newStatus == .running { userScrolledAway = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: .laicaiPanelToggled)) { _ in
                userScrolledAway = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard !userScrolledAway else { return }
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            // 宽度变化检测：侧边栏/工作台切换后自动滚回底部
            .background(alignment: .topLeading) {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { lastContentWidth = geo.size.width }
                        .onChange(of: geo.size.width) { newWidth in
                            guard abs(newWidth - lastContentWidth) > 5 else { return }
                            lastContentWidth = newWidth
                            scheduleScrollToBottom(proxy)
                        }
                }
            }

                // Batch review floating bar
                if let task = thread.task {
                    let pendingReviews = task.steps.filter { $0.kind == .reviewRequest && $0.approved == nil }
                    if pendingReviews.count >= 2 {
                        BatchReviewBar(
                            pendingCount: pendingReviews.count,
                            taskID: task.id,
                            stepIDs: pendingReviews.map(\.id)
                        )
                        .padding(.bottom, AppSpace.sm)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
    }

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy) {
        guard !userScrolledAway else { return }
        scrollToken += 1
        let token = scrollToken
        DispatchQueue.main.async {
            guard token == scrollToken else { return }
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    private func shouldCompact(_ task: AgentTask) -> Bool {
        !showFullHistory && task.steps.count > compactStepLimit
    }

    private func hiddenStepCount(_ task: AgentTask) -> Int {
        max(task.steps.count - compactStepLimit, 0)
    }

    private func visibleSteps(for task: AgentTask) -> [TaskStep] {
        let steps = shouldCompact(task) ? Array(task.steps.suffix(compactStepLimit)) : task.steps
        // Merge continuation textOutput steps into their originals
        let continuations = steps.filter { $0.continuationOf != nil && $0.kind == .textOutput }
        guard !continuations.isEmpty else { return steps }
        var merged = steps.filter { $0.continuationOf == nil || $0.kind != .textOutput }
        for cont in continuations {
            if let idx = merged.firstIndex(where: { $0.id == cont.continuationOf }) {
                var step = merged[idx]
                step.text += "\n" + cont.text
                step.metrics = cont.metrics ?? step.metrics
                step.continuationOf = nil
                merged[idx] = step
            } else {
                merged.append(cont)
            }
        }
        return merged
    }
}

private struct TaskHistoryFoldCard: View {
    let hiddenCount: Int
    @Binding var showFullHistory: Bool

    var body: some View {
        HStack(alignment: .center, spacing: AppSpace.sm) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TextGrade.muted)
                .frame(width: 22, height: 22)
                .background(Circle().fill(SurfaceGrade.sunken.opacity(0.72)))

            VStack(alignment: .leading, spacing: 2) {
                Text("已折叠 \(hiddenCount) 条早期步骤")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                Text("保留最近进展，完整历史仍在本地。")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
            }

            Spacer()

            Button {
                showFullHistory = true
            } label: {
                Text("展开")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(Brand.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.elevated.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(SurfaceGrade.hairline.opacity(0.8), lineWidth: 0.6)
        )
    }
}

private struct ThreadSummaryCard: View {
    let thread: ThreadRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            HStack(spacing: AppSpace.sm) {
                Image(systemName: thread.isPinned ? "pin.fill" : "text.bubble.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(thread.isPinned ? Semantic.warning : Brand.primary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill((thread.isPinned ? Semantic.warning : Brand.primary).opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(AppFont.headline)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(2)
                    Text("线程 · \(thread.events.count) 条记录 · \(RelativeTimeFormatter.string(for: thread.updatedAt))")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }

                Spacer()
            }

            if !thread.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(thread.preview)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(AppSpace.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .fill(SurfaceGrade.panel.opacity(0.75))
                    )
            }
        }
        .padding(AppSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(SurfaceGrade.divider, lineWidth: 0.75)
        )
    }
}

private struct ThreadEventCard: View {
    let event: ThreadEvent

    var body: some View {
        switch event.kind {
        case .user:
            UserInputCard(text: event.text)
        case .assistant:
            TextOutputCard(text: event.text, metrics: event.metrics, isRunning: false)
        case .thinking:
            ThinkingCard(text: event.text, reasoningContent: nil, isRunning: false)
        case .toolCall:
            timelineSystemCard(icon: "wrench.and.screwdriver.fill", title: "工具调用", text: event.text, color: Semantic.toolCall)
        case .toolResult:
            timelineSystemCard(icon: "checkmark.circle.fill", title: "工具结果", text: event.text, color: Semantic.success)
        case .review:
            timelineSystemCard(icon: "eye.fill", title: "审查", text: event.text, color: Semantic.warning)
        case .error:
            timelineSystemCard(icon: "exclamationmark.triangle.fill", title: "错误", text: event.text, color: Semantic.error)
        }
    }

    private func timelineSystemCard(icon: String, title: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: AppSpace.sm) {
            AvatarBadge(icon: icon, color: color)

            VStack(alignment: .leading, spacing: AppSpace.xs) {
                Text(title)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(color)

                Text(text)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.secondary)
                    .textSelection(.enabled)
                    .padding(AppSpace.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .fill(SurfaceGrade.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .strokeBorder(color.opacity(0.18), lineWidth: 1)
                    )
            }

            Spacer()
        }
    }
}

// MARK: - Multi-Agent Flow View

struct MultiAgentFlowView: View {
    let plan: MultiAgentPlan
    @State private var selectedAgentID: UUID?
    @State private var pulsePhase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──
            HStack(spacing: AppSpace.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                        .fill(Brand.purple.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.purple)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("多Agent协同编排")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                    Text("\(plan.agents.count) 个Agent · \(plan.progress)")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }

                Spacer()

                flowStatusPill(for: plan.status)
            }
            .padding(.horizontal, AppSpace.xl)
            .padding(.vertical, AppSpace.lg)

            // ── Divider ──
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.clear, Brand.purple.opacity(0.15), Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)

            // ── Flow Pipeline ──
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(plan.agents.enumerated()), id: \.element.id) { index, agent in
                        flowNodeCard(agent: agent, index: index)
                            .onTapGesture {
                                withAnimation(AppAnimation.spring) {
                                    selectedAgentID = selectedAgentID == agent.id ? nil : agent.id
                                }
                            }

                        if index < plan.agents.count - 1 {
                            flowConnector(from: agent, toIndex: index + 1)
                        }
                    }
                }
                .padding(.horizontal, AppSpace.xl)
                .padding(.vertical, AppSpace.xl)
            }

            // ── Selected Agent Detail ──
            if let selectedID = selectedAgentID,
               let agent = plan.agents.first(where: { $0.id == selectedID }) {
                Rectangle().fill(SurfaceGrade.divider).frame(height: 0.5)
                flowAgentDetail(agent: agent)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Brand.purple.opacity(0.20), Brand.primary.opacity(0.10), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: Brand.purple.opacity(0.08), radius: 20, y: 8)
        .onAppear { pulsePhase = true }
    }

    // ── Node Card ──

    private func flowNodeCard(agent: AgentNode, index: Int) -> some View {
        let isSelected = selectedAgentID == agent.id
        let isRunning = agent.status == .running
        let nodeColor = flowColor(for: agent.status)

        return VStack(spacing: AppSpace.sm) {
            ZStack {
                // Background circle
                Circle()
                    .fill(nodeColor.opacity(0.10))
                    .frame(width: 52, height: 52)

                // Running ring animation
                if isRunning {
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(
                            AngularGradient(
                                colors: [nodeColor.opacity(0), nodeColor],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .frame(width: 52, height: 52)
                        .rotationEffect(.degrees(pulsePhase ? 360 : 0))
                        .animation(
                            .linear(duration: 1.5).repeatForever(autoreverses: false),
                            value: pulsePhase
                        )
                }

                // Completed checkmark ring
                if agent.status == .completed {
                    Circle()
                        .stroke(nodeColor.opacity(0.25), lineWidth: 2)
                        .frame(width: 52, height: 52)
                }

                // Selected ring
                if isSelected && !isRunning {
                    Circle()
                        .stroke(nodeColor.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 56, height: 56)
                }

                // Icon
                Image(systemName: agent.role.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(nodeColor)
            }

            // Label
            VStack(spacing: 2) {
                Text(agent.role.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? TextGrade.primary : TextGrade.secondary)

                flowStatusLabel(agent.status)
            }

            // Step count
            if !agent.stepIDs.isEmpty {
                Text("\(agent.stepIDs.count) 步")
                    .font(AppFont.micro)
                    .foregroundStyle(TextGrade.ghost)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(SurfaceGrade.elevated.opacity(0.6))
                    )
            }
        }
        .frame(minWidth: 80)
        .padding(.vertical, AppSpace.sm)
        .padding(.horizontal, AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(isSelected ? SurfaceGrade.elevated.opacity(0.5) : Color.clear)
        )
    }

    // ── Connector ──

    private func flowConnector(from agent: AgentNode, toIndex: Int) -> some View {
        let handoff = plan.handoffs.first(where: {
            $0.fromAgentID == agent.id && toIndex < plan.agents.count && $0.toAgentID == plan.agents[toIndex].id
        })
        let hasArtifact = !(handoff?.artifact.isEmpty ?? true)
        let isDone = agent.status == .completed
        let isActive = agent.status == .running

        return VStack(spacing: AppSpace.xs) {
            ZStack {
                // Connector line
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        isDone
                        ? LinearGradient(colors: [flowColor(for: .completed).opacity(0.5), flowColor(for: .completed).opacity(0.2)], startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [TextGrade.ghost.opacity(0.3), TextGrade.ghost.opacity(0.15)], startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: 32, height: 2)

                // Active pulse dot
                if isActive {
                    Circle()
                        .fill(Brand.primary)
                        .frame(width: 6, height: 6)
                        .shadow(color: Brand.primary.opacity(0.5), radius: 4)
                        .offset(x: pulsePhase ? 12 : -12)
                        .animation(
                            .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                            value: pulsePhase
                        )
                }

                // Arrow head
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isDone ? flowColor(for: .completed).opacity(0.6) : TextGrade.ghost.opacity(0.4))
                    .offset(x: 20)
            }
            .frame(width: 48)

            if hasArtifact {
                Text("数据")
                    .font(AppFont.micro)
                    .foregroundStyle(Brand.primary.opacity(0.7))
            }
        }
    }

    // ── Agent Detail Panel ──

    private func flowAgentDetail(agent: AgentNode) -> some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(spacing: AppSpace.md) {
                ZStack {
                    Circle()
                        .fill(flowColor(for: agent.status).opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: agent.role.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(flowColor(for: agent.status))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.role.title)
                        .font(AppFont.headline)
                        .foregroundStyle(TextGrade.primary)
                    Text(agent.status.title)
                        .font(AppFont.caption)
                        .foregroundStyle(flowColor(for: agent.status))
                }

                Spacer()

                if !agent.output.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                        Text("已产出")
                            .font(AppFont.captionMedium)
                    }
                    .foregroundStyle(Semantic.success)
                }
            }

            if !agent.input.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    Label("输入", systemImage: "arrow.down.circle")
                        .font(AppFont.micro)
                        .foregroundStyle(TextGrade.ghost)
                    Text(agent.input)
                        .font(AppFont.body)
                        .foregroundStyle(TextGrade.secondary)
                        .lineLimit(4)
                        .padding(AppSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                .fill(SurfaceGrade.sunken)
                        )
                }
            }

            if !agent.output.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    Label("输出", systemImage: "arrow.up.circle")
                        .font(AppFont.micro)
                        .foregroundStyle(TextGrade.ghost)
                    Text(agent.output)
                        .font(AppFont.body)
                        .foregroundStyle(TextGrade.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .padding(AppSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                .fill(SurfaceGrade.sunken)
                        )
                }
            }

            if !agent.stepIDs.isEmpty {
                HStack(spacing: AppSpace.xs) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 10))
                    Text("\(agent.stepIDs.count) 个执行步骤")
                        .font(AppFont.caption)
                }
                .foregroundStyle(TextGrade.muted)
            }
        }
        .padding(AppSpace.xl)
    }

    // ── Helpers ──

    private func flowStatusLabel(_ status: TaskStatus) -> some View {
        Text(status.title)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(flowColor(for: status))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(flowColor(for: status).opacity(0.10))
            )
    }

    private func flowStatusPill(for status: TaskStatus) -> some View {
        HStack(spacing: 4) {
            if status == .running {
                Circle()
                    .fill(flowColor(for: status))
                    .frame(width: 6, height: 6)
                    .scaleEffect(pulsePhase ? 1.3 : 0.8)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: pulsePhase
                    )
            } else {
                Circle()
                    .fill(flowColor(for: status))
                    .frame(width: 6, height: 6)
            }
            Text(status.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(flowColor(for: status))
        }
        .padding(.horizontal, AppSpace.sm + 2)
        .padding(.vertical, AppSpace.xs + 1)
        .background(
            Capsule().fill(flowColor(for: status).opacity(0.10))
        )
        .overlay(
            Capsule().strokeBorder(flowColor(for: status).opacity(0.15), lineWidth: 0.5)
        )
    }

    private func flowColor(for status: TaskStatus) -> Color {
        switch status {
        case .queued: return TextGrade.muted
        case .running: return Brand.primary
        case .waitingReview: return Semantic.warning
        case .completed: return Semantic.success
        case .failed: return Semantic.error
        case .cancelled: return TextGrade.ghost
        }
    }
}

// MARK: - Phase Grouping

struct StepPhaseGroup: Identifiable {
    let id: String
    let phase: TaskPhase
    let steps: [TaskStep]
    var isToolPhase: Bool { steps.allSatisfy { $0.kind == .toolCall || $0.kind == .toolResult } }
}

private func phaseGroups(for steps: [TaskStep]) -> [StepPhaseGroup] {
    var groups: [StepPhaseGroup] = []
    var currentNonTool: [TaskStep] = []

    func flushNonTool() {
        guard !currentNonTool.isEmpty else { return }
        let anchor = currentNonTool[0].id.uuidString
        groups.append(StepPhaseGroup(id: "nontool-\(anchor)", phase: .explore, steps: currentNonTool))
        currentNonTool = []
    }

    var i = 0
    while i < steps.count {
        let step = steps[i]
        if step.kind == .toolCall || step.kind == .toolResult {
            flushNonTool()
            var toolSteps: [TaskStep] = []
            while i < steps.count && (steps[i].kind == .toolCall || steps[i].kind == .toolResult) {
                toolSteps.append(steps[i])
                i += 1
            }
            let anchor = toolSteps[0].id.uuidString
            let phase = AgentLoop.inferPhase(from: toolSteps)
            groups.append(StepPhaseGroup(id: "tool-\(anchor)", phase: phase, steps: toolSteps))
        } else {
            currentNonTool.append(step)
            i += 1
        }
    }
    flushNonTool()
    return groups
}

struct PhaseGroupCard: View {
    let group: StepPhaseGroup
    let taskID: UUID
    let isRunning: Bool
    let isCollapsed: Bool
    let onToggle: () -> Void

    private var toolCallCount: Int {
        group.steps.filter { $0.kind == .toolCall }.count
    }
    private var failureCount: Int {
        group.steps.filter { $0.isFailure }.count
    }
    private var toolNames: [String] {
        Array(Set(group.steps.compactMap { $0.toolName }).filter { $0 != "workspace.index" }).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: group.phase.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.primary)
                    Text(group.phase.title)
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.secondary)
                    Text("\(toolCallCount) 步")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.muted)
                    if !toolNames.isEmpty {
                        Text(toolNames.joined(separator: " · "))
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)
                            .lineLimit(1)
                    }
                    if failureCount > 0 {
                        Text("失败 \(failureCount) 项")
                            .font(AppFont.tiny)
                            .foregroundStyle(Semantic.error)
                    }
                    Spacer()
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(TextGrade.ghost)
                }
                .padding(.horizontal, AppSpace.md)
                .padding(.vertical, AppSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                        .fill(SurfaceGrade.card.opacity(0.55))
                )
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: AppSpace.sm) {
                    ForEach(group.steps) { step in
                        TaskStepCard(step: step, taskID: taskID, isRunning: isRunning)
                            .id(step.id)
                    }
                }
                .padding(.leading, AppSpace.xl)
                .padding(.top, AppSpace.xs)
            }
        }
    }
}

private struct TaskSummaryCard: View {
    let task: AgentTask

    private var completedSteps: Int {
        task.steps.filter { $0.kind != .userInput }.count
    }

    private var failureCount: Int {
        task.steps.filter { $0.isFailure || $0.kind == .error }.count
    }

    private var readCount: Int {
        task.steps.filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(alignment: .center, spacing: AppSpace.md) {
                ZStack {
                    Circle()
                        .fill(task.status.color.opacity(0.10))
                        .frame(width: 28, height: 28)
                    Image(systemName: task.status.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(task.status.color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(TextHelper.compactTitle(task.title))
                        .font(AppFont.headline)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(summaryLine)
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                    if !memoryPills.isEmpty {
                        HStack(spacing: AppSpace.xs) {
                            ForEach(memoryPills.prefix(3), id: \.self) { pill in
                                Text(pill)
                                    .font(AppFont.tiny)
                                    .foregroundStyle(TextGrade.secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, AppSpace.sm)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(SurfaceGrade.sunken.opacity(0.72))
                                    )
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer()
            }

            phaseProgressBar
        }
        .padding(AppSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [task.status.color.opacity(0.18), task.status.color.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
    }

    private var currentPhase: TaskPhase {
        AgentLoop.inferPhase(from: task.steps)
    }

    @State private var phasePulse = false

    private var phaseProgressBar: some View {
        let phases: [TaskPhase] = [.explore, .execute, .verify, .summarize]
        let currentIndex = phases.firstIndex(of: currentPhase) ?? 0
        let isRunning = task.status == .running

        return VStack(alignment: .leading, spacing: AppSpace.xs) {
            // Phase indicator row
            HStack(spacing: 2) {
                ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                    let stepCount = stepsForPhase(phase).count
                    let isActive = index == currentIndex && isRunning
                    let isDone = index < currentIndex || (!isRunning && index <= currentIndex)

                    VStack(spacing: 2) {
                        HStack(spacing: AppSpace.xs) {
                            Image(systemName: isDone ? "checkmark.circle.fill" : phase.icon)
                                .font(.system(size: 8, weight: .semibold))
                            Text(phase.title)
                                .font(AppFont.tiny)
                            if stepCount > 0 {
                                Text("\(stepCount)")
                                    .font(.system(size: 7, weight: .medium))
                                    .foregroundStyle(TextGrade.ghost)
                            }
                        }
                        .foregroundStyle(index <= currentIndex ? Brand.primary : TextGrade.ghost)
                        .padding(.horizontal, AppSpace.sm)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                .fill(index <= currentIndex ? Brand.primary.opacity(0.12) : Color.clear)
                        )
                        .overlay(
                            isActive ?
                            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                .strokeBorder(Brand.primary.opacity(phasePulse ? 0.5 : 0.15), lineWidth: 0.7)
                                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: phasePulse)
                            : nil
                        )
                        .help(phaseTooltip(phase, stepCount: stepCount))

                        // Tool mini-badges
                        if stepCount > 0 {
                            let tools = uniqueToolNames(for: phase)
                            if !tools.isEmpty {
                                HStack(spacing: 2) {
                                    ForEach(tools.prefix(3), id: \.self) { tool in
                                        Text(shortToolName(tool))
                                            .font(.system(size: 7))
                                            .foregroundStyle(TextGrade.ghost)
                                            .padding(.horizontal, 3)
                                            .padding(.vertical, 1)
                                            .background(
                                                Capsule().fill(SurfaceGrade.sunken.opacity(0.5))
                                            )
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Overall progress bar
            GeometryReader { geo in
                let progress = Double(currentIndex + 1) / Double(phases.count)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(SurfaceGrade.sunken.opacity(0.4))
                        .frame(height: 3)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Brand.primary.opacity(0.6))
                        .frame(width: geo.size.width * CGFloat(isRunning ? progress - 0.05 : progress), height: 3)
                        .animation(.easeInOut(duration: 0.4), value: currentIndex)
                }
            }
            .frame(height: 3)
        }
        .onAppear { phasePulse = true }
    }

    private func uniqueToolNames(for phase: TaskPhase) -> [String] {
        let tools = Set(stepsForPhase(phase).compactMap { $0.toolName })
        return tools.sorted()
    }

    private func shortToolName(_ name: String) -> String {
        switch name {
        case "workspace.index": return "索引"
        case "file.read": return "读取"
        case "code.search": return "搜索"
        case "file.write": return "写入"
        case "file.edit": return "编辑"
        case "shell.exec": return "命令"
        case "verify.build": return "验证"
        case "git": return "Git"
        default: return String(name.prefix(4))
        }
    }

    private func stepsForPhase(_ phase: TaskPhase) -> [TaskStep] {
        switch phase {
        case .explore:
            return task.steps.filter { step in
                (step.kind == .toolCall && ["workspace.index", "file.read", "code.search", "git"].contains(step.toolName))
                || (step.kind == .toolResult && ["workspace.index", "file.read", "code.search", "git"].contains(step.toolName))
            }
        case .execute:
            return task.steps.filter { step in
                (step.kind == .toolCall && ["file.write", "file.edit", "shell.exec"].contains(step.toolName))
                || (step.kind == .reviewRequest)
            }
        case .verify:
            return task.steps.filter { step in
                step.kind == .aiThinking && step.text.hasPrefix("完成检查")
                || (step.kind == .toolCall && step.toolName == "verify.build")
                || (step.kind == .toolCall && step.toolName == "shell.exec" && step.toolParams?["command"]?.contains("test") == true)
            }
        case .summarize:
            return task.steps.filter { $0.kind == .textOutput || ($0.kind == .aiThinking && $0.text.hasPrefix("阶段总结")) }
        }
    }

    private func phaseTooltip(_ phase: TaskPhase, stepCount: Int) -> String {
        if stepCount == 0 { return "\(phase.title)阶段：暂无步骤" }
        let names = Array(Set(stepsForPhase(phase).compactMap { $0.toolName })).sorted()
        return "\(phase.title)阶段：\(stepCount) 步" + (names.isEmpty ? "" : "（\(names.joined(separator: "、"))）")
    }

    private func compactTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host else { return trimmed }
        let leaf = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return leaf.isEmpty ? host : "\(host)/\(leaf)"
    }

    private var summaryLine: String {
        var parts = ["\(task.status.label)", "\(completedSteps) 步"]
        if readCount > 0 { parts.append("读 \(readCount) 个文件") }
        if failureCount > 0 { parts.append("失败 \(failureCount) 项") }
        parts.append(RelativeTimeFormatter.string(for: task.updatedAt))
        return parts.joined(separator: " · ")
    }

    private var memoryPills: [String] {
        var pills: [String] = []
        let readFiles = uniqueValues(task.steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] })
        if let first = readFiles.first {
            let extra = readFiles.count > 1 ? " +\(readFiles.count - 1)" : ""
            pills.append("已读 \(shortPath(first))\(extra)")
        }

        if task.steps.contains(where: { $0.kind == .toolResult && $0.toolName == "workspace.index" && !$0.isFailure }) {
            pills.append("已有索引")
        }

        let failedTools = Dictionary(grouping: task.steps.filter { $0.kind == .toolResult && $0.isFailure }, by: { $0.toolName ?? "tool" })
            .map { "\($0.key) ×\($0.value.count)" }
            .sorted()
        if let first = failedTools.first {
            pills.append("失败 \(first)")
        }

        let searches = uniqueValues(task.steps
            .filter { $0.kind == .toolCall && $0.toolName == "code.search" }
            .compactMap { $0.toolParams?["query"] })
        if let first = searches.first {
            pills.append("搜过 \(String(first.prefix(18)))")
        }
        return pills
    }

    private func uniqueValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if parts.count <= 2 { return path }
        return parts.suffix(2).joined(separator: "/")
    }
}

// MARK: - Typing Indicator

private struct TypingIndicator: View {
    @EnvironmentObject private var store: AppStore
    @State private var phase: Int = 0
    @State private var elapsed: Int = 0

    private var activityText: String {
        let text = store.state.liveActivity
        return text.isEmpty ? "正在处理…" : text
    }

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            HStack(spacing: AppSpace.sm) {
                // Pulsing dot
                Circle()
                    .fill(Brand.primary)
                    .frame(width: 7, height: 7)
                    .scaleEffect(phase == 0 ? 1.0 : 0.7)
                    .opacity(phase == 0 ? 1.0 : 0.5)

                Text(activityText)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(1)
                    .animation(.easeInOut(duration: 0.2), value: activityText)

                if elapsed > 0 {
                    Text(elapsedLabel)
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                }
            }
            .padding(.horizontal, AppSpace.lg)
            .padding(.vertical, AppSpace.sm + 2)
            .background(
                Capsule()
                    .fill(SurfaceGrade.card)
                    .overlay(Capsule().strokeBorder(Brand.primary.opacity(0.12), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.10), radius: 6, y: 3)

            Spacer()
        }
        .onAppear {
            startPulse()
            startTimer()
        }
    }

    private var elapsedLabel: String {
        if elapsed < 60 { return "\(elapsed)s" }
        return "\(elapsed / 60)m\(elapsed % 60)s"
    }

    private func startPulse() {
        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                phase = phase == 0 ? 1 : 0
            }
        }
    }

    private func startTimer() {
        elapsed = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsed += 1
        }
    }
}

// TaskStepCard, UserInputCard, ThinkingCard, ToolCallCard, ToolResultCard,
// TextOutputCard, PausedCard, FailedCard, ReviewCard, ReviewResultCard,
// AvatarBadge, DiffPreviewCard, ProgressGlyph, ContinuationStrategyBar
// → TimelineCards.swift

// Step Cards → TimelineCards.swift
// WelcomeView → WelcomePage.swift

// MARK: - Batch Review Bar

struct BatchReviewBar: View {
    @EnvironmentObject private var store: AppStore
    let pendingCount: Int
    let taskID: UUID
    let stepIDs: [UUID]
    @State private var isApproving = false
    @State private var isRejecting = false

    var body: some View {
        HStack(spacing: AppSpace.md) {
            Image(systemName: "eye.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Semantic.warning)

            Text("\(pendingCount) 个变更待审查")
                .font(AppFont.subheadline)
                .foregroundStyle(TextGrade.primary)

            Spacer()

            Button {
                isApproving = true
                for stepID in stepIDs {
                    store.approveReview(taskID: taskID, stepID: stepID)
                }
                isApproving = false
            } label: {
                HStack(spacing: AppSpace.xs) {
                    if isApproving {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text("全部批准")
                        .font(AppFont.captionMedium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, AppSpace.lg)
                .padding(.vertical, AppSpace.sm + 2)
                .background(Capsule().fill(Semantic.success))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button {
                isRejecting = true
                for stepID in stepIDs {
                    store.rejectReview(taskID: taskID, stepID: stepID)
                }
                isRejecting = false
            } label: {
                HStack(spacing: AppSpace.xs) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("全部拒绝")
                        .font(AppFont.captionMedium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, AppSpace.lg)
                .padding(.vertical, AppSpace.sm + 2)
                .background(Capsule().fill(Semantic.error))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpace.lg)
        .padding(.vertical, AppSpace.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.30), radius: 16, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(Semantic.warning.opacity(0.30), lineWidth: 1)
        )
        .padding(.horizontal, AppSpace.xl)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.spring(response: 0.3), value: pendingCount)
    }
}

// MARK: - Task Completion Summary Card

private struct TaskCompletionSummaryCard: View {
    let task: AgentTask

    private var writtenFiles: [String] {
        let reviewApproved = task.steps.filter { $0.kind == .reviewRequest && $0.approved == true }
            .compactMap { $0.diffFilePath }
        let directWrites = task.steps.filter { $0.kind == .toolResult && $0.toolName == "file.write" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] }
        let edits = task.steps.filter { $0.kind == .toolResult && $0.toolName == "file.edit" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] }
        return Array(Set(reviewApproved + directWrites + edits)).sorted()
    }

    private var failedSteps: [TaskStep] {
        task.steps.filter { ($0.isFailure || $0.kind == .error) && $0.kind != .userInput }
    }

    private var shellCommands: [String] {
        task.steps.filter { $0.kind == .toolCall && $0.toolName == "shell.exec" }
            .compactMap { $0.toolParams?["command"] }
    }

    private var duration: String? {
        let interval = task.updatedAt.timeIntervalSince(task.createdAt)
        guard interval > 1 else { return nil }
        if interval < 60 { return "\(Int(interval))秒" }
        if interval < 3600 { return "\(Int(interval / 60))分\(Int(interval.truncatingRemainder(dividingBy: 60)))秒" }
        return "\(Int(interval / 3600))时\(Int((interval.truncatingRemainder(dividingBy: 3600)) / 60))分"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            // Header
            HStack(spacing: AppSpace.sm) {
                Image(systemName: task.status == .completed ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(task.status == .completed ? Semantic.success : Semantic.error)
                Text(task.status == .completed ? "任务完成" : "任务失败")
                    .font(AppFont.subheadline)
                    .foregroundStyle(task.status == .completed ? Semantic.success : Semantic.error)
                if let dur = duration {
                    Text("· \(dur)")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
                Spacer()
            }

            // Changed files
            if !writtenFiles.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    HStack(spacing: AppSpace.xs) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(TextGrade.secondary)
                        Text("变更文件（\(writtenFiles.count)）")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.secondary)
                    }
                    ForEach(writtenFiles.prefix(8), id: \.self) { path in
                        HStack(spacing: AppSpace.xs) {
                            Text("•")
                                .foregroundStyle(Brand.primary)
                            Text(shortPath(path))
                                .font(AppFont.caption)
                                .foregroundStyle(TextGrade.primary)
                                .lineLimit(1)
                        }
                    }
                    if writtenFiles.count > 8 {
                        Text("+\(writtenFiles.count - 8) 个文件…")
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)
                    }
                }
                .padding(AppSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(SurfaceGrade.sunken.opacity(0.5))
                )
            }

            // Failed items
            if !failedSteps.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    HStack(spacing: AppSpace.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Semantic.error)
                        Text("失败项（\(failedSteps.count)）")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(Semantic.error)
                    }
                    ForEach(failedSteps.prefix(5), id: \.id) { step in
                        HStack(spacing: AppSpace.xs) {
                            Text("•")
                                .foregroundStyle(Semantic.error)
                            Text(step.toolName ?? step.kind.title)
                                .font(AppFont.caption)
                                .foregroundStyle(TextGrade.primary)
                            if !step.text.isEmpty {
                                Text("— \(String(step.text.prefix(60)))")
                                    .font(AppFont.tiny)
                                    .foregroundStyle(TextGrade.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(AppSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(Semantic.errorMuted.opacity(0.5))
                )
            }

            // Shell commands summary
            if !shellCommands.isEmpty {
                HStack(spacing: AppSpace.xs) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(TextGrade.secondary)
                    Text("执行了 \(shellCommands.count) 条命令")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
            }
        }
        .padding(AppSpace.lg)
        .frame(maxWidth: 580, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(
                    task.status == .completed
                    ? Semantic.success.opacity(0.20)
                    : Semantic.error.opacity(0.20),
                    lineWidth: 0.7
                )
        )
    }

    private func shortPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count <= 2 { return path }
        return components.suffix(2).joined(separator: "/")
    }
}

// MARK: - Task Rating Bar

private struct TaskRatingBar: View {
    @EnvironmentObject private var store: AppStore
    let threadID: UUID
    let currentRating: Int

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            Text("评价此结果")
                .font(AppFont.caption)
                .foregroundStyle(TextGrade.muted)
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        store.rateThread(id: threadID, rating: star)
                    } label: {
                        Image(systemName: star <= currentRating ? "star.fill" : "star")
                            .font(.system(size: 13))
                            .foregroundStyle(star <= currentRating ? Color.yellow : TextGrade.muted.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            if currentRating > 0 {
                Text(ratingLabel)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, AppSpace.xs)
    }

    private var ratingLabel: String {
        switch currentRating {
        case 1: return "很差"
        case 2: return "不太好"
        case 3: return "一般"
        case 4: return "不错"
        case 5: return "很棒"
        default: return ""
        }
    }
}

// MARK: - Global Image Paste Monitor

/// Singleton that installs a single NSEvent local monitor to intercept ⌘V for image paste.
/// Using a class avoids SwiftUI @State issues with Any? and ensures the monitor persists.
final class PasteImageMonitor {
    static var monitor: Any?
    static weak var storeRef: AppStore?

    static func install(store: AppStore) {
        storeRef = store
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command),
                  !flags.contains(.shift),
                  !flags.contains(.control),
                  event.charactersIgnoringModifiers == "v" else { return event }

            let pb = NSPasteboard.general
            guard let pngData = extractPNG(from: pb) else { return event }

            guard let store = storeRef else { return event }
            let idx = store.state.draftImages.count + 1
            let attachment = ImageAttachment(
                data: pngData,
                mediaType: "image/png",
                thumbnailName: "图片 \(idx)"
            )
            store.addDraftImage(attachment)
            return nil  // consume the event, don't pass to text view
        }
    }

    private static func extractPNG(from pb: NSPasteboard) -> Data? {
        // 1) Raw PNG
        if let data = pb.data(forType: .png), !data.isEmpty { return data }
        // 2) TIFF → PNG
        if let tiffData = pb.data(forType: .tiff), !tiffData.isEmpty,
           let rep = NSBitmapImageRep(data: tiffData),
           let png = rep.representation(using: .png, properties: [:]) { return png }
        // 3) NSImage(pasteboard:) — catches ALL formats (JPEG, HEIC, WebP, etc.)
        if let image = NSImage(pasteboard: pb),
           let tiffData = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiffData),
           let png = rep.representation(using: .png, properties: [:]) { return png }
        return nil
    }
}
