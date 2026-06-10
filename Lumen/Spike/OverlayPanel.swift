import AppKit
import SwiftUI

enum SpikeState {
    case capturing
    case captured(NSImage)
    case error(String)
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: SpikeState = .capturing
}

/// Non-activating floating overlay — the canonical Clicky/Raycast panel:
/// floats above everything (including full-screen apps), never steals focus
/// from the app the user is working in.
@MainActor
final class OverlayPanelController {
    private var panel: NSPanel?
    private let model = OverlayModel()

    func show(state: SpikeState) {
        model.state = state
        if panel == nil {
            panel = makePanel()
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 220, y: frame.minY + 48))
        }
        return panel
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(spacing: 12) {
            switch model.state {
            case .capturing:
                ProgressView()
                Text("Capturing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .captured(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    )
                Text("This is exactly what Lumen captured")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(20)
        .frame(width: 440, height: 320)
        .background(panelBackground)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 24)
                .fill(.clear)
                .glassEffect(in: .rect(cornerRadius: 24))
        } else {
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
        }
    }
}
