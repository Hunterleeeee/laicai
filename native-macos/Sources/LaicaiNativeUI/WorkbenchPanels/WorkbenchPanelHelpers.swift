import SwiftUI

func contextSectionCard<Content: View>(
    title: String,
    tint: Color = Brand.primary,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: AppSpace.sm) {
        Text(title)
            .font(AppFont.captionMedium)
            .foregroundStyle(TextGrade.secondary)
        content()
    }
    .padding(AppSpace.md)
    .background(
        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
            .fill(SurfaceGrade.card.opacity(0.4))
    )
    .overlay(
        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
            .strokeBorder(tint.opacity(0.10), lineWidth: 0.5)
    )
}

func summaryRow(icon: String, label: String, value: String) -> some View {
    HStack(spacing: AppSpace.sm) {
        Image(systemName: icon)
            .font(.system(size: 9))
            .foregroundStyle(Brand.primary)
            .frame(width: 12)
        Text(label)
            .font(AppFont.tiny)
            .foregroundStyle(TextGrade.muted)
            .frame(width: 30, alignment: .leading)
        Spacer()
        Text(value)
            .font(AppFont.codeSmall)
            .foregroundStyle(TextGrade.secondary)
            .lineLimit(1)
    }
}
