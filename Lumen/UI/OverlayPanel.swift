import AppKit
import SwiftUI

enum AssistantState {
    case listening(partial: String)
    case thinking(receipt: NSImage?)
    case answering(text: String, receipt: NSImage?, done: Bool)
    case error(String)
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: AssistantState = .listening(partial: "")
    var onDismiss: (() -> Void)?
}

/// Non-activating floating overlay — floats above everything (including
/// full-screen apps) and never steals focus from the app the user is in.
@MainActor
final class OverlayPanelController {
    private var panel: NSPanel?
    private let model = OverlayModel()

    func show(state: AssistantState) {
        model.state = state
        if panel == nil {
            model.onDismiss = { [weak self] in self?.hide() }
            panel = makePanel()
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
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
            panel.setFrameOrigin(NSPoint(x: frame.midX - 240, y: frame.minY + 48))
        }
        return panel
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(spacing: 14) {
            receipt
            content
        }
        .padding(20)
        .frame(width: 480)
        .frame(minHeight: 120)
        .background(panelBackground)
        .contentShape(RoundedRectangle(cornerRadius: 24))
        // Click anywhere on the panel to dismiss — the panel is
        // non-activating, so the click never steals focus.
        .onTapGesture { model.onDismiss?() }
        .animation(.spring(duration: 0.35), value: stateKey)
    }

    // MARK: - Capture receipt

    /// The receipt: exactly what was captured and sent — nothing more.
    @ViewBuilder
    private var receipt: some View {
        if let image = receiptImage {
            VStack(spacing: 6) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    )
                Text("Sent to the model — exactly this frame")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var receiptImage: NSImage? {
        switch model.state {
        case .thinking(let receipt), .answering(_, let receipt, _):
            return receipt
        default:
            return nil
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .listening(let partial):
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(.teal)
                Text(partial.isEmpty ? "Listening… (release ⌃⌥ when done)" : partial)
                    .font(.callout)
                    .foregroundStyle(partial.isEmpty ? .secondary : .primary)
            }
        case .thinking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .answering(let text, _, let done):
            VStack(alignment: .leading, spacing: 6) {
                if text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for \(ProviderSettings.kind == .anthropic ? "Claude" : ProviderSettings.model)… (first local answer loads the model — can take a while)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if done {
                    Text("⌃⌥ to ask again · click to dismiss")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        case .error(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stateKey: String {
        switch model.state {
        case .listening(let p): return "l\(p)"
        case .thinking: return "t"
        case .answering(let t, _, let d): return "a\(t)\(d)"
        case .error(let e): return "e\(e)"
        }
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
