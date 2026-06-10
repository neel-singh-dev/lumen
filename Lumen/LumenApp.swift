import SwiftUI

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Lumen", systemImage: "rays") {
            Text("Hold ⌃⌥ and ask about your screen")
            Divider()
            Button("Set Anthropic API Key…") {
                appDelegate.assistant.promptForAPIKey()
            }
            Button("Hide Overlays") {
                appDelegate.assistant.hideOverlays()
            }
            Divider()
            Button("Quit Lumen") {
                NSApp.terminate(nil)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let assistant = AssistantController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        assistant.start()
    }
}
