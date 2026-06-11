import SwiftUI

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @AppStorage(ProviderSettings.kindKey) private var providerKind = ProviderKind.anthropic.rawValue
    @AppStorage(Narrator.enabledKey) private var speakAnswers = true

    var body: some Scene {
        MenuBarExtra("Lumen", systemImage: "rays") {
            Text("Hold ⌃⌥ and ask about your screen")
            Divider()
            Toggle("Speak answers", isOn: $speakAnswers)
            Picker("Provider", selection: $providerKind) {
                Text("Claude (Anthropic)").tag(ProviderKind.anthropic.rawValue)
                Text("Local — Ollama / OpenAI-compatible").tag(ProviderKind.openaiCompatible.rawValue)
            }
            .pickerStyle(.inline)
            Button("Set Anthropic API Key…") {
                appDelegate.assistant.promptForAPIKey()
            }
            Button("Configure Local Provider…") {
                appDelegate.assistant.promptForLocalProvider()
            }
            Divider()
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
