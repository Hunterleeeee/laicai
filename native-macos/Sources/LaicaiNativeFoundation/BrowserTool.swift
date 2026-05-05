import Foundation
import LaicaiNativeDomain
import WebKit

// MARK: - Browser Tool

/// Agent tool for browser control: navigate, extract, screenshot, execute JS.
/// Uses WKWebView headlessly on macOS.
public struct BrowserTool: LaicaiTool {
    public var name: String { "browser" }
    public var description: String { "浏览器控制：打开网页、提取内容、执行 JavaScript、截屏" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "action": FunctionProperty(type: "string", description: "动作：navigate / extract / screenshot / js / close"),
                    "url": FunctionProperty(type: "string", description: "目标 URL（navigate 时必填）"),
                    "selector": FunctionProperty(type: "string", description: "CSS 选择器（extract 时用）"),
                    "script": FunctionProperty(type: "string", description: "JavaScript 代码（js 动作时必填）"),
                ],
                required: ["action"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var action: String
            var url: String?
            var selector: String?
            var script: String?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        switch params.action {
        case "navigate":
            guard let urlStr = params.url, let url = URL(string: urlStr) else {
                return ToolResult(output: "缺少有效的 url 参数", success: false, error: "missing_url")
            }
            return await BrowserSession.shared.navigate(to: url)

        case "extract":
            return await BrowserSession.shared.extractContent(selector: params.selector)

        case "screenshot":
            return await BrowserSession.shared.screenshot()

        case "js":
            guard let script = params.script, !script.isEmpty else {
                return ToolResult(output: "缺少 script 参数", success: false, error: "missing_script")
            }
            return await BrowserSession.shared.executeJS(script)

        case "close":
            await BrowserSession.shared.close()
            return ToolResult(output: "浏览器已关闭")

        default:
            return ToolResult(output: "未知动作 '\(params.action)'，支持：navigate / extract / screenshot / js / close", success: false, error: "unknown_action")
        }
    }
}

// MARK: - Browser Session (WKWebView wrapper)

@MainActor
final class BrowserSession: NSObject, WKNavigationDelegate {
    static let shared = BrowserSession()

    private var webView: WKWebView?
    private var currentURL: URL?
    private var navigationContinuation: CheckedContinuation<ToolResult, Never>?
    private var isLoading = false

    private override init() { super.init() }

    // MARK: - Lazy init

    private func ensureWebView() -> WKWebView {
        if let wv = webView { return wv }
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        webView = wv
        return wv
    }

    // MARK: - Navigate

    func navigate(to url: URL) async -> ToolResult {
        let wv = ensureWebView()
        currentURL = url

        return await withCheckedContinuation { continuation in
            self.navigationContinuation = continuation
            self.isLoading = true
            wv.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))

            // Timeout
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                if self.isLoading {
                    self.isLoading = false
                    self.navigationContinuation?.resume(returning: ToolResult(output: "页面加载超时（30秒）", success: false, error: "timeout"))
                    self.navigationContinuation = nil
                }
            }
        }
    }

    // WKNavigationDelegate
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isLoading = false
            let title = webView.title ?? ""
            let urlStr = webView.url?.absoluteString ?? ""
            self.navigationContinuation?.resume(returning: ToolResult(output: "已加载：\(title)\n\(urlStr)"))
            self.navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.isLoading = false
            self.navigationContinuation?.resume(returning: ToolResult(output: "加载失败：\(error.localizedDescription)", success: false, error: "load_failed"))
            self.navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.isLoading = false
            self.navigationContinuation?.resume(returning: ToolResult(output: "导航失败：\(error.localizedDescription)", success: false, error: "nav_failed"))
            self.navigationContinuation = nil
        }
    }

    // MARK: - Extract content

    func extractContent(selector: String?) async -> ToolResult {
        guard let wv = webView else {
            return ToolResult(output: "浏览器未打开，请先 navigate", success: false, error: "not_open")
        }

        let js: String
        if let sel = selector, !sel.isEmpty {
            js = """
            (function() {
                var els = document.querySelectorAll('\(sel.replacingOccurrences(of: "'", with: "\\'"))');
                return Array.from(els).map(function(el) {
                    return el.innerText || el.textContent || '';
                }).join('\\n---\\n');
            })()
            """
        } else {
            // Extract main content heuristic
            js = """
            (function() {
                var article = document.querySelector('article') || document.querySelector('main') || document.querySelector('[role="main"]') || document.body;
                // Remove scripts, styles, nav
                var clone = article.cloneNode(true);
                clone.querySelectorAll('script, style, nav, header, footer, aside, iframe').forEach(function(el) { el.remove(); });
                var text = clone.innerText || clone.textContent || '';
                // Trim excessive whitespace
                text = text.replace(/\\n{3,}/g, '\\n\\n').trim();
                var title = document.title || '';
                var meta = document.querySelector('meta[name="description"]');
                var desc = meta ? meta.content : '';
                return '# ' + title + '\\n' + (desc ? desc + '\\n\\n' : '') + text.substring(0, 8000);
            })()
            """
        }

        do {
            let result = try await wv.evaluateJavaScript(js)
            let text = "\(result)"
            if text.isEmpty {
                return ToolResult(output: "（页面内容为空或选择器未匹配）")
            }
            return ToolResult(output: String(text.prefix(10000)))
        } catch {
            return ToolResult(output: "内容提取失败：\(error.localizedDescription)", success: false, error: "extract_failed")
        }
    }

    // MARK: - Execute JavaScript

    func executeJS(_ script: String) async -> ToolResult {
        guard let wv = webView else {
            return ToolResult(output: "浏览器未打开，请先 navigate", success: false, error: "not_open")
        }
        do {
            let result = try await wv.evaluateJavaScript(script)
            return ToolResult(output: "\(result)")
        } catch {
            return ToolResult(output: "JS 执行失败：\(error.localizedDescription)", success: false, error: "js_failed")
        }
    }

    // MARK: - Screenshot

    func screenshot() async -> ToolResult {
        guard let wv = webView else {
            return ToolResult(output: "浏览器未打开，请先 navigate", success: false, error: "not_open")
        }

        let config = WKSnapshotConfiguration()
        config.rect = wv.bounds

        do {
            let image = try await wv.takeSnapshot(configuration: config)

            // Save to temp file
            let tempDir = NSTemporaryDirectory()
            let filename = "laicai_screenshot_\(Int(Date().timeIntervalSince1970)).png"
            let path = (tempDir as NSString).appendingPathComponent(filename)

            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return ToolResult(output: "截图转换失败", success: false, error: "convert_failed")
            }
            try pngData.write(to: URL(fileURLWithPath: path))
            return ToolResult(output: "截图已保存：\(path)\n尺寸：\(Int(image.size.width))×\(Int(image.size.height))")
        } catch {
            return ToolResult(output: "截图失败：\(error.localizedDescription)", success: false, error: "screenshot_failed")
        }
    }

    // MARK: - Close

    func close() {
        webView?.stopLoading()
        webView = nil
        currentURL = nil
    }
}
