import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func autoResumeInterruptedTask() {
        let interrupted = state.threads
            .filter { $0.isExecution && $0.status == .cancelled }
            .filter { $0.steps.contains(where: { $0.kind == .error && $0.text.contains("上次运行被中断") }) }
            .sorted { $0.updatedAt > $1.updatedAt }

        guard let latest = interrupted.first else { return }

        let timeSinceInterruption = Date.now.timeIntervalSince(latest.updatedAt)
        if timeSinceInterruption < 30 * 60 {
            if let idx = state.threads.firstIndex(where: { $0.id == latest.id }) {
                let hasResumeHint = state.threads[idx].steps.contains(where: {
                    $0.kind == .error && $0.text.contains("自动恢复")
                })
                state.selectThread(id: latest.id)
                if !hasResumeHint {
                    state.threads[idx].steps.append(
                        TaskStep(
                            kind: .error,
                            text: "检测到上次会话被中断（\(Self.relativeTimeString(latest.updatedAt))）。点击「继续 会话」自动恢复，或发送新目标启动新的会话。",
                            isFailure: false,
                            recoverable: true,
                            retryAction: "继续执行"
                        ))
                }
                persistThreads()
            }
        }
    }

    private static func relativeTimeString(_ date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "\(Int(interval))秒前" }
        if interval < 3600 { return "\(Int(interval / 60))分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600))小时前" }
        return "\(Int(interval / 86400))天前"
    }
}
