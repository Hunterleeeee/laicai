import AppKit
import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

// MARK: - Review Cards

struct ReviewCard: View {
    @EnvironmentObject private var store: AppStore
    let step: TaskStep
    let taskID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.medium) {
            HStack(spacing: AppSpace.small) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Semantic.warning)

                Text("需要审查")
                    .font(AppFont.subheadline)
                    .foregroundStyle(Semantic.warning)

                Spacer()
            }

            Text(step.text)
                .font(AppFont.body)
                .foregroundStyle(TextGrade.primary)

            if let filePath = step.diffFilePath {
                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    reviewInfoRow(icon: "doc.text", label: "文件", value: filePath)
                    reviewInfoRow(icon: "shield", label: "风险", value: riskLabel(for: filePath))
                    if let added = step.toolParams?["addedLines"], let removed = step.toolParams?["removedLines"] {
                        reviewInfoRow(icon: "plus.forwardslash.minus", label: "变更", value: "+\(added) -\(removed) 行")
                    }
                }
                .padding(AppSpace.small)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(SurfaceGrade.card.opacity(0.65))
                )
            }

            if let hunks = step.diffHunks, !hunks.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.small) {
                    ForEach(hunks) { hunk in
                        HunkCard(hunk: hunk, stepID: step.id, taskID: taskID, allDecided: step.approved != nil)
                    }
                }
            } else if let filePath = step.diffFilePath,
                let old = step.diffOldContent,
                let new = step.diffNewContent
            {
                DiffPreviewCard(filePath: filePath, oldContent: old, newContent: new)
            }

            if step.approved == nil && (step.diffHunks == nil || step.diffHunks?.isEmpty == true) {
                HStack(spacing: AppSpace.medium) {
                    Button {
                        store.approveReview(taskID: taskID, stepID: step.id)
                    } label: {
                        Label("批准", systemImage: "checkmark")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.large)
                            .padding(.vertical, AppSpace.small + 2)
                            .background(Capsule().fill(Semantic.success))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("y", modifiers: .command)

                    Button {
                        store.rejectReview(taskID: taskID, stepID: step.id)
                    } label: {
                        Label("拒绝", systemImage: "xmark")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.large)
                            .padding(.vertical, AppSpace.small + 2)
                            .background(Capsule().fill(Semantic.error))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("n", modifiers: .command)

                    Button {
                        copyReviewPatch()
                    } label: {
                        Label("复制 diff", systemImage: "doc.on.doc")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.secondary)
                            .padding(.horizontal, AppSpace.large)
                            .padding(.vertical, AppSpace.small + 2)
                            .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.78)))
                            .overlay(Capsule().strokeBorder(SurfaceGrade.divider, lineWidth: 0.7))
                    }
                    .buttonStyle(.plain)
                }
            } else if step.approved == nil && step.diffHunks != nil {
                HStack(spacing: AppSpace.small) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(TextGrade.muted)
                    Text("逐个审查上方每个 hunk，全部决定后自动应用")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
            } else {
                HStack(spacing: AppSpace.small) {
                    HStack(spacing: AppSpace.extraSmall) {
                        Image(systemName: step.approved == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(step.approved == true ? Semantic.success : Semantic.error)
                        Text(step.approved == true ? "已批准" : "已拒绝")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(step.approved == true ? Semantic.success : Semantic.error)
                    }

                    if step.approved == true {
                        Button {
                            store.rollbackApprovedWrite(taskID: taskID, stepID: step.id)
                        } label: {
                            Label("回滚此变更", systemImage: "arrow.uturn.backward")
                                .font(AppFont.captionMedium)
                                .foregroundStyle(TextGrade.secondary)
                                .padding(.horizontal, AppSpace.medium)
                                .padding(.vertical, AppSpace.extraSmall + 1)
                                .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.75)))
                                .overlay(Capsule().strokeBorder(SurfaceGrade.divider, lineWidth: 0.7))
                        }
                        .buttonStyle(.plain)
                        .help("回滚此步骤的文件变更")
                    }
                }
            }
        }
        .padding(AppSpace.large)
        .frame(maxWidth: 580, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.extraLarge, style: .continuous)
                .fill(Semantic.warningMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.extraLarge, style: .continuous)
                .strokeBorder(Semantic.warning.opacity(0.25), lineWidth: 1)
        )
    }

    private func reviewInfoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: AppSpace.small) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Semantic.warning)
                .frame(width: 14)
            Text(label)
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.muted)
                .frame(width: 32, alignment: .leading)
            Text(value)
                .font(AppFont.caption)
                .foregroundStyle(TextGrade.secondary)
                .lineLimit(1)
            Spacer()
        }
    }

    private func riskLabel(for path: String) -> String {
        if !SandboxPolicy().isPathAllowed(path) {
            return "敏感路径，将被拦截"
        }
        return "批准后才会写入磁盘"
    }

    private func copyReviewPatch() {
        var lines: [String] = []
        lines.append("文件：\(step.diffFilePath ?? "文件变更")")
        lines.append("")
        if let old = step.diffOldContent, let new = step.diffNewContent {
            lines.append(Self.simpleDiff(old: old, new: new))
        } else {
            lines.append(step.text)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        ToastCenter.shared.success("已复制 diff")
    }

    static func simpleDiff(old: String, new: String) -> String {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        return SimpleLineDiff(oldLines: oldLines, newLines: newLines).render()
    }
}

private enum DiffLineOperation {
    case unchanged(String)
    case removed(String)
    case added(String)

    var rendered: String {
        switch self {
        case .unchanged(let line): return "  \(line)"
        case .removed(let line): return "- \(line)"
        case .added(let line): return "+ \(line)"
        }
    }
}

private struct SimpleLineDiff {
    let oldLines: [String]
    let newLines: [String]

    func render() -> String {
        operations().map(\.rendered).joined(separator: "\n")
    }

    private func operations() -> [DiffLineOperation] {
        let table = lcsTable()
        var oldIndex = 0
        var newIndex = 0
        var diffLines: [DiffLineOperation] = []

        while oldIndex < oldLines.count || newIndex < newLines.count {
            if canKeep(oldIndex: oldIndex, newIndex: newIndex) {
                diffLines.append(.unchanged(oldLines[oldIndex]))
                oldIndex += 1
                newIndex += 1
            } else if shouldAdd(oldIndex: oldIndex, newIndex: newIndex, table: table) {
                diffLines.append(.added(newLines[newIndex]))
                newIndex += 1
            } else {
                diffLines.append(.removed(oldLines[oldIndex]))
                oldIndex += 1
            }
        }

        return diffLines
    }

    private func lcsTable() -> [[Int]] {
        var table = Array(
            repeating: Array(repeating: 0, count: newLines.count + 1),
            count: oldLines.count + 1
        )
        guard !oldLines.isEmpty, !newLines.isEmpty else { return table }

        for oldIndex in stride(from: oldLines.count - 1, through: 0, by: -1) {
            for newIndex in stride(from: newLines.count - 1, through: 0, by: -1) {
                table[oldIndex][newIndex] = lcsScore(
                    oldIndex: oldIndex,
                    newIndex: newIndex,
                    table: table
                )
            }
        }

        return table
    }

    private func lcsScore(oldIndex: Int, newIndex: Int, table: [[Int]]) -> Int {
        if oldLines[oldIndex] == newLines[newIndex] {
            return table[oldIndex + 1][newIndex + 1] + 1
        }
        return max(table[oldIndex + 1][newIndex], table[oldIndex][newIndex + 1])
    }

    private func canKeep(oldIndex: Int, newIndex: Int) -> Bool {
        oldIndex < oldLines.count
            && newIndex < newLines.count
            && oldLines[oldIndex] == newLines[newIndex]
    }

    private func shouldAdd(oldIndex: Int, newIndex: Int, table: [[Int]]) -> Bool {
        guard newIndex < newLines.count else { return false }
        if oldIndex >= oldLines.count { return true }
        return table[oldIndex][newIndex + 1] >= table[oldIndex + 1][newIndex]
    }
}

struct ReviewResultCard: View {
    let step: TaskStep

    var body: some View {
        HStack(spacing: AppSpace.extraSmall) {
            Image(systemName: step.approved == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(step.approved == true ? Semantic.success : Semantic.error)

            Text(step.text.isEmpty ? (step.approved == true ? "已批准" : "已拒绝") : step.text)
                .font(AppFont.captionMedium)
                .foregroundStyle(step.approved == true ? Semantic.success : Semantic.error)
        }
        .padding(.horizontal, AppSpace.medium)
        .padding(.vertical, AppSpace.small)
        .background(
            Capsule()
                .fill((step.approved == true ? Semantic.success : Semantic.error).opacity(0.1))
        )
    }
}

// MARK: - Hunk Card

struct HunkCard: View {
    @EnvironmentObject private var store: AppStore
    let hunk: DiffHunk
    let stepID: UUID
    let taskID: UUID
    let allDecided: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
            HStack(spacing: AppSpace.small) {
                Image(systemName: "number")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Brand.primary)
                Text(hunk.summary)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                Spacer()
                if let approved = hunk.approved {
                    Image(systemName: approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(approved ? Semantic.success : Semantic.error)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(hunkDiffLines, id: \.offset) { item in
                    HStack(spacing: 0) {
                        Text(item.element.prefix == "+" ? "+" : item.element.prefix == "-" ? "-" : " ")
                            .font(AppFont.codeSmall)
                            .foregroundStyle(hunkLineColor(item.element.prefix))
                            .frame(width: 14)
                        Text(item.element.text)
                            .font(AppFont.codeSmall)
                            .foregroundStyle(hunkLineTextColor(item.element.prefix))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, AppSpace.small)
                    .padding(.vertical, 1)
                    .background(hunkLineBackground(item.element.prefix))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .strokeBorder(SurfaceGrade.divider, lineWidth: 0.5)
            )

            if hunk.approved == nil && !allDecided {
                HStack(spacing: AppSpace.small) {
                    Button {
                        store.approveHunk(taskID: taskID, stepID: stepID, hunkID: hunk.id)
                    } label: {
                        Label("接受", systemImage: "checkmark")
                            .font(AppFont.tiny)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.medium)
                            .padding(.vertical, AppSpace.extraSmall)
                            .background(Capsule().fill(Semantic.success))
                    }
                    .buttonStyle(.plain)

                    Button {
                        store.rejectHunk(taskID: taskID, stepID: stepID, hunkID: hunk.id)
                    } label: {
                        Label("拒绝", systemImage: "xmark")
                            .font(AppFont.tiny)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.medium)
                            .padding(.vertical, AppSpace.extraSmall)
                            .background(Capsule().fill(Semantic.error))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(AppSpace.small)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(hunkBorderColor, lineWidth: 0.7)
        )
    }

    private var hunkBorderColor: Color {
        if hunk.approved == true { return Semantic.success.opacity(0.3) }
        if hunk.approved == false { return Semantic.error.opacity(0.3) }
        return SurfaceGrade.divider
    }

    private struct HunkLine {
        let prefix: String
        let text: String
    }

    private var hunkDiffLines: [EnumeratedSequence<[HunkLine]>.Element] {
        let oldLines = hunk.oldText.components(separatedBy: "\n")
        let newLines = hunk.newText.components(separatedBy: "\n")
        var lines: [HunkLine] = []
        for line in oldLines {
            lines.append(HunkLine(prefix: "-", text: line))
        }
        for line in newLines {
            lines.append(HunkLine(prefix: "+", text: line))
        }
        return Array(lines.enumerated())
    }

    private func hunkLineColor(_ prefix: String) -> Color {
        prefix == "+" ? Semantic.success : prefix == "-" ? Semantic.error : TextGrade.ghost
    }
    private func hunkLineTextColor(_ prefix: String) -> Color {
        prefix == "+" ? Semantic.success : prefix == "-" ? Semantic.error : TextGrade.secondary
    }
    private func hunkLineBackground(_ prefix: String) -> Color {
        prefix == "+" ? Semantic.success.opacity(0.08) : prefix == "-" ? Semantic.error.opacity(0.08) : Color.clear
    }
}

// MARK: - Diff Preview Card

struct DiffPreviewCard: View {
    let filePath: String
    let oldContent: String
    let newContent: String

    @State private var isSideBySide = false
    @State private var isExpanded = false

    private var diffLines: [NumberedDiffLine] {
        computeNumberedDiff()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            diffHeader
            if isSideBySide {
                sideBySideView
            } else {
                unifiedView
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(SurfaceGrade.divider, lineWidth: 0.5)
        )
    }

    // MARK: - Header

    private var diffHeader: some View {
        HStack {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(TextGrade.muted)
            Text(filePath)
                .font(AppFont.codeSmall)
                .foregroundStyle(TextGrade.secondary)
                .lineLimit(1)

            Spacer()

            let stats = diffStats
            HStack(spacing: AppSpace.extraSmall) {
                if stats.added > 0 {
                    Text("+\(stats.added)")
                        .font(AppFont.tiny)
                        .foregroundStyle(Semantic.success)
                }
                if stats.removed > 0 {
                    Text("-\(stats.removed)")
                        .font(AppFont.tiny)
                        .foregroundStyle(Semantic.error)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isSideBySide.toggle() }
            } label: {
                Image(systemName: isSideBySide ? "rectangle.split.1x2" : "rectangle.split.2x1")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(TextGrade.muted)
            }
            .buttonStyle(.plain)
            .help(isSideBySide ? "统一视图" : "并排视图")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(TextGrade.muted)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收起" : "展开")
        }
        .padding(.horizontal, AppSpace.medium)
        .padding(.vertical, AppSpace.small)
        .background(SurfaceGrade.elevated.opacity(0.5))
    }

    // MARK: - Unified View

    private var unifiedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(indexedDiffLines.enumerated()), id: \.offset) { _, entry in
                    let line = entry.line
                    HStack(spacing: 0) {
                        Text(line.oldNum.map { "\($0)" } ?? "")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(TextGrade.ghost)
                            .frame(width: 28, alignment: .trailing)

                        Text(line.newNum.map { "\($0)" } ?? "")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(TextGrade.ghost)
                            .frame(width: 28, alignment: .trailing)

                        Text(line.type == .added ? "+" : line.type == .removed ? "-" : " ")
                            .font(AppFont.codeSmall)
                            .foregroundStyle(lineColor(line.type))
                            .frame(width: 14)

                        // Word-level highlight for changed lines
                        if let pairedContent = entry.pairedContent, line.type != .context {
                            inlineHighlightedText(original: line.content, paired: pairedContent, type: line.type)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            syntaxColoredText(line.content, fileExtension: fileExtension)
                                .font(AppFont.codeSmall)
                                .foregroundStyle(lineTextColor(line.type))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, AppSpace.small)
                    .padding(.vertical, 1.5)
                    .background(lineBackground(line.type))
                }
            }
        }
        .frame(maxHeight: isExpanded ? 600 : 240)
    }

    /// Pairs removed/added lines to enable word-level diff highlighting
    private var indexedDiffLines: [(line: NumberedDiffLine, pairedContent: String?)] {
        let lines = diffLines
        var result: [(line: NumberedDiffLine, pairedContent: String?)] = []
        var lineIndex = 0
        while lineIndex < lines.count {
            if lines[lineIndex].type == .removed,
                lineIndex + 1 < lines.count,
                lines[lineIndex + 1].type == .added
            {
                result.append((line: lines[lineIndex], pairedContent: lines[lineIndex + 1].content))
                result.append((line: lines[lineIndex + 1], pairedContent: lines[lineIndex].content))
                lineIndex += 2
            } else {
                result.append((line: lines[lineIndex], pairedContent: nil))
                lineIndex += 1
            }
        }
        return result
    }

    /// Inline word-level highlighting using AttributedString
    private func inlineHighlightedText(original: String, paired: String, type: DiffLineType) -> some View {
        let origWords = tokenize(original)
        let pairWords = tokenize(paired)
        let changedSet = wordDiffIndices(from: origWords, to: pairWords)

        let highlightColor: Color = type == .added ? Semantic.success : Semantic.error
        let baseColor: Color = lineTextColor(type)

        return HStack(spacing: 0) {
            ForEach(Array(origWords.enumerated()), id: \.offset) { idx, word in
                if changedSet.contains(idx) {
                    Text(word)
                        .font(AppFont.codeSmall)
                        .foregroundStyle(highlightColor)
                        .background(highlightColor.opacity(0.18))
                } else {
                    Text(word)
                        .font(AppFont.codeSmall)
                        .foregroundStyle(baseColor)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Simple tokenizer that preserves whitespace as separate tokens
    private func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inWhitespace = false
        for character in text {
            let isWhitespace = character == " " || character == "\t"
            if isWhitespace != inWhitespace && !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            inWhitespace = isWhitespace
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Returns indices in `from` that differ from `to`
    private func wordDiffIndices(from: [String], to target: [String]) -> Set<Int> {
        var changed = Set<Int>()
        let targetSet = Set(target)
        for (tokenIndex, word) in from.enumerated() where !targetSet.contains(word) {
            changed.insert(tokenIndex)
        }
        // If everything is different, don't highlight (avoids full-line highlight)
        if changed.count == from.count && from.count > 2 { return [] }
        return changed
    }

    private var fileExtension: String {
        (filePath as NSString).pathExtension.lowercased()
    }

    /// Basic syntax coloring for common tokens
    @ViewBuilder
    private func syntaxColoredText(_ text: String, fileExtension: String) -> some View {
        if Self.syntaxKeywords(for: fileExtension).isEmpty {
            Text(text)
        } else {
            Text(buildSyntaxAttributedString(text, ext: fileExtension))
        }
    }

    private func buildSyntaxAttributedString(_ text: String, ext: String) -> AttributedString {
        var result = AttributedString(text)
        let keywords = Self.syntaxKeywords(for: ext)

        // Highlight keywords
        for keyword in keywords {
            var searchRange = result.startIndex..<result.endIndex
            while let range = result[searchRange].range(of: keyword, options: []) {
                let absRange = range
                // Check word boundaries
                let beforeOK =
                    absRange.lowerBound == result.startIndex
                    || !result.characters[result.characters.index(before: absRange.lowerBound)].isLetter
                let afterOK = absRange.upperBound == result.endIndex || !result.characters[absRange.upperBound].isLetter
                if beforeOK && afterOK {
                    result[absRange].foregroundColor = .init(red: 0.7, green: 0.4, blue: 0.9)  // purple for keywords
                }
                searchRange = absRange.upperBound..<result.endIndex
            }
        }

        // Highlight strings (simple: anything between quotes)
        var inString = false
        var stringStart = result.startIndex
        for idx in result.characters.indices {
            let character = result.characters[idx]
            if character == "\"" {
                if inString {
                    let nextIndex = result.characters.index(after: idx)
                    result[stringStart..<nextIndex].foregroundColor = .init(red: 0.8, green: 0.5, blue: 0.2)
                    inString = false
                } else {
                    stringStart = idx
                    inString = true
                }
            }
        }

        // Highlight comments (//)
        if let commentRange = result.range(of: "//") {
            result[commentRange.lowerBound..<result.endIndex].foregroundColor = .init(white: 0.5)  // gray for comments
        }

        return result
    }

    private static func syntaxKeywords(for ext: String) -> [String] {
        switch ext {
        case "swift":
            return [
                "func", "var", "let", "if", "else", "guard", "return", "import", "struct", "class", "enum",
                "case", "self", "private", "public", "static", "override", "init", "for", "while", "in",
                "try", "catch", "throw", "async", "await", "some", "nil", "true", "false",
            ]
        case "py":
            return [
                "def", "class", "if", "else", "elif", "return", "import", "from", "for", "while", "in",
                "try", "except", "with", "as", "self", "None", "True", "False", "async", "await",
                "raise", "yield",
            ]
        case "js", "ts", "jsx", "tsx":
            return [
                "function", "const", "let", "var", "if", "else", "return", "import", "export", "class",
                "new", "this", "for", "while", "try", "catch", "throw", "async", "await", "null",
                "undefined", "true", "false", "from",
            ]
        case "rs":
            return [
                "fn", "let", "mut", "if", "else", "return", "use", "struct", "enum", "impl", "pub",
                "self", "for", "while", "in", "match", "Some", "None", "Ok", "Err", "async", "await",
                "true", "false",
            ]
        case "go":
            return [
                "func", "var", "if", "else", "return", "import", "struct", "type", "for", "range",
                "package", "defer", "go", "chan", "select", "nil", "true", "false",
            ]
        default:
            return []
        }
    }

    // MARK: - Side-by-Side View

    private var sideBySideView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sideBySidePairs.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 0) {
                        // Left (old)
                        HStack(spacing: 0) {
                            Text(pair.oldNum.map { "\($0)" } ?? "")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(TextGrade.ghost)
                                .frame(width: 28, alignment: .trailing)

                            Text(pair.oldText ?? "")
                                .font(AppFont.codeSmall)
                                .foregroundStyle(pair.oldType == .removed ? Semantic.error : TextGrade.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, AppSpace.extraSmall)
                        }
                        .padding(.vertical, 1.5)
                        .padding(.horizontal, AppSpace.small)
                        .background(pair.oldType == .removed ? Semantic.error.opacity(0.10) : Color.clear)

                        Rectangle().fill(SurfaceGrade.divider).frame(width: 1)

                        // Right (new)
                        HStack(spacing: 0) {
                            Text(pair.newNum.map { "\($0)" } ?? "")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(TextGrade.ghost)
                                .frame(width: 28, alignment: .trailing)

                            Text(pair.newText ?? "")
                                .font(AppFont.codeSmall)
                                .foregroundStyle(pair.newType == .added ? Semantic.success : TextGrade.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, AppSpace.extraSmall)
                        }
                        .padding(.vertical, 1.5)
                        .padding(.horizontal, AppSpace.small)
                        .background(pair.newType == .added ? Semantic.success.opacity(0.10) : Color.clear)
                    }
                }
            }
        }
        .frame(maxHeight: isExpanded ? 600 : 240)
    }

    // MARK: - Colors

    private func lineColor(_ type: DiffLineType) -> Color {
        switch type {
        case .added: return Semantic.success
        case .removed: return Semantic.error
        case .context: return TextGrade.ghost
        }
    }

    private func lineTextColor(_ type: DiffLineType) -> Color {
        switch type {
        case .added: return Semantic.success
        case .removed: return Semantic.error
        case .context: return TextGrade.secondary
        }
    }

    private func lineBackground(_ type: DiffLineType) -> Color {
        switch type {
        case .added: return Semantic.success.opacity(0.10)
        case .removed: return Semantic.error.opacity(0.10)
        case .context: return Color.clear
        }
    }

    // MARK: - Stats

    private var diffStats: (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in diffLines {
            if line.type == .added { added += 1 }
            if line.type == .removed { removed += 1 }
        }
        return (added, removed)
    }

    // MARK: - Diff Computation

    private func computeNumberedDiff() -> [NumberedDiffLine] {
        let oldLines = oldContent.components(separatedBy: "\n")
        let newLines = newContent.components(separatedBy: "\n")
        var result: [NumberedDiffLine] = []
        var oldIndex = 1
        var newIndex = 1

        for lineIndex in 0..<min(oldLines.count, newLines.count) {
            if oldLines[lineIndex] == newLines[lineIndex] {
                result.append(NumberedDiffLine(type: .context, content: oldLines[lineIndex], oldNum: oldIndex, newNum: newIndex))
                oldIndex += 1
                newIndex += 1
            } else {
                result.append(NumberedDiffLine(type: .removed, content: oldLines[lineIndex], oldNum: oldIndex, newNum: nil))
                oldIndex += 1
                result.append(NumberedDiffLine(type: .added, content: newLines[lineIndex], oldNum: nil, newNum: newIndex))
                newIndex += 1
            }
        }
        for lineIndex in min(oldLines.count, newLines.count)..<oldLines.count {
            result.append(NumberedDiffLine(type: .removed, content: oldLines[lineIndex], oldNum: oldIndex, newNum: nil))
            oldIndex += 1
        }
        for lineIndex in min(oldLines.count, newLines.count)..<newLines.count {
            result.append(NumberedDiffLine(type: .added, content: newLines[lineIndex], oldNum: nil, newNum: newIndex))
            newIndex += 1
        }
        return result
    }

    private var sideBySidePairs: [SideBySideLine] {
        var pairs: [SideBySideLine] = []
        var lineIndex = 0
        let lines = diffLines
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            if line.type == .context {
                pairs.append(
                    SideBySideLine(
                        oldNum: line.oldNum, oldText: line.content, oldType: .context,
                        newNum: line.newNum, newText: line.content, newType: .context
                    ))
                lineIndex += 1
            } else if line.type == .removed {
                // Check if next line is added (paired change)
                if lineIndex + 1 < lines.count && lines[lineIndex + 1].type == .added {
                    let next = lines[lineIndex + 1]
                    pairs.append(
                        SideBySideLine(
                            oldNum: line.oldNum, oldText: line.content, oldType: .removed,
                            newNum: next.newNum, newText: next.content, newType: .added
                        ))
                    lineIndex += 2
                } else {
                    pairs.append(
                        SideBySideLine(
                            oldNum: line.oldNum, oldText: line.content, oldType: .removed,
                            newNum: nil, newText: nil, newType: .context
                        ))
                    lineIndex += 1
                }
            } else {
                pairs.append(
                    SideBySideLine(
                        oldNum: nil, oldText: nil, oldType: .context,
                        newNum: line.newNum, newText: line.content, newType: .added
                    ))
                lineIndex += 1
            }
        }
        return pairs
    }
}

// MARK: - Diff Data Types

struct NumberedDiffLine {
    let type: DiffLineType
    let content: String
    let oldNum: Int?
    let newNum: Int?
}

struct SideBySideLine {
    let oldNum: Int?
    let oldText: String?
    let oldType: DiffLineType
    let newNum: Int?
    let newText: String?
    let newType: DiffLineType
}
