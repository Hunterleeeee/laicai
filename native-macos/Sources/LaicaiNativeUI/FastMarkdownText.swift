import AppKit
import SwiftUI

struct FastMarkdownText: NSViewRepresentable {
    let markdown: String
    var fontSize: CGFloat = 14
    var maxWidth: CGFloat = LayoutConst.conversationMaxWidth

    func makeNSView(context: Context) -> FastMarkdownTextView {
        let view = FastMarkdownTextView()
        view.configure(markdown: markdown, fontSize: fontSize, maxWidth: maxWidth)
        return view
    }

    func updateNSView(_ view: FastMarkdownTextView, context: Context) {
        view.configure(markdown: markdown, fontSize: fontSize, maxWidth: maxWidth)
    }
}

final class FastMarkdownTextView: NSView {
    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(containerSize: .zero)
    private var lastMarkdown = ""
    private var lastFontSize: CGFloat = 0
    private var lastWidth: CGFloat = 0
    private var measuredHeight: CGFloat = 1
    private var lastMeasureKey: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width)
        guard abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        measure(width: width)
    }

    func configure(markdown: String, fontSize: CGFloat, maxWidth: CGFloat) {
        let width = bounds.width > 1 ? bounds.width : maxWidth
        guard markdown != lastMarkdown || abs(fontSize - lastFontSize) > 0.1 || abs(width - lastWidth) > 0.5 else { return }
        lastMarkdown = markdown
        lastFontSize = fontSize
        lastWidth = width
        textStorage.setAttributedString(Self.attributed(markdown, fontSize: fontSize))
        measure(width: width)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: dirtyRect, in: textContainer)
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
    }

    private func setup() {
        wantsLayer = false
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        setAccessibilityElement(false)
    }

    private func measure(width: CGFloat) {
        let measureKey =
            "\(lastMarkdown.count)-\(Int(width.rounded()))-\(Int(lastFontSize * 10))-\(lastMarkdown.prefix(48))-\(lastMarkdown.suffix(48))"
        if measureKey == lastMeasureKey { return }
        lastMeasureKey = measureKey
        textContainer.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let nextHeight = ceil(used + 2)
        guard abs(nextHeight - measuredHeight) > 0.5 else { return }
        measuredHeight = nextHeight
        invalidateIntrinsicContentSize()
    }

    private static func attributed(_ markdown: String, fontSize: CGFloat) -> NSAttributedString {
        let text = PlainMarkdownRenderer.render(markdown)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 7

        let output = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        applyLineStyles(output, fontSize: fontSize)
        return output
    }

    private static func applyLineStyles(_ output: NSMutableAttributedString, fontSize: CGFloat) {
        let string = output.string as NSString
        let full = NSRange(location: 0, length: string.length)
        string.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = string.substring(with: range)
            if line.hasPrefix("# ") || line.hasPrefix("## ") {
                output.addAttributes(
                    [
                        .font: NSFont.boldSystemFont(ofSize: fontSize + (line.hasPrefix("# ") ? 4 : 2)),
                        .foregroundColor: NSColor.labelColor,
                    ], range: range)
            } else if line.hasPrefix("```") {
                output.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ], range: range)
            } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                output.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
                    ], range: range)
            }
        }
    }
}

private enum PlainMarkdownRenderer {
    static func render(_ markdown: String) -> String {
        var lines: [String] = []
        var inCode = false

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inCode.toggle()
                lines.append(rawLine)
                continue
            }

            if inCode {
                lines.append(rawLine)
                continue
            }

            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.filter({ $0 == "|" }).count >= 3 {
                lines.append(
                    trimmed
                        .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .components(separatedBy: "|")
                        .map { stripInline($0.trimmingCharacters(in: .whitespaces)) }
                        .joined(separator: "    ")
                )
                continue
            }

            if trimmed.range(of: "^\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)+\\|?$", options: .regularExpression) != nil {
                continue
            }

            lines.append(stripInline(rawLine))
        }

        return lines.joined(separator: "\n")
    }

    private static func stripInline(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^\\)]+)\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        return result
    }
}
