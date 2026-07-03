import Foundation

/// 中文友好相对时间格式化器
/// 输出：刚刚 / 5分钟前 / 2小时前 / 昨天 / 3天前 / 05-12
enum RelativeTimeFormatter {
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    static func string(for date: Date) -> String {
        let now = Date()
        let diff = now.timeIntervalSince(date)

        // 未来时间通常来自系统时间漂移或异常持久化，UI 上按最近活动处理。
        if diff < 0 { return "刚刚" }

        // 刚刚（< 30秒）
        if diff < 30 { return "刚刚" }

        // 分钟（< 60分钟）
        if diff < 3600 {
            let mins = Int(diff / 60)
            return "\(mins)分钟前"
        }

        // 小时（< 24小时）
        if diff < 86400 {
            let hours = Int(diff / 3600)
            return "\(hours)小时前"
        }

        // 昨天
        let cal = Calendar.current
        if cal.isDateInYesterday(date) { return "昨天" }

        // 3天内
        if diff < 86400 * 3 {
            let days = Int(diff / 86400)
            return "\(days)天前"
        }

        // 本年内显示 MM-DD
        let year = cal.component(.year, from: now)
        let dateYear = cal.component(.year, from: date)
        if year == dateYear {
            return formatShortDate(date)
        }

        // 更早显示完整日期
        return formatDate(date)
    }

    private static func formatDate(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }

    private static func formatShortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }
}
