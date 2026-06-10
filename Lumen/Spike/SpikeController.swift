import AppKit

/// Hour-zero spike: wires the three primitives everything else builds on.
///   1. Global push-to-talk chord (⌃⌥)  → HotkeyMonitor
///   2. Non-activating floating overlay → OverlayPanelController
///   3. One ScreenCaptureKit capture    → ScreenCapturer
///
/// Acceptance: hold ⌃⌥ anywhere → overlay appears showing exactly what was
/// captured (Lumen's own windows excluded). Release → overlay hides.
/// This is also Capture Receipt v0 — the first feature is the thesis.
@MainActor
final class SpikeController {
    private let hotkey = HotkeyMonitor()
    private let panel = OverlayPanelController()
    private let capturer = ScreenCapturer()

    func start() {
        hotkey.onPushToTalkChanged = { [weak self] isDown in
            guard let self else { return }
            if isDown {
                self.triggerCapture()
            } else {
                self.panel.hide()
            }
        }
        hotkey.start()
    }

    func triggerCapture() {
        panel.show(state: .capturing)
        Task {
            do {
                let image = try await capturer.captureMainDisplay()
                panel.show(state: .captured(image))
            } catch {
                panel.show(state: .error(String(describing: error)))
            }
        }
    }
}
