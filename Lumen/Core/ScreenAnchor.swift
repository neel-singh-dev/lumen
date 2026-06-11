import AppKit

extension NSScreen {
    /// The screen Lumen anchors to: the one with a physical notch (the
    /// MacBook's built-in display), else the primary screen.
    ///
    /// `NSScreen.main` is deliberately avoided everywhere — it tracks the
    /// FOCUSED window's screen, so overlays would drift to whichever
    /// display the user happens to be working on.
    static var lumen: NSScreen? {
        screens.first { $0.safeAreaInsets.top > 0 } ?? screens.first
    }

    /// CoreGraphics display id, for matching against ScreenCaptureKit.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
