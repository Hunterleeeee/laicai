import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Wiki Panel (Knowledge Base Browser + Generator)

struct WikiPanel: View {
    @EnvironmentObject private var store: AppStore

    // MARK: - State
    @State private var query = ""
    @State private var useWeb = false
    @State private var isRunning = false
    @State private var streamingText = ""

    enum Mode { case browse, viewing(VaultNote), generating }
    @State private var mode: Mode = .browse
    @State private var vaultNotes: [VaultNote] = []
    @State private var selectedNote: VaultNote?

    struct VaultNote: Identifiable, Hashable {
        let id: String // relative path
        let title: String
        let folder: String
        let modifiedAt: Date
        let sizeBytes: Int
        var content: String? = nil // lazy-loaded

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (lhs: VaultNote, rhs: VaultNote) -> Bool { lhs.id == rhs.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            wikiHeader
            Divider().opacity(0.3)
            wikiSearchBar.padding(.horizontal, AppSpace.md).padding(.top, AppSpace.sm)
            wikiOptionBar.padding(.horizontal, AppSpace.md).padding(.top, AppSpace.xs)

            switch mode {
            case .browse:
                wikiFileList
            case .viewing(let note):
                wikiNoteViewer(note)
            case .generating:
                wikiStreamingView
            }
        }
        .onAppear { scanVault() }
    }

    // MARK: - Header

    private var wikiHeader: some View {
        HStack(spacing: AppSpace.sm) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.primary)
            Text("知识库")
                .font(AppFont.subheadline)
                .foregroundStyle(TextGrade.primary)

            Spacer()

            Text("\(vaultNotes.count) 篇")
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.ghost)

            if case .viewing = mode {
                Button {
                    mode = .browse
                    selectedNote = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(TextGrade.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, AppSpace.sm)
    }

    // MARK: - Search bar (doubles as generator input)

    private var wikiSearchBar: some View {
        HStack(spacing: AppSpace.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(TextGrade.ghost)

            TextField("搜索或输入新主题…", text: $query)
                .textFieldStyle(.plain)
                .font(AppFont.body)
                .onSubmit { handleSubmit() }

            if isRunning {
                ProgressView().controlSize(.small)
            } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { handleSubmit() } label: {
                    Image(systemName: hasExactMatch ? "magnifyingglass" : "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)
                .help(hasExactMatch ? "搜索" : "生成并保存新知识页")
            }
        }
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(SurfaceGrade.hairline, lineWidth: 0.75)
        )
    }

    // MARK: - Option bar

    private var wikiOptionBar: some View {
        HStack(spacing: AppSpace.sm) {
            wikiPill(label: "联网", icon: "globe", isOn: $useWeb)

            Spacer()

            Button {
                let root = URL(fileURLWithPath: vaultRoot)
                NSWorkspace.shared.open(root)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(vaultLabel)
                        .font(AppFont.tiny)
                }
                .foregroundStyle(TextGrade.ghost)
            }
            .buttonStyle(.plain)
            .help("在 Finder 中打开 Vault")

            Button { scanVault() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(TextGrade.ghost)
            }
            .buttonStyle(.plain)
            .help("刷新")
        }
    }

    // MARK: - File list (browse mode)

    private var wikiFileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if filteredNotes.isEmpty {
                    wikiEmptyState
                } else {
                    // Group by folder
                    let grouped = Dictionary(grouping: filteredNotes, by: \.folder)
                    let sortedFolders = grouped.keys.sorted()

                    ForEach(sortedFolders, id: \.self) { folder in
                        if !folder.isEmpty {
                            Text(folder)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(TextGrade.ghost)
                                .textCase(.uppercase)
                                .padding(.horizontal, AppSpace.sm)
                                .padding(.top, AppSpace.md)
                                .padding(.bottom, 2)
                        }

                        ForEach(grouped[folder] ?? []) { note in
                            wikiNoteRow(note)
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpace.sm)
            .padding(.vertical, AppSpace.sm)
        }
    }

    private func wikiNoteRow(_ note: VaultNote) -> some View {
        Button {
            loadAndViewNote(note)
        } label: {
            HStack(spacing: AppSpace.sm) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(TextGrade.muted)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(note.title)
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                    Text(RelativeTimeFormatter.string(for: note.modifiedAt) + " · \(ByteCountFormatter.string(fromByteCount: Int64(note.sizeBytes), countStyle: .file))")
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, AppSpace.sm)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .fill(selectedNote == note ? Brand.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                let url = URL(fileURLWithPath: vaultRoot).appendingPathComponent(note.id)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: { Label("在 Finder 中显示", systemImage: "folder") }

            Button {
                query = note.title
                generateAndSave()
            } label: { Label("用 AI 更新此页", systemImage: "arrow.triangle.2.circlepath") }

            Button {
                let url = URL(fileURLWithPath: vaultRoot).appendingPathComponent(note.id)
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    ToastCenter.shared.success("已复制")
                }
            } label: { Label("复制内容", systemImage: "doc.on.doc") }
        }
    }

    // MARK: - Note viewer

    private func wikiNoteViewer(_ note: VaultNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack(spacing: AppSpace.sm) {
                Text(note.title)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.content ?? "", forType: .string)
                    ToastCenter.shared.success("已复制")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TextGrade.muted)

                Button {
                    query = note.title
                    generateAndSave()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9))
                        Text("AI 更新")
                            .font(AppFont.tiny)
                    }
                    .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)

                Button {
                    let url = URL(fileURLWithPath: vaultRoot).appendingPathComponent(note.id)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TextGrade.muted)
            }
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.sm)

            Divider().opacity(0.2)

            // Content
            ScrollView {
                if let content = note.content {
                    MarkdownText(Self.stripFrontmatter(content), fontSize: 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppSpace.md)
                } else {
                    ProgressView()
                        .padding()
                }
            }
        }
    }

    // MARK: - Streaming (generation in progress)

    private var wikiStreamingView: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            HStack(spacing: AppSpace.xs) {
                ProgressView().controlSize(.mini)
                Text("正在生成… (\(streamingText.count) 字)")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                Spacer()
            }
            .padding(.horizontal, AppSpace.md)
            .padding(.top, AppSpace.sm)

            ScrollView {
                Text(streamingText)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppSpace.md)
            }
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(SurfaceGrade.card)
            )
            .padding(.horizontal, AppSpace.sm)
        }
    }

    // MARK: - Empty state

    private var wikiEmptyState: some View {
        VStack(spacing: AppSpace.md) {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: "book.closed")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(TextGrade.ghost)
                Text("Vault 中暂无 .md 文件")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                Text("输入主题后回车，AI 生成并直接保存")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
            } else {
                Image(systemName: "plus.circle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Brand.primary.opacity(0.6))
                Text("未找到「\(query)」")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                Button {
                    generateAndSave()
                } label: {
                    Text("用 AI 生成此主题 →")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpace.xl)
    }

    // MARK: - Pill toggle

    private func wikiPill(label: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
                Text(label).font(AppFont.tiny)
            }
            .foregroundStyle(isOn.wrappedValue ? Brand.primary : TextGrade.muted)
            .padding(.horizontal, AppSpace.sm)
            .padding(.vertical, 3)
            .background(Capsule().fill(isOn.wrappedValue ? Brand.primary.opacity(0.12) : SurfaceGrade.elevated.opacity(0.5)))
            .overlay(Capsule().strokeBorder(isOn.wrappedValue ? Brand.primary.opacity(0.3) : Color.clear, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var vaultRoot: String {
        let clean = store.state.settings.vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? store.state.settings.workspacePath : clean
    }

    private var vaultLabel: String { URL(fileURLWithPath: vaultRoot).lastPathComponent }

    private var hasExactMatch: Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return vaultNotes.contains { $0.title.lowercased() == q }
    }

    private var filteredNotes: [VaultNote] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return vaultNotes }
        let terms = q.split(separator: " ").map(String.init)
        return vaultNotes.filter { note in
            let hay = (note.title + " " + note.folder).lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    private static func stripFrontmatter(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return trimmed }
        let parts = trimmed.components(separatedBy: "---")
        guard parts.count >= 3 else { return trimmed }
        return parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Actions

    private func handleSubmit() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        // If there's a match, open it; otherwise generate
        if let match = filteredNotes.first {
            loadAndViewNote(match)
        } else {
            generateAndSave()
        }
    }

    private func loadAndViewNote(_ note: VaultNote) {
        var n = note
        if n.content == nil {
            let url = URL(fileURLWithPath: vaultRoot).appendingPathComponent(note.id)
            n.content = try? String(contentsOf: url, encoding: .utf8)
        }
        selectedNote = n
        mode = .viewing(n)
    }

    private func scanVault() {
        let root = URL(fileURLWithPath: vaultRoot)
        guard FileManager.default.fileExists(atPath: root.path) else { vaultNotes = []; return }

        Task.detached(priority: .userInitiated) {
            var notes: [VaultNote] = []
            guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return }
            while let file = enumerator.nextObject() as? String {
                if file.hasPrefix(".") || file.contains("/.") || file.contains("node_modules") {
                    enumerator.skipDescendants()
                    continue
                }
                guard file.hasSuffix(".md") else { continue }
                let url = root.appendingPathComponent(file)
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let modified = attrs?[.modificationDate] as? Date ?? Date.distantPast
                let size = attrs?[.size] as? Int ?? 0

                let pathURL = URL(fileURLWithPath: file)
                let folder = pathURL.deletingLastPathComponent().path
                let title = pathURL.deletingPathExtension().lastPathComponent

                notes.append(VaultNote(id: file, title: title, folder: folder == "." ? "" : folder, modifiedAt: modified, sizeBytes: size))
            }
            notes.sort { $0.modifiedAt > $1.modifiedAt }
            let scannedNotes = notes
            Task { @MainActor in vaultNotes = scannedNotes }
        }
    }

    private func generateAndSave() {
        let cleanTopic = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTopic.isEmpty, !isRunning else { return }
        isRunning = true
        streamingText = ""
        mode = .generating

        Task {
            let built = await store.buildWikiTopic(
                topic: cleanTopic,
                vaultRoot: vaultRoot,
                save: true,
                useWeb: useWeb,
                onChunk: { chunk in self.streamingText += chunk }
            )
            await MainActor.run {
                isRunning = false
                streamingText = ""
                ToastCenter.shared.success("已保存：\(built.notePath)")
                // Refresh vault and show the new note
                scanVault()
                let note = VaultNote(
                    id: built.notePath,
                    title: built.topic,
                    folder: URL(fileURLWithPath: built.notePath).deletingLastPathComponent().path,
                    modifiedAt: Date(),
                    sizeBytes: built.renderedMarkdown.utf8.count,
                    content: built.renderedMarkdown
                )
                selectedNote = note
                mode = .viewing(note)
            }
        }
    }
}

private struct WikiSourceRow: View {
    let source: WikiSource

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.sm) {
            Image(systemName: source.kind == "web" ? "globe" : "doc.text")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Brand.primary)
                .frame(width: 12)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                Text(source.path)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                    .lineLimit(1)
                if !source.preview.isEmpty {
                    Text(source.preview)
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.muted)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Pipeline Status Card

struct PipelineStatusCard: View {
    let pipeline: SkillPipeline
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            HStack(spacing: AppSpace.sm) {
                Image(systemName: "arrow.forward.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Semantic.toolRunning)
                Text(pipeline.name)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                Spacer()
                Button { onCancel() } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Semantic.error)
                }
                .buttonStyle(.plain)
                .help("取消管道")
            }

            ForEach(pipeline.steps) { step in
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: stepIcon(step.status))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(stepColor(step.status))
                        .frame(width: 14)
                    Text(step.skillName)
                        .font(AppFont.tiny)
                        .foregroundStyle(step.status == .running ? TextGrade.primary : TextGrade.muted)
                        .lineLimit(1)
                    Spacer()
                    if step.status == .running {
                        ProgressView().controlSize(.mini)
                    } else if step.status == .completed, let output = step.output {
                        Text(String(output.prefix(30)))
                            .font(AppFont.codeSmall)
                            .foregroundStyle(TextGrade.ghost)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(AppSpace.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Semantic.toolRunning.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(Semantic.toolRunning.opacity(0.2), lineWidth: 0.75)
        )
    }

    private func stepIcon(_ status: PipelineStepStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .running: return "circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "arrow.right.circle"
        }
    }

    private func stepColor(_ status: PipelineStepStatus) -> Color {
        switch status {
        case .pending: return TextGrade.ghost
        case .running: return Semantic.toolRunning
        case .completed: return Semantic.success
        case .failed: return Semantic.error
        case .skipped: return TextGrade.muted
        }
    }
}

struct PipelineHistoryRow: View {
    let pipeline: SkillPipeline

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            Image(systemName: pipeline.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(pipeline.status == .completed ? Semantic.success : Semantic.error)
            VStack(alignment: .leading, spacing: 1) {
                Text(pipeline.name)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                Text("\(pipeline.steps.count) 步 · \(pipeline.steps.filter { $0.status == .completed }.count) 完成")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
            }
            Spacer()
            if let completed = pipeline.completedAt {
                Text(RelativeTimeFormatter.string(for: completed))
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
            }
        }
        .padding(.vertical, AppSpace.xs)
    }
}
