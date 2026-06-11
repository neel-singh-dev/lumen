import AppKit
import ApplicationServices

/// Detects the ⌃⌥ (Control+Option) chord — Lumen's push-to-talk — by watching
/// modifier-flag changes. Modifier-only chords can't use Carbon hotkeys, so we
/// use NSEvent monitors; the global monitor requires Accessibility trust,
/// which Lumen needs anyway for element-anchored pointing and agent actions.
final class HotkeyMonitor {
    var onPushToTalkChanged: ((Bool) -> Void)?
    /// Escape dismisses whatever Lumen is doing — mid-listen, mid-answer,
    /// mid-narration.
    var onEscape: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var isDown = false

    func start() {
        // Surfaces the system Accessibility prompt on first launch.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(flags: event.modifierFlags)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(flags: event.modifierFlags)
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.onEscape?() }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.onEscape?() }
            return event
        }
    }

    private func handle(flags: NSEvent.ModifierFlags) {
        let chordDown = flags.contains(.control) && flags.contains(.option)
        guard chordDown != isDown else { return }
        isDown = chordDown
        onPushToTalkChanged?(chordDown)
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }
}
