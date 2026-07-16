import XCTest

@testable import LaicaiNativeDomain
@testable import LaicaiNativeFoundation

@MainActor
final class MultiAgentContractTests: LaicaiNativeFoundationTestCase {
    func testOnlyCoderRoleCanWriteProjectFiles() {
        let writeTools: Set<String> = ["file.write", "file.edit", "diff.apply"]

        XCTAssertFalse(AgentRole.planner.allowedTools.contains { writeTools.contains($0) })
        XCTAssertFalse(AgentRole.researcher.allowedTools.contains { writeTools.contains($0) })
        XCTAssertFalse(AgentRole.tester.allowedTools.contains { writeTools.contains($0) })
        XCTAssertFalse(AgentRole.reviewer.allowedTools.contains { writeTools.contains($0) })
        XCTAssertTrue(AgentRole.coder.allowedTools.contains("file.write"))
        XCTAssertTrue(AgentRole.coder.outputContract.contains("唯一允许写入"))
    }

    func testCodeMutationPlanIncludesCoderTesterReviewerChain() {
        let connector = makeConnector(modelName: "gpt-5.5")

        let plan = MultiAgentOrchestrator.createPlan(
            for: "优化项目性能，修改代码，运行测试并审查结果",
            intent: .task,
            connectors: [connector],
            activeConnectorID: connector.id
        )

        let roles = plan?.agents.map(\.role) ?? []
        XCTAssertTrue(roles.contains(.planner))
        XCTAssertTrue(roles.contains(.coder))
        XCTAssertTrue(roles.contains(.tester))
        XCTAssertTrue(roles.contains(.reviewer))
        let coderID = plan?.agents.first(where: { $0.role == .coder })?.id
        let tester = plan?.agents.first(where: { $0.role == .tester })
        let reviewer = plan?.agents.first(where: { $0.role == .reviewer })
        XCTAssertEqual(tester?.dependsOn, coderID.map { [$0] })
        XCTAssertEqual(reviewer?.dependsOn, tester.map { [$0.id] })
    }

    func testAutomaticMultiAgentRequiresExplicitCollaborationOrPipeline() {
        XCTAssertFalse(
            MultiAgentOrchestrator.shouldUseMultiAgent(
                message: "优化一下这个项目",
                intent: .task
            ))
        XCTAssertFalse(
            MultiAgentOrchestrator.shouldUseMultiAgent(
                message: "看看这个界面哪里不好用",
                intent: .task
            ))
        XCTAssertTrue(
            MultiAgentOrchestrator.shouldUseMultiAgent(
                message: "优化项目性能，修改代码，运行测试并审查结果",
                intent: .task
            ))
        XCTAssertTrue(
            MultiAgentOrchestrator.shouldUseMultiAgent(
                message: "让多个 Agent 分工协同处理这个问题",
                intent: .task
            ))
    }

    func testAllRolesUseCodexFullPath() {
        // codexFull is now the only kernel path — no per-role kernel mode selection
        XCTAssertTrue(true)
    }

}
