import AppKit
import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI
import UniformTypeIdentifiers

private struct ChatIntentModeLabel {
    let text: String
    let icon: String
    let color: Color
}

struct ChatDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showingSettings: Bool
    @ObservedObject private var skillRegistry = SkillRegistry.shared

    @State private var composerFocused = false
    @State private var composerTextHeight: CGFloat = 28
    @State private var gaugeTokens: Int = 0
    @State private var gaugePct: Double = 0
    @State private var gaugeLastThread: UUID?
    @State private var localDraftMessage = ""
    @State private var predictedIntent: UserIntent = .chat
    @State private var intentClassificationTask: Task<Void, Never>?
    @State private var lastPublishedDraftMessage = ""
    @State private var lastLocalDraftEditAt = Date.distantPast

    private var intentModeLabel: ChatIntentModeLabel {
        switch predictedIntent {
        case .chat: return ChatIntentModeLabel(text: "问答", icon: "bubble.left.and.bubble.right", color: .blue)
        case .research: return ChatIntentModeLabel(text: "研究", icon: "magnifyingglass", color: .purple)
        case .task: return ChatIntentModeLabel(text: "执行", icon: "hammer", color: .orange)
        case .workflow: return ChatIntentModeLabel(text: "工作流", icon: "arrow.triangle.branch", color: .green)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            composer
        }
        .background(SurfaceGrade.base)
        .onAppear {
            syncLocalDraftFromStore(force: true)
        }
        .onDisappear {
            intentClassificationTask?.cancel()
        }
        .onChange(of: store.state.draftMessage) {
            syncLocalDraftFromStore(force: false)
        }
        .onChange(of: store.state.selectedThreadID) {
            syncLocalDraftFromStore(force: true)
        }
        .onChange(of: store.composerFocusEpoch) { _, _ in
            composerFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .laicaiNewThread)) { _ in
            store.newThread()
            composerFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .laicaiContinueLastTask)) { _ in
            if let agent = store.state.continuableAgents.first {
                store.selectThread(id: agent.id)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let thread = store.state.selectedThread, shouldShowTimeline(for: thread) {
            ThreadTimelineView(
                thread: thread,
                generationPresentation: store.generationPresentation,
                streamPresentation: store.streamPresentation,
                connectors: store.state.connectors,
                activeConnectorID: store.state.activeConnectorID,
                workspaceRoot: store.state.settings.workspacePath,
                userRating: thread.userRating,
                showsDebugPanels: store.state.settings.showDebugPanels,
                onPlanChange: { store.updateMultiAgentPlan($0, for: thread.id) },
                onExecutePlan: { store.executeEditedPlan(threadID: thread.id) },
                onCancelPlan: { store.cancelMultiAgentPlan(for: thread.id) },
                onResumePlan: { store.resumeFailedPlan(threadID: thread.id) }
            )
            .id("\(thread.id)")
        } else {
            WelcomeView(showingSettings: $showingSettings)
        }
    }

    private var selectedThreadIsGenerating: Bool {
        store.selectedThreadIsGenerating
    }

    private func shouldShowTimeline(for thread: Thread) -> Bool {
        if !thread.steps.isEmpty { return true }
        if thread.status == .running || thread.executionState == .running { return true }
        if selectedThreadIsGenerating, thread.id == store.state.selectedThreadID { return true }
        if thread.multiAgentPlan != nil { return true }
        // Keep the selected empty conversation in the stable timeline shell.
        // The first send then updates the existing surface instead of swapping
        // WelcomeView and timeline in the same frame, which caused a white flash.
        return thread.id == store.state.selectedThreadID
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: AppSpace.small) {
            if !store.state.draftAttachments.isEmpty {
                attachmentChips
            }
            if !store.state.draftImages.isEmpty {
                imagePreviewStrip
            }

            VStack(alignment: .leading, spacing: 0) {
                ComposerTextView(
                    text: Binding(
                        get: { localDraftMessage },
                        set: { newValue in
                            updateLocalDraft(newValue)
                        }
                    ),
                    placeholder: composerPlaceholder,
                    onSend: {
                        submitLocalDraft()
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
                    isFocused: $composerFocused,
                    measuredHeight: $composerTextHeight
                )
                .frame(height: max(52, composerTextHeight), alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .clipped()
                // Typing stays enabled without a connector — the send path and
                // the status bar below guide users to connect instead of
                // blocking input outright.
                .opacity(store.state.activeConnector == nil ? 0.75 : 1)

                HStack(alignment: .center, spacing: AppSpace.small) {
                    attachImageButton
                    attachFileButton
                    skillPickerMenu
                    contextGauge

                    // Intent mode label
                    if !localDraftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let mode = intentModeLabel
                        HStack(spacing: 3) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 9, weight: .semibold))
                            Text(mode.text)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(mode.color)
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .background(Capsule().fill(mode.color.opacity(0.10)))
                        .overlay(Capsule().strokeBorder(mode.color.opacity(0.22), lineWidth: 0.6))
                        .help("当前意图模式：\(mode.text)")
                    }

                    Spacer(minLength: AppSpace.small)

                    if selectedThreadIsGenerating {
                        appendInstructionButton
                    } else {
                        sendButton
                    }
                }
                .padding(.top, AppSpace.small)
            }
            .padding(.horizontal, AppSpace.large)
            .padding(.top, AppSpace.medium + 2)
            .padding(.bottom, AppSpace.small + 2)
            .background(
                RoundedRectangle(cornerRadius: LayoutConst.composerCornerRadius, style: .continuous)
                    .fill(SurfaceGrade.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LayoutConst.composerCornerRadius, style: .continuous)
                    .strokeBorder(
                        composerFocused ? Brand.primary.opacity(0.54) : SurfaceGrade.border.opacity(0.72),
                        lineWidth: composerFocused ? 1.1 : 0.7
                    )
            )
            .shadow(color: Color.black.opacity(0.10), radius: 24, y: 10)

            if store.state.activeConnector == nil || store.hasRunningGenerationTasks {
                composerStatusBar
            }
        }
        .frame(maxWidth: LayoutConst.composerMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppSpace.extraLarge)
        .padding(.top, AppSpace.extraSmall)
        .padding(.bottom, AppSpace.extraLarge)
        .background(
            LinearGradient(
                colors: [
                    SurfaceGrade.base.opacity(0.0),
                    SurfaceGrade.base.opacity(0.82),
                    SurfaceGrade.base,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var paths = Array<String?>(repeating: nil, count: providers.count)
            let pathsLock = NSLock()
            let group = DispatchGroup()
            for (index, provider) in providers.enumerated() {
                group.enter()
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                    defer { group.leave() }
                    let path: String?
                    if let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        path = url.path
                    } else if let url = data as? URL {
                        path = url.path
                    } else {
                        path = nil
                    }
                    pathsLock.lock()
                    paths[index] = path
                    pathsLock.unlock()
                }
            }
            group.notify(queue: .main) {
                let resolvedPaths = paths.compactMap { $0 }
                if !resolvedPaths.isEmpty {
                    store.addDraftAttachments(resolvedPaths)
                    composerFocused = true
                }
            }
            return true
        }
    }

    private var composerStatusBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpace.small) {
                if store.state.activeConnector == nil {
                    composerChip(icon: "exclamationmark.triangle", text: "未连接模型", tone: .warning)
                    Button {
                        showingSettings = true
                    } label: {
                        HStack(spacing: AppSpace.extraSmall) {
                            Image(systemName: "link")
                                .font(.system(size: 10, weight: .semibold))
                            Text("去连接")
                                .font(AppFont.tiny)
                        }
                        .foregroundStyle(Brand.primary)
                        .padding(.horizontal, AppSpace.small + 1)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Brand.primary.opacity(0.10)))
                        .overlay(Capsule().strokeBorder(Brand.primary.opacity(0.22), lineWidth: 0.6))
                    }
                    .buttonStyle(.plain)
                }
                if selectedThreadIsGenerating {
                    composerChip(icon: "plus.bubble", text: "追加指令", tone: .active)
                    if let thread = store.state.selectedThread {
                        composerChip(icon: "target", text: TextHelper.compactTitle(thread.title), tone: .neutral)
                    }
                } else if store.hasRunningGenerationTasks {
                    composerChip(icon: "waveform.path.ecg", text: "后台会话运行中", tone: .active)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TextGrade.muted)
                .padding(.horizontal, AppSpace.small)
                .frame(height: 24)
                .background(
                    Capsule()
                        .fill(SurfaceGrade.elevated)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(SurfaceGrade.hairline, lineWidth: 0.6)
                )
                .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("技能快捷入口")
    }

    @ViewBuilder
    private var contextGauge: some View {
        if gaugeTokens > 0 {
            let color: Color = gaugePct < 0.5 ? Semantic.success : (gaugePct < 0.8 ? Semantic.warning : Semantic.error)
            let label = gaugeTokens >= 1000 ? "\(gaugeTokens / 1000)k" : "\(gaugeTokens)"

            HStack(spacing: 3) {
                ZStack {
                    Circle()
                        .stroke(color.opacity(0.18), lineWidth: 2)
                        .frame(width: 11, height: 11)
                    Circle()
                        .trim(from: 0, to: gaugePct)
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 11, height: 11)
                        .rotationEffect(.degrees(-90))
                }
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.6))
            .help("当前会话 已用 \(gaugeTokens.formatted()) token · 约占模型窗口 \(Int(gaugePct * 100))%")
            .onAppear { refreshGauge() }
            .onChange(of: store.state.selectedThread?.id) { _, _ in refreshGauge() }
            .onChange(of: selectedThreadIsGenerating) { _, gen in if !gen { refreshGauge() } }
        } else {
            Color.clear.frame(width: 0, height: 0)
                .onAppear { refreshGauge() }
                .onChange(of: store.state.selectedThread?.id) { _, _ in refreshGauge() }
                .onChange(of: selectedThreadIsGenerating) { _, gen in if !gen { refreshGauge() } }
        }
    }

    private func refreshGauge() {
        let threadID = store.state.selectedThread?.id.uuidString ?? ""
        guard !threadID.isEmpty else {
            gaugeTokens = 0
            gaugePct = 0
            return
        }
        let connMode = store.state.settings.contextMode
        let conn = store.state.activeConnector
        DispatchQueue.global(qos: .utility).async {
            let usage = UsageTracker.shared.threadUsage(threadID: threadID)
            let total = usage.inputTokens + usage.outputTokens
            let contextWindow: Int = {
                if let connector = conn {
                    return max(128_000, ConnectorCapabilityProfile.infer(for: connector, mode: connMode).contextWindow)
                }
                return 128_000
            }()
            let pct = min(1.0, Double(usage.inputTokens) / Double(contextWindow))
            DispatchQueue.main.async {
                gaugeTokens = total
                gaugePct = pct
            }
        }
    }

    private func applySkillTemplate(_ skill: SkillDefinition) {
        var template = ""
        if let workflow = skill.workflowName {
            template = "请执行\(workflow)工作流"
        } else if !skill.tools.isEmpty {
            template = "请使用\(skill.tools.joined(separator: "、"))处理以下目标："
        }
        if !template.isEmpty {
            setLocalDraft(template, publishImmediately: true)
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
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(SurfaceGrade.elevated)
                )
                .overlay(Circle().strokeBorder(SurfaceGrade.hairline, lineWidth: 0.6))
                .contentShape(Circle())
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
            HStack(spacing: AppSpace.small) {
                ForEach(store.state.draftImages) { img in
                    DraftImageThumbnail(
                        data: img.data,
                        onRemove: { store.removeDraftImage(id: img.id) }
                    )
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
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(SurfaceGrade.elevated)
                )
                .overlay(Circle().strokeBorder(SurfaceGrade.hairline, lineWidth: 0.6))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("添加附件")
    }

    private func composerChip(icon: String, text: String, tone: ComposerChipTone = .neutral) -> some View {
        HStack(spacing: AppSpace.extraSmall) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(AppFont.tiny)
                .lineLimit(1)
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, AppSpace.small + 1)
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

    private var sendButton: some View {
        Button {
            submitLocalDraft()
        } label: {
            Group {
                if selectedThreadIsGenerating {
                    ZStack {
                        Circle()
                            .fill(hasPendingFollowUp ? Brand.primary.opacity(0.22) : SurfaceGrade.elevated)
                            .frame(width: 27, height: 27)
                            .overlay(
                                Circle().strokeBorder(
                                    hasPendingFollowUp ? Brand.primary.opacity(0.40) : SurfaceGrade.border.opacity(0.45), lineWidth: 0.7)
                            )
                        Image(systemName: "plus.bubble.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(hasPendingFollowUp ? Brand.primary : TextGrade.ghost)
                    }
                } else {
                    ZStack {
                        Circle()
                            .fill(canSend ? AnyShapeStyle(Brand.primary) : AnyShapeStyle(SurfaceGrade.sunken))
                            .frame(width: 27, height: 27)

                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(canSend ? .white : TextGrade.ghost)
                    }
                    .shadow(color: canSend ? Brand.primary.opacity(0.30) : .clear, radius: 6, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(selectedThreadIsGenerating ? !hasPendingFollowUp : !canSend)
        .accessibilityLabel(selectedThreadIsGenerating ? "追加指令" : "发送")
        .accessibilityHint(selectedThreadIsGenerating ? (hasPendingFollowUp ? "将指令加入当前运行会话" : "请输入要追加的内容") : (canSend ? "发送当前消息" : "请输入内容后发送"))
        .help(selectedThreadIsGenerating ? (hasPendingFollowUp ? "追加指令 (↵)" : "输入要追加的指令") : (canSend ? "发送 (↵)" : "输入内容后发送"))
    }

    private var canSend: Bool {
        let hasText =
            !localDraftMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return (hasText || !store.state.draftAttachments.isEmpty || !store.state.draftImages.isEmpty) && store.state.activeConnector != nil
    }

    private var hasPendingFollowUp: Bool {
        !localDraftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var appendInstructionButton: some View {
        Button {
            submitLocalDraft()
        } label: {
            HStack(spacing: AppSpace.extraSmall) {
                Image(systemName: "plus.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("追加")
                    .font(AppFont.captionMedium)
            }
            .foregroundStyle(hasPendingFollowUp ? .white : TextGrade.ghost)
            .padding(.horizontal, AppSpace.medium)
            .padding(.vertical, AppSpace.small)
            .background(
                Capsule()
                    .fill(hasPendingFollowUp ? Brand.primary : SurfaceGrade.sunken)
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasPendingFollowUp)
        .accessibilityLabel("追加指令")
        .accessibilityHint(hasPendingFollowUp ? "将指令加入当前运行会话" : "请输入要追加的内容")
        .help(hasPendingFollowUp ? "追加指令 (↵)" : "输入要追加的指令")
    }

    private var composerPlaceholder: String {
        if store.state.activeConnector == nil { return "先连接模型…" }
        let base = "输入问题或目标…"
        if selectedThreadIsGenerating { return "补充一句，让它调整方向…" }
        if let agent = store.state.selectedThread, agent.canContinue {
            switch agent.status {
            case .cancelled: return "继续处理，或输入新的处理方式…"
            case .failed: return "描述如何处理失败，或直接重试…"
            case .waitingReview: return "审查完成后继续…"
            case .running: return "追加指令或等待完成…"
            default: break
            }
        }
        return "\(base)  ⌘K"
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
            HStack(spacing: AppSpace.small) {
                ForEach(store.state.draftAttachments, id: \.self) { path in
                    DraftAttachmentChip(
                        path: path,
                        onRemove: { store.removeDraftAttachment(path) }
                    )
                    .help(path)
                }
            }
        }
    }

    private func updateLocalDraft(_ value: String) {
        guard localDraftMessage != value else { return }
        lastLocalDraftEditAt = Date()
        localDraftMessage = value
        scheduleIntentClassification(value)
    }

    private func setLocalDraft(_ value: String, publishImmediately: Bool) {
        localDraftMessage = value
        scheduleIntentClassification(value)
        if publishImmediately {
            syncDraftImmediately()
        } else {
            lastPublishedDraftMessage = value
        }
    }

    private func syncLocalDraftFromStore(force: Bool) {
        let storeDraft = store.state.draftMessage
        defer { lastPublishedDraftMessage = storeDraft }
        guard force || localDraftMessage != storeDraft else { return }
        guard force || storeDraft != lastPublishedDraftMessage else { return }
        let isActivelyEditing =
            composerFocused
            && Date().timeIntervalSince(lastLocalDraftEditAt) < 1.2
        guard force || !isActivelyEditing else { return }
        localDraftMessage = storeDraft
        scheduleIntentClassification(storeDraft)
    }

    private func syncDraftImmediately() {
        if store.state.draftMessage != localDraftMessage {
            store.updateDraft(localDraftMessage)
        }
        lastPublishedDraftMessage = localDraftMessage
    }

    private func scheduleIntentClassification(_ value: String) {
        intentClassificationTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            predictedIntent = .chat
            return
        }
        intentClassificationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            predictedIntent = IntentRouter.classify(trimmed)
        }
    }

    private func submitLocalDraft() {
        syncDraftImmediately()
        if selectedThreadIsGenerating {
            store.submitFollowUp()
        } else {
            store.sendDraft()
        }
        setLocalDraft(store.state.draftMessage, publishImmediately: false)
    }

}

/// Attachment chip with filesystem metadata resolved once per path in a
/// cancellable task instead of on every body evaluation.
private struct DraftAttachmentChip: View {
    let path: String
    let onRemove: () -> Void

    @State private var isDir = false
    @State private var hint = ""

    var body: some View {
        HStack(spacing: AppSpace.extraSmall + 1) {
            Image(systemName: isDir ? "folder.fill" : "doc.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isDir ? Brand.primary : TextGrade.muted)
            VStack(alignment: .leading, spacing: 0) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                if isDir && !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                        .lineLimit(1)
                }
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(TextGrade.ghost)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, AppSpace.small)
        .padding(.trailing, AppSpace.extraSmall + 2)
        .padding(.vertical, AppSpace.extraSmall + 1)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(isDir ? Brand.primary.opacity(0.2) : SurfaceGrade.border.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: 200)
        .task(id: path) {
            var isDirectoryObjC: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectoryObjC)
            isDir = exists && isDirectoryObjC.boolValue
            guard isDir else {
                hint = ""
                return
            }
            let url = URL(fileURLWithPath: path)
            let count = (try? FileManager.default.contentsOfDirectory(atPath: path).count) ?? 0
            let parent = url.deletingLastPathComponent().lastPathComponent
            hint = count > 0 ? "\(count) 项 · \(parent)" : parent
        }
    }
}

/// Draft image thumbnail decoded once per attachment (off the main thread,
/// downsampled via ImageIO) instead of a full NSImage decode per body eval.
private struct DraftImageThumbnail: View {
    let data: Data
    let onRemove: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let nsImage = thumbnail {
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

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .background(Circle().fill(Color.black.opacity(0.6)).frame(width: 16, height: 16))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
        .task(id: data) {
            let source = data
            let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let imageSource = CGImageSourceCreateWithData(source as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                    let cgImage = CGImageSourceCreateThumbnailAtIndex(
                        imageSource, 0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceThumbnailMaxPixelSize: 160,
                        ] as CFDictionary)
                else { return nil }
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }.value
            thumbnail = image
        }
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
