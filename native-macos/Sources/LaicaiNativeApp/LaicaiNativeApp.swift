import AppKit
import SwiftUI
import LaicaiNativeFoundation
import LaicaiNativeUI

@main
@MainActor
struct LaicaiNativeApp: App {
    @NSApplicationDelegateAdaptor(LaicaiAppDelegate.self) private var appDelegate
    @StateObject private var store: AppStore

    init() {
        let store = LaicaiAppRuntime.store
        _store = StateObject(wrappedValue: store)
        appDelegate.store = store
        let delegate = appDelegate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            delegate.store = store
            delegate.ensureMainWindow(reason: "app-init")
        }
    }

    var body: some Scene {
        WindowGroup("来财", id: "main") {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.light)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    appDelegate.store = store
                    appDelegate.ensureMainWindow(reason: "swiftui-task")
                    await LaicaiRuntimeServices.start(store: store, appDelegate: appDelegate)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新任务") {
                    store.newThread()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("新会话") {
                    store.newThread()
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

                Button("停止生成") {
                    store.stopGenerating()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!store.state.isGenerating)

                Divider()

                Button("滚动到底部") {
                    NotificationCenter.default.post(name: .laicaiScrollToBottom, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])

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

@MainActor
private enum LaicaiAppRuntime {
    static let store = AppStore.live()
}

@MainActor
private enum LaicaiRuntimeServices {
    private static var didStart = false

    static func start(store: AppStore, appDelegate: LaicaiAppDelegate) async {
        if HeadlessRunner.shared.isHeadless {
            _ = HeadlessRunner.shared.runIfNeeded(store: store)
            return
        }
        guard !didStart else { return }
        didStart = true

        MenuBarAgent.shared.install()
        MenuBarAgent.shared.setOpenMainWindowHandler { [weak appDelegate] in
            appDelegate?.ensureMainWindow(reason: "menu-bar")
        }
        GlobalShortcutManager.shared.install()
        NotificationManager.shared.requestPermission()
        store.checkAllConnectorsHealth()
    }
}

@MainActor
final class LaicaiAppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore?
    private var fallbackWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        store = store ?? LaicaiAppRuntime.store
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        store = store ?? LaicaiAppRuntime.store
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.ensureMainWindow(reason: "did-finish-launching")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ensureMainWindow(reason: "reopen")
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.ensureMainWindow(reason: "activate")
        }
    }

    func ensureMainWindow(reason: String) {
        guard !HeadlessRunner.shared.isHeadless else { return }
        NSApp.setActivationPolicy(.regular)
        let visibleWindows = NSApp.windows.filter(isMainAppWindow(_:))
        if let visible = preferredMainWindow(from: visibleWindows) {
            closeDuplicateMainWindows(keeping: visible, in: visibleWindows)
            closeHiddenAuxiliaryWindows(keeping: visible)
            visible.makeKeyAndOrderFront(nil)
            visible.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let store = store ?? LaicaiAppRuntime.store
        let window = makeFallbackMainWindow(store: store)
        fallbackWindow = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        closeHiddenAuxiliaryWindows(keeping: window)
        NSApp.activate(ignoringOtherApps: true)
        return
    }

    private func makeFallbackMainWindow(store: AppStore) -> NSWindow {
        let root = RootView()
            .environmentObject(store)
            .preferredColorScheme(.light)
            .frame(minWidth: 900, minHeight: 600)
            .task { [weak self] in
                guard let self else { return }
                self.store = store
                await LaicaiRuntimeServices.start(store: store, appDelegate: self)
            }
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = "来财"
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        return window
    }

    private func preferredMainWindow(from windows: [NSWindow]) -> NSWindow? {
        windows.first(where: { $0.isKeyWindow })
            ?? windows.first(where: { $0.isMainWindow })
            ?? windows.first
    }

    private func closeDuplicateMainWindows(keeping keptWindow: NSWindow, in windows: [NSWindow]) {
        for window in windows where window !== keptWindow {
            window.close()
        }
    }

    private func closeHiddenAuxiliaryWindows(keeping keptWindow: NSWindow) {
        for window in NSApp.windows where window !== keptWindow {
            guard window.level == .normal, !window.isVisible || window.title.isEmpty else { continue }
            window.close()
        }
    }

    private func isMainAppWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible, window.level == .normal, !window.isMiniaturized else { return false }
        if window.title == "来财" { return true }
        return false
    }
}
