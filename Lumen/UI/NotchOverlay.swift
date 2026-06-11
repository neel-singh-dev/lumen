import AppKit
import SwiftUI

/// Lumen's presence — a Dynamic-Island-style capsule that extends from the
/// MacBook notch (top-center on any display). It expands while listening
/// (waveform + your words, live), morphs to a loader while thinking, and a
/// speaker while narrating. Status lives here; answer text lives in the
/// cursor pill. The panel is fixed-size and mouse-transparent; only the
/// capsule inside animates, so there is no window-resize churn.
@MainActor
final class NotchModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening(String)
        case thinking
        case speaking
        case answering
    }

    @Published var phase: Phase = .hidden
}

@MainActor
final class NotchOverlayController {
    let model = NotchModel()
    private var panel: NSPanel?
    private var orderOutTask: Task<Void, Never>?

    func set(_ phase: NotchModel.Phase) {
        ensurePanel()
        orderOutTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
            model.phase = phase
        }
        if case .hidden = phase {
            orderOutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                self?.panel?.orderOut(nil)
            }
        } else {
            panel?.orderFrontRegardless()
        }
    }

    private func ensurePanel() {
        guard panel == nil, let screen = NSScreen.main else {
            reposition()
            return
        }
        let size = NSSize(width: 520, height: 56)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: NotchView(model: model))
        // Flush with the physical top edge — where the notch lives.
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        ))
        self.panel = panel
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - panel.frame.width / 2,
            y: screen.frame.maxY - panel.frame.height
        ))
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(spacing: 0) {
            capsule
            Spacer(minLength: 0)
        }
        .frame(width: 520, height: 56, alignment: .top)
    }

    @ViewBuilder
    private var capsule: some View {
        HStack(spacing: 9) {
            icon
            text
        }
        .padding(.horizontal, 16)
        .frame(width: width, height: 37)
        .background(
            // Notch-black so the capsule reads as the notch itself expanding.
            UnevenRoundedRectangle(
                bottomLeadingRadius: 17,
                bottomTrailingRadius: 17
            )
            .fill(.black)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        )
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.6, anchor: .top)
    }

    private var visible: Bool {
        model.phase != .hidden
    }

    private var width: CGFloat {
        switch model.phase {
        case .hidden: return 150
        case .listening(let partial): return partial.isEmpty ? 230 : 440
        case .thinking: return 190
        case .speaking: return 210
        case .answering: return 210
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .listening:
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(.teal)
        case .thinking:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .speaking:
            Image(systemName: "speaker.wave.2.fill")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(.teal)
        case .answering:
            Image(systemName: "text.alignleft")
                .foregroundStyle(.teal)
        }
    }

    @ViewBuilder
    private var text: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .listening(let partial):
            Text(partial.isEmpty ? "Listening…" : partial)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            Text("Thinking…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        case .speaking:
            Text("Lumen")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        case .answering:
            Text("Answering…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
