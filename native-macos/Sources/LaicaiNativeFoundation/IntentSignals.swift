import Foundation
import LaicaiNativeDomain

struct IntentSignals {
    let input: String

    /// Strip negated phrases so "不用说建议" doesn't match "建议"
    private var effectiveInput: String {
        var s = input
        let negationPrefixes = ["不用说", "不用给", "不要说", "不要给", "不需要", "别给我", "别说", "不用", "不要", "别"]
        for prefix in negationPrefixes {
            // Remove "不用说建议" → removes the whole negated phrase
            if let range = s.range(of: prefix) {
                let after = s[range.upperBound...]
                // Remove up to 4 chars after the negation prefix (the negated keyword)
                let charsToRemove = min(4, after.count)
                s.removeSubrange(range.lowerBound..<s.index(range.upperBound, offsetBy: charsToRemove))
            }
        }
        return s
    }

    private var isDirectQuestion: Bool {
        let prefixes = ["什么", "为什么", "怎么", "如何", "是否", "哪里", "哪个", "多少", "能介绍", "请问", "你是", "你能", "你有", "你会"]
        let suffixes = ["吗", "么", "呢", "？", "?", "模型", "啥"]
        let contains = ["是什么", "什么是", "怎么样", "是谁", "多少", "几个", "几种", "能不能", "可不可以", "有没有"]
        return prefixes.contains(where: { input.hasPrefix($0) })
            || suffixes.contains(where: { input.hasSuffix($0) })
            || contains.contains(where: { input.contains($0) })
    }

    var isQuestion: Bool {
        isDirectQuestion
            // Short inputs without action markers are likely questions.
            || (input.count <= 15 && !hasDirectActionCue)
    }

    private var hasDirectActionCue: Bool {
        containsExplicitURLAction
            || requestsFreshInformation
            || requestsLocalIO
            || requestsShellExecution
            || requestsWikiPersistence
            || requestsMutation
            || rawRequestsWebResearch
            || requestsModelCurrentInfo
            || rawRequestedDeliverable
            || requestsPMDocument
    }

    var isCreativePromptChat: Bool {
        guard !containsLocalPath,
              !referencesOfficeDocument,
              !containsExplicitURLAction,
              !requestsShellExecution,
              !requestsLocalIO,
              !requestsMutation else { return false }

        let promptMarkers = ["prompt", "提示词", "描述词", "描述prompt", "怎么描述", "描述一下", "梳理一下", "帮我梳理", "润色"]
        let creativeTargets = ["gemini", "歌曲", "写歌", "作一首歌", "作歌", "音乐", "歌词", "mv", "视频", "短片", "画面", "风格", "电影感", "古风", "电子"]
        if promptMarkers.contains(where: { input.localizedCaseInsensitiveContains($0) })
            && creativeTargets.contains(where: { input.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        let styleWords = ["古风", "电子", "电影感", "男生", "女生", "故事", "伤感", "治愈", "热血", "赛博", "国风", "摇滚", "民谣"]
        let separators = [",", "，", "、", " "]
        let looksLikeStyleList = separators.contains(where: { input.contains($0) })
            && styleWords.filter { input.contains($0) }.count >= 2
            && input.count <= 80
        return looksLikeStyleList
    }

    var workflow: String? {
        if wantsCodeReview { return "code-review" }
        if wantsTestGeneration { return "test-gen" }
        if wantsDebugWorkflow { return "debug" }
        if wantsRefactorWorkflow { return "refactor" }
        if wantsDocumentationWorkflow { return "doc-gen" }
        if wantsTranslationWorkflow { return "translate" }
        return nil
    }

    /// Information retrieval that needs web search but NOT file writes or shell commands
    var isResearch: Bool {
        guard !requestsShellExecution, !requestsMutation, !requestsWikiPersistence else { return false }
        return requestsExternalInfo || requestsMarketSurvey || requestsRecommendation || requestsFreshInfoOnly || rawRequestsWebResearch
    }

    var researchReason: String {
        if requestsMarketSurvey { return "用户在了解市面上有什么选择，需要联网搜索获取信息。" }
        if requestsRecommendation { return "用户在请求推荐或对比，需要联网搜索获取最新信息。" }
        if requestsFreshInfoOnly { return "用户在询问新闻或时事信息，需要联网搜索获取最新信息。" }
        return "用户需要外部信息检索，需要联网搜索。"
    }

    /// Fresh information request WITHOUT any local/mutation intent — this is research, not task
    private var requestsFreshInfoOnly: Bool {
        guard requestsFreshInformation else { return false }
        return !requestsLocalIO && !requestsMutation && !requestsShellExecution
    }

    private var requestsExternalInfo: Bool {
        // Questions about external things that require web search, NOT workspace operations
        let externalMarkers = ["有什么", "有哪些", "哪些好用", "哪些好的", "市面上", "市场上", "行业", "趋势"]
        let topicMarkers = ["工具", "框架", "库", "方案", "产品", "服务", "平台", "skill", "plugin", "tool", "sdk", "api"]
        return externalMarkers.contains(where: { input.contains($0) })
            && topicMarkers.contains(where: { input.contains($0) })
    }

    private var requestsMarketSurvey: Bool {
        let strongMarkers = ["市面上", "市场上"]
        if strongMarkers.contains(where: { input.contains($0) }) { return true }
        let weakMarkers = ["有什么好用", "有什么有用", "有哪些好的", "有哪些有用", "都有什么", "都有哪些"]
        let topicMarkers = ["工具", "框架", "库", "方案", "产品", "服务", "平台", "模型", "插件", "sdk", "api", "app"]
        return weakMarkers.contains(where: { input.contains($0) })
            && topicMarkers.contains(where: { input.contains($0) })
    }

    private var requestsRecommendation: Bool {
        ["推荐", "推荐一下", "建议用", "建议用什么", "选哪个", "用哪个", "哪个好"].contains { input.contains($0) }
            && !capabilityOnly
    }

    var requiresExecution: Bool {
        input.hasPrefix("/")
            || containsLocalPath
            || referencesOfficeDocument
            || containsExplicitURLAction
            || requestsImageGeneration
            || requestsFreshInformation
            || requestsShellExecution
            || requestsWikiPersistence
            || requestsMutation
            || requestsWebResearch
            || requestsModelCurrentInfo
            || requestsPMDocument
    }

    var requestsAction: Bool {
        requestsImageGeneration
            || requestsFreshInformation
            || requestsLocalIO
            || requestsShellExecution
            || requestsWikiPersistence
            || requestsMutation
            || requestsWebResearch
            || requestsModelCurrentInfo
            || requestedDeliverable
            || referencesOfficeDocument
            || requestsPMDocument
    }

    var shouldInspectBeforeActing: Bool {
        let contextualInspection = hasInspectableLocalContext
            && (requestsDiagnosis || requestsAdvice || requestsEvaluation || requestsSummary || requestsPlanOnly || reportsInspectableProblem)
        return requestsLocalIO || contextualInspection
    }

    var isExplicitPlanOnly: Bool {
        explicitPlanOnly
    }

    var prefersAnalysisOnly: Bool {
        explicitPlanOnly || asksForAdviceInsteadOfMutation
    }

    var isPersonalDeviceHowToQuestion: Bool {
        guard isQuestion,
              !containsURL,
              !containsLocalPath,
              !referencesOfficeDocument,
              !codeOrProjectContext,
              !requestsWikiPersistence,
              !requestsImageGeneration,
              !requestsWebResearch,
              !requestsFreshInformation,
              !requestsModelCurrentInfo,
              !requestsPMDocument else {
            return false
        }
        let deviceMarkers = [
            "我的电脑", "电脑", "macos", "系统", "本机", "网络", "网卡", "虚拟网卡",
            "vpn", "终端", "命令行", "浏览器", "键盘", "鼠标", "显示器"
        ]
        let howToMarkers = [
            "怎么弄", "怎么设置", "如何设置", "怎么开", "如何开启", "怎么打开",
            "怎么配置", "如何配置", "应该怎么", "怎么办", "怎么用"
        ]
        let explicitExecutionMarkers = [
            "帮我运行", "帮我执行", "直接运行", "直接执行", "现在运行", "现在执行",
            "帮我安装", "直接安装", "帮我创建", "直接创建", "跑一下"
        ]
        return deviceMarkers.contains { input.localizedCaseInsensitiveContains($0) }
            && howToMarkers.contains { input.localizedCaseInsensitiveContains($0) }
            && !explicitExecutionMarkers.contains { input.localizedCaseInsensitiveContains($0) }
    }

    private var containsURL: Bool {
        input.contains("http://") || input.contains("https://")
    }

    private var containsLocalPath: Bool {
        input.range(of: #"/[^\s，。；;）)\]}>\"']+"#, options: .regularExpression) != nil
    }

    private var referencesOfficeDocument: Bool {
        input.range(of: #"[A-Za-z0-9_./\-\u{4e00}-\u{9fff}]+\.(pptx|docx|xlsx|xlsm|ppt|doc|xls)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// URL presence alone should not trigger execution. Only trigger if user explicitly
    /// wants to act on the URL (read, fetch, visit, open, download).
    private var containsExplicitURLAction: Bool {
        guard containsURL else { return false }
        let actionMarkers = ["打开", "访问", "读取", "获取", "下载", "fetch", "download", "visit", "read this", "open this", "看看这个链接", "看看这个网页", "访问一下", "打开这个"]
        return actionMarkers.contains(where: { input.contains($0) })
    }

    private var requestsFreshInformation: Bool {
        let temporal = ["今天", "今日", "最新", "刚刚", "新闻", "早间", "日报", "周报", "趋势", "现在", "近期", "本周", "本月", "2026"]
        let topics = ["新闻", "整理", "搜索", "查", "汇总", "简报", "动态", "发生", "发布", "更新", "价格", "版本"]
        return temporal.contains(where: { input.contains($0) })
            && topics.contains(where: { input.contains($0) })
    }

    private var requestsWebResearch: Bool {
        rawRequestsWebResearch && !capabilityOnly
    }

    private var rawRequestsWebResearch: Bool {
        let markers = ["联网", "上网", "网页", "官网", "搜一下", "搜搜", "查一下", "查查"]
        // "搜索" alone is too broad — "你搜索到的" refers to past results, not a web search request.
        // Only count "搜索" if it's NOT preceded by backward-referencing context.
        let hasSearchMarker = markers.contains { input.contains($0) }
        let hasPlainSearch = input.contains("搜索")
            && !["搜索到的", "搜索结果", "你搜索", "已搜索", "刚搜索"].contains(where: { input.contains($0) })
        return hasSearchMarker || hasPlainSearch
    }

    private var requestsModelCurrentInfo: Bool {
        let comparisonIntent = ["对比", "比较", "比", "能力", "强多少", "发布", "最新"].contains { input.contains($0) }
        guard comparisonIntent else { return false }
        let modelMarkers = ["qwen", "gpt", "glm", "kimi", "claude", "deepseek", "llama", "gemini", "模型"]
        if modelMarkers.contains(where: { input.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        return input.range(of: #"[a-zA-Z\u{4e00}-\u{9fff}]+[0-9]+(\.[0-9]+)?"#, options: .regularExpression) != nil
    }

    private var requestsLocalIO: Bool {
        if containsLocalPath || referencesOfficeDocument { return true }
        return ["读取", "读一下", "打开文件", "看这个文件", "这个路径", "这些路径", "搜索", "搜索项目", "搜索代码", "查找文件", "当前项目", "工作区",
         "看看项目", "看下项目", "看一下项目", "看看代码", "看下代码", "查看项目", "查看代码",
         "检查项目", "检查代码", "分析项目", "分析代码", "找到", "找一下", "定位"].contains {
            input.contains($0)
        }
    }

    private var requestsDiagnosis: Bool {
        ["诊断", "排查", "分析一下", "看下原因", "为什么", "哪里出问题", "问题在哪", "哪里不好", "不对劲", "不好用", "难用", "卡住",
         "卡顿", "卡死", "很卡", "各种卡", "慢", "很慢", "延迟", "掉帧", "性能"].contains {
            input.contains($0)
        }
    }

    private var requestsAdvice: Bool {
        ["优化建议", "改进建议", "怎么优化", "如何优化", "哪里能优化", "哪些能优化", "怎么改进", "如何改进", "哪里能改进", "哪些能改进", "应该怎么", "给建议", "出方案", "给思路", "看法"].contains {
            effectiveInput.contains($0)
        }
    }

    private var requestsEvaluation: Bool {
        ["评估", "评价", "review一下", "看一下质量", "优缺点", "利弊", "风险", "可行性"].contains {
            input.contains($0)
        }
    }

    private var requestsSummary: Bool {
        ["总结", "汇总", "梳理", "复盘", "整理一下", "讲清楚", "说明一下"].contains {
            input.contains($0)
        }
    }

    private var requestsPlanOnly: Bool {
        ["计划", "规划", "roadmap", "路线图", "步骤", "下一步", "先别改", "不要改", "只给建议", "只分析"].contains {
            input.contains($0)
        }
    }

    private var explicitPlanOnly: Bool {
        ["先别改", "不要改", "别改", "不用改", "只给建议", "只分析", "先只分析", "不要执行", "先不执行", "只要方案"].contains {
            input.contains($0)
        }
    }

    private var asksForAdviceInsteadOfMutation: Bool {
        if explicitPlanOnly { return true }
        let adviceMarkers = [
            "优化建议", "改进建议", "怎么优化", "如何优化", "哪里能优化", "哪些能优化",
            "怎么改进", "如何改进", "哪里能改进", "哪些能改进",
            "应该怎么", "给建议", "出方案", "给思路", "看法", "优缺点", "利弊"
        ]
        guard adviceMarkers.contains(where: { effectiveInput.contains($0) }) else { return false }
        let explicitMutationMarkers = [
            "直接改", "帮我改", "修改", "写入", "创建文件", "删除文件", "实现", "修复",
            "改一下", "改写", "接入", "集成", "迁移", "替换", "重命名", "保存",
            "改成", "换成", "改为", "重写", "拆分", "合并",
            "fix", "implement", "create", "add", "remove", "update", "refactor", "rewrite"
        ]
        return !explicitMutationMarkers.contains { input.contains($0) }
    }

    private var requestsShellExecution: Bool {
        ["运行", "执行命令", "跑测试", "构建", "部署", "启动服务",
         "安装", "卸载", "升级", "更新", "下载", "编译", "打包", "发布",
         "npm install", "pip install", "brew install", "cargo install", "apt install", "yarn add", "pnpm add",
         "make", "cmake", "build", "run", "setup"].contains { input.contains($0) }
    }

    private var requestsMutation: Bool {
        guard !asksForAdviceInsteadOfMutation else { return false }
        let strongMutationMarkers = [
            "直接改", "帮我改", "修改", "写入", "创建文件", "删除文件", "实现", "修复", "改一下", "改写",
            "接入", "集成", "迁移", "替换", "重命名", "移动", "复制",
            "导入", "导出", "初始化", "保存", "另存", "翻译成", "转成",
            "改成", "换成", "改为", "重写", "拆分", "合并",
            "记住", "记下", "长期记忆", "写进记忆", "保存偏好", "保存到记忆", "remember",
            "fix", "implement", "create", "add", "remove", "update", "refactor", "rewrite"
        ]
        if strongMutationMarkers.contains(where: { input.contains($0) }) { return true }

        let broadMutationMarkers = [
            "添加", "增加", "配置", "设置", "加入", "注册",
            "调整", "改进", "优化", "优化下", "优化一下", "性能优化", "提升性能", "提速", "加速"
        ]
        guard broadMutationMarkers.contains(where: { input.contains($0) }) else { return false }
        let questionOrAdviceMarkers = [
            "怎么", "如何", "哪里", "哪些", "什么", "建议", "方案", "思路", "看法",
            "可不可以", "能不能", "是否", "要不要", "该不该"
        ]
        return !questionOrAdviceMarkers.contains { input.contains($0) }
    }

    private var requestsWikiPersistence: Bool {
        RoutingTextHeuristics.requestsWikiPersistence(input)
    }

    private var requestedDeliverable: Bool {
        rawRequestedDeliverable && !capabilityOnly
    }

    private var rawRequestedDeliverable: Bool {
        ["生成", "创建", "整理", "汇总", "给我一份", "写一个", "写一份", "写一段", "做一个"].contains { input.contains($0) }
    }

    var requestsImageGeneration: Bool {
        guard !capabilityOnly else { return false }
        return RoutingTextHeuristics.requestsImageGeneration(input)
    }

    private var requestsPMDocument: Bool {
        let pmMarkers = ["prd", "PRD", "需求文档", "产品需求", "用户故事", "user story", "user stories",
                         "竞品分析", "竞品调研", "competitive analysis", "实验设计", "a/b test", "ab test",
                         "okr", "OKR", "复盘", "retrospective", "用户画像", "persona",
                         "上线清单", "launch checklist", "发版说明", "release notes",
                         "jtbd", "JTBD", "验收标准", "acceptance criteria",
                         "边界用例", "edge case", "方案简述", "solution brief",
                         "架构决策", "adr", "ADR", "问题定义", "problem statement",
                         "假设验证", "hypothesis", "干系人汇报"]
        return pmMarkers.contains { input.localizedCaseInsensitiveContains($0) }
    }

    private var wantsCodeReview: Bool {
        let reviewMarkers = ["代码审查", "审查代码", "review", "审查", "看下改动", "看一下改动", "检查改动"]
        guard reviewMarkers.contains(where: { input.contains($0) }) else { return false }
        return codeOrProjectContext
    }

    private var wantsTestGeneration: Bool {
        let testMarkers = ["生成测试", "写测试", "补测试", "测试用例", "单元测试"]
        guard testMarkers.contains(where: { input.contains($0) }) else { return false }
        return codeOrProjectContext || input.contains("这个模块") || input.contains("这个函数")
    }

    private var wantsDebugWorkflow: Bool {
        let debugMarkers = ["调试", "诊断", "排查", "排查报错", "分析报错", "定位报错", "这个报错"]
        guard debugMarkers.contains(where: { input.contains($0) }) else { return false }
        return codeOrProjectContext || input.contains("日志") || input.contains("堆栈") || input.contains("异常") || input.contains("报错") || input.contains("crash")
    }

    private var wantsRefactorWorkflow: Bool {
        let refactorMarkers = ["重构", "优化结构"]
        guard refactorMarkers.contains(where: { input.contains($0) }) else { return false }
        return codeOrProjectContext
    }

    private var wantsDocumentationWorkflow: Bool {
        let docMarkers = ["生成文档", "写文档", "补文档", "接口文档"]
        guard docMarkers.contains(where: { input.contains($0) }) else { return false }
        return codeOrProjectContext || input.contains("readme")
    }

    private var wantsTranslationWorkflow: Bool {
        let translateMarkers = ["翻译文件", "翻译这个文件", "翻译成", "转成英文", "英文版", "国际化", "i18n", "本地化"]
        return translateMarkers.contains { input.contains($0) } && (codeOrProjectContext || containsLocalPath || referencesOfficeDocument)
    }

    private var codeOrProjectContext: Bool {
        let markers = [
            "代码", "项目", "文件", "模块", "函数", "类", "组件", "接口", "仓库",
            "diff", "commit", "pr", "分支", "变更", "改动", ".swift", ".ts", ".tsx",
            ".js", ".py", ".md", ".pptx", ".docx", ".xlsx", ".xlsm", "package.json", "readme"
        ]
        return markers.contains { input.contains($0) }
    }

    private var hasInspectableLocalContext: Bool {
        if requestsLocalIO || codeOrProjectContext || containsLocalPath || referencesOfficeDocument {
            return true
        }
        let appContextMarkers = [
            "页面", "界面", "按钮", "输入", "输入框", "交互", "性能", "侧栏", "左边", "右边", "窗口",
            "会话", "追问", "历史任务", "新会话", "上下文", "agent", "Agent",
            "连接器", "工具调用", "工具", "来财", "app", "应用", "UI", "ui"
        ]
        return appContextMarkers.contains { input.contains($0) }
    }

    private var reportsInspectableProblem: Bool {
        guard hasInspectableLocalContext else { return false }
        let problemMarkers = [
            "有问题", "不对", "丢失", "没反应", "没生效", "坏了", "异常",
            "报错", "bug", "Bug", "卡", "慢", "卡顿", "不好用", "难用"
        ]
        return problemMarkers.contains { input.contains($0) }
    }

    func workflowReason(for workflow: String) -> String {
        switch workflow {
        case "code-review":
            return "用户要求审查代码或项目改动，适合进入代码审查工作流。"
        case "test-gen":
            return "用户要求为代码或模块补测试，适合进入测试生成工作流。"
        case "debug":
            return "用户要求定位报错或异常，适合进入调试诊断工作流。"
        case "refactor":
            return "用户要求重构代码或项目结构，适合进入重构工作流。"
        case "doc-gen":
            return "用户要求生成或补充项目文档，适合进入文档工作流。"
        case "translate":
            return "用户要求翻译文件或做本地化，适合进入翻译工作流。"
        default:
            return "用户目标匹配可复用工作流。"
        }
    }

    func workflowCapabilities(for workflow: String) -> [String] {
        switch workflow {
        case "code-review":
            return ["读取变更", "审查风险", "汇总问题"]
        case "test-gen":
            return ["读取代码", "生成测试", "提出文件修改"]
        case "debug":
            return ["搜索错误", "运行诊断", "定位原因"]
        case "refactor":
            return ["读取结构", "规划重构", "提出文件修改"]
        case "doc-gen":
            return ["读取项目", "生成文档", "提出文件修改"]
        case "translate":
            return ["读取文件", "翻译内容", "提出文件修改"]
        default:
            return ["读取上下文", "执行预设步骤", "汇总结果"]
        }
    }

    var capabilityOnly: Bool {
        let capabilityPatterns = ["你能", "能不能", "可以", "会不会", "是否支持", "支持", "能否", "可不可以"]
        guard isDirectQuestion, capabilityPatterns.contains(where: { input.contains($0) }) else { return false }
        guard !requestsMutation else { return false }
        return !input.contains("帮我") && !input.contains("给我") && !input.contains("现在") && !input.contains("一下")
    }

    var executionConfidence: Double {
        if containsURL || requestsFreshInformation || requestsWebResearch || requestsModelCurrentInfo { return 0.88 }
        if requestsWikiPersistence { return 0.86 }
        if requestsImageGeneration { return 0.84 }
        if requestsMutation || requestsShellExecution { return 0.84 }
        if requestsLocalIO { return 0.80 }
        return 0.70
    }

    var executionReason: String {
        if containsURL { return "用户提供了网页链接，需要读取外部资料。" }
        if requestsWikiPersistence { return "用户要求把当前材料沉淀到 Wiki/知识库，需要调用知识库写入能力。" }
        if requestsImageGeneration { return "用户要求生成视觉素材，需要调用图片生成能力。" }
        if requestsFreshInformation || requestsWebResearch || requestsModelCurrentInfo { return "用户需要联网或时效信息，需要调用搜索/网页工具。" }
        if requestsLocalIO { return "用户要求读取、搜索或理解本地工作区。" }
        if requestsShellExecution { return "用户要求运行命令、测试、构建或部署。" }
        if requestsMutation { return "用户要求修改或生成本地文件，需要进入可审查的执行流程。" }
        return "用户要求产出具体结果。"
    }

    var expectedCapabilities: [String] {
        var capabilities: [String] = []
        if requestsImageGeneration { capabilities.append("生成图片") }
        if requestsFreshInformation || requestsWebResearch || requestsModelCurrentInfo || containsURL { capabilities.append("联网检索") }
        let contextualInspection = hasInspectableLocalContext
            && (requestsDiagnosis || requestsAdvice || requestsEvaluation || requestsSummary || requestsPlanOnly || reportsInspectableProblem)
        if requestsLocalIO || contextualInspection { capabilities.append("读取工作区") }
        if requestsShellExecution { capabilities.append("运行命令") }
        if requestsWikiPersistence { capabilities.append("写入知识库") }
        if requestsMutation || (!prefersAnalysisOnly && hasInspectableLocalContext && (requestsDiagnosis || requestsAdvice || reportsInspectableProblem)) { capabilities.append("提出文件修改") }
        if requestedDeliverable || requestsWikiPersistence { capabilities.append("整理交付") }
        if !prefersAnalysisOnly, !capabilities.contains("形成可验证结果") { capabilities.append("形成可验证结果") }
        return capabilities.isEmpty ? ["规划", "执行", "总结"] : capabilities
    }
}
