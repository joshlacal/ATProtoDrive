import SwiftUI

@MainActor
public struct BrowserRefreshAction: Sendable {
    public let perform: @MainActor @Sendable () async -> Void

    public init(perform: @escaping @MainActor @Sendable () async -> Void) {
        self.perform = perform
    }
}

public extension FocusedValues {
    @Entry var browserRefreshAction: BrowserRefreshAction?
    @Entry var browserSession: BrowserSession?
}

public struct BrowserCommands: Commands {
    @FocusedValue(\.browserRefreshAction) private var refreshAction
    @FocusedValue(\.browserSession) private var session

    public init() {}

    public var body: some Commands {
        SidebarCommands()
        InspectorCommands()

        CommandGroup(after: .sidebar) {
            Button("Back") {
                session?.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(session?.canGoBack != true)

            Button("Forward") {
                session?.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(session?.canGoForward != true)
        }

        CommandGroup(after: .pasteboard) {
            Button("Refresh") {
                Task {
                    await refreshAction?.perform()
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(refreshAction == nil)
        }
    }
}
