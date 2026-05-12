import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreRoutingPlannerTests: LaicaiNativeFoundationTestCase {
    func testNormalizesFailurePreview() {
        let raw = #"请求失败：provider returned {"error":{"message":"model does not exist","type":"invalid_request_error"}}"#

        XCTAssertEqual(normalizedSessionPreview(raw), "请求失败，请检查连接器配置。")
    }
    func testCapabilityQuestionStaysInChatMode() {
        XCTAssertEqual(IntentRouter.classify("你能生成视频吗？"), .chat)
        XCTAssertEqual(IntentRouter.classify("你可以创建图片吗?"), .chat)
        XCTAssertEqual(IntentRouter.classify("你能联网搜索吗？"), .chat)
        XCTAssertEqual(IntentRouter.classify("你支持运行测试吗？"), .chat)
    }
    func testCapabilityQuestionDoesNotRecurseThroughActionSignals() {
        let prompts = [
            "你能生成视频吗？",
            "你可以整理资料吗？",
            "是否支持联网搜索？",
            "能不能创建图片？"
        ]

        for prompt in prompts {
            XCTAssertEqual(IntentRouter.plan(prompt).intent, .chat)
        }
    }
    func testConcreteGenerationRequestBecomesTask() {
        XCTAssertEqual(IntentRouter.classify("帮我生成一个 README"), .task)
    }
    func testSemanticImageRequestsBecomeImageGenerationTasks() {
        let prompts = [
            "做一张雪碧介绍图",
            "设计个产品主图",
            "来个活动海报",
            "给这个品牌做个 logo",
            "make a poster for Sprite"
        ]

        for prompt in prompts {
            let decision = IntentRouter.plan(prompt)
            XCTAssertEqual(decision.intent, .task, prompt)
            XCTAssertEqual(decision.routeLabel, "图片生成", prompt)
            XCTAssertTrue(decision.expectedCapabilities.contains("生成图片"), prompt)
        }
    }
    func testImageCapabilityQuestionStaysChat() {
        XCTAssertEqual(IntentRouter.classify("你能生成图片吗？"), .chat)
    }
    func testPoliteExplanationRequestStaysInChatMode() {
        XCTAssertEqual(IntentRouter.classify("请先解释一下"), .chat)
        XCTAssertEqual(IntentRouter.classify("请说说你的能力"), .chat)
    }
    func testExplicitToolRequestsBecomeTask() {
        XCTAssertEqual(IntentRouter.classify("请帮我联网搜索一下 Qwen3.6 相比 3.5 有哪些新能力？"), .task)
        XCTAssertEqual(IntentRouter.classify("为什么不能联网搜搜呢？"), .task)
        XCTAssertEqual(IntentRouter.classify("上网查一下 Qwen3.6"), .task)
        XCTAssertEqual(IntentRouter.classify("帮我搜一下 Qwen3.6 比 Qwen3.5 强多少"), .task)
        XCTAssertEqual(IntentRouter.classify("读一下 https://example.com 这个页面"), .task)
        XCTAssertEqual(IntentRouter.classify("跑测试看看有没有问题"), .task)
    }
    func testFreshNewsRequestBecomesTask() {
        XCTAssertEqual(IntentRouter.classify("你先给我整理下今天的早间新闻，重点在AI领域"), .task)
        XCTAssertEqual(IntentRouter.classify("今天 AI 领域有什么最新动态？"), .task)
    }
    func testCurrentModelComparisonBecomesTask() {
        let decision = IntentRouter.plan("glm-5.1和kimi k2.6 能力对比")

        XCTAssertEqual(decision.intent, .task)
        XCTAssertTrue(decision.expectedCapabilities.contains("联网检索"))
    }
    func testProjectRewritePlansReadAndMutation() {
        let decision = IntentRouter.plan("你能读取本地的项目吧？并且优化项目，直接改写本地文件")

        XCTAssertEqual(decision.intent, .task)
        XCTAssertTrue(decision.expectedCapabilities.contains("读取工作区"))
        XCTAssertTrue(decision.expectedCapabilities.contains("提出文件修改"))
    }
    func testWorkflowRequestsRouteBySemanticGoal() {
        let decision = IntentRouter.plan("帮我审查一下这次改动")

        XCTAssertEqual(decision.intent, .workflow("code-review"))
        XCTAssertTrue(decision.reason.contains("代码审查"))
        XCTAssertTrue(decision.expectedCapabilities.contains("审查风险"))
        XCTAssertEqual(IntentRouter.classify("给这个模块补测试用例"), .workflow("test-gen"))
        XCTAssertEqual(IntentRouter.classify("排查一下这个报错"), .workflow("debug"))
    }
    func testWorkflowKeywordsNeedCodeOrProjectContext() {
        XCTAssertEqual(IntentRouter.classify("review 一下 Claude Code 和 Codex 的体验差距"), .chat)
        XCTAssertEqual(IntentRouter.classify("这个词怎么翻译更自然？"), .chat)
        XCTAssertEqual(IntentRouter.classify("帮我翻译这个文件"), .workflow("translate"))
    }
    func testPlannerDecisionExplainsRoute() {
        let decision = IntentRouter.plan("帮我搜一下 Qwen3.6 比 Qwen3.5 强多少")

        XCTAssertEqual(decision.intent, .task)
        XCTAssertGreaterThan(decision.confidence, 0.8)
        XCTAssertEqual(decision.routeLabel, "任务")
        XCTAssertTrue(decision.expectedCapabilities.contains("联网检索"))
        XCTAssertFalse(decision.reason.isEmpty)
    }
    func testFrustrationDetectorRecognizesContextLossComplaints() {
        XCTAssertTrue(UserFrustrationDetector.isFrustrated("你看，胡说八道了，刚才那个会话上下文没了"))
        XCTAssertTrue(UserFrustrationDetector.shouldRecoverRecentTask("输出被截断了，然后又新建线程"))
        XCTAssertFalse(UserFrustrationDetector.isFrustrated("请解释一下这个概念"))
    }
}
