import AppKit
import Foundation
import LaicaiNativeDomain

// MARK: - Real Browser Tool

private struct RealBrowserToolParams: Codable {
    var action: String
    var url: String?
    var selector: String?
    var script: String?
    var text: String?
    var browser: String?
    var timeout: Int?
    var tabIndex: Int?

    enum CodingKeys: String, CodingKey {
        case action, url, selector, script, text, browser, timeout
        case tabIndex = "tab_index"
    }
}

/// Controls the user's real browser (Safari or Chrome) via AppleScript/JXA.
/// Unlike the headless BrowserTool, this operates on the actual visible browser
/// the user sees, enabling true browser automation.
public struct RealBrowserTool: LaicaiTool {
    public var name: String { "browser.real" }
    public var description: String { "操控真实浏览器（Safari/Chrome）：打开URL、获取标签页、提取页面内容、执行JS、点击元素、填写表单、截屏、等待页面或元素" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "action": FunctionProperty(
                        type: "string",
                        description:
                            "动作：open / tabs / extract / js / click / fill / screenshot / scroll / back / forward / close_tab / switch_tab / wait_for"
                    ),
                    "url": FunctionProperty(type: "string", description: "目标 URL（open 时必填）"),
                    "selector": FunctionProperty(type: "string", description: "CSS 选择器（extract/click/fill 时用）"),
                    "script": FunctionProperty(type: "string", description: "JavaScript 代码（js 动作时必填）"),
                    "text": FunctionProperty(type: "string", description: "文本内容（fill 动作时用）"),
                    "browser": FunctionProperty(type: "string", description: "浏览器：safari / chrome（默认自动检测）"),
                    "tab_index": FunctionProperty(type: "integer", description: "标签页索引（switch_tab/close_tab 时用，从1开始）"),
                    "timeout": FunctionProperty(type: "integer", description: "wait_for 超时秒数（默认 10）"),
                ],
                required: ["action"]
            )
        )
    }

    public var requiresReview: Bool { true }
    public var executionPolicy: ToolExecutionPolicy { .explicitUserApproval }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        let params: RealBrowserToolParams
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(RealBrowserToolParams.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let browser = detectBrowser(params.browser)

        switch params.action {
        case "open":
            return await executeOpen(params, browser: browser)
        case "js":
            return await executeScript(params, browser: browser)
        case "click", "fill":
            return await executeElementAction(params, browser: browser)
        case "switch_tab":
            return await executeSwitchTab(params, browser: browser)
        case "tabs", "extract", "screenshot", "scroll", "back", "forward", "close_tab", "wait_for":
            return await executeSimpleAction(params, browser: browser)
        default:
            return ToolResult(
                output: [
                    "未知动作 '\(params.action)'，支持：open / tabs / extract / js / click / fill / screenshot",
                    "/ scroll / back / forward / close_tab / switch_tab / wait_for",
                ].joined(separator: " "),
                success: false,
                error: "unknown_action"
            )
        }
    }

    private func executeOpen(_ params: RealBrowserToolParams, browser: BrowserType) async -> ToolResult {
        guard let urlStr = params.url, !urlStr.isEmpty else {
            return ToolResult(output: "缺少 url 参数", success: false, error: "missing_url")
        }
        return await openURL(urlStr, browser: browser)
    }

    private func executeScript(_ params: RealBrowserToolParams, browser: BrowserType) async -> ToolResult {
        guard let script = params.script, !script.isEmpty else {
            return ToolResult(output: "缺少 script 参数", success: false, error: "missing_script")
        }
        return await executeJS(script, browser: browser)
    }

    private func executeElementAction(_ params: RealBrowserToolParams, browser: BrowserType) async -> ToolResult {
        guard let selector = params.selector, !selector.isEmpty else {
            return ToolResult(output: "缺少 selector 参数", success: false, error: "missing_selector")
        }
        if params.action == "click" {
            return await clickElement(selector: selector, browser: browser)
        }
        return await fillElement(selector: selector, text: params.text ?? "", browser: browser)
    }

    private func executeSwitchTab(_ params: RealBrowserToolParams, browser: BrowserType) async -> ToolResult {
        guard let idx = params.tabIndex else {
            return ToolResult(output: "缺少 tab_index 参数", success: false, error: "missing_tab_index")
        }
        return await switchTab(index: idx, browser: browser)
    }

    private func executeSimpleAction(_ params: RealBrowserToolParams, browser: BrowserType) async -> ToolResult {
        switch params.action {
        case "tabs":
            return await listTabs(browser: browser)
        case "extract":
            return await extractContent(selector: params.selector, browser: browser)
        case "screenshot":
            return await screenshotBrowser(browser: browser)
        case "scroll":
            return await scrollPage(direction: params.text ?? "down", browser: browser)
        case "back":
            return await navigateHistory(direction: "back", browser: browser)
        case "forward":
            return await navigateHistory(direction: "forward", browser: browser)
        case "close_tab":
            return await closeTab(index: params.tabIndex, browser: browser)
        default:
            return await waitForElement(selector: params.selector ?? "", timeout: params.timeout ?? 10, browser: browser)
        }
    }

    // MARK: - Browser Detection

    private func detectBrowser(_ preferred: String?) -> BrowserType {
        if let pref = preferred?.lowercased() {
            if pref.contains("chrome") { return .chrome }
            if pref.contains("safari") { return .safari }
        }
        // Auto-detect: prefer frontmost browser, else check what's running
        if let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            if frontApp == "com.google.Chrome" { return .chrome }
            if frontApp == "com.apple.Safari" { return .safari }
        }
        // Check if Chrome is running
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
            return .chrome
        }
        return .safari
    }

    private enum BrowserType {
        case safari, chrome

        var appName: String {
            switch self {
            case .safari: return "Safari"
            case .chrome: return "Google Chrome"
            }
        }
    }

    // MARK: - Actions

    private func openURL(_ urlStr: String, browser: BrowserType) async -> ToolResult {
        let script: String
        switch browser {
        case .safari:
            script = """
                tell application "Safari"
                    activate
                    if (count of windows) = 0 then
                        make new document with properties {URL:"\(escapeAS(urlStr))"}
                    else
                        tell front window
                            set current tab to (make new tab with properties {URL:"\(escapeAS(urlStr))"})
                        end tell
                    end if
                    delay 2
                    set pageTitle to name of current tab of front window
                    return pageTitle
                end tell
                """
        case .chrome:
            script = """
                tell application "Google Chrome"
                    activate
                    if (count of windows) = 0 then
                        make new window
                    end if
                    tell front window
                        make new tab with properties {URL:"\(escapeAS(urlStr))"}
                    end tell
                    delay 2
                    set pageTitle to title of active tab of front window
                    return pageTitle
                end tell
                """
        }

        let result = runAS(script)
        if result.success {
            return ToolResult(output: "已打开：\(urlStr)\n标题：\(result.output)")
        }
        return result
    }

    private func listTabs(browser: BrowserType) async -> ToolResult {
        let script: String
        switch browser {
        case .safari:
            script = """
                tell application "Safari"
                    set tabList to ""
                    set winCount to count of windows
                    repeat with w from 1 to winCount
                        set tabCount to count of tabs of window w
                        repeat with t from 1 to tabCount
                            set tabTitle to name of tab t of window w
                            set tabURL to URL of tab t of window w
                            set isCurrent to (current tab of window w) is (tab t of window w)
                            set marker to ""
                            if isCurrent and w = 1 then set marker to " ★"
                            set tabList to tabList & "[W" & w & "T" & t & marker & "] " & tabTitle & " — " & tabURL & linefeed
                        end repeat
                    end repeat
                    return tabList
                end tell
                """
        case .chrome:
            script = """
                tell application "Google Chrome"
                    set tabList to ""
                    set winCount to count of windows
                    repeat with w from 1 to winCount
                        set tabCount to count of tabs of window w
                        set activeIdx to active tab index of window w
                        repeat with t from 1 to tabCount
                            set tabTitle to title of tab t of window w
                            set tabURL to URL of tab t of window w
                            set marker to ""
                            if t = activeIdx and w = 1 then set marker to " ★"
                            set tabList to tabList & "[W" & w & "T" & t & marker & "] " & tabTitle & " — " & tabURL & linefeed
                        end repeat
                    end repeat
                    return tabList
                end tell
                """
        }

        return runAS(script)
    }

    private func extractContent(selector: String?, browser: BrowserType) async -> ToolResult {
        let javaScript: String
        if let sel = selector, !sel.isEmpty {
            javaScript = """
                (function() {
                    var els = document.querySelectorAll('\(escapeJS(sel))');
                    if (els.length === 0) return '(未找到匹配元素: \(escapeJS(sel)))';
                    return Array.from(els).map(function(el) {
                        return el.innerText || el.textContent || '';
                    }).join('\\n---\\n');
                })()
                """
        } else {
            javaScript = """
                (function() {
                    var article = document.querySelector('article') ||
                        document.querySelector('main') ||
                        document.querySelector('[role="main"]') ||
                        document.body;
                    var clone = article.cloneNode(true);
                    clone.querySelectorAll('script, style, nav, header, footer, aside, iframe, [aria-hidden]').forEach(function(el) { el.remove(); });
                    var text = clone.innerText || clone.textContent || '';
                    text = text.replace(/\\n{3,}/g, '\\n\\n').trim();
                    var title = document.title || '';
                    var url = window.location.href;
                    var meta = document.querySelector('meta[name="description"]');
                    var desc = meta ? meta.content : '';
                    return '# ' + title + '\\nURL: ' + url + '\\n' + (desc ? desc + '\\n\\n' : '\\n') + text.substring(0, 12000);
                })()
                """
        }

        return await executeJS(javaScript, browser: browser)
    }

    private func executeJS(_ jsCode: String, browser: BrowserType) async -> ToolResult {
        let escapedJS = jsCode.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        switch browser {
        case .safari:
            script = """
                tell application "Safari"
                    set jsResult to do JavaScript "\(escapedJS)" in current tab of front window
                    return jsResult as text
                end tell
                """
        case .chrome:
            script = """
                tell application "Google Chrome"
                    set jsResult to execute active tab of front window javascript "\(escapedJS)"
                    return jsResult as text
                end tell
                """
        }

        return runAS(script)
    }

    private func clickElement(selector: String, browser: BrowserType) async -> ToolResult {
        let javaScript = """
            (function() {
                var el = document.querySelector('\(escapeJS(selector))');
                if (!el) return 'NOT_FOUND';
                el.scrollIntoView({behavior: 'smooth', block: 'center'});
                el.click();
                return 'CLICKED: ' + (el.tagName || '') + ' ' + (el.innerText || '').substring(0, 50);
            })()
            """
        let result = await executeJS(javaScript, browser: browser)
        if result.output.contains("NOT_FOUND") {
            return ToolResult(output: "未找到元素：\(selector)", success: false, error: "not_found")
        }
        return result
    }

    private func fillElement(selector: String, text: String, browser: BrowserType) async -> ToolResult {
        let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let javaScript = """
            (function() {
                var el = document.querySelector('\(escapeJS(selector))');
                if (!el) return 'NOT_FOUND';
                el.focus();
                el.value = '\(escapedText)';
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                return 'FILLED: ' + el.tagName + ' value=' + el.value.substring(0, 50);
            })()
            """
        let result = await executeJS(javaScript, browser: browser)
        if result.output.contains("NOT_FOUND") {
            return ToolResult(output: "未找到元素：\(selector)", success: false, error: "not_found")
        }
        return result
    }

    private func waitForElement(selector: String, timeout: Int, browser: BrowserType) async -> ToolResult {
        let clampedTimeout = min(max(1, timeout), 30)  // hard cap at 30s
        let actualAttempts = clampedTimeout * 2  // poll every 500ms

        if selector.isEmpty {
            // No selector: wait for page load (document.readyState == 'complete')
            for attempt in 1...actualAttempts {
                let javaScript = "document.readyState"
                let result = await executeJS(javaScript, browser: browser)
                if result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "complete" {
                    return ToolResult(output: "页面加载完成（第 \(attempt) 次检查）")
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            return ToolResult(output: "等待页面加载超时（\(clampedTimeout)秒）", success: false, error: "timeout")
        }

        // Wait for CSS selector to appear
        for attempt in 1...actualAttempts {
            let javaScript = """
                (function() {
                    var el = document.querySelector('\(escapeJS(selector))');
                    return el ? 'FOUND:' + (el.tagName || '') + ' ' + (el.innerText || '').substring(0, 50) : 'NOT_FOUND';
                })()
                """
            let result = await executeJS(javaScript, browser: browser)
            if result.output.hasPrefix("FOUND:") {
                let detail = String(result.output.dropFirst("FOUND:".count))
                return ToolResult(output: "元素已出现（第 \(attempt) 次检查）：\(detail)")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return ToolResult(output: "等待元素 '\(selector)' 超时（\(clampedTimeout)秒）", success: false, error: "timeout")
    }

    private func screenshotBrowser(browser: BrowserType) async -> ToolResult {
        // Activate browser first, then use screencapture on the frontmost window
        let activateScript: String
        switch browser {
        case .safari: activateScript = "tell application \"Safari\" to activate"
        case .chrome: activateScript = "tell application \"Google Chrome\" to activate"
        }
        runAS(activateScript)

        // Small delay for window to come to front
        try? await Task.sleep(for: .milliseconds(300))

        let tempDir = NSTemporaryDirectory()
        let filename = "laicai_browser_\(Int(Date().timeIntervalSince1970)).png"
        let path = (tempDir as NSString).appendingPathComponent(filename)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if let wid = windowID(for: browser) {
            process.arguments = ["-x", "-l", wid, path]
        } else {
            process.arguments = ["-x", "-w", "-o", path]
        }

        do {
            try process.run()
            process.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                return ToolResult(output: "浏览器截图已保存：\(path)", data: ["path": path])
            }
            return ToolResult(output: "截图失败", success: false, error: "capture_failed")
        } catch {
            return ToolResult(output: "截图失败：\(error.localizedDescription)", success: false, error: "capture_failed")
        }
    }

    private func scrollPage(direction: String, browser: BrowserType) async -> ToolResult {
        let javaScript: String
        switch direction.lowercased() {
        case "up": javaScript = "window.scrollBy(0, -window.innerHeight * 0.8); 'scrolled up'"
        case "top": javaScript = "window.scrollTo(0, 0); 'scrolled to top'"
        case "bottom": javaScript = "window.scrollTo(0, document.body.scrollHeight); 'scrolled to bottom'"
        default: javaScript = "window.scrollBy(0, window.innerHeight * 0.8); 'scrolled down'"
        }
        return await executeJS(javaScript, browser: browser)
    }

    private func navigateHistory(direction: String, browser: BrowserType) async -> ToolResult {
        let javaScript = direction == "back" ? "history.back(); 'went back'" : "history.forward(); 'went forward'"
        return await executeJS(javaScript, browser: browser)
    }

    private func closeTab(index: Int?, browser: BrowserType) async -> ToolResult {
        let script: String
        switch browser {
        case .safari:
            if let idx = index {
                script = "tell application \"Safari\" to close tab \(idx) of front window"
            } else {
                script = "tell application \"Safari\" to close current tab of front window"
            }
        case .chrome:
            if let idx = index {
                script = "tell application \"Google Chrome\" to close tab \(idx) of front window"
            } else {
                script = "tell application \"Google Chrome\" to close active tab of front window"
            }
        }
        let result = runAS(script)
        return result.success ? ToolResult(output: "已关闭标签页") : result
    }

    private func switchTab(index: Int, browser: BrowserType) async -> ToolResult {
        let script: String
        switch browser {
        case .safari:
            script = """
                tell application "Safari"
                    set current tab of front window to tab \(index) of front window
                    return name of current tab of front window
                end tell
                """
        case .chrome:
            script = """
                tell application "Google Chrome"
                    set active tab index of front window to \(index)
                    return title of active tab of front window
                end tell
                """
        }
        let result = runAS(script)
        if result.success {
            return ToolResult(output: "已切换到标签页 \(index)：\(result.output)")
        }
        return result
    }

    // MARK: - Helpers

    private func escapeAS(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private func escapeJS(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    @discardableResult
    private func runAS(_ source: String) -> ToolResult {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)

        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
            return ToolResult(output: "AppleScript 错误：\(msg)", success: false, error: "applescript_error")
        }

        let output = result?.stringValue ?? ""
        return ToolResult(output: String(output.prefix(15000)))
    }

    private func windowID(for browser: BrowserType) -> String? {
        let bundleID: String
        switch browser {
        case .safari: bundleID = "com.apple.Safari"
        case .chrome: bundleID = "com.google.Chrome"
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            return nil
        }
        let pid = app.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windowList {
            if let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                ownerPID == pid,
                let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                let windowNumber = window[kCGWindowNumber as String] as? Int
            {
                return String(windowNumber)
            }
        }
        return nil
    }
}
