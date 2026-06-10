import SwiftUI

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Lumen", systemImage: "rays") {
            Button("Test capture (or hold ⌃⌥)") {
                appDelegate.spike.triggerCapture()
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
    let spike = SpikeController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        spike.start()
    }
}
