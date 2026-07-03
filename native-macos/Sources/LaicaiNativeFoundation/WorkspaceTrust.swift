import Foundation

public enum WorkspaceTrust {
    public static func isTrusted(_ workspaceRoot: String) -> Bool {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return false }
        let trustFile = (root as NSString).appendingPathComponent(".laicai/trusted")
        return FileManager.default.fileExists(atPath: trustFile)
    }
}
