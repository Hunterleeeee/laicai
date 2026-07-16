import Foundation

extension AgentLoop {
    /// Rough token estimate accounting for script density.
    static func roughTokenCount(_ text: String) -> Int {
        var cjk = 0
        var ascii = 0
        var other = 0
        for scalar in text.unicodeScalars {
            let scalarValue = scalar.value
            if scalarValue < 0x80 {
                ascii += 1
            } else if (0x3000...0x303F).contains(scalarValue)
                || (0x3040...0x309F).contains(scalarValue)
                || (0x30A0...0x30FF).contains(scalarValue)
                || (0x3400...0x4DBF).contains(scalarValue)
                || (0x4E00...0x9FFF).contains(scalarValue)
                || (0xAC00...0xD7AF).contains(scalarValue)
                || (0xF900...0xFAFF).contains(scalarValue)
                || (0xFF00...0xFFEF).contains(scalarValue)
                || (0x20000...0x2A6DF).contains(scalarValue)
                || (0x2A700...0x2B73F).contains(scalarValue)
                || (0x2B740...0x2B81F).contains(scalarValue)
                || (0x2B820...0x2CEAF).contains(scalarValue)
                || (0x2CEB0...0x2EBEF).contains(scalarValue)
                || (0x30000...0x3134F).contains(scalarValue)
            {
                cjk += 1
            } else {
                other += 1
            }
        }
        return max(1, cjk + (ascii / 4) + (other / 2))
    }

    /// Returns true when a search query is semantically equivalent to a cached query.
    static func isSemanticDuplicate(newQuery: String, cachedQueries: [String], toolName: String) -> Bool {
        guard toolName == "code.search" || toolName == "web.search" else { return false }
        let newNorm = newQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for cached in cachedQueries {
            let cachedNorm = cached.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if newNorm == cachedNorm { return true }
            if newNorm.contains(cachedNorm) || cachedNorm.contains(newNorm) { return true }

            let newWords = Set(newNorm.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 1 })
            let cachedWords = Set(cachedNorm.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 1 })
            guard !newWords.isEmpty && !cachedWords.isEmpty else { continue }
            let overlap = newWords.intersection(cachedWords).count
            if Double(overlap) / Double(max(newWords.count, cachedWords.count)) > 0.8 {
                return true
            }
        }
        return false
    }
}
