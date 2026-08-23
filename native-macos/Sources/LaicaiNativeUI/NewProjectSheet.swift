import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

// MARK: - New Project Sheet

struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var projectName = ""
    @State private var selectedPath = ""
    @State private var createNew = false
    @State private var newFolderName = ""

    var body: some View {
        VStack(spacing: AppSpace.large) {
            // Header
            HStack {
                Text("新建项目")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(TextGrade.ghost)
                }
                .buttonStyle(.plain)
            }

            // Project name
            VStack(alignment: .leading, spacing: 4) {
                Text("项目名称")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TextGrade.muted)
                TextField("例如：来财 macOS", text: $projectName)
                    .textFieldStyle(.roundedBorder)
            }

            // Mode toggle
            Picker("项目文件夹操作", selection: $createNew) {
                Text("选择已有文件夹").tag(false)
                Text("创建新文件夹").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityHint("选择使用已有文件夹或创建新文件夹")

            if createNew {
                // Create new folder
                VStack(alignment: .leading, spacing: 4) {
                    Text("文件夹名称")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TextGrade.muted)
                    TextField("例如：my-project", text: $newFolderName)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Text("将创建在：")
                            .font(.system(size: 10))
                            .foregroundStyle(TextGrade.ghost)
                        Text(targetNewPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(TextGrade.muted)
                            .lineLimit(1)
                    }

                    Button("选择父目录...") {
                        pickFolder { path in selectedPath = path }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Brand.primary)
                }
            } else {
                // Select existing
                VStack(alignment: .leading, spacing: 4) {
                    Text("项目文件夹")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TextGrade.muted)

                    HStack {
                        Text(selectedPath.isEmpty ? "未选择" : abbreviateHome(selectedPath))
                            .font(.system(size: 11))
                            .foregroundStyle(selectedPath.isEmpty ? TextGrade.ghost : TextGrade.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("选择文件夹...") {
                            pickFolder { path in
                                selectedPath = path
                                if projectName.isEmpty {
                                    projectName = URL(fileURLWithPath: path).lastPathComponent
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Brand.primary)
                    }
                    .padding(AppSpace.small)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(SurfaceGrade.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(SurfaceGrade.border.opacity(0.3), lineWidth: 0.5)
                    )
                }
            }

            Spacer()

            // Actions
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .foregroundStyle(TextGrade.muted)

                Spacer()

                Button {
                    createProject()
                    dismiss()
                } label: {
                    Text("创建项目")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppSpace.large)
                        .padding(.vertical, AppSpace.small)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                .fill(canCreate ? AnyShapeStyle(Brand.primary) : AnyShapeStyle(TextGrade.ghost))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("创建项目")
                .accessibilityHint(canCreate ? "创建并打开项目" : "请先填写项目名称和文件夹")
                .disabled(!canCreate)
            }
        }
        .padding(AppSpace.extraLarge)
        .frame(width: 420, height: 380)
        .background(SurfaceGrade.panel)
    }

    private var canCreate: Bool {
        if createNew {
            return !projectName.isEmpty && !newFolderName.isEmpty && !selectedPath.isEmpty
        } else {
            return !projectName.isEmpty && !selectedPath.isEmpty
        }
    }

    private var targetNewPath: String {
        guard !selectedPath.isEmpty, !newFolderName.isEmpty else { return "..." }
        return (selectedPath as NSString).appendingPathComponent(newFolderName)
    }

    @MainActor
    private func createProject() {
        let rootPath: String
        if createNew {
            rootPath = targetNewPath
            try? FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
        } else {
            rootPath = selectedPath
        }
        guard !rootPath.isEmpty else { return }
        let project = ProjectManager.shared.createProject(name: projectName, rootPath: rootPath)
        store.switchWorkspace(to: project.rootPath)
        store.newThreadInProject(project.id)
    }

    private func pickFolder(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
