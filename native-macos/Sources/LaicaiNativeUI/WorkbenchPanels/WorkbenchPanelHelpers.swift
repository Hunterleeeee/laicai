import SwiftUI

func contextSectionCard<Content: View>(
    title: String,
    tint: Color = Brand.primary,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: AppSpace.md) {
        HStack(spacing: AppSpace.xs) {
            Circle()
                .fill(tint.opacity(0.55))
                .frame(width: 5, height: 5)
            Text(title)
                .font(AppFont.captionMedium)
                .foregroundStyle(TextGrade.secondary)
            Spacer()
        }
        content()
    }
    .padding(AppSpace.md)
    .background(
        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [SurfaceGrade.card.opacity(0.88), SurfaceGrade.elevated.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    )
    .overlay(
        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
            .strokeBorder(tint.opacity(0.14), lineWidth: 0.7)
    )
    .shadow(color: AppShadow.sm.color.opacity(0.75), radius: AppShadow.sm.radius, y: AppShadow.sm.y)
}

func workbenchHeroCard<Content: View>(
    icon: String,
    title: String,
    subtitle: String,
    tint: Color = Brand.primary,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: AppSpace.md) {
        HStack(alignment: .top, spacing: AppSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.opacity(0.10)))

            VStack(alignment: .leading, spacing: AppSpace.xs) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(AppFont.caption)
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(2)
            }

            Spacer()
        }

        content()
    }
    .padding(AppSpace.lg)
    .background(
        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [SurfaceGrade.card, SurfaceGrade.elevated.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    )
    .overlay(
        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
            .strokeBorder(tint.opacity(0.14), lineWidth: 0.7)
    )
    .shadow(color: AppShadow.sm.color, radius: AppShadow.sm.radius, y: AppShadow.sm.y)
}

func workbenchSearchField(text: Binding<String>, placeholder: String) -> some View {
    HStack(spacing: AppSpace.sm) {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(TextGrade.ghost)
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(AppFont.caption)
    }
    .padding(.horizontal, AppSpace.md)
    .padding(.vertical, AppSpace.sm)
    .background(
        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
            .fill(SurfaceGrade.card.opacity(0.76))
    )
    .overlay(
        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
            .strokeBorder(SurfaceGrade.hairline.opacity(0.85), lineWidth: 0.7)
    )
}

func workbenchSectionHeader(title: String, count: Int? = nil) -> some View {
    HStack {
        Text(title)
            .font(AppFont.captionMedium)
            .foregroundStyle(TextGrade.secondary)
        Spacer()
        if let count {
            Text("\(count)")
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.ghost)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.8)))
        }
    }
}

func workbenchEmptyState(icon: String, title: String, hint: String) -> some View {
    VStack(spacing: AppSpace.md) {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Brand.primary)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Brand.primary.opacity(0.10)))
        VStack(spacing: AppSpace.xs) {
            Text(title)
                .font(AppFont.captionMedium)
                .foregroundStyle(TextGrade.secondary)
            Text(hint)
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.muted)
                .multilineTextAlignment(.center)
        }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, AppSpace.lg)
    .background(
        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
            .fill(SurfaceGrade.card.opacity(0.62))
    )
    .overlay(
        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
            .strokeBorder(SurfaceGrade.hairline.opacity(0.75), lineWidth: 0.6)
    )
}

func summaryRow(icon: String, label: String, value: String) -> some View {
    HStack(spacing: AppSpace.sm) {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Brand.primary)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Brand.primary.opacity(0.08)))
        Text(label)
            .font(AppFont.tiny)
            .foregroundStyle(TextGrade.muted)
            .frame(width: 34, alignment: .leading)
        Spacer()
        Text(value)
            .font(AppFont.codeSmall)
            .foregroundStyle(TextGrade.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
