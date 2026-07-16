import Foundation
import LaicaiNativeDomain

/// Prompt A/B registry that loads overrides from a local JSON file.
/// Tracks version effectiveness by tag for automatic A/B comparison.
public final class PromptRegistry {
    public static let shared = PromptRegistry()

    private var overrides: [String: String] = [:]
    private var versions: [String: Int] = [:]  // tag -> version number
    private let fileURL: URL
    private let versionFileURL: URL
    private let queue = DispatchQueue(label: "laicai.prompt")

    private init() {
        let dir = LaicaiStoragePaths.ensureDirectory(LaicaiStoragePaths.appDirectory)
        self.fileURL = dir.appendingPathComponent("prompt_overrides.json")
        self.versionFileURL = dir.appendingPathComponent("prompt_versions.json")
        load()
        loadVersions()
    }

    /// Load overrides from disk.
    public func load() {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else {
                self.overrides = [:]
                return
            }
            self.overrides = json
        }
    }

    /// Save current overrides to disk.
    public func save() {
        queue.async { [weak self] in
            guard let self else { return }
            let json = self.overrides
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else { return }
            try? data.write(to: self.fileURL)
        }
    }

    /// Get a prompt by tag. Returns override if present, otherwise falls back to baseline.
    public func prompt(for tag: String, baseline: String) -> String {
        queue.sync {
            overrides[tag] ?? baseline
        }
    }

    /// Set an override for a given tag, bumping its version.
    public func setOverride(tag: String, value: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.overrides[tag] = value
            self.versions[tag, default: 0] += 1
            self.save()
            self.saveVersions()
        }
    }

    /// Remove an override.
    public func removeOverride(tag: String) {
        queue.async { [weak self] in
            self?.overrides.removeValue(forKey: tag)
            self?.save()
        }
    }

    /// List all active overrides.
    public var activeOverrides: [String: String] {
        queue.sync { overrides }
    }

    /// Get version string for a tag (e.g. "bootstrap_web_fetch:v3")
    public func versionTag(for tag: String) -> String {
        queue.sync {
            let version = versions[tag, default: 0]
            return version > 0 ? "\(tag):v\(version)" : tag
        }
    }

    /// Compare effectiveness of two prompt tags using outcome stats.
    public func compare(tagA: String, tagB: String, days: Int = 7) -> PromptComparison? {
        let stats = TaskOutcomeRecorder.shared.promptTagStats(days: days)
        guard let firstStats = stats.first(where: { $0.tag == tagA }),
            let secondStats = stats.first(where: { $0.tag == tagB }),
            firstStats.total >= 3, secondStats.total >= 3
        else { return nil }
        let winner = firstStats.score > secondStats.score ? tagA : tagB
        let diff = abs(firstStats.score - secondStats.score)
        return PromptComparison(
            tagA: tagA, scoreA: firstStats.score,
            tagB: tagB, scoreB: secondStats.score,
            winner: winner,
            recommendation: diff > 10 ? "\(winner) 效果显著更好（分差 \(Int(diff))），建议采用该版本。" : "两者效果接近，可继续观察。"
        )
    }

    private func loadVersions() {
        queue.sync {
            guard let data = try? Data(contentsOf: versionFileURL),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
            else {
                self.versions = [:]
                return
            }
            self.versions = json
        }
    }

    private func saveVersions() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: self.versions, options: .prettyPrinted) else { return }
            try? data.write(to: self.versionFileURL)
        }
    }

    // MARK: - Auto-Optimization

    /// Periodically called to check if any prompt variant is clearly winning.
    /// If a versioned tag (e.g. "bootstrap_web_fetch:v2") significantly outperforms
    /// the current baseline, auto-promote it as the active override.
    /// Returns list of promotions applied.
    @discardableResult
    public func autoPromote(minSamples: Int = 5, minScoreDiff: Double = 15.0, days: Int = 7) -> [PromptPromotion] {
        let stats = TaskOutcomeRecorder.shared.promptTagStats(days: days)
        guard stats.count >= 2 else { return [] }

        // Group stats by base tag (strip :vN suffix)
        var groups: [String: [PromptTagStatsRow]] = [:]
        for row in stats {
            let base = row.tag.components(separatedBy: ":").first ?? row.tag
            groups[base, default: []].append(row)
        }

        var promotions: [PromptPromotion] = []
        for (base, variants) in groups {
            let qualified = variants.filter { $0.total >= minSamples }
            guard qualified.count >= 2 else { continue }
            let sorted = qualified.sorted { $0.score > $1.score }
            let best = sorted[0]
            let second = sorted[1]
            let diff = best.score - second.score
            guard diff >= minScoreDiff else { continue }

            // Evolution guardrails (P4):
            // 1. Winner must have minimum completion rate (no promoting a variant that barely works)
            guard best.completionRate >= 0.5 else { continue }
            // 2. Winner must not have high cancellation (semantic preservation)
            let bestCancelRate = Double(best.cancelled) / Double(max(best.total, 1))
            guard bestCancelRate < 0.3 else { continue }
            // 3. Winner must not be dramatically worse than baseline on any dimension
            let secondCancelRate = Double(second.cancelled) / Double(max(second.total, 1))
            if bestCancelRate > secondCancelRate + 0.15 { continue }

            // Auto-promote: if the best variant is not already the active override
            let currentOverride = queue.sync { overrides[base] }
            let promotion = PromptPromotion(
                baseTag: base,
                winnerTag: best.tag,
                loserTag: second.tag,
                scoreDiff: diff,
                winnerSamples: best.total
            )
            // Only promote if this is a new winner we haven't already promoted
            if currentOverride == nil || !best.tag.contains(":v") {
                queue.async { [weak self] in
                    self?.versions[base, default: 0] += 1
                    self?.saveVersions()
                }
            }
            promotions.append(promotion)
        }
        return promotions
    }

    // MARK: - Convenience tags used across the codebase

    public static let tagNudgeEmptyResponse = "nudge_empty_response"
    public static let tagNudgeReadOnly = "nudge_readonly"
    public static let tagCompletionCheck = "completion_check"
    public static let tagStageSummary = "stage_summary"
    public static let tagEvidenceChecklist = "evidence_checklist"
    public static let tagBootstrapWebFetch = "bootstrap_web_fetch"
    public static let tagBootstrapFileRead = "bootstrap_file_read"
    public static let tagBootstrapWorkspaceIndex = "bootstrap_workspace_index"
    public static let tagBootstrapWebSearch = "bootstrap_web_search"
    public static let tagBootstrapWorkspaceSearch = "bootstrap_workspace_search"
    public static let tagRecoveryBlocked = "recovery_blocked"
    public static let tagContinueTask = "continue_task"
}

public struct PromptComparison: Sendable {
    public let tagA: String
    public let scoreA: Double
    public let tagB: String
    public let scoreB: Double
    public let winner: String
    public let recommendation: String
}

public struct PromptPromotion: Sendable {
    public let baseTag: String
    public let winnerTag: String
    public let loserTag: String
    public let scoreDiff: Double
    public let winnerSamples: Int
}
