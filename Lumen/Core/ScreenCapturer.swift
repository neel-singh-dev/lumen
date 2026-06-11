import AppKit
import ScreenCaptureKit

/// One captured frame, in the exact form it is sent to the model.
/// The overlay receipt renders `image` — the same bytes the model sees,
/// which is what makes the receipt structurally truthful.
struct ScreenCapture {
    let image: NSImage
    let cgImage: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let jpegBase64: String

    /// Blacks out the given screen-point rects (secure text fields) in the
    /// REAL payload — the returned capture's JPEG bytes are redacted, and
    /// the receipt renders those same bytes, so what the user sees blurred
    /// is provably what the model cannot see.
    func redacting(_ rects: [CGRect], screenSize: CGSize) -> ScreenCapture {
        guard !rects.isEmpty, screenSize.width > 0, screenSize.height > 0 else { return self }
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return self }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))

        let scaleX = CGFloat(pixelWidth) / screenSize.width
        let scaleY = CGFloat(pixelHeight) / screenSize.height
        for rect in rects {
            let width = rect.width * scaleX + 8
            let height = rect.height * scaleY + 8
            let x = rect.minX * scaleX - 4
            // Screen rects are top-left origin; CGContext is bottom-left.
            let y = CGFloat(pixelHeight) - (rect.minY * scaleY) - height + 4
            context.fill(CGRect(x: x, y: y, width: width, height: height))
        }

        guard let redacted = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: redacted)
                  .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { return self }

        return ScreenCapture(
            image: NSImage(cgImage: redacted, size: NSSize(width: pixelWidth, height: pixelHeight)),
            cgImage: redacted,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            jpegBase64: jpeg.base64EncodedString()
        )
    }
}

/// Single-shot screen capture via ScreenCaptureKit.
/// Lumen's own windows are excluded from the frame — the assistant never
/// captures itself, so the receipt shows only what the user sees.
final class ScreenCapturer {
    enum CaptureError: Error {
        case noDisplay
        case encodingFailed
    }

    /// Captures Lumen's anchor display (the notched screen — the same one
    /// every overlay renders on, so pointer coordinates stay consistent),
    /// downscaled to ~1280px wide and encoded as JPEG.
    func captureMainDisplay() async throws -> ScreenCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let anchorID = await MainActor.run { NSScreen.lumen?.displayID }
        guard let display = content.displays.first(where: { $0.displayID == anchorID })
            ?? content.displays.first
        else {
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

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw CaptureError.encodingFailed
        }

        return ScreenCapture(
            image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)),
            cgImage: cgImage,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            jpegBase64: jpeg.base64EncodedString()
        )
    }
}
