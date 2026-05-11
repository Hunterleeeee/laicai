import Foundation
import LaicaiNativeDomain

// MARK: - Product Manager Agent
// Inspired by ChatPRD + PM-Skills (Triple Diamond framework).
// Provides structured PM workflows: PRD, user stories, competitive analysis,
// experiment design, retrospective, and more.

public enum PMSkillType: String, CaseIterable, Codable, Sendable {
    // Discover
    case competitiveAnalysis = "competitive_analysis"
    case interviewSynthesis = "interview_synthesis"
    case stakeholderSummary = "stakeholder_summary"
    // Define
    case problemStatement = "problem_statement"
    case hypothesis = "hypothesis"
    case persona = "persona"
    case jtbdCanvas = "jtbd_canvas"
    // Develop
    case solutionBrief = "solution_brief"
    case adr = "adr"
    // Deliver
    case prd = "prd"
    case userStories = "user_stories"
    case acceptanceCriteria = "acceptance_criteria"
    case edgeCases = "edge_cases"
    case launchChecklist = "launch_checklist"
    case releaseNotes = "release_notes"
    // Measure
    case experimentDesign = "experiment_design"
    case okrWriter = "okr_writer"
    // Iterate
    case retrospective = "retrospective"
    case pivotDecision = "pivot_decision"

    public var displayName: String {
        switch self {
        case .competitiveAnalysis: return "竞品分析"
        case .interviewSynthesis: return "用研综述"
        case .stakeholderSummary: return "干系人汇报"
        case .problemStatement: return "问题定义"
        case .hypothesis: return "假设验证"
        case .persona: return "用户画像"
        case .jtbdCanvas: return "JTBD 画布"
        case .solutionBrief: return "方案简述"
        case .adr: return "架构决策记录"
        case .prd: return "PRD"
        case .userStories: return "用户故事"
        case .acceptanceCriteria: return "验收标准"
        case .edgeCases: return "边界用例"
        case .launchChecklist: return "上线清单"
        case .releaseNotes: return "发版说明"
        case .experimentDesign: return "实验设计"
        case .okrWriter: return "OKR 撰写"
        case .retrospective: return "复盘总结"
        case .pivotDecision: return "转型决策"
        }
    }

    public var phase: String {
        switch self {
        case .competitiveAnalysis, .interviewSynthesis, .stakeholderSummary: return "Discover"
        case .problemStatement, .hypothesis, .persona, .jtbdCanvas: return "Define"
        case .solutionBrief, .adr: return "Develop"
        case .prd, .userStories, .acceptanceCriteria, .edgeCases, .launchChecklist, .releaseNotes: return "Deliver"
        case .experimentDesign, .okrWriter: return "Measure"
        case .retrospective, .pivotDecision: return "Iterate"
        }
    }

    public var icon: String {
        switch self {
        case .prd: return "doc.text"
        case .userStories: return "person.3"
        case .competitiveAnalysis: return "chart.bar"
        case .experimentDesign: return "flask"
        case .retrospective: return "arrow.counterclockwise"
        case .persona: return "person.crop.circle"
        case .okrWriter: return "target"
        case .launchChecklist: return "checklist"
        case .releaseNotes: return "megaphone"
        case .hypothesis: return "lightbulb"
        case .problemStatement: return "exclamationmark.triangle"
        default: return "doc.plaintext"
        }
    }
}

// MARK: - PM Agent Prompts

public enum PMAgentPrompts {
    public static func systemPrompt(skill: PMSkillType) -> String {
        let base = """
        你是一位资深产品经理 AI 助手，拥有 10 年以上互联网产品经验。
        你精通 Triple Diamond 框架（Discover → Define → Develop → Deliver → Measure → Iterate）。
        你的输出必须是结构化、可直接交付给团队的专业文档。

        ## 核心原则
        - **用户价值导向**：一切从用户问题出发，不是从技术方案出发
        - **数据驱动**：决策必须有数据支撑或明确的假设
        - **MECE 原则**：分类必须互斥穷尽
        - **可执行性**：输出的每一项都必须可落地执行
        - **简洁专业**：避免废话，直击要点

        """

        return base + skillSpecificPrompt(skill)
    }

    private static func skillSpecificPrompt(_ skill: PMSkillType) -> String {
        switch skill {
        case .prd:
            return """
            ## 当前任务：撰写 PRD（产品需求文档）

            按以下结构输出完整 PRD：

            ### 1. 概述
            - **产品名称**
            - **版本号**
            - **作者 & 日期**
            - **一句话描述**：用户可以通过 [功能] 解决 [问题]，从而获得 [价值]

            ### 2. 背景与问题
            - **业务背景**：为什么要做这个功能？市场/用户/业务驱动力
            - **用户痛点**：具体场景下的具体问题（JTBD 视角）
            - **现有方案的不足**：竞品或当前方案的差距
            - **关键数据**：支撑决策的核心指标

            ### 3. 目标与成功指标
            - **北极星指标**
            - **OKR**：Objective + 2-3 个 Key Results（可量化）
            - **非目标**：明确不做什么

            ### 4. 用户故事与场景
            - 按优先级列出核心用户故事（As a... I want... So that...）
            - 每个故事附加验收标准

            ### 5. 功能需求
            - **P0 必做**（MVP）
            - **P1 应做**
            - **P2 可做**
            - 每个需求：描述、交互逻辑、边界条件、异常处理

            ### 6. 非功能需求
            - 性能、安全、兼容性、可访问性

            ### 7. 技术方案概要
            - 架构选型建议
            - 依赖与风险
            - 数据模型变更

            ### 8. 里程碑与排期
            | 阶段 | 内容 | 时间 |
            |------|------|------|

            ### 9. 风险与缓解
            | 风险 | 影响 | 缓解措施 |
            |------|------|----------|

            ### 10. 附录
            - 竞品截图、用户访谈摘要、相关链接

            要求：
            - 如果用户提供了产品背景信息，围绕背景深入展开
            - 如果信息不足，用 [待确认] 标记并给出合理假设
            - 所有数字和时间线必须合理、可执行
            """

        case .userStories:
            return """
            ## 当前任务：撰写用户故事

            按以下格式为每个功能点生成用户故事：

            ```
            ### US-[编号]: [简短标题]
            **角色**：As a [用户角色]
            **需求**：I want to [用户行为]
            **价值**：So that [获得价值]

            **验收标准**：
            - [ ] Given [前置条件], When [用户操作], Then [期望结果]
            - [ ] Given [前置条件], When [用户操作], Then [期望结果]

            **优先级**：P0/P1/P2
            **估算**：[故事点或人天]
            **依赖**：[其他故事编号或无]
            ```

            要求：
            - 按 INVEST 原则：Independent, Negotiable, Valuable, Estimable, Small, Testable
            - 验收标准用 Given-When-Then 格式
            - 按优先级排序
            - 标注前后依赖关系
            - 边界场景和异常路径单独列出
            """

        case .competitiveAnalysis:
            return """
            ## 当前任务：竞品分析

            按以下结构输出竞品分析报告：

            ### 1. 分析目标与范围
            - 分析目的、关注维度

            ### 2. 竞品概览
            | 竞品 | 定位 | 目标用户 | 核心功能 | 商业模式 | 融资/规模 |
            |------|------|----------|----------|----------|-----------|

            ### 3. 功能对比矩阵
            | 功能点 | 我方 | 竞品A | 竞品B | 竞品C |
            |--------|------|-------|-------|-------|
            用 ✅ ❌ 🔶(部分) 标注

            ### 4. 各竞品深度分析
            每个竞品：
            - **差异化优势**
            - **薄弱环节**
            - **用户口碑**（App Store/社交媒体评价摘要）
            - **近期动态**（最近 3-6 个月的重要更新）

            ### 5. 竞争格局图
            用 2x2 矩阵或波特五力分析

            ### 6. 机会与威胁
            - **我方机会**：竞品未覆盖的空白
            - **威胁**：竞品可能蚕食的领域
            - **差异化建议**：3-5 个具体的差异化方向

            ### 7. 行动建议
            - 短期（1-3月）
            - 中期（3-6月）
            - 长期（6-12月）

            如果用户提供了竞品名称，优先使用 web_search 获取最新信息。
            如果没有提供竞品，先帮用户识别 3-5 个主要竞品。
            """

        case .experimentDesign:
            return """
            ## 当前任务：实验设计（A/B Test）

            按以下结构输出实验方案：

            ### 1. 实验概述
            - **实验名称**
            - **假设**：如果我们 [做了改变]，那么 [指标] 会 [变化方向]，因为 [原因]
            - **实验类型**：A/B / 多变量 / 分桶灰度

            ### 2. 指标设计
            - **主要指标**（Primary Metric）：直接衡量假设是否成立
            - **护栏指标**（Guardrail Metrics）：确保不伤害其他关键体验
            - **辅助指标**（Secondary Metrics）：帮助解释结果的补充数据

            ### 3. 实验组设计
            | 组别 | 描述 | 流量占比 |
            |------|------|----------|
            | 对照组 | | 50% |
            | 实验组 | | 50% |

            ### 4. 样本量与时长
            - 当前基线指标值
            - 最小可检测效应（MDE）
            - 显著性水平（α = 0.05）
            - 统计功效（1-β = 0.8）
            - 计算所需样本量和预估时长

            ### 5. 分桶策略
            - 分桶单位（用户/设备/会话）
            - 排除条件
            - 新用户 vs 老用户

            ### 6. 风险评估
            - 可能的干扰因素
            - 回退方案
            - 监控告警

            ### 7. 结果分析框架
            - 如何判定成功/失败/不确定
            - 如何处理不显著结果
            - 后续行动决策树
            """

        case .retrospective:
            return """
            ## 当前任务：项目复盘

            按以下结构输出复盘报告：

            ### 1. 项目概况
            - 项目名称、时间线、团队成员
            - 原始目标 vs 实际交付

            ### 2. 关键成果
            - **达成的目标**：列举具体成果和数据
            - **超预期的部分**：哪些做得比预想好
            - **未达预期**：哪些没做到

            ### 3. 时间线回顾
            | 里程碑 | 计划日期 | 实际日期 | 偏差原因 |
            |--------|----------|----------|----------|

            ### 4. What Went Well (WWW)
            - 做对了什么？为什么？如何复制？

            ### 5. What Went Wrong (WWW)
            - 出了什么问题？根因分析（5 Whys）
            - 影响范围和程度

            ### 6. What to Improve (WTI)
            | 改进项 | 负责人 | 截止日期 | 优先级 |
            |--------|--------|----------|--------|

            ### 7. 团队健康度
            - 协作效率
            - 沟通质量
            - 士气状态

            ### 8. 下一步行动
            - 3 个最重要的改进承诺
            - 如何确保执行
            """

        case .problemStatement:
            return """
            ## 当前任务：问题定义

            输出结构：
            ### 问题陈述
            [目标用户] 在 [场景] 下需要 [做某事]，但由于 [障碍/痛点]，导致 [负面结果]。

            ### 问题拆解（5W1H）
            - **Who**：谁遇到了这个问题？用户画像
            - **What**：具体是什么问题？
            - **When**：什么时候发生？频率？
            - **Where**：在哪个场景/触点？
            - **Why**：为什么会发生？（5 Whys 深挖根因）
            - **How**：目前用户如何应对？替代方案是什么？

            ### 问题规模
            - 受影响用户数 / 比例
            - 频率和严重程度
            - 商业影响估算

            ### 约束条件
            - 技术约束、资源约束、时间约束、政策约束

            ### 成功标准
            - 如果问题被解决，可量化的衡量标准是什么？
            """

        case .hypothesis:
            return """
            ## 当前任务：假设验证

            输出格式：
            ### 假设 [编号]
            **如果**我们 [采取行动]
            **那么** [目标指标] 将会 [变化方向和幅度]
            **因为** [基于的用户洞察/数据/理论]

            **验证方法**：[如何证明/证伪]
            **关键风险**：[如果假设错误的后果]
            **信心等级**：高/中/低（附理由）
            **验证周期**：[预计时间]
            **最小验证 MVP**：[最小可行验证方案]
            """

        case .persona:
            return """
            ## 当前任务：用户画像

            为每个画像输出：
            ### 画像：[姓名]（[角色标签]）

            **基本信息**
            - 年龄、职业、技术水平、收入水平

            **场景描述**
            一段 3-5 句的第一人称叙述，描述这个用户在什么情况下使用产品

            **目标与动机**
            - 想要达成什么？
            - 深层动机是什么？

            **痛点与挫折**
            - 现在遇到的最大障碍
            - 情绪感受

            **行为特征**
            - 使用频率、习惯、偏好渠道

            **一句话总结**
            "作为 [角色]，我需要 [功能]，因为 [原因]"
            """

        case .jtbdCanvas:
            return """
            ## 当前任务：Jobs to Be Done 画布

            ### Core Job
            [用户的核心任务是什么？]

            ### Job Map（任务步骤）
            1. 定义 → 2. 搜索 → 3. 准备 → 4. 确认 → 5. 执行 → 6. 监控 → 7. 修改 → 8. 完成

            每个步骤列出：
            - 用户想要的结果
            - 当前的痛点
            - 机会分值（重要度 × 满意度差距）

            ### Emotional Jobs
            - 用户想要感受到什么？
            - 想要避免什么感受？

            ### Social Jobs
            - 用户想要被如何看待？

            ### 机会排序
            | 机会 | 重要度(1-10) | 当前满意度(1-10) | 机会分 |
            |------|-------------|------------------|--------|
            """

        case .solutionBrief:
            return """
            ## 当前任务：方案简述

            ### 方案概述
            一段话描述方案核心思路

            ### 解决的问题
            对应哪个问题定义文档

            ### 方案详情
            - **方案 A**：[描述] — 优势/劣势/风险/工作量
            - **方案 B**：[描述] — 优势/劣势/风险/工作量
            - **推荐方案**：[哪个，为什么]

            ### 技术可行性
            - 依赖什么技术组件？
            - 有无技术难点？

            ### 范围定义
            - MVP 包含什么
            - V2 可以扩展什么
            - 明确不做什么
            """

        case .adr:
            return """
            ## 当前任务：Architecture Decision Record

            ### ADR-[编号]: [决策标题]

            **状态**：Proposed / Accepted / Deprecated / Superseded

            **背景**
            为什么需要做这个决策？

            **决策**
            我们决定 [具体选择]

            **备选方案**
            | 方案 | 优势 | 劣势 | 适用场景 |
            |------|------|------|----------|

            **理由**
            选择当前方案的核心原因（技术/业务/团队）

            **影响**
            - 正面影响
            - 需要接受的代价
            - 受影响的系统/团队

            **后续行动**
            - [ ] 行动项 1
            - [ ] 行动项 2
            """

        case .acceptanceCriteria:
            return """
            ## 当前任务：验收标准

            对每个功能点输出：
            ### AC-[编号]: [功能点名称]

            **正常路径**
            - Given [前置条件], When [操作], Then [期望结果]

            **边界条件**
            - Given [边界情况], When [操作], Then [期望结果]

            **异常路径**
            - Given [异常情况], When [操作], Then [期望处理]

            **性能要求**
            - 响应时间 < [X]ms
            - 并发支持 [X] QPS

            **安全要求**
            - 权限检查
            - 数据校验
            """

        case .edgeCases:
            return """
            ## 当前任务：边界用例分析

            按类别列出所有边界用例：
            ### 输入边界
            - 空值/null、超长文本、特殊字符、emoji、多语言

            ### 并发与竞态
            - 多用户同时操作、重复提交、断网恢复

            ### 权限边界
            - 未登录、权限不足、被封禁用户

            ### 数据状态
            - 新用户（空状态）、数据迁移、历史数据兼容

            ### 设备与环境
            - 不同屏幕尺寸、低端设备、弱网、离线

            每个用例标注：严重程度（Critical/Major/Minor）+ 建议处理方式
            """

        case .launchChecklist:
            return """
            ## 当前任务：上线清单

            ### 上线前
            - [ ] PRD 评审通过
            - [ ] 设计评审通过
            - [ ] 代码 Review 完成
            - [ ] 单元测试覆盖率 > [X]%
            - [ ] E2E 测试通过
            - [ ] 性能测试通过
            - [ ] 安全审计通过
            - [ ] 灰度方案确认
            - [ ] 回滚方案准备
            - [ ] 监控告警配置
            - [ ] 文档更新

            ### 上线中
            - [ ] 灰度发布 [X]%
            - [ ] 核心指标监控
            - [ ] 错误日志检查
            - [ ] 客服/运营同步

            ### 上线后
            - [ ] 全量发布
            - [ ] 数据验收
            - [ ] 用户反馈收集
            - [ ] 复盘排期
            """

        case .releaseNotes:
            return """
            ## 当前任务：发版说明

            ### [产品名] v[版本号] 发版说明
            **发布日期**：[日期]

            #### ✨ 新功能
            - **[功能名]**：一句话描述用户价值

            #### 🔧 优化改进
            - **[改进项]**：具体改善了什么

            #### 🐛 问题修复
            - 修复了 [具体场景] 下 [具体问题]

            #### ⚠️ 已知问题
            - [问题描述]（预计 [时间] 修复）

            要求：面向用户，不要技术术语。突出用户价值而非实现细节。
            """

        case .okrWriter:
            return """
            ## 当前任务：OKR 撰写

            ### Objective: [目标]
            明确、鼓舞人心、有挑战性

            **KR1**: [可量化的关键结果]
            - 基线：[当前值]
            - 目标：[目标值]
            - 衡量方式：[如何测量]

            **KR2**: [可量化的关键结果]
            - 基线 → 目标 → 衡量

            **KR3**: [可量化的关键结果]
            - 基线 → 目标 → 衡量

            要求：
            - O 定性描述方向，KR 定量衡量进度
            - KR 必须可量化、有时限、有挑战但可达
            - 通常 3-5 个 KR per O
            - 建议目标完成率 60-70% 为健康（说明有挑战性）
            """

        case .interviewSynthesis:
            return """
            ## 当前任务：用户访谈综述

            ### 访谈概况
            - 访谈人数、时间、方式
            - 受访者画像

            ### 关键发现
            按主题聚类，每个发现：
            - **发现**：一句话概括
            - **频率**：[X/N] 位受访者提到
            - **原话佐证**："引用1-2句原话"
            - **严重程度**：Critical / Important / Nice-to-have

            ### 共性模式
            - 所有/多数受访者共同提到的需求和痛点

            ### 意外发现
            - 访谈前没预料到的洞察

            ### 行动建议
            按优先级排序的改进方向

            如果用户提供了访谈记录，基于记录分析；否则帮用户设计访谈提纲。
            """

        case .stakeholderSummary:
            return """
            ## 当前任务：干系人汇报

            ### 项目状态概览
            🟢 On Track / 🟡 At Risk / 🔴 Blocked

            ### 上周进展
            - 完成了什么（按优先级）
            - 关键里程碑达成情况

            ### 本周计划
            - 核心待办
            - 预计产出

            ### 风险与阻塞
            | 风险项 | 影响 | 状态 | 需要的支持 |
            |--------|------|------|------------|

            ### 关键指标
            | 指标 | 目标 | 当前 | 趋势 |
            |------|------|------|------|

            ### 需要决策的事项
            1. [决策项] — 选项A / 选项B — 建议选 [X] 因为 [理由]
            """

        case .pivotDecision:
            return """
            ## 当前任务：转型/策略调整决策

            ### 当前状态
            - 现有方向的数据表现
            - 投入了多少资源
            - 距离目标的差距

            ### 转型信号
            - 哪些数据表明需要调整？
            - 市场/用户反馈变化

            ### 选项分析
            | 选项 | 描述 | 预期收益 | 所需投入 | 风险 |
            |------|------|----------|----------|------|
            | 坚持 | | | | |
            | 微调 | | | | |
            | 转型 | | | | |

            ### 建议
            - 推荐哪个选项？为什么？
            - 执行步骤
            - 验证节点（多久后再评估）
            """
        }
    }
}

// MARK: - PM Agent Tool

public struct PMAgentTool: LaicaiTool {
    public var name: String { "pm.agent" }
    public var description: String { "产品经理 Agent：生成 PRD、用户故事、竞品分析、实验设计、OKR、复盘等专业产品文档。基于 Triple Diamond 框架。" }
    public var requiresReview: Bool { false }

    public var functionDefinition: FunctionDefinition {
        let skillList = PMSkillType.allCases.map { "\($0.rawValue)=\($0.displayName)" }.joined(separator: ", ")
        return FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "skill": FunctionProperty(type: "string", description: "技能类型：\(skillList)"),
                    "topic": FunctionProperty(type: "string", description: "主题/产品/功能名称"),
                    "context": FunctionProperty(type: "string", description: "可选，额外背景信息：用户画像、业务目标、技术栈、竞品列表等"),
                    "save": FunctionProperty(type: "boolean", description: "是否保存到工作区 docs/ 目录（默认 false，仅预览）"),
                    "useWeb": FunctionProperty(type: "boolean", description: "是否联网搜索最新信息（竞品分析等建议开启）")
                ],
                required: ["skill", "topic"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var skill: String
            var topic: String
            var context: String?
            var save: Bool?
            var useWeb: Bool?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        guard let skill = PMSkillType(rawValue: params.skill) else {
            let available = PMSkillType.allCases.map { "\($0.rawValue) (\($0.displayName))" }.joined(separator: "\n")
            return ToolResult(
                output: "未知技能 '\(params.skill)'。可用技能：\n\(available)",
                success: false,
                error: "unknown_skill"
            )
        }

        let systemPrompt = PMAgentPrompts.systemPrompt(skill: skill)
        var userPrompt = "主题：\(params.topic)"
        if let extra = params.context, !extra.isEmpty {
            userPrompt += "\n\n补充背景：\n\(extra)"
        }

        // If useWeb, do a web search first and append results
        var webContext = ""
        if params.useWeb == true {
            let searchQuery: String
            switch skill {
            case .competitiveAnalysis:
                searchQuery = "\(params.topic) 竞品 竞争对手 2025"
            case .experimentDesign:
                searchQuery = "\(params.topic) A/B test best practices"
            case .releaseNotes:
                searchQuery = "\(params.topic) latest release changelog"
            default:
                searchQuery = "\(params.topic) product management"
            }
            if let searchTool = await ToolRegistry.shared.tool(named: "web.search") {
                let searchJSON = #"{"query":"\#(searchQuery)","maxResults":5}"#
                if let searchResult = try? await searchTool.execute(argumentsJSON: searchJSON, context: context),
                   searchResult.success {
                    webContext = "\n\n## 网络搜索结果\n\(String(searchResult.output.prefix(3000)))"
                }
            }
        }

        if !webContext.isEmpty {
            userPrompt += webContext
        }

        userPrompt += "\n\n请直接输出完整的 \(skill.displayName) 文档，使用 Markdown 格式。"

        // Build the generation instruction for the agent loop.
        // The tool result is injected as a system message; the LLM will then generate
        // the full document in its next response.
        let saveInstruction: String
        if params.save == true {
            let docsDir = "docs/pm"
            let filename = "\(skill.rawValue)-\(sanitize(params.topic)).md"
            saveInstruction = "\n\n生成完毕后，使用 file_write 将文档保存到 `\(docsDir)/\(filename)`。"
        } else {
            saveInstruction = ""
        }

        let output = """
        PM Agent 已激活 [\(skill.phase)] \(skill.displayName) 模式。

        现在请严格按照以下框架，直接输出关于「\(params.topic)」的完整 \(skill.displayName) 文档。
        不要输出任何多余解释或确认，直接输出文档正文。\(saveInstruction)

        === 框架指令 ===
        \(systemPrompt)

        === 用户输入 ===
        \(userPrompt)
        """

        return ToolResult(
            output: output,
            data: [
                "skill": skill.rawValue,
                "topic": params.topic,
                "phase": skill.phase,
            ],
            success: true
        )
    }

    private func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: #"[/\\:?*\"|<>]"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
            .prefix(60).description
    }
}
