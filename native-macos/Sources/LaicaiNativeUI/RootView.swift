import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

public struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingSettings = false
    @State private var showSidebar = true
    @State private var showWorkbench = false
    @State private var showingCommandPalette = false
    @State private var sidebarExpanded = true

    public init() {}

    public var body: some View {
        ZStack {
            // Base background — deep void
            SurfaceGrade.base.ignoresSafeArea()

            HStack(spacing: 0) {
                // Thread Rail — always visible, ultra-compact or expanded
                SidebarView(showingSettings: $showingSettings, isVisible: $showSidebar)
                    .frame(width: sidebarExpanded ? LayoutConst.threadRailExpandedWidth : LayoutConst.threadRailWidth)
                    .background(SurfaceGrade.panel)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [Brand.primary.opacity(0.3), Brand.purple.opacity(0.15), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 1)
                    }

                // Main Canvas
                VStack(spacing: 0) {
                    ChatDetailView(
                        showingSettings: $showingSettings,
                        showSidebar: $showSidebar,
                        showWorkbench: $showWorkbench
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Status Bar — live system metrics
                    StatusBarView()
                }
                .background(SurfaceGrade.base)

                // Workbench Panel
                if showWorkbench {
                    Rectangle()
                        .fill(SurfaceGrade.divider)
                        .frame(width: 0.5)

                    WorkbenchView(isVisible: $showWorkbench)
                        .frame(width: 340)
                        .background(SurfaceGrade.panel)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .overlay(alignment: .top) {
            ToastOverlay()
                .padding(.top, 6)
        }
        .overlay {
            if showingCommandPalette {
                CommandPaletteView(
                    isPresented: $showingCommandPalette,
                    showingSettings: $showingSettings,
                    showWorkbench: $showWorkbench
                )
                .environmentObject(store)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView().environmentObject(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .laicaiToggleCommandPalette)) { _ in
            withAnimation(AppAnimation.spring) { showingCommandPalette.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .laicaiOpenSettings)) { _ in
            showingSettings = true
        }
        .onChange(of: store.state.notice?.id) { _ in
            guard let notice = store.state.notice else { return }
            switch notice.style {
            case .info:    ToastCenter.shared.show(notice.message, style: .info)
            case .success: ToastCenter.shared.success(notice.message)
            case .warning: ToastCenter.shared.warn(notice.message)
            case .error:   ToastCenter.shared.error(notice.message)
            }
        }
        .onChange(of: store.state.activeConnectorID) { newID in
            if let id = newID, let c = store.state.connectors.first(where: { $0.id == id }) {
                ToastCenter.shared.success("已切换到 \(c.name)")
            }
        }
        .onChange(of: showSidebar) { newVal in
            withAnimation(AppAnimation.spring) { sidebarExpanded = newVal }
            NotificationCenter.default.post(name: .laicaiPanelToggled, object: nil)
        }
        .onChange(of: showWorkbench) { _ in
            NotificationCenter.default.post(name: .laicaiPanelToggled, object: nil)
        }
    }
}

// MARK: - Status Bar

struct StatusBarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            // Gradient accent line
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Brand.primary, Brand.purple, Brand.teal],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .opacity(0.4)

            HStack(spacing: 0) {
                // Left: active connector + model
                HStack(spacing: AppSpace.sm) {
                    if let c = store.state.activeConnector {
                        Circle()
                            .fill(c.health.color)
                            .frame(width: 6, height: 6)
                            .shadow(color: c.health.color.opacity(0.5), radius: 3)
                        Text(c.modelName.isEmpty ? c.name : c.modelName)
                            .lineLimit(1)
                    } else {
                        Circle()
                            .fill(TextGrade.ghost)
                            .frame(width: 6, height: 6)
                        Text("未连接")
                            .foregroundStyle(TextGrade.ghost)
                    }
                }

                Spacer()

                // Center: active task status
                if store.state.isGenerating {
                    HStack(spacing: AppSpace.xs) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        if let task = store.state.selectedTask {
                            let stepCount = task.steps.filter({ $0.kind == .toolCall || $0.kind == .toolResult }).count
                            Text("步骤 \(stepCount)")
                        } else {
                            Text("生成中")
                        }
                    }
                    .foregroundStyle(Brand.primary)
                }

                Spacer()

                // Right: thread count + keyboard hint
                HStack(spacing: AppSpace.md) {
                    Text("\(store.state.threads.count) 会话")
                    Text("⌘K")
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                                )
                        )
                }
            }
            .statusBarStyle()
            .padding(.horizontal, AppSpace.lg)
            .frame(height: LayoutConst.statusBarHeight)
            .background(SurfaceGrade.base.opacity(0.95))
        }
    }
}
