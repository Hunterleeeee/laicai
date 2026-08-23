import SwiftUI

struct AdaptiveMarkdownText: View {
    let markdown: String
    var fontSize: CGFloat = 14
    var enablesTextSelection: Bool = true
    var forceFast: Bool = false
    var isStreaming: Bool = false

    private var shouldUseFastRenderer: Bool {
        forceFast || markdown.count > 9_000 || markdown.components(separatedBy: "\n").count > 220
    }

    var body: some View {
        if shouldUseFastRenderer {
            FastMarkdownText(markdown: markdown, fontSize: fontSize, isStreaming: isStreaming)
        } else {
            MarkdownText(
                markdown,
                fontSize: fontSize,
                enablesTextSelection: enablesTextSelection,
                previewLimit: 18_000
            )
        }
    }
}

// MARK: - Markdown Text

struct MarkdownText: View {
    let markdown: String
    let fontSize: CGFloat
    let enablesTextSelection: Bool
    let previewLimit: Int
    @State private var expanded = false

    init(
        _ markdown: String,
        fontSize: CGFloat = 14,
        enablesTextSelection: Bool = true,
        previewLimit: Int = 12_000
    ) {
        self.markdown = markdown
        self.fontSize = fontSize
        self.enablesTextSelection = enablesTextSelection
        self.previewLimit = previewLimit
    }

    var body: some View {
        let cachedBlocks = blocks
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cachedBlocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }

            if isLong {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "收起长内容" : "展开完整内容")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)
                .padding(.top, AppSpace.small)
            }
        }
    }

    // MARK: - Block model

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(indent: Int, ordered: Bool, index: Int, text: String)
        case blockquote(String)
        case code(lang: String, code: String)
        case table(headers: [String], rows: [[String]])
        case divider
        case blank
    }

    // MARK: - Block renderer

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.inlineAttributed(text))
                    .font(
                        .system(
                            size: Self.headingSize(level: level, base: fontSize),
                            weight: Self.headingWeight(level: level)
                        )
                    )
                    .foregroundStyle(level <= 3 ? TextGrade.primary : TextGrade.secondary)
                    .selectableText(enablesTextSelection)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if level == 1 {
                    Rectangle()
                        .fill(SurfaceGrade.divider.opacity(0.72))
                        .frame(height: 1)
                        .padding(.top, 6)
                }
            }
            .padding(.top, Self.headingTopPadding(level: level))
            .padding(.bottom, Self.headingBottomPadding(level: level))

        case .paragraph(let text):
            Text(Self.inlineAttributed(text))
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(TextGrade.primary)
                .lineSpacing(5)
                .selectableText(enablesTextSelection)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 3)

        case .listItem(let indent, let ordered, let index, let text):
            let bullets = ["•", "◦", "▪"]
            let bullet = ordered ? "\(index)." : bullets[min(indent, bullets.count - 1)]
            let markerWidth = ordered ? max(CGFloat(18), CGFloat(bullet.count * 8 + 8)) : CGFloat(10)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(bullet)
                    .font(.system(size: ordered ? fontSize - 1 : fontSize, weight: .medium, design: ordered ? .monospaced : .default))
                    .foregroundStyle(TextGrade.muted)
                    .frame(minWidth: markerWidth, alignment: .trailing)
                Text(Self.inlineAttributed(text))
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundStyle(TextGrade.primary)
                    .lineSpacing(4)
                    .selectableText(enablesTextSelection)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, CGFloat(indent) * 16)
            .padding(.vertical, 2)

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [Brand.primary.opacity(0.6), Brand.primary.opacity(0.2)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                Text(Self.inlineAttributed(text))
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundStyle(TextGrade.secondary)
                    .italic()
                    .lineSpacing(5)
                    .selectableText(enablesTextSelection)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(Brand.primary.opacity(0.03))
            )

        case .code(let lang, let code):
            CodeBlockView(language: lang, code: code, fontSize: fontSize - 2, enablesTextSelection: enablesTextSelection)
                .padding(.vertical, 4)

        case .table(let headers, let rows):
            TableBlockView(headers: headers, rows: rows, fontSize: fontSize - 1, enablesTextSelection: enablesTextSelection)
                .padding(.vertical, 6)

        case .divider:
            Rectangle()
                .fill(SurfaceGrade.divider)
                .frame(height: 1)
                .padding(.vertical, 8)

        case .blank:
            Spacer().frame(height: 6)
        }
    }

    private static func headingSize(level: Int, base: CGFloat) -> CGFloat {
        switch level {
        case 1: return base + 5
        case 2: return base + 3
        case 3: return base + 1.5
        default: return base + 1
        }
    }

    private static func headingWeight(level: Int) -> Font.Weight {
        if level <= 2 { return .bold }
        return level == 3 ? .semibold : .medium
    }

    private static func headingTopPadding(level: Int) -> CGFloat {
        if level == 1 { return 14 }
        return level == 2 ? 12 : 8
    }

    private static func headingBottomPadding(level: Int) -> CGFloat {
        level == 1 ? 6 : 4
    }

    // MARK: - Inline formatting (bold, code, links)

    private static func inlineAttributed(_ text: String) -> AttributedString {
        let key = NSString(string: cacheKey(for: text))
        if let cached = inlineCache.object(forKey: key) {
            return cached.value
        }
        var result: AttributedString
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            result = attributed
        } else {
            result = AttributedString(text)
        }
        for run in result.runs {
            let range = run.range
            // Inline code: monospace + tinted background
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[range].font = .system(size: 13, weight: .regular, design: .monospaced)
                result[range].foregroundColor = Brand.primaryDark
                result[range].backgroundColor = SurfaceGrade.elevated
            }
            // Bold: ensure it's visually prominent
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                result[range].foregroundColor = TextGrade.primary
            }
            // Links: brand color
            if run.link != nil {
                result[range].foregroundColor = Brand.primary
            }
        }
        inlineCache.setObject(InlineCacheEntry(value: result), forKey: key)
        inlineCache.countLimit = 400
        return result
    }

    // MARK: - Parser

    private var isLong: Bool { markdown.count > previewLimit }

    private var visibleMarkdown: String {
        guard isLong, !expanded else { return markdown }
        return String(markdown.prefix(previewLimit))
            + "\n\n... 长内容已折叠，展开后查看完整回复 ..."
    }

    private var blocks: [Block] {
        // Cache key: markdown content + expanded state determines visible text
        Self.cachedParse(visibleMarkdown)
    }

    private final class BlockCacheEntry {
        let blocks: [Block]
        init(blocks: [Block]) { self.blocks = blocks }
    }

    private final class InlineCacheEntry {
        let value: AttributedString
        init(value: AttributedString) { self.value = value }
    }

    private static let blockCache = NSCache<NSString, BlockCacheEntry>()
    private static let inlineCache = NSCache<NSString, InlineCacheEntry>()

    private static func cachedParse(_ text: String) -> [Block] {
        let key = NSString(string: cacheKey(for: text))
        if let cached = blockCache.object(forKey: key) {
            return cached.blocks
        }

        let preprocessed = preprocess(text)
        let parsed = parseBlocks(from: preprocessed)

        let entry = BlockCacheEntry(blocks: parsed)
        blockCache.setObject(entry, forKey: key)
        blockCache.countLimit = 60
        return parsed
    }

    private static func cacheKey(for text: String) -> String {
        "\(text.count)_\(text.hashValue)"
    }

    /// Normalize LLM output: ensure headings/lists start on their own line.
    private static func preprocess(_ text: String) -> String {
        var result = text
        // Heading not at line start
        result = result.replacingOccurrences(of: "([^\\n])\\s*(#{1,6}\\s)", with: "$1\n\n$2", options: .regularExpression)
        // List item not at line start
        result = result.replacingOccurrences(of: "([：:;；。!?])\\s+([-*]\\s)", with: "$1\n$2", options: .regularExpression)
        result = result.replacingOccurrences(of: "([^\\n])\\s{2,}([-*]\\s)", with: "$1\n$2", options: .regularExpression)
        result = result.replacingOccurrences(of: "([：:;；。!?])\\s+(\\d{1,3}[\\.)]\\s+)", with: "$1\n$2", options: .regularExpression)
        result = result.replacingOccurrences(of: "([^\\n])\\s{2,}(\\d{1,3}[\\.)]\\s+)", with: "$1\n$2", options: .regularExpression)
        // Collapse excessive newlines
        result = result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return result
    }

    private static func parseBlocks(from source: String) -> [Block] {
        var blocks: [Block] = []
        let lines = source.components(separatedBy: "\n")
        var index = 0
        var orderedCounters: [Int: Int] = [:]

        func resetOrderedCounters(atOrBelow indent: Int? = nil) {
            if let indent {
                for key in Array(orderedCounters.keys) where key >= indent {
                    orderedCounters.removeValue(forKey: key)
                }
            } else {
                orderedCounters.removeAll()
            }
        }

        func consumeCodeFence(line: String, trimmed: String) -> Bool {
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(lang: lang, code: codeLines.joined(separator: "\n")))
                resetOrderedCounters()
                return true
            }
            return false
        }

        func consumeBlank(line: String, trimmed: String) -> Bool {
            if trimmed.isEmpty {
                if let last = blocks.last, case .blank = last {
                    // skip consecutive blanks
                } else {
                    blocks.append(.blank)
                }
                resetOrderedCounters()
                index += 1
                return true
            }
            return false
        }

        func consumeDivider(line: String, trimmed: String) -> Bool {
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == " " }) && trimmed.filter({ $0 == "-" || $0 == "*" }).count >= 3 {
                blocks.append(.divider)
                resetOrderedCounters()
                index += 1
                return true
            }
            return false
        }

        func consumeTable(line: String, trimmed: String) -> Bool {
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.filter({ $0 == "|" }).count >= 3 {
                var tableLines: [String] = []
                while index < lines.count {
                    let tableLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard tableLine.hasPrefix("|") else { break }
                    tableLines.append(tableLine)
                    index += 1
                }
                if let tbl = Self.parseTable(tableLines) {
                    blocks.append(.table(headers: tbl.headers, rows: tbl.rows))
                } else {
                    for tableLine in tableLines {
                        blocks.append(.paragraph(tableLine))
                    }
                }
                resetOrderedCounters()
                return true
            }
            return false
        }

        func consumeHeading(line: String, trimmed: String) -> Bool {
            if let headingMatch = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                let hashes = trimmed[headingMatch].filter { $0 == "#" }.count
                let content = String(trimmed[headingMatch.upperBound...])
                blocks.append(.heading(level: hashes, text: content))
                resetOrderedCounters()
                index += 1
                return true
            }
            return false
        }

        func consumeBlockquote(line: String, trimmed: String) -> Bool {
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = []
                while index < lines.count {
                    let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                    if quoteLine.hasPrefix("> ") {
                        quoteLines.append(String(quoteLine.dropFirst(2)))
                    } else if quoteLine == ">" {
                        quoteLines.append("")
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)))
                resetOrderedCounters()
                return true
            }
            return false
        }

        func consumeUnorderedList(line: String, trimmed: String) -> Bool {
            if let listMatch = trimmed.range(of: "^[-*+]\\s+", options: .regularExpression) {
                let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                let indent = leadingSpaces / 2
                let content = String(trimmed[listMatch.upperBound...])
                blocks.append(.listItem(indent: indent, ordered: false, index: 0, text: content))
                resetOrderedCounters(atOrBelow: indent)
                index += 1
                return true
            }
            return false
        }

        func consumeOrderedList(line: String, trimmed: String) -> Bool {
            if let numMatch = trimmed.range(of: "^\\d+[\\.)]\\s+", options: .regularExpression) {
                let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                let indent = leadingSpaces / 2
                let content = String(trimmed[numMatch.upperBound...])
                let marker = String(trimmed[numMatch])
                let explicitIndex = Int(marker.prefix(while: { $0.isNumber })) ?? 1
                let previousIndex = orderedCounters[indent]
                let displayIndex: Int
                if let previousIndex, explicitIndex <= 1 {
                    displayIndex = previousIndex + 1
                } else {
                    displayIndex = explicitIndex
                }
                for key in Array(orderedCounters.keys) where key > indent {
                    orderedCounters.removeValue(forKey: key)
                }
                orderedCounters[indent] = displayIndex
                blocks.append(.listItem(indent: indent, ordered: true, index: displayIndex, text: content))
                index += 1
                return true
            }
            return false
        }

        func consumeParagraph(trimmed: String) {
            // Paragraph: collect consecutive non-special lines.
            // For CJK text, preserve line breaks instead of joining with space —
            // Chinese content uses line breaks semantically (计划/结论/总结 etc.).
            var paraLines: [String] = [trimmed]
            resetOrderedCounters()
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || next.hasPrefix("#") || next.hasPrefix("```")
                    || next.hasPrefix(">")
                    || (next.hasPrefix("|") && next.hasSuffix("|"))
                    || next.range(of: "^[-*+]\\s+", options: .regularExpression) != nil
                    || next.range(of: "^\\d+[\\.)]\\s+", options: .regularExpression) != nil
                {
                    break
                }
                // Break paragraph when next line starts with a CJK label (e.g. "计划：", "结论：")
                if next.range(of: "^[\\p{Han}\\p{Katakana}\\p{Hiragana}].*[：:]", options: .regularExpression) != nil
                    && paraLines.count >= 1
                {
                    break
                }
                paraLines.append(next)
                index += 1
            }
            // Use newline for CJK content to preserve intentional line breaks
            let hasCJK = paraLines.contains { line in
                line.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
            }
            blocks.append(.paragraph(paraLines.joined(separator: hasCJK ? "\n" : " ")))
        }

        let blockConsumers: [(String, String) -> Bool] = [
            consumeCodeFence,
            consumeBlank,
            consumeDivider,
            consumeTable,
            consumeHeading,
            consumeBlockquote,
            consumeUnorderedList,
            consumeOrderedList,
        ]

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if blockConsumers.contains(where: { $0(line, trimmed) }) {
                continue
            }
            consumeParagraph(trimmed: trimmed)
        }

        return blocks
    }

    // MARK: - Table parser
    private static func parseTable(_ lines: [String]) -> (headers: [String], rows: [[String]])? {
        guard lines.count >= 2 else { return nil }
        func splitCells(_ line: String) -> [String] {
            line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let headers = splitCells(lines[0])
        guard headers.count >= 2 else { return nil }
        // Line 1 is the separator (|---|---|)
        let startRow = lines.count > 1 && lines[1].contains("-") ? 2 : 1
        var rows: [[String]] = []
        for index in startRow..<lines.count {
            let cells = splitCells(lines[index])
            // Skip separator-only lines
            if cells.allSatisfy({ $0.allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " }) }) { continue }
            rows.append(cells)
        }
        return (headers, rows)
    }
}

// MARK: - Code Block View

private struct CodeBlockView: View {
    let language: String
    let code: String
    let fontSize: CGFloat
    let enablesTextSelection: Bool
    @State private var isHovered = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar with language + copy
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TextGrade.muted)
                    .textCase(.uppercase)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1500))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(copied ? Semantic.success : TextGrade.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(copied ? Semantic.success.opacity(0.12) : SurfaceGrade.elevated)
                    )
                }
                .buttonStyle(.plain)
                .help("复制代码")
                .opacity(isHovered || copied ? 1 : 0.72)
            }
            .padding(.horizontal, AppSpace.medium)
            .padding(.vertical, AppSpace.small)
            .background(SurfaceGrade.elevated)

            Rectangle().fill(SurfaceGrade.divider).frame(height: 1)

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                    .foregroundStyle(TextGrade.secondary)
                    .lineSpacing(4)
                    .selectableText(enablesTextSelection)
                    .padding(.horizontal, AppSpace.medium)
                    .padding(.vertical, AppSpace.small)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(SurfaceGrade.sunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(SurfaceGrade.border.opacity(0.55), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering } }
    }
}

// MARK: - Table Block View

private struct TableBlockView: View {
    let headers: [String]
    let rows: [[String]]
    let fontSize: CGFloat
    let enablesTextSelection: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { idx, header in
                        Text(header)
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundStyle(TextGrade.primary)
                            .selectableText(enablesTextSelection)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(minWidth: columnWidth(idx), alignment: .leading)
                    }
                }
                .background(SurfaceGrade.elevated)

                Rectangle().fill(SurfaceGrade.divider).frame(height: 1)

                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.prefix(headers.count).enumerated()), id: \.offset) { colIdx, cell in
                            Text(cell)
                                .font(.system(size: fontSize, weight: .regular))
                                .foregroundStyle(TextGrade.secondary)
                                .selectableText(enablesTextSelection)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(minWidth: columnWidth(colIdx), alignment: .leading)
                        }
                    }
                    .background(rowIdx % 2 == 1 ? SurfaceGrade.elevated.opacity(0.55) : Color.clear)

                    if rowIdx < rows.count - 1 {
                        Rectangle().fill(SurfaceGrade.hairline).frame(height: 0.5)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(SurfaceGrade.sunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(SurfaceGrade.border.opacity(0.55), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }

    private func columnWidth(_ index: Int) -> CGFloat {
        let allCells = [headers[safe: index] ?? ""] + rows.compactMap { $0[safe: index] }
        let maxLen = allCells.map(\.count).max() ?? 4
        return CGFloat(max(60, min(maxLen * 9 + 20, 240)))
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension View {
    @ViewBuilder
    fileprivate func selectableText(_ enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
    }
}
