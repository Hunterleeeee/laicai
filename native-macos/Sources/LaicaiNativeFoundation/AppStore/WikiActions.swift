import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func buildWikiTopic(
        topic: String,
        vaultRoot: String,
        save: Bool,
        useWeb: Bool = false,
        onChunk: (@Sendable @MainActor (String) -> Void)? = nil
    ) async -> WikiBuildResult {
        await WikiEngine.buildTopic(
            topic: topic,
            vaultRoot: vaultRoot,
            save: save,
            useWeb: useWeb,
            topK: 8,
            connector: state.activeConnector,
            runtime: environment.runtimeClient,
            onChunk: onChunk
        )
    }
}
