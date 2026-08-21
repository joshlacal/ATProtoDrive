import SwiftUI

@main
struct ATProtoDriveApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                Text("Accounts")
            } content: {
                Text("Spaces")
            } detail: {
                Text("Records")
            }
        }
    }
}
