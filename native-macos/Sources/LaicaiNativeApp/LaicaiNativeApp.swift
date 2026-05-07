import SwiftUI
import LaicaiNativeFoundation
import LaicaiNativeUI

@main
@MainActor
struct LaicaiNativeApp: App {
    @StateObject private var store: AppStore

    init() {
        let store = AppStore.live()
        _store = StateObject(wrappedValue: store)
    }

    private func startRuntimeServices() async {
        let isHeadless = HeadlessRunner.shared.isHeadless
        if isHeadless {
            _ = HeadlessRunner.shared.runIfNeeded(store: store)
            return
        }

        MenuBarAgent.shared.install()
        GlobalShortcutManager.shared.install()
        NotificationManager.shared.requestPermission()
        store.checkAllConnectorsHealth()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    await startRuntimeServices()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新会话") {
                    store.newSession()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("切换工作台标签") {
                    store.selectNextWorkbenchTab()
                }
                .keyboardShortcut("3", modifiers: [.command])
            }

            CommandMenu("会话") {
                Button("命令面板") {
                    NotificationCenter.default.post(name: .laicaiToggleCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button(store.state.isGenerating ? "停止生成" : "发送草稿") {
                    if store.state.isGenerating {
                        store.stopGenerating()
                    } else {
                        store.sendDraft()
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button("搜索") {
                    NotificationCenter.default.post(name: .laicaiToggleSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
