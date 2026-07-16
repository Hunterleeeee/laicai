import Foundation
import LaicaiNativeDomain

// MARK: - Web Search Tool

public struct WebSearchTool: LaicaiTool {
    public var name: String { "web.search" }
    public var description: String { "联网搜索最新公开网页信息，适合今天、最新、新闻、趋势等问题" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "query": FunctionProperty(type: "string", description: "搜索关键词，包含必要的日期或来源限定"),
                    "maxResults": FunctionProperty(type: "integer", description: "最大结果数（可选，默认5）"),
                ],
                required: ["query"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var query: String
            var maxResults: Int?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let query = Self.normalizedFreshnessQuery(params.query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else {
            return ToolResult(output: "搜索关键词不能为空。", success: false, error: "empty_query")
        }

        let limit = max(1, min(params.maxResults ?? 5, 10))
        do {
            let results = try await Self.searchDuckDuckGo(query: query, limit: limit)
            let fallbackResults = results.isEmpty ? try await Self.searchHackerNews(query: query, limit: limit) : results
            guard !fallbackResults.isEmpty else {
                return ToolResult(output: "未找到网页搜索结果：\(query)", data: ["query": query, "count": "0"], success: true)
            }

            let output = fallbackResults.enumerated().map { index, item in
                "\(index + 1). \(item.title)\n\(item.url)\n\(item.snippet)"
            }.joined(separator: "\n\n")

            await AuditLog.shared.record(
                tool: name,
                input: query,
                output: "找到 \(fallbackResults.count) 条网页结果",
                success: true
            )

            return ToolResult(output: output, data: ["query": query, "count": "\(fallbackResults.count)"])
        } catch {
            return ToolResult(output: "联网搜索失败：\(error.localizedDescription)", success: false, error: "network_error")
        }
    }

    private struct SearchResult {
        var title: String
        var url: String
        var snippet: String
    }

    private static func normalizedFreshnessQuery(_ query: String) -> String {
        let freshnessMarkers = ["今天", "今日", "最新", "新闻", "趋势", "today", "latest", "news"]
        guard freshnessMarkers.contains(where: { query.localizedCaseInsensitiveContains($0) }) else {
            return query
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日"
        let today = formatter.string(from: Date())

        var normalized = query.replacingOccurrences(
            of: #"\d{4}年\d{1,2}月\d{1,2}日"#,
            with: today,
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\d{4}-\d{1,2}-\d{1,2}"#,
            with: today,
            options: .regularExpression
        )
        if !normalized.contains(today) && (normalized.contains("今天") || normalized.localizedCaseInsensitiveContains("today")) {
            normalized += " \(today)"
        }
        return normalized
    }

    private static func searchDuckDuckGo(query: String, limit: Int) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkDefaults.shortRequest
        request.setValue("Mozilla/5.0 Laicai/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await NetworkDefaults.ephemeralSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else { return [] }
        let html = String(data: data, encoding: .utf8) ?? ""
        return parseDuckDuckGoHTML(html, limit: limit)
    }

    private static func searchHackerNews(query: String, limit: Int) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://hn.algolia.com/api/v1/search_by_date")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "tags", value: "story"),
            URLQueryItem(name: "hitsPerPage", value: "\(limit)"),
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkDefaults.shortRequest
        let (data, response) = try await NetworkDefaults.ephemeralSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else { return [] }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hits = json["hits"] as? [[String: Any]]
        else {
            return []
        }

        return hits.compactMap { hit in
            guard let title = hit["title"] as? String ?? hit["story_title"] as? String else { return nil }
            let url = (hit["url"] as? String) ?? "https://news.ycombinator.com/item?id=\(hit["objectID"] as? String ?? "")"
            let author = hit["author"] as? String ?? "HN"
            let createdAt = hit["created_at"] as? String ?? ""
            let snippet = "Hacker News · \(author) · \(createdAt)"
            return SearchResult(title: title, url: url, snippet: snippet)
        }
    }

    private static func parseDuckDuckGoHTML(_ html: String, limit: Int) -> [SearchResult] {
        let titlePattern = #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern =
            #"<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>|<div[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</div>"#

        let titleMatches = matches(pattern: titlePattern, in: html)
        let snippets = matches(pattern: snippetPattern, in: html).map { match in
            match.dropFirst().first { !$0.isEmpty } ?? ""
        }

        return titleMatches.prefix(limit).enumerated().map { index, match in
            let url = decodeHTML(match[safe: 1] ?? "")
            let title = cleanHTML(match[safe: 2] ?? "搜索结果")
            let snippet = index < snippets.count ? cleanHTML(snippets[index]) : ""
            return SearchResult(title: title, url: url, snippet: snippet)
        }
    }

    private static func matches(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: nsRange).map { match in
            (0..<match.numberOfRanges).map { idx in
                guard let range = Range(match.range(at: idx), in: text) else { return "" }
                return String(text[range])
            }
        }
    }

    private static func cleanHTML(_ text: String) -> String {
        let withoutTags = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeHTML(withoutTags)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
// MARK: - Web Fetch Tool

public struct WebFetchTool: LaicaiTool {
    public var name: String { "web.fetch" }
    public var description: String { "读取指定网页 URL，抽取标题和正文摘要，适合用户直接给链接的任务" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "url": FunctionProperty(type: "string", description: "要读取的 http/https 网页 URL"),
                    "maxCharacters": FunctionProperty(type: "integer", description: "最多返回字符数，默认8000"),
                ],
                required: ["url"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var url: String
            var maxCharacters: Int?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let rawURL = params.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme)
        else {
            return ToolResult(output: "请输入有效的 http/https 网页链接。", success: false, error: "invalid_url")
        }
        if Self.isBlockedHost(url.host) {
            return ToolResult(output: "出于安全原因，不能读取本机、内网或云元数据地址：\(rawURL)", success: false, error: "blocked_private_host")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = NetworkDefaults.webFetch
        request.setValue("Mozilla/5.0 Laicai/0.1", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await NetworkDefaults.ephemeralSession.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(statusCode) else {
                return ToolResult(output: "网页读取失败（HTTP \(statusCode)）：\(rawURL)", success: false, error: "http_\(statusCode)")
            }

            let html =
                String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .unicode)
                ?? ""
            let readable = Self.extractReadableText(fromHTML: html, url: rawURL, maxCharacters: params.maxCharacters ?? 8000)

            await AuditLog.shared.record(
                tool: name,
                input: rawURL,
                output: "读取网页 \(readable.title)，\(readable.content.count) 字符",
                success: true
            )

            let output = """
                标题：\(readable.title)
                URL：\(rawURL)

                \(readable.content)
                """
            return ToolResult(
                output: output,
                data: [
                    "url": rawURL,
                    "title": readable.title,
                    "size": "\(readable.content.count)",
                ],
                success: true
            )
        } catch {
            return ToolResult(output: "网页读取失败：\(error.localizedDescription)", success: false, error: "network_error")
        }
    }

    private static func isBlockedHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased(),
            !host.isEmpty
        else { return true }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if ["::1", "0:0:0:0:0:0:0:1"].contains(host) { return true }
        if host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let firstOctet = parts[0]
        let secondOctet = parts[1]
        if firstOctet == 10 || firstOctet == 127 || firstOctet == 0 { return true }
        if firstOctet == 169 && secondOctet == 254 { return true }
        if firstOctet == 172 && (16...31).contains(secondOctet) { return true }
        if firstOctet == 192 && secondOctet == 168 { return true }
        if firstOctet == 100 && (64...127).contains(secondOctet) { return true }
        return false
    }

    public static func extractReadableText(fromHTML html: String, url: String, maxCharacters: Int) -> (title: String, content: String) {
        let title =
            firstMatch(pattern: #"<title[^>]*>(.*?)</title>"#, in: html)
            .map(cleanHTML(_:))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(string: url)?.host
            ?? "网页"

        var body =
            html
            .replacingOccurrences(of: #"(?is)<script[^>]*>.*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<style[^>]*>.*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<nav[^>]*>.*?</nav>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<footer[^>]*>.*?</footer>"#, with: " ", options: .regularExpression)
        body = cleanHTML(body)

        let limit = max(500, min(maxCharacters, 30000))
        if body.count > limit {
            body = String(body.prefix(limit)) + "\n...（网页内容已截断）"
        }
        return (title, body)
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range])
    }

    private static func cleanHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"[ \t\r\f]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
