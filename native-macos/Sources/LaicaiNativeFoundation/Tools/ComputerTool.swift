import Foundation
import AppKit
import LaicaiNativeDomain

// MARK: - Computer Tool

/// Agent tool for macOS automation: launch apps, simulate keyboard/mouse,
/// manage windows, clipboard, screenshots, system info, and notifications.
/// Uses NSWorkspace, CGEvent, and AppleScript under the hood.
public struct ComputerTool: LaicaiTool {
    public var name: String { "computer" }
    public var description: String { "macOS 电脑控制：打开应用、模拟按键、窗口管理、剪贴板、截屏、系统信息、发送通知" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "action": FunctionProperty(type: "string", description: "动作：open_app / open_url / keystroke / type_text / click / screenshot / clipboard_read / clipboard_write / frontmost / windows / system_info / notify / applescript"),
                    "target": FunctionProperty(type: "string", description: "目标：应用名(open_app)、URL(open_url)、按键(keystroke, e.g. 'cmd+c')、文本(type_text)、AppleScript代码(applescript)"),
                    "text": FunctionProperty(type: "string", description: "文本内容（clipboard_write / type_text / notify 时用）"),
                    "x": FunctionProperty(type: "integer", description: "屏幕 X 坐标（click 动作时用）"),
                    "y": FunctionProperty(type: "integer", description: "屏幕 Y 坐标（click 动作时用）"),
                ],
                required: ["action"]
            )
        )
    }

    public var requiresReview: Bool { true }
    public var executionPolicy: ToolExecutionPolicy { .explicitUserApproval }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var action: String
            var target: String?
            var text: String?
            var x: Int?
            var y: Int?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        switch params.action {

        // MARK: - Open App
        case "open_app":
            guard let appName = params.target, !appName.isEmpty else {
                return ToolResult(output: "缺少 target（应用名）", success: false, error: "missing_target")
            }
            return await openApp(appName)

        // MARK: - Open URL
        case "open_url":
            guard let urlStr = params.target, let url = URL(string: urlStr) else {
                return ToolResult(output: "缺少有效的 target（URL）", success: false, error: "missing_target")
            }
            NSWorkspace.shared.open(url)
            return ToolResult(output: "已在默认浏览器打开：\(urlStr)")

        // MARK: - Keystroke
        case "keystroke":
            guard let combo = params.target, !combo.isEmpty else {
                return ToolResult(output: "缺少 target（按键组合，如 'cmd+c'）", success: false, error: "missing_target")
            }
            return simulateKeystroke(combo)

        // MARK: - Type Text
        case "type_text":
            let text = params.text ?? params.target ?? ""
            guard !text.isEmpty else {
                return ToolResult(output: "缺少 text 或 target", success: false, error: "missing_text")
            }
            return typeText(text)

        // MARK: - Click
        case "click":
            guard let x = params.x, let y = params.y else {
                return ToolResult(output: "缺少 x 和 y 坐标", success: false, error: "missing_coords")
            }
            return simulateClick(x: x, y: y)

        // MARK: - Screenshot
        case "screenshot":
            return await captureScreen()

        // MARK: - Clipboard Read
        case "clipboard_read":
            return readClipboard()

        // MARK: - Clipboard Write
        case "clipboard_write":
            let text = params.text ?? params.target ?? ""
            guard !text.isEmpty else {
                return ToolResult(output: "缺少 text 参数", success: false, error: "missing_text")
            }
            return writeClipboard(text)

        // MARK: - Frontmost App
        case "frontmost":
            return frontmostApp()

        // MARK: - Window List
        case "windows":
            return listWindows()

        // MARK: - System Info
        case "system_info":
            return systemInfo()

        // MARK: - Notification
        case "notify":
            let text = params.text ?? params.target ?? "来自 Laicai 的通知"
            return sendNotification(text)

        // MARK: - AppleScript
        case "applescript":
            guard let script = params.target, !script.isEmpty else {
                return ToolResult(output: "缺少 target（AppleScript 代码）", success: false, error: "missing_target")
            }
            return await runAppleScript(script)

        default:
            return ToolResult(
                output: "未知动作 '\(params.action)'，支持：open_app / open_url / keystroke / type_text / click / screenshot / clipboard_read / clipboard_write / frontmost / windows / system_info / notify / applescript",
                success: false,
                error: "unknown_action"
            )
        }
    }

    // MARK: - Implementation

    private func openApp(_ name: String) async -> ToolResult {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        // Try by bundle ID first
        let knownBundleIDs: [String: String] = [
            "safari": "com.apple.Safari",
            "finder": "com.apple.finder",
            "terminal": "com.apple.Terminal",
            "mail": "com.apple.mail",
            "notes": "com.apple.Notes",
            "pages": "com.apple.iWork.Pages",
            "numbers": "com.apple.iWork.Numbers",
            "keynote": "com.apple.iWork.Keynote",
            "xcode": "com.apple.dt.Xcode",
            "music": "com.apple.Music",
            "photos": "com.apple.Photos",
            "preview": "com.apple.Preview",
            "textedit": "com.apple.TextEdit",
            "activity monitor": "com.apple.ActivityMonitor",
            "system preferences": "com.apple.systempreferences",
            "system settings": "com.apple.systempreferences",
            "vscode": "com.microsoft.VSCode",
            "visual studio code": "com.microsoft.VSCode",
            "chrome": "com.google.Chrome",
            "google chrome": "com.google.Chrome",
            "firefox": "org.mozilla.firefox",
            "slack": "com.tinyspeck.slackmacgap",
            "wechat": "com.tencent.xinWeChat",
            "微信": "com.tencent.xinWeChat",
            "qq": "com.tencent.qq",
            "feishu": "com.bytedance.lark",
            "飞书": "com.bytedance.lark",
            "dingtalk": "com.alibaba.DingTalkMac",
            "钉钉": "com.alibaba.DingTalkMac",
        ]

        let lowerName = name.lowercased()
        if let bundleID = knownBundleIDs[lowerName],
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            do {
                try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
                return ToolResult(output: "已打开：\(name)")
            } catch {
                return ToolResult(output: "打开 \(name) 失败：\(error.localizedDescription)", success: false, error: "open_failed")
            }
        }

        // Fallback: search in /Applications
        let searchPaths = ["/Applications", "/System/Applications", "/Applications/Utilities"]
        for searchPath in searchPaths {
            let appPath = "\(searchPath)/\(name).app"
            if FileManager.default.fileExists(atPath: appPath) {
                do {
                    try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: config)
                    return ToolResult(output: "已打开：\(name)")
                } catch {
                    return ToolResult(output: "打开 \(name) 失败：\(error.localizedDescription)", success: false, error: "open_failed")
                }
            }
        }

        // Last resort: use AppleScript
        let result = await runAppleScript("tell application \"\(name)\" to activate")
        if result.success {
            return ToolResult(output: "已打开：\(name)")
        }
        return ToolResult(output: "找不到应用：\(name)", success: false, error: "not_found")
    }

    private func simulateKeystroke(_ combo: String) -> ToolResult {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyPart = parts.last else {
            return ToolResult(output: "无效按键组合", success: false, error: "invalid_key")
        }

        var flags: CGEventFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "alt", "option", "opt", "⌥": flags.insert(.maskAlternate)
            case "shift", "⇧": flags.insert(.maskShift)
            default: break
            }
        }

        // If only modifier specified (e.g., "cmd+c"), the key is the last part
        guard let keyCode = Self.keyCodeMap[keyPart] else {
            return ToolResult(output: "未知按键：'\(keyPart)'。支持：a-z, 0-9, return, space, tab, escape, delete, up/down/left/right, f1-f12", success: false, error: "unknown_key")
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return ToolResult(output: "无法创建键盘事件", success: false, error: "event_failed")
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        return ToolResult(output: "已发送按键：\(combo)")
    }

    private func typeText(_ text: String) -> ToolResult {
        // Use clipboard + paste for reliable CJK input
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Cmd+V
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),  // V key
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return ToolResult(output: "无法模拟粘贴", success: false, error: "event_failed")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // Restore clipboard after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let old = oldContents {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(old, forType: .string)
            }
        }

        return ToolResult(output: "已输入 \(text.count) 个字符")
    }

    private func simulateClick(x: Int, y: Int) -> ToolResult {
        let point = CGPoint(x: x, y: y)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return ToolResult(output: "无法创建鼠标事件", success: false, error: "event_failed")
        }

        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)

        return ToolResult(output: "已点击坐标 (\(x), \(y))")
    }

    private func captureScreen() async -> ToolResult {
        let tempDir = NSTemporaryDirectory()
        let filename = "laicai_screen_\(Int(Date().timeIntervalSince1970)).png"
        let path = (tempDir as NSString).appendingPathComponent(filename)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-C", path]  // -x no sound, -C capture cursor

        do {
            try process.run()
            process.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                // Get image dimensions
                if let image = NSImage(contentsOfFile: path) {
                    return ToolResult(
                        output: "截屏已保存：\(path)\n尺寸：\(Int(image.size.width))×\(Int(image.size.height))",
                        data: ["path": path, "width": "\(Int(image.size.width))", "height": "\(Int(image.size.height))"]
                    )
                }
                return ToolResult(output: "截屏已保存：\(path)")
            }
            return ToolResult(output: "截屏失败", success: false, error: "capture_failed")
        } catch {
            return ToolResult(output: "截屏失败：\(error.localizedDescription)", success: false, error: "capture_failed")
        }
    }

    private func readClipboard() -> ToolResult {
        if let text = NSPasteboard.general.string(forType: .string) {
            return ToolResult(output: String(text.prefix(10000)))
        }
        // Check for image
        if let imageData = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff) {
            let tempDir = NSTemporaryDirectory()
            let filename = "laicai_clipboard_\(Int(Date().timeIntervalSince1970)).png"
            let path = (tempDir as NSString).appendingPathComponent(filename)
            do {
                try imageData.write(to: URL(fileURLWithPath: path))
                return ToolResult(output: "剪贴板包含图片，已保存到：\(path)", data: ["path": path, "type": "image"])
            } catch {
                return ToolResult(output: "剪贴板包含图片但保存失败", success: false, error: "save_failed")
            }
        }
        // Check for file URLs
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path).joined(separator: "\n")
            return ToolResult(output: "剪贴板包含文件：\n\(paths)")
        }
        return ToolResult(output: "剪贴板为空或不包含可识别内容")
    }

    private func writeClipboard(_ text: String) -> ToolResult {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return ToolResult(output: "已写入剪贴板（\(text.count) 个字符）")
    }

    private func frontmostApp() -> ToolResult {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ToolResult(output: "无法获取前台应用")
        }
        let name = app.localizedName ?? "unknown"
        let bundleID = app.bundleIdentifier ?? "unknown"
        let pid = app.processIdentifier
        return ToolResult(output: "前台应用：\(name)\nBundle ID：\(bundleID)\nPID：\(pid)")
    }

    private func listWindows() -> ToolResult {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return ToolResult(output: "无法获取窗口列表", success: false, error: "failed")
        }

        var lines: [String] = []
        for window in windowList.prefix(30) {
            let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
            let name = window[kCGWindowName as String] as? String ?? ""
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let x = bounds?["X"] as? Int ?? 0
            let y = bounds?["Y"] as? Int ?? 0
            let w = bounds?["Width"] as? Int ?? 0
            let h = bounds?["Height"] as? Int ?? 0
            guard layer == 0 else { continue }  // Only normal windows
            lines.append("\(owner): \(name.isEmpty ? "(无标题)" : name) [\(x),\(y) \(w)×\(h)]")
        }

        if lines.isEmpty {
            return ToolResult(output: "没有找到可见窗口")
        }
        return ToolResult(output: "当前窗口（\(lines.count) 个）：\n" + lines.joined(separator: "\n"))
    }

    private func systemInfo() -> ToolResult {
        let info = ProcessInfo.processInfo
        var lines: [String] = []
        lines.append("主机名：\(info.hostName)")
        lines.append("系统：macOS \(info.operatingSystemVersionString)")
        lines.append("CPU 核心：\(info.processorCount) 个")
        lines.append("内存：\(info.physicalMemory / (1024 * 1024 * 1024)) GB")
        lines.append("运行时间：\(Int(info.systemUptime / 3600)) 小时")
        lines.append("用户：\(NSUserName())")
        lines.append("主目录：\(NSHomeDirectory())")

        // Disk space
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
            let total = (attrs[.systemSize] as? Int64 ?? 0) / (1024 * 1024 * 1024)
            let free = (attrs[.systemFreeSize] as? Int64 ?? 0) / (1024 * 1024 * 1024)
            lines.append("磁盘：\(free) GB 可用 / \(total) GB 总计")
        }

        // Battery
        let batteryScript = "do shell script \"pmset -g batt | grep -o '[0-9]*%'\""
        if let result = try? NSAppleScript(source: batteryScript)?.executeAndReturnError(nil),
           let battery = result.stringValue {
            lines.append("电量：\(battery)")
        }

        return ToolResult(output: lines.joined(separator: "\n"))
    }

    private func sendNotification(_ text: String) -> ToolResult {
        let script = """
        display notification "\(text.replacingOccurrences(of: "\"", with: "\\\""))" with title "Laicai" sound name "default"
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            return ToolResult(output: "通知发送失败：\(error)", success: false, error: "notify_failed")
        }
        return ToolResult(output: "已发送通知：\(text)")
    }

    private func runAppleScript(_ source: String) async -> ToolResult {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)

        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
            return ToolResult(output: "AppleScript 错误：\(msg)", success: false, error: "applescript_error")
        }

        let output = result?.stringValue ?? "(无返回值)"
        return ToolResult(output: String(output.prefix(10000)))
    }

    // MARK: - Key Code Map

    private static let keyCodeMap: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [:]
        // Letters
        let letters: [(String, CGKeyCode)] = [
            ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14), ("f", 3),
            ("g", 5), ("h", 4), ("i", 34), ("j", 38), ("k", 40), ("l", 37),
            ("m", 46), ("n", 45), ("o", 31), ("p", 35), ("q", 12), ("r", 15),
            ("s", 1), ("t", 17), ("u", 32), ("v", 9), ("w", 13), ("x", 7),
            ("y", 16), ("z", 6),
        ]
        for (key, code) in letters { map[key] = code }
        // Numbers
        let numbers: [(String, CGKeyCode)] = [
            ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
            ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25),
        ]
        for (key, code) in numbers { map[key] = code }
        // Special keys
        map["return"] = 36; map["enter"] = 36
        map["tab"] = 48
        map["space"] = 49
        map["delete"] = 51; map["backspace"] = 51
        map["escape"] = 53; map["esc"] = 53
        map["up"] = 126; map["down"] = 125; map["left"] = 123; map["right"] = 124
        map["home"] = 115; map["end"] = 119
        map["pageup"] = 116; map["pagedown"] = 121
        // Function keys
        for i in 1...12 {
            let codes: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
            map["f\(i)"] = codes[i - 1]
        }
        // Punctuation
        map["-"] = 27; map["="] = 24; map["["] = 33; map["]"] = 30
        map[";"] = 41; map["'"] = 39; map[","] = 43; map["."] = 47
        map["/"] = 44; map["\\"] = 42; map["`"] = 50
        return map
    }()
}
