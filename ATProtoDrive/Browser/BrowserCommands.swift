import SwiftUI

public struct BrowserCommands: Commands {
    public init() {}

    public var body: some Commands {
        SidebarCommands()
        InspectorCommands()
    }
}
