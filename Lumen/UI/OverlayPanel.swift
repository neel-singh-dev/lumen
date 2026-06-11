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
    @Published var receiptNote = "Sent to the model — exactly this frame"
    var onDismiss: (() -> Void)?
}

/// The conversation pill — a compact, non-activating glass capsule that
/// appears right beside the mouse pointer at summon (everything happens
/// where the user's eyes already are), shows the live transcript while
/// they speak, then morphs into the streaming answer. It grows downward
/// from its anchor and never steals focus.
@MainActor
final class OverlayPanelController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<OverlayView>?
    private let model = OverlayModel()

    func show(state: AssistantState) {
        model.state = state
        if panel == nil {
            model.onDismiss = { [weak self] in self?.hide() }
            build()
        }
        guard let panel, let hosting else { return }

        let wasVisible = panel.isVisible
        let size = hosting.fittingSize

        if wasVisible {
            // Resize only when the height actually changes — per-token
            // window churn saturates the main thread.
            if abs(size.height - panel.frame.height) > 0.5 {
                // Keep the top edge pinned; grow downward as content streams.
                let top = panel.frame.maxY
                let x = panel.frame.origin.x
                panel.setContentSize(size)
                panel.setFrameOrigin(NSPoint(x: x, y: top - size.height))
            }
        } else {
            panel.setContentSize(size)
            position(panel, near: NSEvent.mouseLocation, size: size)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Describes the full payload sent to the model (frame + AX elements).
    func setNote(_ note: String) {
        model.receiptNote = note
    }

    private func position(_ panel: NSPanel, near mouse: NSPoint, size: NSSize) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        // Beside and below the cursor; flip sides at screen edges.
        var origin = NSPoint(x: mouse.x + 18, y: mouse.y - size.height - 16)
        if origin.x + size.width > screen.maxX - 8 {
            origin.x = mouse.x - size.width - 18
        }
        origin.x = max(screen.minX + 8, min(origin.x, screen.maxX - size.width - 8))
        if origin.y < screen.minY + 8 {
            origin.y = mouse.y + 20
        }
        origin.y = max(screen.minY + 8, min(origin.y, screen.maxY - size.height - 8))
        panel.setFrameOrigin(origin)
    }

    private func build() {
        let hosting = NSHostingView(rootView: OverlayView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
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
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(width: 360, alignment: .leading)
        .background(pillBackground)
        .contentShape(RoundedRectangle(cornerRadius: 22))
        // Click anywhere on the pill to dismiss — non-activating, so the
        // click never steals focus from the app underneath.
        .onTapGesture { model.onDismiss?() }
        .animation(.spring(duration: 0.35), value: stateKey)
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .listening(let partial):
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(.teal)
                    .font(.body)
                Text(partial.isEmpty ? "Listening… release ⌃⌥ when done" : partial)
                    .font(.callout)
                    .foregroundStyle(partial.isEmpty ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .thinking(let receipt):
            VStack(alignment: .leading, spacing: 8) {
                receiptRow(receipt)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .answering(let text, let receipt, let done):
            VStack(alignment: .leading, spacing: 8) {
                receiptRow(receipt)
                if text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for \(ProviderSettings.kind == .anthropic ? "Claude" : ProviderSettings.model)…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // fixedSize is load-bearing: without it, NSHostingView's
                    // fittingSize under-measures multi-line text and the
                    // pill's content overlaps.
                    Text(text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if done {
                    Text("⌃⌥ ask again · click to dismiss")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        case .error(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The capture receipt, pill-sized: a small truthful thumbnail of the
    /// exact frame sent, with the payload note beside it.
    @ViewBuilder
    private func receiptRow(_ image: NSImage?) -> some View {
        if let image {
            HStack(spacing: 10) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    )
                Text(model.receiptNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Coarse key: animates state-KIND transitions only. Keying on the full
    /// text made every streamed token an animated transaction — a main-
    /// thread storm that froze the stream and starved the narrator.
    private var stateKey: String {
        switch model.state {
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .answering(_, _, let done): return done ? "answered" : "answering"
        case .error: return "error"
        }
    }

    @ViewBuilder
    private var pillBackground: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 22)
                    .fill(.clear)
                    .glassEffect(in: .rect(cornerRadius: 22))
            } else {
                RoundedRectangle(cornerRadius: 22)
                    .fill(.ultraThinMaterial)
            }
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(
                    LinearGradient(
                        colors: [.teal.opacity(0.35), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }
}
