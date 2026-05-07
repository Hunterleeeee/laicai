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
            store.newSession()
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
                if let thread = store.state.selectedThread {
                    HStack(spacing: AppSpace.sm) {
                        if let task = store.state.selectedTask {
                            Circle()
                                .fill(task.status.color)
                                .frame(width: 6, height: 6)
                        }
                        Text(thread.shortID)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(TextGrade.ghost)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(SurfaceGrade.card.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(TextHelper.compactTitle(thread.title))
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(thread.source == .task ? TextGrade.primary : TextGrade.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 300, alignment: .leading)
                        if let task = store.state.selectedTask {
                            statusBadge(for: task.status)
                        }
                    }
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
                    // Left: skill picker
                    HStack(spacing: AppSpace.xs) {
                        modeIndicator
                        skillPickerMenu
                    }

                    Spacer()

                    // Right: attach + send
                    HStack(spacing: AppSpace.sm) {
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

    private var modeIndicator: some View {
        HStack(spacing: AppSpace.xs) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .medium))
            Text(store.state.modeLabel.isEmpty ? "自动" : store.state.modeLabel)
                .font(AppFont.captionMedium)
        }
        .foregroundStyle(TextGrade.muted)
        .padding(.horizontal, AppSpace.sm + 2)
        .frame(height: 28)
        .background(
            Capsule()
                .fill(TextGrade.muted.opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(TextGrade.muted.opacity(0.28), lineWidth: 0.8)
        )
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
        let base = "输入问题或目标…"
        if let task = store.state.selectedTask {
            switch task.status {
            case .cancelled: return "继续处理，或输入新的处理方式…"
            case .failed: return "描述如何处理失败，或直接重试…"
            case .waitingReview: return "审查完成后继续…"
            case .running: return "追加指令或等待完成…"
            default: break
            }
        }
        return "\(base)    ⌘K 命令面板"
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
        return store.state.selectedSession == nil ? "新会话" : "会话"
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
