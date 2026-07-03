import Foundation
import LaicaiNativeDomain

public enum AppNoticeStyle: String, Equatable, Sendable {
    case info
    case success
    case warning
    case error
}

public struct AppNotice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var message: String
    public var style: AppNoticeStyle

    public init(id: UUID = UUID(), message: String, style: AppNoticeStyle = .info) {
        self.id = id
        self.message = message
        self.style = style
    }
}

public enum ExecutionMode: String, CaseIterable, Equatable, Sendable, Codable {
    case auto

    public var title: String { "自动" }
    public var icon: String { "wand.and.stars" }

    public init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer().decode(String.self)
        self = .auto
    }
}

public struct ImageAttachment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let data: Data
    public let mediaType: String
    public let thumbnailName: String
    public let width: Int
    public let height: Int

    public init(id: UUID = UUID(), data: Data, mediaType: String = "image/png", thumbnailName: String = "图片", width: Int = 0, height: Int = 0) {
        self.id = id
        self.data = data
        self.mediaType = mediaType
        self.thumbnailName = thumbnailName
        self.width = width
        self.height = height
    }

    public static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool {
        lhs.id == rhs.id
    }

    /// Convert to OpenAI vision ContentPart.
    public func toContentPart() -> ContentPart {
        .imageBase64(data: data, mediaType: mediaType, detail: "auto")
    }
}
