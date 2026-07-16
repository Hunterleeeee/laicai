import AppKit
import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

// MARK: - Multi-Agent Flow View

struct MultiAgentFlowView: View {
    let plan: MultiAgentPlan
    @State private var selectedAgentID: UUID?
    @State private var pulsePhase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──
            HStack(spacing: AppSpace.medium) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(Brand.purple.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.purple)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("多会话协同编排")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                    Text("\(plan.agents.count) 个会话 · \(plan.progress)")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }

                Spacer()

                flowStatusPill(for: plan.status)
            }
            .padding(.horizontal, AppSpace.extraLarge)
            .padding(.vertical, AppSpace.large)

            // ── Divider ──
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.clear, Brand.purple.opacity(0.15), Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)

            // ── Flow Pipeline ──
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(plan.agents.enumerated()), id: \.element.id) { index, agent in
                        flowNodeCard(agent: agent, index: index)
                            .onTapGesture {
                                selectedAgentID = selectedAgentID == agent.id ? nil : agent.id
                            }

                        if index < plan.agents.count - 1 {
                            flowConnector(from: agent, toIndex: index + 1)
                        }
                    }
                }
                .padding(.horizontal, AppSpace.extraLarge)
                .padding(.vertical, AppSpace.extraLarge)
            }

            // ── Selected Agent Detail ──
            if let selectedID = selectedAgentID,
                let agent = plan.agents.first(where: { $0.id == selectedID })
            {
                Rectangle().fill(SurfaceGrade.divider).frame(height: 0.5)
                flowAgentDetail(agent: agent)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.extraLarge, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.extraLarge, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Brand.purple.opacity(0.20), Brand.primary.opacity(0.10), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: Brand.purple.opacity(0.035), radius: 6, y: 2)
        .onAppear { pulsePhase = true }
    }

    // ── Node Card ──

    private func flowNodeCard(agent: AgentNode, index: Int) -> some View {
        let isSelected = selectedAgentID == agent.id
        let isRunning = agent.status == .running
        let nodeColor = flowColor(for: agent.status)

        return VStack(spacing: AppSpace.small) {
            ZStack {
                // Background circle
                Circle()
                    .fill(nodeColor.opacity(0.10))
                    .frame(width: 52, height: 52)

                if isRunning {
                    Circle()
                        .stroke(nodeColor.opacity(0.35), lineWidth: 2)
                        .frame(width: 52, height: 52)
                }

                // Completed checkmark ring
                if agent.status == .completed {
                    Circle()
                        .stroke(nodeColor.opacity(0.25), lineWidth: 2)
                        .frame(width: 52, height: 52)
                }

                // Selected ring
                if isSelected && !isRunning {
                    Circle()
                        .stroke(nodeColor.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 56, height: 56)
                }

                // Icon
                Image(systemName: agent.role.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(nodeColor)
            }

            // Label
            VStack(spacing: 2) {
                Text(agent.role.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? TextGrade.primary : TextGrade.secondary)

                flowStatusLabel(agent.status)
            }

            // Step count
            if !agent.stepIDs.isEmpty {
                Text("\(agent.stepIDs.count) 步")
                    .font(AppFont.micro)
                    .foregroundStyle(TextGrade.ghost)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(SurfaceGrade.elevated.opacity(0.6))
                    )
            }
        }
        .frame(minWidth: 80)
        .padding(.vertical, AppSpace.small)
        .padding(.horizontal, AppSpace.small)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(isSelected ? SurfaceGrade.elevated.opacity(0.5) : Color.clear)
        )
    }

    // ── Connector ──

    private func flowConnector(from agent: AgentNode, toIndex: Int) -> some View {
        let handoff = plan.handoffs.first(where: {
            $0.fromAgentID == agent.id && toIndex < plan.agents.count && $0.toAgentID == plan.agents[toIndex].id
        })
        let hasArtifact = !(handoff?.artifact.isEmpty ?? true)
        let isDone = agent.status == .completed
        let isActive = agent.status == .running
        let completedColors = [
            flowColor(for: .completed).opacity(0.5),
            flowColor(for: .completed).opacity(0.2),
        ]
        let idleColors = [
            TextGrade.ghost.opacity(0.3),
            TextGrade.ghost.opacity(0.15),
        ]

        return VStack(spacing: AppSpace.extraSmall) {
            ZStack {
                // Connector line
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        isDone
                            ? LinearGradient(colors: completedColors, startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: idleColors, startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: 32, height: 2)

                if isActive {
                    Circle()
                        .fill(Brand.primary)
                        .frame(width: 6, height: 6)
                }

                // Arrow head
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isDone ? flowColor(for: .completed).opacity(0.6) : TextGrade.ghost.opacity(0.4))
                    .offset(x: 20)
            }
            .frame(width: 48)

            if hasArtifact {
                Text("数据")
                    .font(AppFont.micro)
                    .foregroundStyle(Brand.primary.opacity(0.7))
            }
        }
    }

    // ── Agent Detail Panel ──

    private func flowAgentDetail(agent: AgentNode) -> some View {
        VStack(alignment: .leading, spacing: AppSpace.medium) {
            HStack(spacing: AppSpace.medium) {
                ZStack {
                    Circle()
                        .fill(flowColor(for: agent.status).opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: agent.role.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(flowColor(for: agent.status))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.role.title)
                        .font(AppFont.headline)
                        .foregroundStyle(TextGrade.primary)
                    Text(agent.status.title)
                        .font(AppFont.caption)
                        .foregroundStyle(flowColor(for: agent.status))
                }

                Spacer()

                if !agent.output.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                        Text("已产出")
                            .font(AppFont.captionMedium)
                    }
                    .foregroundStyle(Semantic.success)
                }
            }

            if !agent.input.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    Label("输入", systemImage: "arrow.down.circle")
                        .font(AppFont.micro)
                        .foregroundStyle(TextGrade.ghost)
                    Text(agent.input)
                        .font(AppFont.body)
                        .foregroundStyle(TextGrade.secondary)
                        .lineLimit(4)
                        .padding(AppSpace.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                .fill(SurfaceGrade.sunken)
                        )
                }
            }

            if !agent.output.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    Label("输出", systemImage: "arrow.up.circle")
                        .font(AppFont.micro)
                        .foregroundStyle(TextGrade.ghost)
                    Text(agent.output)
                        .font(AppFont.body)
                        .foregroundStyle(TextGrade.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .padding(AppSpace.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                .fill(SurfaceGrade.sunken)
                        )
                }
            }

            if !agent.stepIDs.isEmpty {
                HStack(spacing: AppSpace.extraSmall) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 10))
                    Text("\(agent.stepIDs.count) 个执行步骤")
                        .font(AppFont.caption)
                }
                .foregroundStyle(TextGrade.muted)
            }
        }
        .padding(AppSpace.extraLarge)
    }

    // ── Helpers ──

    private func flowStatusLabel(_ status: TaskStatus) -> some View {
        Text(status.title)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(flowColor(for: status))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(flowColor(for: status).opacity(0.10))
            )
    }

    private func flowStatusPill(for status: TaskStatus) -> some View {
        HStack(spacing: 4) {
            if status == .running {
                Circle()
                    .fill(flowColor(for: status))
                    .frame(width: 6, height: 6)
            } else {
                Circle()
                    .fill(flowColor(for: status))
                    .frame(width: 6, height: 6)
            }
            Text(status.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(flowColor(for: status))
        }
        .padding(.horizontal, AppSpace.small + 2)
        .padding(.vertical, AppSpace.extraSmall + 1)
        .background(
            Capsule().fill(flowColor(for: status).opacity(0.10))
        )
        .overlay(
            Capsule().strokeBorder(flowColor(for: status).opacity(0.15), lineWidth: 0.5)
        )
    }

    private func flowColor(for status: TaskStatus) -> Color {
        switch status {
        case .queued: return TextGrade.muted
        case .running: return Brand.primary
        case .waitingReview: return Semantic.warning
        case .completed: return Semantic.success
        case .failed: return Semantic.error
        case .cancelled: return TextGrade.ghost
        }
    }
}
