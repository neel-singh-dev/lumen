import AppKit
import ScreenCaptureKit

/// Single-shot screen capture via ScreenCaptureKit.
/// Lumen's own windows are excluded from the frame — the assistant never
/// captures itself, so the receipt shows only what the user sees.
final class ScreenCapturer {
    enum CaptureError: Error {
        case noDisplay
    }

    /// Captures the main display, downscaled to ~1280px wide (Clicky parity:
    /// enough for vision models, cheap to transmit).
    func captureMainDisplay() async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let ownWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let config = SCStreamConfiguration()
        let targetWidth = min(display.width, 1280)
        config.width = targetWidth
        config.height = display.width == 0
            ? display.height
            : Int(Double(targetWidth) * Double(display.height) / Double(display.width))
        config.showsCursor = true

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
