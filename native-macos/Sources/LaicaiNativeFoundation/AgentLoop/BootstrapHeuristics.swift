import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    static func shouldBootstrapWebSearch(for message: String, intent: UserIntent) -> Bool {
        guard intent != .chat else { return false }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        // Research intent always bootstraps with web search
        if intent == .research { return true }

        let freshnessMarkers = [
            "今天", "今日", "最新", "新闻", "资讯", "趋势", "热点", "实时",
            "价格", "股价", "汇率", "天气", "版本", "发布", "更新",
            "today", "latest", "news", "current", "recent"
        ]
        if freshnessMarkers.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        if looksLikeCurrentModelComparison(text) {
            return true
        }

        // Market survey / recommendation patterns
        let explorationMarkers = [
            "市面上", "市场上", "有什么好用", "有什么有用", "有哪些好的", "有哪些有用",
            "都有什么", "都有哪些", "推荐", "哪个好", "选哪个", "用哪个"
        ]
        if explorationMarkers.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        let webActionMarkers = [
            "搜索一下", "搜一下", "搜搜", "查一下", "查找", "联网搜索", "上网查", "网页资料",
            "访问一下", "打开这个", "看看这个链接", "site:", "http://", "https://"
        ]
        return webActionMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func looksLikeCurrentModelComparison(_ text: String) -> Bool {
        let comparisonMarkers = ["对比", "比较", "强多少", "能力", "发布", "最新"]
        guard comparisonMarkers.contains(where: { text.localizedCaseInsensitiveContains($0) }) else { return false }
        let modelMarkers = ["qwen", "gpt", "glm", "kimi", "claude", "deepseek", "llama", "gemini", "模型"]
        if modelMarkers.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        return text.range(of: #"[a-zA-Z\u{4e00}-\u{9fff}]+[0-9]+(\.[0-9]+)?"#, options: .regularExpression) != nil
    }

    static func isPureContinuationCommand(_ message: String) -> Bool {
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 20 else { return false }
        let continuations = [
            "继续", "接着", "接着说", "继续输出", "继续说",
            "没发完", "没写完", "没说完", "被截断", "后面呢", "剩下的",
            "接着写", "接着输出", "说完", "写完", "继续吧", "go on",
            "continue", "keep going"
        ]
        return continuations.contains(where: { cleaned.localizedCaseInsensitiveContains($0) })
    }

    static func shouldBootstrapWorkspaceSearch(for message: String, intent: UserIntent, context: TaskContext) -> Bool {
        guard intent != .chat else { return false }
        guard !context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !shouldBootstrapWebSearch(for: message, intent: intent) else { return false }
        guard firstURL(in: message) == nil else { return false }
        guard !shouldBootstrapWorkspaceIndex(for: message, intent: intent) else { return false }
        return !bootstrapWorkspaceSearchQuery(for: message).isEmpty
    }

    static func shouldBootstrapWorkspaceIndex(for message: String, intent: UserIntent) -> Bool {
        guard intent != .chat else { return false }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, firstURL(in: text) == nil, firstLocalPath(in: text) == nil else { return false }
        let projectMarkers = ["项目", "工作区", "代码库", "工程", "repo", "repository"]
        // Only trigger full workspace indexing for explicit structural scan requests.
        // '优化', '改写', '找问题', '审查' etc. don't need full index first.
        let indexMarkers = ["全量", "全部", "整个", "整体", "结构", "架构", "扫描", "全面了解"]
        return projectMarkers.contains { text.localizedCaseInsensitiveContains($0) }
            && indexMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    static func bootstrapWebSearchArgumentsJSON(for message: String) -> String {
        let query = bootstrapWebSearchQuery(for: message)
        let payload: [String: Any] = [
            "query": query,
            "maxResults": 5
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"query":"\#(query)","maxResults":5}"#
        }
        return json
    }

    static func bootstrapWebSearchMessage(for message: String, priorSteps: [TaskStep]) -> String {
        let cleaned = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isGenericWebFollowUp(cleaned),
              let subject = priorSteps
                .filter({ $0.kind == .userInput })
                .map(\.text)
                .last(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) != message.trimmingCharacters(in: .whitespacesAndNewlines) })?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !subject.isEmpty else {
            return message
        }
        return "\(subject) \(cleaned)"
    }

    static func bootstrapWorkspaceSearchArgumentsJSON(for message: String) -> String {
        let query = bootstrapWorkspaceSearchQuery(for: message)
        let payload: [String: Any] = [
            "query": query,
            "scope": "content",
            "maxResults": 8
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"query":"\#(query)","scope":"content","maxResults":8}"#
        }
        return json
    }

    static func bootstrapWorkspaceIndexArgumentsJSON(maxFiles: Int = 300, maxDepth: Int = 5) -> String {
        #"{"maxFiles":\#(maxFiles),"maxDepth":\#(maxDepth)}"#
    }

    static func bootstrapReadArgumentsJSON(for path: String) -> String {
        let payload: [String: Any] = [
            "path": path,
            "offset": 1,
            "limit": 160
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"path":"\#(path)","offset":1,"limit":160}"#
        }
        return json
    }

    static func bootstrapExtractArgumentsJSON(for path: String) -> String {
        let payload: [String: Any] = [
            "path": path,
            "limit": 60_000
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"path":"\#(path)","limit":60000}"#
        }
        return json
    }

    static func firstReadablePath(inSearchOutput output: String, workspaceRoot: String) -> String? {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let ignoredExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "pdf", "zip", "gz", "dmg", "app",
                                               "ico", "svg", "woff", "woff2", "ttf", "eot", "map"]
        // Skip auto-generated, minified, vendor, and HTML-resource files
        let ignoredPatterns = ["_files/", "node_modules/", ".min.js", ".min.css", ".bundle.js",
                               "vendor/", "dist/", "DerivedData/", ".build/", "target/debug/", "target/release/"]
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("未找到") else { continue }
            let candidate = line.components(separatedBy: ":").first ?? line
            let cleaned = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \t`\"'"))
            guard !cleaned.isEmpty else { continue }
            let ext = (cleaned as NSString).pathExtension.lowercased()
            if ignoredExtensions.contains(ext) { continue }
            let lower = cleaned.lowercased()
            if ignoredPatterns.contains(where: { lower.contains($0) }) { continue }
            if !root.isEmpty, cleaned.hasPrefix(root + "/") {
                let relative = String(cleaned.dropFirst(root.count + 1))
                if !relative.isEmpty { return relative }
            }
            if !cleaned.hasPrefix("/") {
                return cleaned
            }
        }
        return nil
    }

    static func bootstrapWorkspaceSearchQuery(for message: String) -> String {
        let cleaned = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        let genericContinuations = ["继续", "接着", "接着说", "继续输出", "继续说", "没发完", "没写完", "没说完", "被截断", "后面呢", "剩下的"]
        if genericContinuations.contains(where: { cleaned.localizedCaseInsensitiveContains($0) }) && cleaned.count <= 12 {
            return ""
        }
        if looksLikeBroadProjectImprovement(cleaned) {
            return #"TODO|FIXME|fatalError|print\(|mock|demo|Direct|直连|selectedTask|selectedSession|ChatSession|AgentTask"#
        }

        if let backtick = firstMatch(in: cleaned, pattern: #"`([^`]{2,80})`"#) {
            return backtick
        }
        if let fileLike = firstMatch(in: cleaned, pattern: #"[A-Za-z0-9_./-]+\.(swift|py|ts|tsx|js|jsx|md|json|yaml|yml|toml|txt)"#) {
            return fileLike
        }
        if let symbol = firstMatch(in: cleaned, pattern: #"[A-Za-z_][A-Za-z0-9_]{2,}"#) {
            return symbol
        }

        let stopWords: Set<String> = [
            "请", "帮我", "帮忙", "继续", "一下", "这个", "那个", "代码", "项目",
            "实现", "修复", "修改", "重构", "搜索", "查找", "看看", "解释", "说明"
        ]
        let normalized = cleaned
            .replacingOccurrences(of: "，", with: " ")
            .replacingOccurrences(of: "。", with: " ")
            .replacingOccurrences(of: "？", with: " ")
            .replacingOccurrences(of: "?", with: " ")
        let candidates = normalized
            .split(whereSeparator: { $0.isWhitespace || "/\\:：,.;；()[]{}<>「」『』".contains($0) })
            .map(String.init)
            .map { token in stopWords.reduce(token) { $0.replacingOccurrences(of: $1, with: "") } }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        return candidates.first.map { String($0.prefix(40)) } ?? String(cleaned.prefix(40))
    }

    private static func looksLikeBroadProjectImprovement(_ message: String) -> Bool {
        let lowered = message.lowercased()
        let projectMarkers = ["本地项目", "当前项目", "整个项目", "项目", "工作区"]
        let actionMarkers = ["优化", "改写", "改进", "重构", "看看问题", "找问题"]
        return projectMarkers.contains { lowered.localizedCaseInsensitiveContains($0) }
            && actionMarkers.contains { lowered.localizedCaseInsensitiveContains($0) }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else {
            return nil
        }
        let targetRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
        guard let range = Range(targetRange, in: text) else { return nil }
        return String(text[range])
    }

    static func firstURL(in message: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(message.startIndex..., in: message)
        guard let match = regex.firstMatch(in: message, options: [], range: nsRange),
              let range = Range(match.range, in: message) else {
            return nil
        }
        return String(message[range]).trimmingCharacters(in: CharacterSet(charactersIn: "。，、；;）)]}"))
    }

    /// E2: Extract search keywords from user messages like "搜索 XXX" / "查找 XXX"
    static func extractSearchKeywords(from message: String) -> String? {
        let patterns = [
            #"(?:搜索|查找|找一下|search\s+(?:for\s+)?|grep\s+)[\s：:]*(.+)"#,
            #"(?:搜|找|查)\s*[\s：:][\s]*(.+)"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: message) {
                let keywords = String(message[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !keywords.isEmpty && keywords.count < 100 { return keywords }
            }
        }
        return nil
    }

    /// Extract all absolute paths from user message (for granting write access)
    static func extractAbsolutePaths(from message: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"/(?:Users|home|tmp|var|opt|mnt)[^\n\r\t\s，。、；;）)\]}>\"']*"#) else {
            return []
        }
        let nsRange = NSRange(message.startIndex..., in: message)
        let matches = regex.matches(in: message, options: [], range: nsRange)
        return matches.compactMap { match in
            guard let range = Range(match.range, in: message) else { return nil }
            let path = String(message[range]).trimmingCharacters(in: CharacterSet(charactersIn: "。，、；;）)]}"))
            return path.count > 3 ? path : nil
        }
    }

    static func firstLocalPath(in message: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"/[^\n\r\t ]+"#) else {
            return nil
        }
        let nsRange = NSRange(message.startIndex..., in: message)
        guard let match = regex.firstMatch(in: message, options: [], range: nsRange),
              let range = Range(match.range, in: message) else {
            return nil
        }
        return String(message[range]).trimmingCharacters(in: CharacterSet(charactersIn: "。，、；;）)]}>\"'"))
    }

    static func bootstrapWebFetchArgumentsJSON(for url: String) -> String {
        let payload: [String: Any] = [
            "url": url,
            "maxCharacters": 8000
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"url":"\#(url)","maxCharacters":8000}"#
        }
        return json
    }

    static func bootstrapWebSearchQuery(for message: String) -> String {
        let cleaned = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let needsDate = ["今天", "今日", "最新", "新闻", "趋势", "today", "latest", "news"]
            .contains { cleaned.localizedCaseInsensitiveContains($0) }
        guard needsDate else { return cleaned }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日"
        let today = formatter.string(from: Date())
        return cleaned.contains(today) ? cleaned : "\(cleaned) \(today)"
    }

    private static func isGenericWebFollowUp(_ message: String) -> Bool {
        let normalized = message
            .replacingOccurrences(of: "，", with: " ")
            .replacingOccurrences(of: "。", with: " ")
            .replacingOccurrences(of: "！", with: " ")
            .replacingOccurrences(of: "？", with: " ")
            .lowercased()
        let words = normalized.split(whereSeparator: { $0.isWhitespace || ",.;；:：()[]{}".contains($0) }).map(String.init)
        guard !words.isEmpty else { return false }
        let genericMarkers = [
            "联网", "搜索", "搜", "搜一下", "搜搜", "查", "查一下", "上网",
            "另外", "如果", "可以", "输出", "一条", "两条", "不完", "直接", "继续"
        ]
        let topicLike = words.filter { word in
            !genericMarkers.contains(where: { word.contains($0) })
                && word.count >= 3
                && !word.localizedCaseInsensitiveContains("token")
        }
        return normalized.contains("联网") || normalized.contains("搜") || normalized.contains("查")
            ? topicLike.isEmpty
            : false
    }
}
