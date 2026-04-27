import PdffCore
import SwiftUI

@main
struct PdffApp: App {
    @StateObject private var workspace = DocumentWorkspace()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspace)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF...") {
                    workspace.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }

            CommandGroup(after: .saveItem) {
                Button("Export Filled PDF...") {
                    workspace.presentExportPanel()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(workspace.document == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(workspace)
        }
    }
}
