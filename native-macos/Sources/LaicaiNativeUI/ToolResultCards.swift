// Tool result rendering extracted from TimelineCards.
import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

struct ToolResultCard: View {
    @EnvironmentObject private var store: AppStore
    let step: TaskStep
    let taskID: UUID

    var body: some View {
        if step.isFailure && !isTerminalOutput {
            FailedCard(step: step, taskID: taskID)
        } else {
            HStack(alignment: .top, spacing: AppSpace.small) {
                ProgressGlyph(icon: step.isFailure ? "xmark" : "checkmark", color: step.isFailure ? Semantic.error : Semantic.success)

                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    HStack(spacing: AppSpace.small) {
                         Text(ToolCallCard.friendlyToolName(step.toolName ?? "工具结果"))
                             .font(AppFont.tiny)
                             .foregroundStyle(TextGrade.muted)
                         Spacer()
                         if step.isCollapsible {
                             Image(systemName: step.isCollapsed ? "chevron.down" : "chevron.up")
                                 .font(.system(size: 8, weight: .bold))
                                 .foregroundStyle(TextGrade.ghost)
                         }
                     }
                     if isTerminalOutput && !step.isCollapsed {
                        TerminalOutputCard(text: step.text, isFailure: step.isFailure)
                    } else if let imagePath {
                        GeneratedImagePreviewCard(path: imagePath, caption: displayText)
                    } else if !step.isCollapsed {
                        toolTextView
                    } else {
                        Text("已完成")
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)
                            .lineLimit(1)
                    }

                    if step.isFailure {
                        Button {
                            store.retryLastMessage()
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(AppFont.tiny)
                                .foregroundStyle(Brand.primary)
                                .padding(.horizontal, AppSpace.small)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Brand.primary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                guard step.isCollapsible else { return }
                store.toggleStepCollapsed(taskID: taskID, stepID: step.id)
            }
        }
    }

    private var isTerminalOutput: Bool {
        ["shell.exec", "verify.build"].contains(step.toolName ?? "")
    }

    // Resolving the image path stats the filesystem and runs a regex over the
    // output text. Cache per step ID so streaming re-renders don't redo disk IO
    // on every body evaluation.
    private static let imagePathCache = NSCache<NSUUID, NSString>()

    private var imagePath: String? {
        guard step.toolName == "image.generate", !step.isFailure else { return nil }
        let key = step.id as NSUUID
        if let cached = Self.imagePathCache.object(forKey: key) {
            return (cached as String).isEmpty ? nil : (cached as String)
        }
        let resolved = Self.resolveImagePath(step: step)
        Self.imagePathCache.setObject((resolved as NSString), forKey: key)
        return resolved.isEmpty ? nil : resolved
    }

    private static func resolveImagePath(step: TaskStep) -> String {
        if let path = step.toolParams?["imagePath"], FileManager.default.fileExists(atPath: path) {
            return path
        }
        return firstImagePath(in: step.text) ?? ""
    }

    private static let imagePathRegex = try? NSRegularExpression(
        pattern: #"(/[^\n\r\t]+?\.(?:png|jpg|jpeg|webp|heic))"#,
        options: [.caseInsensitive])

    private static func firstImagePath(in text: String) -> String? {
        guard let regex = imagePathRegex else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        let raw = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "。.,，)）]】\"'"))
        return FileManager.default.fileExists(atPath: raw) ? raw : nil
    }

    private var displayText: String {
        let maxLen = 2000
        if step.text.count <= maxLen { return step.text }
        return String(step.text.prefix(maxLen)) + "\n\n… 共 \(step.text.count) 字，已截断显示"
    }

    private var toolTextView: some View {
        Text(displayText)
            .font(AppFont.codeSmall)
            .foregroundStyle(step.isFailure ? Semantic.error : TextGrade.muted)
            .lineLimit(step.isFailure ? 6 : 4)
            .padding(.horizontal, AppSpace.small)
            .padding(.vertical, AppSpace.extraSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(SurfaceGrade.sunken.opacity(0.34))
            )
    }
}

struct GeneratedImagePreviewCard: View {
    @EnvironmentObject private var store: AppStore
    let path: String
    let caption: String

    // Metadata + preview are loaded off the main thread once per path. Decoding
    // NSImage(contentsOfFile:) on every body evaluation made long timelines
    // with image results progressively slower.
    @State private var fileSizeLabel = ""
    @State private var dimensionsLabel = ""
    @State private var thumbnail: NSImage?

    private var url: URL {
        URL(fileURLWithPath: path)
    }

    private var filename: String {
        url.lastPathComponent
    }

    var body: some View {
        cardContent
            .onAppear(perform: loadMetadataIfNeeded)
            .onChange(of: path) { _ in loadMetadataIfNeeded() }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: AppSpace.medium) {
            HStack(spacing: AppSpace.small) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Semantic.success)

                VStack(alignment: .leading, spacing: 2) {
                    Text("图片已生成")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.primary)
                    HStack(spacing: AppSpace.small) {
                        Text(filename)
                            .font(AppFont.codeSmall)
                            .foregroundStyle(TextGrade.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !dimensionsLabel.isEmpty {
                            Text(dimensionsLabel)
                        }
                        if !fileSizeLabel.isEmpty {
                            Text(fileSizeLabel)
                        }
                    }
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                }

                Spacer(minLength: AppSpace.small)

                imageAction(icon: "arrow.clockwise", label: "重新生成") {
                    store.retryLastMessage()
                }
                imageAction(icon: "doc.on.doc", label: "复制路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                    ToastCenter.shared.success("已复制图片路径")
                }
            }

            if let image = thumbnail {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 640, maxHeight: 420)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                .strokeBorder(SurfaceGrade.border.opacity(0.25), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("打开图片")
            } else {
                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    Text("图片文件暂时无法预览")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(Semantic.warning)
                    Text(path)
                        .font(AppFont.codeSmall)
                        .foregroundStyle(TextGrade.ghost)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(AppSpace.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous).fill(SurfaceGrade.sunken.opacity(0.42)))
            }

            HStack(spacing: AppSpace.small) {
                imageAction(icon: "arrow.up.right.square", label: "打开") {
                    NSWorkspace.shared.open(url)
                }
                imageAction(icon: "folder", label: "Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }

                Spacer(minLength: AppSpace.small)

                Text(path)
                    .font(AppFont.codeSmall)
                    .foregroundStyle(TextGrade.ghost)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Text(caption)
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.ghost)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(AppSpace.medium)
        .frame(maxWidth: 680, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Semantic.success.opacity(0.22), lineWidth: 0.8)
        )
    }

    private func imageAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(AppFont.tiny)
            }
            .foregroundStyle(TextGrade.secondary)
            .padding(.horizontal, AppSpace.small)
            .padding(.vertical, 5)
            .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.72)))
            .overlay(Capsule().strokeBorder(SurfaceGrade.border.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func loadMetadataIfNeeded() {
        guard thumbnail == nil else { return }
        let filePath = path
        Task.detached(priority: .userInitiated) {
            let sizeLabel = Self.fileSizeLabel(atPath: filePath)
            let (image, dims) = Self.downsampledImageAndDimensions(atPath: filePath, maxPixel: 1280)
            await MainActor.run {
                fileSizeLabel = sizeLabel
                dimensionsLabel = dims
                thumbnail = image
            }
        }
    }

    private nonisolated static func fileSizeLabel(atPath path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attrs[.size] as? NSNumber
        else { return "" }
        let value = size.doubleValue
        if value >= 1_048_576 { return String(format: "%.1f MB", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0f KB", value / 1024) }
        return "\(Int(value)) B"
    }

    /// Downsample via ImageIO instead of decoding the full-resolution source.
    private nonisolated static func downsampledImageAndDimensions(atPath path: String, maxPixel: Int) -> (NSImage?, String) {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, sourceOptions) else {
            return (nil, "")
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return (nil, "")
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return (image, "\(cgImage.width) x \(cgImage.height)")
    }
}

