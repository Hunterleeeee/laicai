import XCTest

@testable import LaicaiNativeDomain
@testable import LaicaiNativeFoundation

@MainActor
final class AppStoreStreamTextStoreTests: LaicaiNativeFoundationTestCase {
    private func makeStoreWithThread() -> (AppStore, UUID) {
        let store = makeTestStore()
        store.newThread()
        let threadID = store.state.selectedThreadID!
        return (store, threadID)
    }

    func testLiveFlushKeepsAppStateStepEmptyAndAccumulatesInStore() {
        let (store, threadID) = makeStoreWithThread()

        store.appendStreamDelta("你好", to: threadID)

        // First flush fires immediately (lastFlush defaults to .distantPast):
        // the placeholder is created once with empty text and the live content
        // lives exclusively in StreamTextStore.
        let placeholder = store.state.threads.first { $0.id == threadID }?.steps.last {
            $0.kind == .textOutput && $0.toolCallId == AppStore.streamingOutputID
        }
        XCTAssertNotNil(placeholder)
        XCTAssertEqual(placeholder?.text, "")
        XCTAssertEqual(store.streamPresentation.text(forThread: threadID), "你好")
        XCTAssertGreaterThan(store.streamPresentation.revision, 0)
    }

    func testTerminalFlushFoldsLiveAndBufferedTextIntoPersistedStep() {
        let (store, threadID) = makeStoreWithThread()

        store.appendStreamDelta("第一段", to: threadID)
        // Second delta lands in the raw buffer (interval + size thresholds).
        store.appendStreamDelta("第二段", to: threadID)

        store.flushStreamBuffer(for: threadID, persist: true)

        let placeholder = store.state.threads.first { $0.id == threadID }?.steps.last {
            $0.kind == .textOutput && $0.toolCallId == AppStore.streamingOutputID
        }
        XCTAssertEqual(placeholder?.text, "第一段第二段")
        XCTAssertEqual(store.streamPresentation.text(forThread: threadID), "")
        XCTAssertEqual(store.streamBuffers[threadID] ?? "", "")
    }

    func testFinalStepReplacesPlaceholderAndClearsStore() {
        let (store, threadID) = makeStoreWithThread()

        store.appendStreamDelta("流式内容", to: threadID)
        let final = TaskStep(kind: .textOutput, text: "最终完整回复")
        store.appendTaskStep(final, to: threadID)

        let steps = store.state.threads.first { $0.id == threadID }?.steps ?? []
        let outputs = steps.filter { $0.kind == .textOutput }
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?.toolCallId, nil)
        XCTAssertEqual(outputs.first?.text, "最终完整回复")
        XCTAssertEqual(store.streamPresentation.text(forThread: threadID), "")
    }

    func testThinkingFlushKeepsReasoningInStoreDuringRun() {
        let (store, threadID) = makeStoreWithThread()

        store.appendThinkingDelta("推理片段", to: threadID)

        let placeholder = store.state.threads.first { $0.id == threadID }?.steps.last {
            $0.kind == .aiThinking && $0.toolCallId == AppStore.thinkingStreamID
        }
        XCTAssertNotNil(placeholder)
        XCTAssertTrue(placeholder?.reasoningContent?.isEmpty ?? false)
        XCTAssertEqual(store.streamPresentation.reasoning(forThread: threadID), "推理片段")

        store.flushThinkingBuffer(for: threadID, persist: true)
        XCTAssertEqual(placeholder?.reasoningContent, "")
        let persisted = store.state.threads.first { $0.id == threadID }?.steps.last {
            $0.kind == .aiThinking && $0.toolCallId == AppStore.thinkingStreamID
        }
        XCTAssertEqual(persisted?.reasoningContent, "推理片段")
        XCTAssertEqual(store.streamPresentation.reasoning(forThread: threadID), "")
    }

    func testMarkGenerationStartedClearsResidueFromPreviousRun() {
        let (store, threadID) = makeStoreWithThread()

        store.appendStreamDelta("上次残留", to: threadID)
        store.appendThinkingDelta("上次思考残留", to: threadID)
        XCTAssertFalse(store.streamPresentation.text(forThread: threadID).isEmpty)

        _ = store.markGenerationStarted(for: threadID, activity: "运行中")

        XCTAssertEqual(store.streamPresentation.text(forThread: threadID), "")
        XCTAssertEqual(store.streamPresentation.reasoning(forThread: threadID), "")
    }

    func testCancelGenerationTaskDiscardsLiveEntries() {
        let (store, threadID) = makeStoreWithThread()

        store.appendStreamDelta("将被丢弃", to: threadID)
        _ = store.cancelGenerationTask(for: threadID, discardBuffers: true, markCancelled: false)

        XCTAssertEqual(store.streamPresentation.text(forThread: threadID), "")
    }
}
