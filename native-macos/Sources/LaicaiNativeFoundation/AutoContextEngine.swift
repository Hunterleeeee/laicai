import Foundation
import LaicaiNativeDomain

// MARK: - Auto Context Engine

public struct AutoContextEngine {
    public static func buildContext(
        workspaceRoot: String,
        vaultRoot: String? = nil,
        userInput: String,
        fileLimit: Int = 200,
        comfyUIServerURL: String? = nil,
        comfyUIModelName: String? = nil
    ) -> TaskContext {
        let cleanVault = vaultRoot?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeWorkspaceRoot: String
        if WorkspaceSandbox.isOverlyBroadWorkspace(workspaceRoot)
            || WorkspaceSandbox.isDisposableSmokeWorkspace(workspaceRoot) {
            safeWorkspaceRoot = ""
        } else {
            safeWorkspaceRoot = workspaceRoot
        }
        var context = TaskContext(
            workspaceRoot: safeWorkspaceRoot,
            vaultRoot: cleanVault?.isEmpty == false ? cleanVault : nil,
            comfyUIServerURL: comfyUIServerURL,
            comfyUIModelName: comfyUIModelName
        )
        if safeWorkspaceRoot.isEmpty, !workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.metadata["workspaceRootRejected"] = workspaceRoot
        }

        // PERF-1+3: Run git + file scan in parallel; skip heavy ops for chat (fileLimit=0)
        let isChatFastPath = fileLimit == 0
        let group = DispatchGroup()
        var claudeMD: String?
        var gitBranch: String?
        var gitDiff: String?
        var relevantFiles: [FileInfo] = []

        let queue = DispatchQueue(label: "laicai.context-build", attributes: .concurrent)
        group.enter()
        queue.async {
            claudeMD = loadProjectInstructions(workspaceRoot: safeWorkspaceRoot)
            group.leave()
        }
        group.enter()
        queue.async {
            gitBranch = currentGitBranch(workspaceRoot: safeWorkspaceRoot)
            group.leave()
        }
        if !isChatFastPath {
            group.enter()
            queue.async {
                gitDiff = currentGitDiff(workspaceRoot: safeWorkspaceRoot)
                group.leave()
            }
            group.enter()
            queue.async {
                relevantFiles = findRelevantFiles(workspaceRoot: safeWorkspaceRoot, query: userInput, limit: fileLimit)
                group.leave()
            }
        }
        group.wait()

        context.claudeMD = claudeMD
        context.gitBranch = gitBranch
        context.gitDiff = gitDiff
        context.relevantFiles = relevantFiles

        return context
    }

    private static func loadProjectInstructions(workspaceRoot: String) -> String? {
        // Priority-ordered instruction files (higher priority first)
        let instructionFiles = [
            "LAICAI.md",
            "AGENTS.md",
            ".agents/AGENTS.md",
            "CLAUDE.md",
            ".claude/CLAUDE.md",
            ".laicai/CLAUDE.md",
            ".cursor/rules",
            ".cursorrules"
        ]
        let loaded = instructionFiles.compactMap { relativePath -> String? in
            let fullPath = (workspaceRoot as NSString).appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) else { return nil }
            let content: String?
            if isDirectory.boolValue {
                content = loadInstructionDirectory(fullPath)
            } else {
                content = try? String(contentsOfFile: fullPath, encoding: .utf8)
            }
            guard let trimmed = content?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return "### \(relativePath)\n\(String(trimmed.prefix(12_000)))"
        }

        // README summary (first 3000 chars, typically contains project overview)
        let readmeFiles = ["README.md", "README", "README.txt", "readme.md"]
        let readmeContent = readmeFiles.compactMap { name -> String? in
            let fullPath = (workspaceRoot as NSString).appendingPathComponent(name)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { return nil }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return "### \(name)\n\(String(trimmed.prefix(3_000)))"
        }.first

        // Package config summaries (extract key metadata, not full content)
        let packageConfigs: [(path: String, label: String)] = [
            ("Package.swift", "Swift Package"),
            ("pyproject.toml", "Python Project"),
            ("package.json", "Node Package"),
            ("Cargo.toml", "Rust Package"),
            ("go.mod", "Go Module"),
            ("pom.xml", "Maven Project"),
            ("build.gradle", "Gradle Project"),
            ("Gemfile", "Ruby Gems"),
            ("requirements.txt", "Python Requirements"),
            ("Podfile", "CocoaPods")
        ]
        let packageSummaries = packageConfigs.compactMap { config -> String? in
            let fullPath = (workspaceRoot as NSString).appendingPathComponent(config.path)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { return nil }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Only include first 800 chars for package configs — enough for name/version/deps
            return "### \(config.label) (\(config.path))\n\(String(trimmed.prefix(800)))"
        }

        // Subdirectory rule inheritance: scan top-level subdirs for .laicai/CLAUDE.md
        let subDirRules = loadSubDirectoryRules(workspaceRoot: workspaceRoot)

        var allSections = loaded
        if let readme = readmeContent { allSections.append(readme) }
        allSections.append(contentsOf: packageSummaries)
        if !subDirRules.isEmpty { allSections.append(subDirRules) }

        guard !allSections.isEmpty else { return nil }
        return allSections.joined(separator: "\n\n")
    }

    /// Load rule files from top-level subdirectories (one level deep).
    /// This enables per-module instructions like `src/.laicai/CLAUDE.md`.
    private static func loadSubDirectoryRules(workspaceRoot: String) -> String {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: workspaceRoot) else { return "" }

        var rules: [String] = []
        for entry in entries.sorted().prefix(20) {
            let subPath = (workspaceRoot as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
            // Skip hidden and common non-project dirs
            guard !entry.hasPrefix(".") && !["node_modules", "build", "dist", ".git", "DerivedData"].contains(entry) else { continue }

            let ruleFile = (subPath as NSString).appendingPathComponent(".laicai/CLAUDE.md")
            guard let content = try? String(contentsOfFile: ruleFile, encoding: .utf8) else { continue }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            rules.append("### \(entry)/.laicai/CLAUDE.md\n\(String(trimmed.prefix(2_000)))")
        }
        return rules.isEmpty ? "" : "## 子目录规则\n" + rules.joined(separator: "\n\n")
    }

    private static func loadInstructionDirectory(_ path: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return
            entries
            .sorted()
            .filter { $0.hasSuffix(".md") || $0.hasSuffix(".mdc") || $0.hasSuffix(".txt") }
            .prefix(6)
            .compactMap { entry in
                let full = (path as NSString).appendingPathComponent(entry)
                guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { return nil }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return "#### \(entry)\n\(String(trimmed.prefix(4_000)))"
            }
            .joined(separator: "\n\n")
    }

    private static func currentGitBranch(workspaceRoot: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--abbrev-ref", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func currentGitDiff(workspaceRoot: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "diff", "--stat"]
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }

    private static func findRelevantFiles(workspaceRoot: String, query: String, limit: Int) -> [FileInfo] {
        let fileManager = FileManager.default
        var files: [FileInfo] = []
        let boundedLimit = max(0, min(limit, 500))
        guard boundedLimit > 0 else { return [] }
        let ignored: Set<String> = [
            ".git", "node_modules", ".build", "DerivedData", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
            ".venv", "venv", ".next", "dist", "build",
            ".config", ".ssh", ".aws", ".gnupg", ".docker", ".kube", ".cursor", "Library", "Applications", "Downloads",
            "Movies", "Music", "Pictures", "Public"
        ]
        let sensitiveNames: Set<String> = ["auth.json", "credentials", "credentials.json", ".env", ".env.local", "id_rsa", "id_ed25519"]
        let codeExtensions: Set<String> = [
            "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "rb", "java", "kt", "c", "cpp", "h", "hpp", "css", "html", "yaml", "yml", "json", "toml", "md"
        ]

        let enumerator = fileManager.enumerator(atPath: workspaceRoot)
        while let file = enumerator?.nextObject() as? String {
            let ext = (file as NSString).pathExtension
            let name = (file as NSString).lastPathComponent
            let components = file.components(separatedBy: "/")
            let dir = components.first ?? ""
            if ignored.contains(name) || ignored.contains(dir) || components.contains(where: { ignored.contains($0) }) || sensitiveNames.contains(name) {
                enumerator?.skipDescendants()
                continue
            }
            if codeExtensions.contains(ext) {
                // PERF-2: Skip reading file content — pure path scan is 10-50× faster.
                // Detailed content is loaded later by workspace_index or file_read tools.
                files.append(FileInfo(path: file, language: ext, summary: ""))
                if files.count >= boundedLimit { break }
            }
        }
        return files
    }
}
