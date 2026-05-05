import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Report Panel

struct ReportPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var reportType: ReportType = .daily
    @State private var reportContent: String = ""
    @State private var isGenerated = false

    enum ReportType: String, CaseIterable {
        case daily = "日报"
        case weekly = "周报"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            header
            typePicker
            if isGenerated {
                reportView
                actionBar
            } else {
                emptyState
            }

            Divider().padding(.vertical, AppSpace.sm)
            OutcomeStatsPanel()
        }
        .padding(AppSpace.lg)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Brand.primary)
            Text("报告")
                .font(AppFont.subheadline)
                .foregroundStyle(TextGrade.primary)
            Spacer()
        }
    }

    // MARK: - Type Picker

    private var typePicker: some View {
        HStack(spacing: AppSpace.sm) {
            ForEach(ReportType.allCases, id: \.rawValue) { type in
                Button {
                    reportType = type
                    isGenerated = false
                    reportContent = ""
                } label: {
                    Text(type.rawValue)
                        .font(AppFont.captionMedium)
                        .foregroundStyle(reportType == type ? .white : TextGrade.secondary)
                        .padding(.horizontal, AppSpace.lg)
                        .padding(.vertical, AppSpace.sm)
                        .background(
                            Capsule().fill(reportType == type ? Brand.primary : SurfaceGrade.elevated.opacity(0.72))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                reportType == type ? Color.clear : SurfaceGrade.hairline,
                                lineWidth: 0.6
                            )
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                generateReport()
            } label: {
                Label("生成", systemImage: "sparkles")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppSpace.lg)
                    .padding(.vertical, AppSpace.sm)
                    .background(Capsule().fill(Brand.primary))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: AppSpace.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(TextGrade.ghost)
            Text("点击「生成」查看\(reportType.rawValue)")
                .font(AppFont.caption)
                .foregroundStyle(TextGrade.muted)
            VStack(spacing: AppSpace.xs) {
                Text("包含：活动日志、文件变更汇总、Wiki 建议")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                Text(reportType == .daily ? "汇总今日的任务、对话、工具调用和文件变更" : "汇总本周活动 + 每日分解 + 知识沉淀建议")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpace.xxl)
    }

    // MARK: - Report View

    private var reportView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MarkdownText(reportContent, fontSize: 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(AppSpace.lg)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(SurfaceGrade.card.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(SurfaceGrade.hairline, lineWidth: 0.6)
            )
        }
        .frame(maxHeight: 400)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: AppSpace.sm) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reportContent, forType: .string)
                ToastCenter.shared.success("报告已复制")
            } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                    .padding(.horizontal, AppSpace.md)
                    .padding(.vertical, AppSpace.sm)
                    .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.78)))
                    .overlay(Capsule().strokeBorder(SurfaceGrade.divider, lineWidth: 0.7))
            }
            .buttonStyle(.plain)

            Button {
                generateReport()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                    .padding(.horizontal, AppSpace.md)
                    .padding(.vertical, AppSpace.sm)
                    .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.78)))
                    .overlay(Capsule().strokeBorder(SurfaceGrade.divider, lineWidth: 0.7))
            }
            .buttonStyle(.plain)

            Button {
                saveReportToVault()
            } label: {
                Label("存入 Wiki", systemImage: "book.closed")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(Brand.primary)
                    .padding(.horizontal, AppSpace.md)
                    .padding(.vertical, AppSpace.sm)
                    .background(Capsule().fill(Brand.primary.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(Brand.primary.opacity(0.2), lineWidth: 0.7))
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    // MARK: - Generate

    private func generateReport() {
        let threads = store.state.threads
        switch reportType {
        case .daily:
            reportContent = ReportGenerator.generateDailyReport(threads: threads)
        case .weekly:
            reportContent = ReportGenerator.generateWeeklyReport(threads: threads)
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            isGenerated = true
        }
    }

    private func saveReportToVault() {
        let vault = store.state.settings.vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vault.isEmpty else {
            ToastCenter.shared.error("请先在设置中配置 Vault 路径")
            return
        }
        let root = URL(fileURLWithPath: vault)
        let reportsDir = root.appendingPathComponent("04 Reports", isDirectory: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let fileName = reportType == .daily ? "日报-\(fmt.string(from: Date())).md" : "周报-\(fmt.string(from: Date())).md"
        let fileURL = reportsDir.appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
            try reportContent.write(to: fileURL, atomically: true, encoding: .utf8)
            ToastCenter.shared.success("已保存到 04 Reports/\(fileName)")
        } catch {
            ToastCenter.shared.error("保存失败：\(error.localizedDescription)")
        }
    }
}
