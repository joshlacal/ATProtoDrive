import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class BrowserSession {
    public var selectedSource: BrowserSource?
    public var path: BrowserPath?
    public var selectedItemIDs: Set<String>
    public private(set) var selectedReferences: [String: ResourceReference]
    public var history: [BrowserPath]
    public private(set) var historyIndex: Int?
    public var openedPublicRepositories: [OpenedRepositorySummary]
    public var isInspectorPresented: Bool
    public var columnVisibility: NavigationSplitViewVisibility
    public var sort: BrowserSort
    public var searchQuery: SearchQuery

    public init(
        selectedSource: BrowserSource? = nil,
        path: BrowserPath? = nil,
        selectedItemIDs: Set<String> = [],
        selectedReferences: [String: ResourceReference] = [:],
        history: [BrowserPath] = [],
        historyIndex: Int? = nil,
        openedPublicRepositories: [OpenedRepositorySummary] = [],
        isInspectorPresented: Bool = false,
        columnVisibility: NavigationSplitViewVisibility = .all,
        sort: BrowserSort = BrowserSort(),
        searchQuery: SearchQuery = SearchQuery()
    ) {
        self.selectedSource = selectedSource
        self.path = path
        self.selectedItemIDs = selectedItemIDs
        self.selectedReferences = selectedReferences
        self.history = history
        self.historyIndex = historyIndex
        self.openedPublicRepositories = openedPublicRepositories
        self.isInspectorPresented = isInspectorPresented
        self.columnVisibility = columnVisibility
        self.sort = sort
        self.searchQuery = searchQuery
    }

    public var primarySelectionID: String? {
        selectedItemIDs.min()
    }

    public var primarySelection: ResourceReference? {
        guard let primarySelectionID else { return nil }
        return selectedReferences[primarySelectionID]
    }

    public var currentRepositoryScope: RepositoryScope? {
        guard let path else { return nil }
        for component in path.components {
            return component.scope
        }
        return nil
    }

    public var canGoBack: Bool {
        if let historyIndex {
            return historyIndex > 0
        }
        return false
    }

    public var canGoForward: Bool {
        if let historyIndex {
            return historyIndex < history.count - 1
        }
        return false
    }

    @discardableResult
    public func replaceSelection(with references: Set<ResourceReference>) -> Bool {
        if let scope = currentRepositoryScope {
            for ref in references {
                if ref.scope != scope {
                    return false
                }
            }
        }
        selectedItemIDs = Set(references.map(\.stableID))
        selectedReferences = Dictionary(uniqueKeysWithValues: references.map { ($0.stableID, $0) })
        return true
    }

    public func selectSource(_ source: BrowserSource?) {
        guard selectedSource != source else { return }
        guard let source else {
            selectedSource = nil
            return
        }
        if path?.source == source {
            selectedSource = source
            return
        }
        selectedSource = source
        path = nil
        history = []
        historyIndex = nil
        selectedItemIDs = []
        selectedReferences = [:]
    }

    public func navigate(to newPath: BrowserPath) {
        guard path != newPath else { return }
        if let index = historyIndex, index < history.count - 1 {
            history = Array(history.prefix(upTo: index + 1))
        }
        history.append(newPath)
        historyIndex = history.count - 1
        applyNavigation(newPath)
    }

    public func goBack() {
        guard canGoBack, let index = historyIndex else { return }
        let newIndex = index - 1
        historyIndex = newIndex
        applyNavigation(history[newIndex])
    }

    public func goForward() {
        guard canGoForward, let index = historyIndex else { return }
        let newIndex = index + 1
        historyIndex = newIndex
        applyNavigation(history[newIndex])
    }

    private func applyNavigation(_ newPath: BrowserPath) {
        path = newPath
        selectedSource = newPath.source
        selectedItemIDs = []
        selectedReferences = [:]
        searchQuery = SearchQuery()
    }

    public func rememberOpenedRepository(_ summary: OpenedRepositorySummary) {
        openedPublicRepositories.removeAll { $0.id == summary.id }
        openedPublicRepositories.insert(summary, at: 0)
        if openedPublicRepositories.count > 10 {
            openedPublicRepositories = Array(openedPublicRepositories.prefix(10))
        }
    }
}
