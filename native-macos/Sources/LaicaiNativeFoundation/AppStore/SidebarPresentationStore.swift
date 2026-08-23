import Combine
import Foundation
import LaicaiNativeDomain

/// Low-frequency sidebar projection. It deliberately owns only the data needed
/// to render/search the thread list, rather than subscribing to full AppState.
@MainActor
public final class SidebarPresentationStore: ObservableObject {
    @Published public private(set) var records: [ThreadRecord] = []
    @Published public private(set) var selectedThreadID: UUID?
    @Published public private(set) var searchText = ""
    @Published public private(set) var debouncedSearchText = ""

    public init() {}

    public func update(
        records: [ThreadRecord],
        selectedThreadID: UUID?,
        searchText: String,
        debouncedSearchText: String
    ) {
        if self.records != records { self.records = records }
        if self.selectedThreadID != selectedThreadID { self.selectedThreadID = selectedThreadID }
        if self.searchText != searchText { self.searchText = searchText }
        if self.debouncedSearchText != debouncedSearchText { self.debouncedSearchText = debouncedSearchText }
    }
}
