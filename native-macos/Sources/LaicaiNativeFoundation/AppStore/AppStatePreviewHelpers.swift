import Foundation

func normalizedSessionPreview(_ text: String, limit: Int = 80) -> String {
    let preview =
        text
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !preview.isEmpty else { return "" }

    if preview.hasPrefix("Request failed (404)") || preview.hasPrefix("未找到") || preview.contains("HTTP 404") {
        return "未找到接口，请检查端点地址是否正确。"
    }
    if preview.hasPrefix("Request failed (401)") || preview.hasPrefix("鉴权") || preview.contains("HTTP 401") {
        return "鉴权失败，请检查 API 密钥是否正确。"
    }
    if preview.hasPrefix("请求失败")
        || preview.hasPrefix("请求格式不被")
        || preview.hasPrefix("任务执行失败")
        || preview.contains("Request failed")
        || preview.contains("provider returned")
        || preview.contains("{\"error\"")
        || preview.localizedCaseInsensitiveContains("\"error\"")
        || preview.localizedCaseInsensitiveContains("invalid_request_error")
    {
        return "请求失败，请检查连接器配置。"
    }
    if preview.count > limit {
        return String(preview.prefix(max(0, limit - 1))) + "…"
    }
    return preview
}
