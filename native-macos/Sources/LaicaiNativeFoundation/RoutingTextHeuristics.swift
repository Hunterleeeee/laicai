import Foundation

enum RoutingTextHeuristics {
    private static let wikiTargets = ["wiki", "知识库", "obsidian", "vault", "笔记"]
    private static let wikiPersistenceActions = [
        "沉淀", "保存", "存到", "写到", "写进", "写入", "整理到", "整理成",
        "生成", "生成到", "收进", "归档", "落地", "放到", "记录到"
    ]

    private static let imageActions = [
        "生成", "重新生成", "创建", "做一张", "做张", "做个", "画一张", "画张", "画个",
        "设计", "出一张", "出张", "出个", "来一张", "来张", "来个", "制作",
        "generate", "create", "draw", "design", "make"
    ]
    private static let imageTargets = [
        "图片", "图像", "图", "配图", "插图", "海报", "封面", "主图", "介绍图",
        "宣传图", "商品图", "产品图", "详情图", "页面图", "生图", "banner", "logo", "头像", "壁纸",
        "poster", "image", "illustration", "cover", "thumbnail", "visual"
    ]
    private static let nonGenerativeImageContexts = [
        "代码图", "架构图", "流程图", "类图", "mermaid", "截图", "看图", "读图", "图片里"
    ]

    static func requestsWikiPersistence(_ message: String) -> Bool {
        let text = normalized(message)
        guard !text.isEmpty else { return false }
        return containsAny(wikiTargets, in: text)
            && containsAny(wikiPersistenceActions, in: text)
    }

    static func requestsImageGeneration(_ message: String) -> Bool {
        let text = normalized(message)
        guard !text.isEmpty else { return false }
        return containsAny(imageActions, in: text)
            && containsAny(imageTargets, in: text)
            && !containsAny(nonGenerativeImageContexts, in: text)
    }

    private static func normalized(_ message: String) -> String {
        message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func containsAny(_ needles: [String], in haystack: String) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
