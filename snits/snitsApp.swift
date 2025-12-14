import SwiftUI
import UniformTypeIdentifiers

@main
struct SwiftSNESApp: App {
    @StateObject private var emulator = SNESSystem()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(emulator)
                .frame(minWidth: 512, minHeight: 448)
        }
        // Removed .windowStyle(.titlebar) as it is not standard SwiftUI on macOS
        // Removed .fileImporter from Scene (Moved to ContentView.swift)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open ROM...") {
                    // This action needs to trigger ContentView's state.
                    // For simplicity in this architecture, shortcuts are handled inside ContentView.
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
