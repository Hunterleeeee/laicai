import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

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
        VStack(alignment: .leading, spacing: AppSpace.large) {
            reportOverview
            typePicker
            if isGenerated {
                reportView
                actionBar
            } else {
                emptyState
            }

            Rectangle()
                .fill(SurfaceGrade.divider.opacity(0.6))
                .frame(height: 0.7)
            OutcomeStatsPanel()
        }
    }

    // MARK: - Header

    private var reportOverview: some View {
        workbenchHeroCard(
            icon: "chart.bar.doc.horizontal",
            title: "报告",
            subtitle: reportType == .daily ? "汇总今天的进展与沉淀。" : "把本周工作整理成可复盘的摘要。",
            tint: Brand.primary
        ) {
            Button {
                generateReport()
            } label: {
                Label(isGenerated ? "重新生成" : "生成报告", systemImage: "sparkles")
                    .font(AppFont.captionMedium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.primary)
            .padding(.vertical, AppSpace.small)
            .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(Brand.primary.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(Brand.primary.opacity(0.18), lineWidth: 0.6))
        }
    }

    // MARK: - Type Picker

    private var typePicker: some View {
        HStack(spacing: AppSpace.small) {
            ForEach(ReportType.allCases, id: \.rawValue) { type in
                Button {
                    reportType = type
                    isGenerated = false
                    reportContent = ""
                } label: {
                    Text(type.rawValue)
                        .font(AppFont.captionMedium)
                        .foregroundStyle(reportType == type ? Brand.primaryDark : TextGrade.secondary)
                        .padding(.horizontal, AppSpace.large)
                        .padding(.vertical, AppSpace.small)
                        .background(
                            Capsule().fill(reportType == type ? Brand.primary.opacity(0.12) : SurfaceGrade.elevated.opacity(0.72))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                reportType == type ? Brand.primary.opacity(0.18) : SurfaceGrade.hairline,
                                lineWidth: 0.6
                            )
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: AppSpace.medium) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(TextGrade.ghost)
            Text("还没有生成\(reportType.rawValue)")
                .font(AppFont.caption)
                .foregroundStyle(TextGrade.muted)
            VStack(spacing: AppSpace.extraSmall) {
                Text("会整理活动、变更和知识沉淀建议")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                Text(reportType == .daily ? "汇总今日的会话、工具调用和文件变更" : "汇总本周活动 + 每日分解 + 知识沉淀建议")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpace.xxl)
        .background(RoundedRectangle(cornerRadius: AppRadius.large).fill(SurfaceGrade.card.opacity(0.62)))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.large).strokeBorder(SurfaceGrade.hairline.opacity(0.75), lineWidth: 0.6))
    }

    // MARK: - Report View

    private var reportView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MarkdownText(reportContent, fontSize: 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(AppSpace.large)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                    .fill(SurfaceGrade.card.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                    .strokeBorder(SurfaceGrade.hairline, lineWidth: 0.6)
            )
        }
        .frame(maxHeight: 400)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: AppSpace.small) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reportContent, forType: .string)
                ToastCenter.shared.success("报告已复制")
            } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                    .padding(.horizontal, AppSpace.medium)
                    .padding(.vertical, AppSpace.small)
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
                    .padding(.horizontal, AppSpace.medium)
                    .padding(.vertical, AppSpace.small)
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
                    .padding(.horizontal, AppSpace.medium)
                    .padding(.vertical, AppSpace.small)
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
