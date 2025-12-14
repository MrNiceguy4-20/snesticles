import SwiftUI

@main
struct SwiftSNESApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .commands {
            SidebarCommands()
        }
    }
}
