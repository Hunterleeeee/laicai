import SwiftUI

// MARK: - Markdown Text

struct MarkdownText: View {
    let markdown: String
    let fontSize: CGFloat
    @State private var expanded = false
    private let previewLimit = 12_000

    init(_ markdown: String, fontSize: CGFloat = 14) {
        self.markdown = markdown
        self.fontSize = fontSize
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
                .padding(.top, AppSpace.sm)
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
            let size: CGFloat = {
                switch level {
                case 1: return fontSize + 8
                case 2: return fontSize + 5
                case 3: return fontSize + 2.5
                default: return fontSize + 1
                }
            }()
            let weight: Font.Weight = level <= 2 ? .bold : (level == 3 ? .semibold : .medium)
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.inlineAttributed(text))
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(level <= 3 ? TextGrade.primary : TextGrade.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if level <= 2 {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.1), Color.white.opacity(0.02)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(height: level == 1 ? 1.5 : 1)
                        .padding(.top, 6)
                }
            }
            .padding(.top, level == 1 ? 20 : (level == 2 ? 16 : 10))
            .padding(.bottom, 6)

        case .paragraph(let text):
            Text(Self.inlineAttributed(text))
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(TextGrade.primary)
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)

        case .listItem(let indent, let ordered, let index, let text):
            let bullets = ["•", "◦", "▪"]
            let bullet = ordered ? "\(index)." : bullets[min(indent, bullets.count - 1)]
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(bullet)
                    .font(.system(size: ordered ? fontSize - 1 : fontSize, weight: .medium, design: ordered ? .monospaced : .default))
                    .foregroundStyle(TextGrade.muted)
                    .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                Text(Self.inlineAttributed(text))
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundStyle(TextGrade.primary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, CGFloat(indent) * 16)
            .padding(.vertical, 1.5)

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
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .fill(Brand.primary.opacity(0.03))
            )

        case .code(let lang, let code):
            CodeBlockView(language: lang, code: code, fontSize: fontSize - 2)
                .padding(.vertical, 4)

        case .table(let headers, let rows):
            TableBlockView(headers: headers, rows: rows, fontSize: fontSize - 1)
                .padding(.vertical, 6)

        case .divider:
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 8)

        case .blank:
            Spacer().frame(height: 8)
        }
    }

    // MARK: - Inline formatting (bold, code, links)

    private static func inlineAttributed(_ text: String) -> AttributedString {
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
                result[range].font = .system(size: 13, weight: .medium, design: .monospaced)
                result[range].foregroundColor = Color(hex: "C8D0FF")
                result[range].backgroundColor = Color.white.opacity(0.07)
            }
            // Bold: ensure it's visually prominent
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                result[range].foregroundColor = Color.white
            }
            // Links: brand color
            if run.link != nil {
                result[range].foregroundColor = Brand.primary
            }
        }
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

    private static let blockCache = NSCache<NSString, BlockCacheEntry>()

    private static func cachedParse(_ text: String) -> [Block] {
        let key = NSString(string: String(text.prefix(64)) + "_\(text.count)_\(text.suffix(32).hashValue)")
        if let cached = blockCache.object(forKey: key) {
            return cached.blocks
        }
        let parsed = parseBlocks(from: preprocess(text))
        let entry = BlockCacheEntry(blocks: parsed)
        blockCache.setObject(entry, forKey: key)
        blockCache.countLimit = 30
        return parsed
    }

    /// Normalize LLM output: ensure headings/lists start on their own line.
    private static func preprocess(_ text: String) -> String {
        var r = text
        // Heading not at line start
        r = r.replacingOccurrences(of: "([^\\n])\\s*(#{1,6}\\s)", with: "$1\n\n$2", options: .regularExpression)
        // List item not at line start
        r = r.replacingOccurrences(of: "([^\\n])\\s+([-*]\\s)", with: "$1\n$2", options: .regularExpression)
        r = r.replacingOccurrences(of: "([^\\n])\\s+(\\d+\\.\\s)", with: "$1\n$2", options: .regularExpression)
        // Collapse excessive newlines
        r = r.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return r
    }

    private static func parseBlocks(from source: String) -> [Block] {
        var blocks: [Block] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0
        var orderedCounter = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code fence
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.code(lang: lang, code: codeLines.joined(separator: "\n")))
                orderedCounter = 0
                continue
            }

            // Blank line
            if trimmed.isEmpty {
                if let last = blocks.last, case .blank = last {
                    // skip consecutive blanks
                } else {
                    blocks.append(.blank)
                }
                orderedCounter = 0
                i += 1
                continue
            }

            // Divider (--- or ***)
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == " " }) && trimmed.filter({ $0 == "-" || $0 == "*" }).count >= 3 {
                blocks.append(.divider)
                orderedCounter = 0
                i += 1
                continue
            }

            // Table (lines starting with |)
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.filter({ $0 == "|" }).count >= 3 {
                var tableLines: [String] = []
                while i < lines.count {
                    let tl = lines[i].trimmingCharacters(in: .whitespaces)
                    guard tl.hasPrefix("|") else { break }
                    tableLines.append(tl)
                    i += 1
                }
                if let tbl = Self.parseTable(tableLines) {
                    blocks.append(.table(headers: tbl.headers, rows: tbl.rows))
                } else {
                    for tl in tableLines {
                        blocks.append(.paragraph(tl))
                    }
                }
                orderedCounter = 0
                continue
            }

            // Heading
            if let headingMatch = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                let hashes = trimmed[headingMatch].filter { $0 == "#" }.count
                let content = String(trimmed[headingMatch.upperBound...])
                blocks.append(.heading(level: hashes, text: content))
                orderedCounter = 0
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = []
                while i < lines.count {
                    let ql = lines[i].trimmingCharacters(in: .whitespaces)
                    if ql.hasPrefix("> ") {
                        quoteLines.append(String(ql.dropFirst(2)))
                    } else if ql == ">" {
                        quoteLines.append("")
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)))
                orderedCounter = 0
                continue
            }

            // Unordered list item
            if let listMatch = trimmed.range(of: "^[-*+]\\s+", options: .regularExpression) {
                let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                let indent = leadingSpaces / 2
                let content = String(trimmed[listMatch.upperBound...])
                blocks.append(.listItem(indent: indent, ordered: false, index: 0, text: content))
                orderedCounter = 0
                i += 1
                continue
            }

            // Ordered list item
            if let numMatch = trimmed.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
                let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                let indent = leadingSpaces / 2
                let content = String(trimmed[numMatch.upperBound...])
                orderedCounter += 1
                blocks.append(.listItem(indent: indent, ordered: true, index: orderedCounter, text: content))
                i += 1
                continue
            }

            // Paragraph: collect consecutive non-special lines.
            // For CJK text, preserve line breaks instead of joining with space —
            // Chinese content uses line breaks semantically (计划/结论/总结 etc.).
            var paraLines: [String] = [trimmed]
            orderedCounter = 0
            i += 1
            while i < lines.count {
                let next = lines[i].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || next.hasPrefix("#") || next.hasPrefix("```")
                    || next.hasPrefix(">")
                    || (next.hasPrefix("|") && next.hasSuffix("|"))
                    || next.range(of: "^[-*+]\\s+", options: .regularExpression) != nil
                    || next.range(of: "^\\d+\\.\\s+", options: .regularExpression) != nil {
                    break
                }
                // Break paragraph when next line starts with a CJK label (e.g. "计划：", "结论：")
                if next.range(of: "^[\\p{Han}\\p{Katakana}\\p{Hiragana}].*[：:]", options: .regularExpression) != nil
                    && paraLines.count >= 1 {
                    break
                }
                paraLines.append(next)
                i += 1
            }
            // Use newline for CJK content to preserve intentional line breaks
            let hasCJK = paraLines.contains { line in
                line.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
            }
            blocks.append(.paragraph(paraLines.joined(separator: hasCJK ? "\n" : " ")))
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
        for i in startRow..<lines.count {
            let cells = splitCells(lines[i])
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
                            .fill(copied ? Semantic.success.opacity(0.12) : Color.white.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
                .opacity(isHovered || copied ? 1 : 0)
            }
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.sm)
            .background(Color.white.opacity(0.03))

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(hex: "E0E0F0"))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(AppSpace.md)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(SurfaceGrade.sunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { isHovered = h } }
    }
}

// MARK: - Table Block View

private struct TableBlockView: View {
    let headers: [String]
    let rows: [[String]]
    let fontSize: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { idx, header in
                        Text(header)
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundStyle(TextGrade.primary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(minWidth: columnWidth(idx), alignment: .leading)
                    }
                }
                .background(Color.white.opacity(0.05))

                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.prefix(headers.count).enumerated()), id: \.offset) { colIdx, cell in
                            Text(cell)
                                .font(.system(size: fontSize, weight: .regular))
                                .foregroundStyle(TextGrade.secondary)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(minWidth: columnWidth(colIdx), alignment: .leading)
                        }
                    }
                    .background(rowIdx % 2 == 1 ? Color.white.opacity(0.02) : Color.clear)

                    if rowIdx < rows.count - 1 {
                        Rectangle().fill(Color.white.opacity(0.04)).frame(height: 0.5)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.sunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func columnWidth(_ index: Int) -> CGFloat {
        let allCells = [headers[safe: index] ?? ""] + rows.compactMap { $0[safe: index] }
        let maxLen = allCells.map(\.count).max() ?? 4
        return CGFloat(max(60, min(maxLen * 9 + 20, 240)))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
