import AppKit
import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Review Cards

struct ReviewCard: View {
    @EnvironmentObject private var store: AppStore
    let step: TaskStep
    let taskID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(spacing: AppSpace.sm) {
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
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    reviewInfoRow(icon: "doc.text", label: "文件", value: filePath)
                    reviewInfoRow(icon: "shield", label: "风险", value: riskLabel(for: filePath))
                    if let added = step.toolParams?["addedLines"], let removed = step.toolParams?["removedLines"] {
                        reviewInfoRow(icon: "plus.forwardslash.minus", label: "变更", value: "+\(added) -\(removed) 行")
                    }
                }
                .padding(AppSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(SurfaceGrade.card.opacity(0.65))
                )
            }

            if let hunks = step.diffHunks, !hunks.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.sm) {
                    ForEach(hunks) { hunk in
                        HunkCard(hunk: hunk, stepID: step.id, taskID: taskID, allDecided: step.approved != nil)
                    }
                }
            } else if let filePath = step.diffFilePath,
               let old = step.diffOldContent,
               let new = step.diffNewContent {
                DiffPreviewCard(filePath: filePath, oldContent: old, newContent: new)
            }

            if step.approved == nil && (step.diffHunks == nil || step.diffHunks?.isEmpty == true) {
                HStack(spacing: AppSpace.md) {
                    Button {
                        store.approveReview(taskID: taskID, stepID: step.id)
                    } label: {
                        Label("批准", systemImage: "checkmark")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.lg)
                            .padding(.vertical, AppSpace.sm + 2)
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
                            .padding(.horizontal, AppSpace.lg)
                            .padding(.vertical, AppSpace.sm + 2)
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
                            .padding(.horizontal, AppSpace.lg)
                            .padding(.vertical, AppSpace.sm + 2)
                            .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.78)))
                            .overlay(Capsule().strokeBorder(SurfaceGrade.divider, lineWidth: 0.7))
                    }
                    .buttonStyle(.plain)
                }
            } else if step.approved == nil && step.diffHunks != nil {
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(TextGrade.muted)
                    Text("逐个审查上方每个 hunk，全部决定后自动应用")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
            } else {
                HStack(spacing: AppSpace.sm) {
                    HStack(spacing: AppSpace.xs) {
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
                                .padding(.horizontal, AppSpace.md)
                                .padding(.vertical, AppSpace.xs + 1)
                                .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.75)))
                                .overlay(Capsule().strokeBorder(SurfaceGrade.divider, lineWidth: 0.7))
                        }
                        .buttonStyle(.plain)
                        .help("回滚此步骤的文件变更")
                    }
                }
            }
        }
        .padding(AppSpace.lg)
        .frame(maxWidth: 580, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(Semantic.warningMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(Semantic.warning.opacity(0.25), lineWidth: 1)
        )
    }

    private func reviewInfoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: AppSpace.sm) {
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
        var result: [String] = []

        var idx = 0
        while idx < max(oldLines.count, newLines.count) {
            let inOld = idx < oldLines.count
            let inNew = idx < newLines.count

            if inOld && inNew && oldLines[idx] == newLines[idx] {
                result.append("  \(oldLines[idx])")
                idx += 1
            } else {
                let hunkStart = max(0, idx - 3)
                if hunkStart > 0 && hunkStart < idx {
                    let oldStart = hunkStart + 1
                    let newStart = hunkStart + 1
                    result.append("@@ -\(oldStart),\(idx - hunkStart + 1) +\(newStart),\(idx - hunkStart + 1) @@")
                }

                while idx < oldLines.count && (idx >= newLines.count || oldLines[idx] != newLines[min(idx, newLines.count - 1)]) {
                    if idx < newLines.count && oldLines[idx] == newLines[idx] { break }
                    result.append("- \(oldLines[idx])")
                    idx += 1
                    if idx >= oldLines.count { break }
                }
                let addedIdx = idx
                while addedIdx < newLines.count && (addedIdx >= oldLines.count || oldLines[min(addedIdx, oldLines.count - 1)] != newLines[addedIdx]) {
                    if addedIdx < oldLines.count && oldLines[addedIdx] == newLines[addedIdx] { break }
                    result.append("+ \(newLines[addedIdx])")
                    idx = addedIdx + 1
                    break
                }
                if idx < newLines.count {
                    for j in idx..<newLines.count {
                        if j < oldLines.count && oldLines[j] == newLines[j] { break }
                        result.append("+ \(newLines[j])")
                    }
                }
                idx = max(idx, min(oldLines.count, newLines.count))
                while idx < oldLines.count && idx < newLines.count && oldLines[idx] == newLines[idx] {
                    idx += 1
                }
            }
        }

        if result.isEmpty && (!old.isEmpty || !new.isEmpty) {
            result = []
            for line in oldLines { result.append("- \(line)") }
            for line in newLines { result.append("+ \(line)") }
        }

        return result.joined(separator: "\n")
    }
}

struct ReviewResultCard: View {
    let step: TaskStep

    var body: some View {
        HStack(spacing: AppSpace.xs) {
            Image(systemName: step.approved == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(step.approved == true ? Semantic.success : Semantic.error)

            Text(step.text.isEmpty ? (step.approved == true ? "已批准" : "已拒绝") : step.text)
                .font(AppFont.captionMedium)
                .foregroundStyle(step.approved == true ? Semantic.success : Semantic.error)
        }
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, AppSpace.sm)
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
        VStack(alignment: .leading, spacing: AppSpace.xs) {
            HStack(spacing: AppSpace.sm) {
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
                    .padding(.horizontal, AppSpace.sm)
                    .padding(.vertical, 1)
                    .background(hunkLineBackground(item.element.prefix))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .strokeBorder(SurfaceGrade.divider, lineWidth: 0.5)
            )

            if hunk.approved == nil && !allDecided {
                HStack(spacing: AppSpace.sm) {
                    Button {
                        store.approveHunk(taskID: taskID, stepID: stepID, hunkID: hunk.id)
                    } label: {
                        Label("接受", systemImage: "checkmark")
                            .font(AppFont.tiny)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.md)
                            .padding(.vertical, AppSpace.xs)
                            .background(Capsule().fill(Semantic.success))
                    }
                    .buttonStyle(.plain)

                    Button {
                        store.rejectHunk(taskID: taskID, stepID: stepID, hunkID: hunk.id)
                    } label: {
                        Label("拒绝", systemImage: "xmark")
                            .font(AppFont.tiny)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.md)
                            .padding(.vertical, AppSpace.xs)
                            .background(Capsule().fill(Semantic.error))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(hunk.approved == true ? Semantic.success.opacity(0.3) : hunk.approved == false ? Semantic.error.opacity(0.3) : SurfaceGrade.divider, lineWidth: 0.7)
        )
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
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
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
            HStack(spacing: AppSpace.xs) {
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
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, AppSpace.sm)
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
                    .padding(.horizontal, AppSpace.sm)
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
        var i = 0
        while i < lines.count {
            if lines[i].type == .removed && i + 1 < lines.count && lines[i + 1].type == .added {
                result.append((line: lines[i], pairedContent: lines[i + 1].content))
                result.append((line: lines[i + 1], pairedContent: lines[i].content))
                i += 2
            } else {
                result.append((line: lines[i], pairedContent: nil))
                i += 1
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
        for ch in text {
            let isWS = ch == " " || ch == "\t"
            if isWS != inWhitespace && !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            inWhitespace = isWS
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Returns indices in `from` that differ from `to`
    private func wordDiffIndices(from: [String], to: [String]) -> Set<Int> {
        var changed = Set<Int>()
        let toSet = Set(to)
        for (i, word) in from.enumerated() {
            if !toSet.contains(word) {
                changed.insert(i)
            }
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
                let beforeOK = absRange.lowerBound == result.startIndex || !result.characters[result.characters.index(before: absRange.lowerBound)].isLetter
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
            let ch = result.characters[idx]
            if ch == "\"" {
                if inString {
                    let nextIdx = result.characters.index(after: idx)
                    result[stringStart..<nextIdx].foregroundColor = .init(red: 0.8, green: 0.5, blue: 0.2) // orange for strings
                    inString = false
                } else {
                    stringStart = idx
                    inString = true
                }
            }
        }

        // Highlight comments (//)
        if let commentRange = result.range(of: "//") {
            result[commentRange.lowerBound..<result.endIndex].foregroundColor = .init(white: 0.5) // gray for comments
        }

        return result
    }

    private static func syntaxKeywords(for ext: String) -> [String] {
        switch ext {
        case "swift":
            return ["func", "var", "let", "if", "else", "guard", "return", "import", "struct", "class", "enum", "case", "self", "private", "public", "static", "override", "init", "for", "while", "in", "try", "catch", "throw", "async", "await", "some", "nil", "true", "false"]
        case "py":
            return ["def", "class", "if", "else", "elif", "return", "import", "from", "for", "while", "in", "try", "except", "with", "as", "self", "None", "True", "False", "async", "await", "raise", "yield"]
        case "js", "ts", "jsx", "tsx":
            return ["function", "const", "let", "var", "if", "else", "return", "import", "export", "class", "new", "this", "for", "while", "try", "catch", "throw", "async", "await", "null", "undefined", "true", "false", "from"]
        case "rs":
            return ["fn", "let", "mut", "if", "else", "return", "use", "struct", "enum", "impl", "pub", "self", "for", "while", "in", "match", "Some", "None", "Ok", "Err", "async", "await", "true", "false"]
        case "go":
            return ["func", "var", "if", "else", "return", "import", "struct", "type", "for", "range", "package", "defer", "go", "chan", "select", "nil", "true", "false"]
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
                                .padding(.leading, AppSpace.xs)
                        }
                        .padding(.vertical, 1.5)
                        .padding(.horizontal, AppSpace.sm)
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
                                .padding(.leading, AppSpace.xs)
                        }
                        .padding(.vertical, 1.5)
                        .padding(.horizontal, AppSpace.sm)
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
        var a = 0, r = 0
        for line in diffLines {
            if line.type == .added { a += 1 }
            if line.type == .removed { r += 1 }
        }
        return (a, r)
    }

    // MARK: - Diff Computation

    private func computeNumberedDiff() -> [NumberedDiffLine] {
        let o = oldContent.components(separatedBy: "\n")
        let n = newContent.components(separatedBy: "\n")
        var result: [NumberedDiffLine] = []
        var oldIdx = 1, newIdx = 1

        for i in 0..<min(o.count, n.count) {
            if o[i] == n[i] {
                result.append(NumberedDiffLine(type: .context, content: o[i], oldNum: oldIdx, newNum: newIdx))
                oldIdx += 1; newIdx += 1
            } else {
                result.append(NumberedDiffLine(type: .removed, content: o[i], oldNum: oldIdx, newNum: nil))
                oldIdx += 1
                result.append(NumberedDiffLine(type: .added, content: n[i], oldNum: nil, newNum: newIdx))
                newIdx += 1
            }
        }
        for i in min(o.count, n.count)..<o.count {
            result.append(NumberedDiffLine(type: .removed, content: o[i], oldNum: oldIdx, newNum: nil))
            oldIdx += 1
        }
        for i in min(o.count, n.count)..<n.count {
            result.append(NumberedDiffLine(type: .added, content: n[i], oldNum: nil, newNum: newIdx))
            newIdx += 1
        }
        return result
    }

    private var sideBySidePairs: [SideBySideLine] {
        var pairs: [SideBySideLine] = []
        var i = 0
        let lines = diffLines
        while i < lines.count {
            let line = lines[i]
            if line.type == .context {
                pairs.append(SideBySideLine(
                    oldNum: line.oldNum, oldText: line.content, oldType: .context,
                    newNum: line.newNum, newText: line.content, newType: .context
                ))
                i += 1
            } else if line.type == .removed {
                // Check if next line is added (paired change)
                if i + 1 < lines.count && lines[i + 1].type == .added {
                    let next = lines[i + 1]
                    pairs.append(SideBySideLine(
                        oldNum: line.oldNum, oldText: line.content, oldType: .removed,
                        newNum: next.newNum, newText: next.content, newType: .added
                    ))
                    i += 2
                } else {
                    pairs.append(SideBySideLine(
                        oldNum: line.oldNum, oldText: line.content, oldType: .removed,
                        newNum: nil, newText: nil, newType: .context
                    ))
                    i += 1
                }
            } else {
                pairs.append(SideBySideLine(
                    oldNum: nil, oldText: nil, oldType: .context,
                    newNum: line.newNum, newText: line.content, newType: .added
                ))
                i += 1
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
