import Foundation
import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

struct ActivityRow: View {
    let activity: ToolActivity

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.small) {
            Image(systemName: activity.isFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppSpace.extraSmall) {
                    Text(activity.summary.isEmpty ? activity.name : activity.summary)
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(RelativeTimeFormatter.string(for: activity.timestamp))
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                        .lineLimit(1)
                }

                if !activity.statusLine.isEmpty {
                    Text(activity.statusLine)
                        .font(AppFont.tiny)
                        .foregroundStyle(activity.isFailure ? Semantic.error : TextGrade.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(activity.name)
                    .font(AppFont.codeSmall)
                    .foregroundStyle(TextGrade.ghost)
                    .lineLimit(1)
                    .opacity(activity.name.isEmpty || activity.name == activity.summary ? 0 : 1)
            }
        }
        .padding(.vertical, AppSpace.small)
        .padding(.horizontal, AppSpace.extraSmall)
    }

    private var statusColor: Color {
        activity.isFailure ? Semantic.error : Semantic.success
    }
}
