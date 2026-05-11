import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - SkillHub UI — 技能市场浏览/安装/评分/统计

public struct SkillHubView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var registry = SkillRegistry.shared
    @State private var searchText = ""
    @State private var selectedCategory: SkillCategory = .all
    @State private var showingCreateSheet = false
    @State private var selectedSkill: SkillDefinition?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            categoryBar
            Divider()
            skillList
        }
        .sheet(isPresented: $showingCreateSheet) {
            SkillCreateSheet()
        }
        .sheet(item: $selectedSkill) { skill in
            SkillDetailSheet(skill: skill)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AppSpace.md) {
            Spacer()

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TextGrade.ghost)
                TextField("搜索技能…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(maxWidth: 180)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(SurfaceGrade.elevated.opacity(0.5))
            )
            .overlay(
                Capsule()
                    .strokeBorder(SurfaceGrade.border.opacity(0.1), lineWidth: 0.5)
            )

            Button { showingCreateSheet = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Brand.primary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Brand.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("创建新技能")
        }
        .padding(.horizontal, AppSpace.lg)
        .padding(.vertical, 8)
    }

    // MARK: - Category Bar

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(SkillCategory.allCases, id: \.self) { cat in
                    let isActive = selectedCategory == cat
                    Button {
                        withAnimation(AppAnimation.quick) { selectedCategory = cat }
                    } label: {
                        Text(cat.title)
                            .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? TextGrade.primary : TextGrade.ghost)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                isActive
                                ? AnyShapeStyle(SurfaceGrade.hover)
                                : AnyShapeStyle(Color.clear)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AppSpace.lg)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Skill List

    private var filteredSkills: [SkillDefinition] {
        var result = registry.skills
        if selectedCategory != .all {
            result = result.filter { categorize($0) == selectedCategory }
        }
        if !searchText.isEmpty {
            let lower = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(lower) || $0.description.lowercased().contains(lower)
            }
        }
        return result
    }

    private var skillList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if filteredSkills.isEmpty {
                    VStack(spacing: AppSpace.md) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 28, weight: .thin))
                            .foregroundStyle(TextGrade.ghost)
                        Text("暂无匹配的技能")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TextGrade.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    ForEach(filteredSkills) { skill in
                        SkillCard(skill: skill, category: categorize(skill))
                            .onTapGesture { selectedSkill = skill }
                    }
                }
            }
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.sm)
        }
    }

    // MARK: - Categorization

    private func categorize(_ skill: SkillDefinition) -> SkillCategory {
        if let cat = skill.category, let matched = SkillCategory(rawValue: cat) {
            return matched
        }
        if skill.workflowName != nil { return .workflow }
        if skill.tools.contains("web.search") || skill.tools.contains("web.fetch") || skill.tools.contains("wiki.build") {
            return .research
        }
        if skill.tools.contains("shell.exec") || skill.tools.contains("verify.build") {
            return .execution
        }
        if skill.tools.contains("file.write") || skill.tools.contains("file.edit") || skill.tools.contains("batch.apply") {
            return .editing
        }
        if skill.tools.contains("code.search") || skill.tools.contains("file.read") || skill.tools.contains("workspace.index") || skill.tools.contains("git") {
            return .analysis
        }
        return .general
    }
}

// MARK: - Skill Category

enum SkillCategory: String, CaseIterable {
    case all, analysis, editing, execution, research, workflow
    case marketing, product, content, data, business, design
    case general

    var title: String {
        switch self {
        case .all: return "全部"
        case .analysis: return "分析"
        case .editing: return "编辑"
        case .execution: return "执行"
        case .research: return "研究"
        case .workflow: return "工作流"
        case .marketing: return "营销"
        case .product: return "产品"
        case .content: return "内容"
        case .data: return "数据"
        case .business: return "商业"
        case .design: return "设计"
        case .general: return "通用"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .analysis: return "magnifyingglass"
        case .editing: return "pencil"
        case .execution: return "terminal"
        case .research: return "globe"
        case .workflow: return "arrow.triangle.branch"
        case .marketing: return "megaphone"
        case .product: return "shippingbox"
        case .content: return "doc.richtext"
        case .data: return "chart.bar"
        case .business: return "briefcase"
        case .design: return "paintpalette"
        case .general: return "star"
        }
    }
}

// MARK: - Skill Card

struct SkillCard: View {
    let skill: SkillDefinition
    var category: SkillCategory = .general
    @EnvironmentObject private var store: AppStore
    @State private var hovered = false

    private var accentColor: Color {
        switch category {
        case .analysis: return Color(hex: "3B82F6")
        case .editing: return Color(hex: "F59E0B")
        case .execution: return Color(hex: "EF4444")
        case .research: return Color(hex: "10B981")
        case .workflow: return Color(hex: "8B5CF6")
        case .marketing: return Color(hex: "EC4899")
        case .product: return Color(hex: "F97316")
        case .content: return Color(hex: "06B6D4")
        case .data: return Color(hex: "6366F1")
        case .business: return Color(hex: "84CC16")
        case .design: return Color(hex: "D946EF")
        default: return Brand.primary
        }
    }

    private var skillIcon: String {
        // Map well-known skills to distinctive icons
        let n = skill.name
        if n.contains("演示") || n.contains("PPT") { return "rectangle.on.rectangle.angled" }
        if n.contains("UI") || n.contains("界面") || n.contains("设计") { return "paintpalette" }
        if n.contains("审查") && n.contains("代码") { return "checkmark.shield" }
        if n.contains("测试") { return "testtube.2" }
        if n.contains("调试") { return "ladybug" }
        if n.contains("重构") { return "arrow.triangle.2.circlepath" }
        if n.contains("文档") || n.contains("README") { return "doc.text" }
        if n.contains("翻译") || n.contains("多语言") { return "globe" }
        if n.contains("搜索") { return "magnifyingglass" }
        if n.contains("读取") { return "doc.viewfinder" }
        if n.contains("项目概览") || n.contains("架构") { return "building.columns" }
        if n.contains("Git") { return "arrow.triangle.branch" }
        if n.contains("依赖") { return "link" }
        if n.contains("性能") { return "gauge.with.dots.needle.67percent" }
        if n.contains("安全") { return "lock.shield" }
        if n.contains("修改") || n.contains("编辑") { return "pencil.line" }
        if n.contains("重命名") { return "textformat" }
        if n.contains("格式化") { return "text.alignleft" }
        if n.contains("类型注解") { return "t.square" }
        if n.contains("API") { return "network" }
        if n.contains("数据模型") { return "cylinder" }
        if n.contains("配置") { return "gearshape.2" }
        if n.contains("错误处理") { return "exclamationmark.triangle" }
        if n.contains("执行命令") { return "terminal" }
        if n.contains("构建验证") { return "hammer" }
        if n.contains("环境") { return "cpu" }
        if n.contains("网页搜索") { return "safari" }
        if n.contains("调研") || n.contains("竞品") { return "chart.bar.doc.horizontal" }
        if n.contains("知识页") || n.contains("Wiki") { return "book" }
        if n.contains("链接") || n.contains("总结") { return "link.circle" }
        if n.contains("论文") { return "graduationcap" }
        if n.contains("解释代码") { return "text.book.closed" }
        if n.contains("需求") { return "list.clipboard" }
        if n.contains("代码转换") { return "arrow.left.arrow.right" }
        if n.contains("正则") { return "textformat.abc.dottedunderline" }
        if n.contains("SQL") { return "tablecells" }
        if n.contains("Prompt") { return "sparkles" }
        if n.contains("Commit") { return "checkmark.message" }
        if n.contains("PR") { return "arrow.triangle.pull" }
        if n.contains("Changelog") { return "clock.arrow.circlepath" }
        if n.contains("CI/CD") { return "arrow.circlepath" }
        if n.contains("迁移") { return "arrow.right.arrow.left" }
        if n.contains("代码问答") { return "questionmark.bubble" }
        if n.contains("学习") { return "map" }
        if n.contains("面试") { return "person.crop.rectangle" }
        if n.contains("营销文案") { return "megaphone" }
        if n.contains("小红书") { return "heart.text.square" }
        if n.contains("公众号") { return "newspaper" }
        if n.contains("视频脚本") || n.contains("短视频") { return "video" }
        if n.contains("SEO") { return "chart.line.uptrend.xyaxis" }
        if n.contains("广告") { return "rectangle.and.text.magnifyingglass" }
        if n.contains("评价回复") { return "star.bubble" }
        if n.contains("PRD") { return "doc.plaintext" }
        if n.contains("用户故事") { return "person.text.rectangle" }
        if n.contains("优先级") { return "list.number" }
        if n.contains("问卷") { return "checklist" }
        if n.contains("发布计划") { return "calendar.badge.checkmark" }
        if n.contains("长文") { return "doc.richtext" }
        if n.contains("周报") || n.contains("日报") { return "note.text" }
        if n.contains("邮件") { return "envelope" }
        if n.contains("会议纪要") { return "person.3" }
        if n.contains("文风改写") { return "textformat.size" }
        if n.contains("数据分析") { return "chart.bar" }
        if n.contains("Excel") { return "tablecells" }
        if n.contains("可视化") { return "chart.pie" }
        if n.contains("商业计划") { return "briefcase" }
        if n.contains("合同") { return "doc.text.magnifyingglass" }
        if n.contains("JD") { return "person.badge.plus" }
        if n.contains("OKR") { return "target" }
        if n.contains("方案书") || n.contains("客户方案") { return "doc.badge.gearshape" }
        if n.contains("SWOT") { return "square.grid.2x2" }
        // Fallback: match by description keywords for custom skills
        let d = skill.description.lowercased()
        if d.contains("ppt") || d.contains("slide") || d.contains("演示") || d.contains("汇报") { return "rectangle.on.rectangle.angled" }
        if d.contains("ui") || d.contains("ux") || d.contains("界面") || d.contains("设计") { return "paintpalette" }
        if d.contains("网站") || d.contains("web") || d.contains("html") { return "globe" }
        if d.contains("数据") || d.contains("data") || d.contains("报表") { return "chart.bar" }
        if d.contains("邮件") || d.contains("email") { return "envelope" }
        if d.contains("视频") || d.contains("video") { return "video" }
        if d.contains("图片") || d.contains("image") || d.contains("配图") { return "photo" }
        if d.contains("写作") || d.contains("文章") || d.contains("内容") { return "doc.richtext" }
        if d.contains("代码") || d.contains("code") { return "chevron.left.forwardslash.chevron.right" }
        if d.contains("搜索") || d.contains("search") { return "magnifyingglass" }
        if d.contains("分析") || d.contains("analysis") { return "chart.bar.doc.horizontal" }
        if d.contains("翻译") || d.contains("translate") { return "globe" }
        return category.icon
    }

    var body: some View {
        HStack(spacing: 12) {
            // Category accent line
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accentColor.opacity(hovered ? 0.7 : 0.3))
                .frame(width: 3, height: 32)

            // Icon
            Image(systemName: skillIcon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accentColor)
                .frame(width: 30, height: 30)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                    if skill.workflowName != nil {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(accentColor.opacity(0.6))
                    }
                }
                Text(skill.description)
                    .font(.system(size: 10))
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Action
            if hovered {
                Button {
                    store.useSkill(skill)
                } label: {
                    Text(skill.workflowName == nil ? "使用" : "运行")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(accentColor)
                        )
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered ? SurfaceGrade.hover.opacity(0.5) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(AppAnimation.quick) { hovered = h } }
    }
}

// MARK: - Skill Detail Sheet

struct SkillDetailSheet: View {
    let skill: SkillDefinition
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: AppSpace.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Brand.primary.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: skill.modelPreference.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.primary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(TextGrade.primary)
                    Text(skill.description)
                        .font(.system(size: 12))
                        .foregroundStyle(TextGrade.muted)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TextGrade.muted)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(SurfaceGrade.elevated))
                }
                .buttonStyle(.plain)
            }

            Rectangle().fill(SurfaceGrade.divider).frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                detailRow("模型偏好", value: skill.modelPreference.title)
                if let wf = skill.workflowName {
                    detailRow("工作流", value: wf)
                }
                if !skill.tools.isEmpty {
                    detailRow("工具", value: skill.tools.joined(separator: ", "))
                }
                detailRow("来源", value: skill.isBuiltin ? "内置" : (skill.isPublished ? "本地（已发布）" : "本地"))
            }

            Spacer()

            HStack {
                if !skill.isBuiltin && !skill.isPublished {
                    Button {
                        let root = store.state.settings.workspacePath
                        if SkillRegistry.shared.publish(skillID: skill.id, workspaceRoot: root) {
                            ToastCenter.shared.success("技能已发布")
                        }
                        dismiss()
                    } label: {
                        Text("发布到工作区")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TextGrade.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(SurfaceGrade.elevated))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    store.useSkill(skill)
                    dismiss()
                } label: {
                    Text("使用此技能")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Brand.premiumGradient))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 440, height: 380)
        .background(SurfaceGrade.base)
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: AppSpace.md) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TextGrade.ghost)
                .textCase(.uppercase)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(TextGrade.secondary)
        }
    }
}

// MARK: - Skill Create Sheet

struct SkillCreateSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var toolsText = ""
    @State private var workflowName = ""
    @State private var preference: ModelPreference = .default
    @State private var selectedCategory: SkillCategory = .general
    @State private var errorMessage: String?

    private var selectableCategories: [SkillCategory] {
        SkillCategory.allCases.filter { $0 != .all }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("创建技能")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TextGrade.muted)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(SurfaceGrade.elevated))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(SurfaceGrade.divider).frame(height: 1) }

            VStack(alignment: .leading, spacing: 14) {
                createField("名称") {
                    TextField("技能名称", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                createField("描述") {
                    TextField("描述", text: $description)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                createField("工具") {
                    TextField("逗号分隔，如 web.search, file.read", text: $toolsText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                }
                createField("工作流") {
                    TextField("关联工作流名（可选）", text: $workflowName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }

                createField("分类") {
                    Picker("", selection: $selectedCategory) {
                        ForEach(selectableCategories, id: \.self) { cat in
                            Text(cat.title).tag(cat)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                createField("模型偏好") {
                    Picker("", selection: $preference) {
                        ForEach(ModelPreference.allCases, id: \.self) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(Semantic.error)
                }
            }
            .padding(20)

            // Footer
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    create()
                } label: {
                    Text("创建")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.md)
                                .fill(name.isEmpty ? AnyShapeStyle(SurfaceGrade.elevated) : AnyShapeStyle(Brand.premiumGradient))
                        )
                }
                .buttonStyle(.plain)
                .disabled(name.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(SurfaceGrade.divider).frame(height: 1) }
        }
        .frame(width: 400)
        .background(SurfaceGrade.base)
    }

    private func createField<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TextGrade.ghost)
                .textCase(.uppercase)
            content()
                .padding(AppSpace.sm)
                .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(SurfaceGrade.card))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(SurfaceGrade.border.opacity(0.15), lineWidth: 0.5))
        }
    }

    private func create() {
        let tools = toolsText.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let root = store.state.settings.workspacePath
        do {
            try SkillRegistry.shared.createDraft(
                name: name,
                description: description,
                tools: tools,
                workflowName: workflowName.isEmpty ? nil : workflowName,
                category: selectedCategory == .general ? nil : selectedCategory.rawValue,
                workspaceRoot: root
            )
            ToastCenter.shared.success("技能「\(name)」已创建")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Model Regression Panel (for Settings)

public struct ModelRegressionPanel: View {
    @ObservedObject private var runner = ModelRegressionRunner.shared
    @State private var expandedResult: UUID?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            // Header
            HStack(spacing: AppSpace.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Brand.primary.opacity(0.12))
                        .frame(width: 24, height: 24)
                    Image(systemName: "stethoscope")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.primary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("连接器诊断")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                    Text("测试各模型 API 的连通性和功能兼容性")
                        .font(.system(size: 10))
                        .foregroundStyle(TextGrade.muted)
                }
                Spacer()
                if runner.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("测试中: \(runner.currentTest)")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.primary)
                } else {
                    Button {
                        Task { await runner.runAll() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text("全部测试")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Brand.premiumGradient))
                    }
                    .buttonStyle(.plain)
                }
            }

            if !runner.results.isEmpty {
                VStack(spacing: 6) {
                    ForEach(runner.results, id: \.id) { result in
                        connectorResultCard(result)
                    }
                }
            } else {
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(TextGrade.ghost)
                    Text("点击「全部测试」检查已配置连接器的兼容性")
                        .font(.system(size: 11))
                        .foregroundStyle(TextGrade.ghost)
                }
                .padding(.vertical, AppSpace.sm)
            }
        }
        .padding(AppSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(SurfaceGrade.border.opacity(0.2), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func connectorResultCard(_ result: ModelTestResult) -> some View {
        let isExpanded = expandedResult == result.id
        VStack(alignment: .leading, spacing: 0) {
            // Summary row
            Button {
                withAnimation(AppAnimation.quick) {
                    expandedResult = isExpanded ? nil : result.id
                }
            } label: {
                HStack(spacing: AppSpace.sm) {
                    // Status badge
                    Circle()
                        .fill(result.overallPassed ? Semantic.success : Semantic.error)
                        .frame(width: 8, height: 8)

                    Text(result.testCase.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TextGrade.primary)

                    Spacer()

                    // Capability pills
                    HStack(spacing: 3) {
                        ForEach(result.results, id: \.check) { cr in
                            Text(checkShortLabel(cr.check))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(cr.passed ? Semantic.success : Semantic.error)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill((cr.passed ? Semantic.success : Semantic.error).opacity(0.1))
                                )
                        }
                    }

                    // Latency
                    let totalMs = result.results.map(\.latencyMs).reduce(0, +)
                    Text(totalMs < 1000 ? "\(totalMs)ms" : String(format: "%.1fs", Double(totalMs) / 1000))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(TextGrade.ghost)
                        .frame(width: 40, alignment: .trailing)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(TextGrade.ghost)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, AppSpace.sm)
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.results, id: \.check) { cr in
                        HStack(spacing: AppSpace.sm) {
                            Image(systemName: cr.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(cr.passed ? Semantic.success : Semantic.error)
                            Text(checkLabel(cr.check))
                                .font(.system(size: 11))
                                .foregroundStyle(TextGrade.secondary)
                            Spacer()
                            if !cr.detail.isEmpty {
                                Text(cr.detail)
                                    .font(.system(size: 9))
                                    .foregroundStyle(TextGrade.ghost)
                                    .lineLimit(1)
                            }
                            Text("\(cr.latencyMs)ms")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(TextGrade.ghost)
                        }
                    }
                    if let err = result.results.first(where: { !$0.passed })?.error {
                        Text(err)
                            .font(.system(size: 9))
                            .foregroundStyle(Semantic.error)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, AppSpace.md)
                .padding(.bottom, AppSpace.sm)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.elevated.opacity(0.5))
        )
    }

    private func checkShortLabel(_ check: ModelTestCase.Check) -> String {
        switch check {
        case .healthCheck: return "连通"
        case .basicChat: return "对话"
        case .streamingChat: return "流式"
        case .toolCalling: return "工具"
        case .reasoning: return "推理"
        case .longContext: return "长文"
        case .chineseOutput: return "中文"
        }
    }

    private func checkLabel(_ check: ModelTestCase.Check) -> String {
        switch check {
        case .healthCheck: return "API 连通性"
        case .basicChat: return "基础对话"
        case .streamingChat: return "流式输出"
        case .toolCalling: return "工具调用"
        case .reasoning: return "推理链"
        case .longContext: return "长上下文"
        case .chineseOutput: return "中文输出"
        }
    }
}

// MARK: - Teleport Panel

public struct TeleportPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var importMessage: String?
    @State private var exportMessage: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(spacing: AppSpace.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Brand.primary.opacity(0.1))
                        .frame(width: 24, height: 24)
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.primary)
                }
                Text("会话接力")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)
            }

            HStack(spacing: AppSpace.md) {
                Button {
                    exportSessions()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 10, weight: .medium))
                        Text("导出")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(TextGrade.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(SurfaceGrade.elevated))
                }
                .buttonStyle(.plain)

                Button {
                    importSessions()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .medium))
                        Text("导入")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(TextGrade.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(SurfaceGrade.elevated))
                }
                .buttonStyle(.plain)
            }

            if let msg = exportMessage ?? importMessage {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(TextGrade.muted)
                    .transition(.opacity)
            }
        }
        .padding(AppSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(SurfaceGrade.border.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func exportSessions() {
        let url = SessionTeleport.suggestedExportURL(workspaceName: store.state.workspaceName)
        do {
            try SessionTeleport.shared.exportBundle(
                threads: store.state.threads,
                connectors: store.state.connectors,
                settings: store.state.settings,
                skills: SkillRegistry.shared.skills.filter { !$0.isBuiltin },
                to: url
            )
            exportMessage = "已导出到: \(url.lastPathComponent)"
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        } catch {
            exportMessage = "导出失败: \(error.localizedDescription)"
        }
    }

    private func importSessions() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.title = "选择来财会话文件"
        panel.prompt = "导入"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bundle = try SessionTeleport.shared.importBundle(from: url)
            var threads = store.state.threads
            var connectors = store.state.connectors
            let result = SessionTeleport.shared.mergeBundle(bundle, into: &threads, connectors: &connectors)
            // Imported threads are merged via the public thread import API
            for thread in bundle.threads where !store.state.threads.contains(where: { $0.id == thread.id }) {
                if let json = try? JSONEncoder().encode(thread), let jsonStr = String(data: json, encoding: .utf8) {
                    _ = store.importSession(json: jsonStr)
                }
            }
            importMessage = result.summary
        } catch {
            importMessage = "导入失败: \(error.localizedDescription)"
        }
    }
}
