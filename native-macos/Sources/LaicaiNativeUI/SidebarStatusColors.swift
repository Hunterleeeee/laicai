import LaicaiNativeDomain
import SwiftUI

extension TaskStatus {
    var color: Color {
        switch self {
        case .queued: return Semantic.warning
        case .running: return Brand.primary
        case .waitingReview: return Semantic.warning
        case .completed: return Semantic.success
        case .failed: return Semantic.error
        case .cancelled: return TextGrade.muted
        }
    }

    var label: String { title }
}

extension ConnectorHealth {
    var color: Color {
        switch self {
        case .ready: return Semantic.success
        case .attention: return Semantic.warning
        case .offline: return Semantic.error
        }
    }
}
