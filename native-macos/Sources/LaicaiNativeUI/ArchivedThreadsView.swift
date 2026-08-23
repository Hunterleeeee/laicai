import LaicaiNativeFoundation
import SwiftUI

struct ArchivedThreadsView: View {
    @EnvironmentObject private var store: AppStore
    let onRestore: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.large) {
            HStack {
                Text("归档会话")
                    .font(AppFont.title)
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("关闭归档会话")
            }

            let archived = store.state.threads
                .filter(\.isArchived)
                .sorted { $0.updatedAt > $1.updatedAt }
            if archived.isEmpty {
                ContentUnavailableView("暂无归档会话", systemImage: "archivebox")
            } else {
                ScrollView {
                    LazyVStack(spacing: AppSpace.small) {
                        ForEach(archived) { thread in
                            HStack(spacing: AppSpace.medium) {
                                Image(systemName: "archivebox.fill")
                                    .foregroundStyle(TextGrade.muted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(thread.title.isEmpty ? "无标题会话" : thread.title)
                                        .foregroundStyle(TextGrade.primary)
                                        .lineLimit(1)
                                    Text(thread.preview.isEmpty ? "暂无摘要" : thread.preview)
                                        .font(AppFont.caption)
                                        .foregroundStyle(TextGrade.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("恢复") {
                                    onRestore(thread.id)
                                    dismiss()
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("恢复会话：\(thread.title.isEmpty ? "无标题会话" : thread.title)")
                                .accessibilityHint("将会话移出归档并返回会话列表")
                            }
                            .padding(AppSpace.medium)
                            .background(SurfaceGrade.card)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                        }
                    }
                }
            }
        }
        .padding(AppSpace.extraLarge)
        .frame(minWidth: 520, minHeight: 360)
    }
}
