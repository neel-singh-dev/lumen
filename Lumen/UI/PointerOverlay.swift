import AppKit
import SwiftUI

/// The annotation layer — a click-through, full-screen transparent panel
/// drawing Lumen's pointer and highlight boxes. Element-anchored targets
/// arrive in screen points (AX coordinates, top-left origin — the same
/// space this view renders in, so no conversion); pixel-fallback targets
/// are converted by the caller.
@MainActor
final class PointerOverlayController {
    private var panel: NSPanel?
    private let model = PointerModel()
    private var hideTask: Task<Void, Never>?

    /// Points at a location in screen points (top-left origin).
    func point(atScreenPoint target: CGPoint, label: String) {
        guard let screen = NSScreen.main else { return }
        ensurePanel(on: screen)
        model.showPointer(target: target, label: label)
        scheduleAutoHide()
    }

    /// Draws a highlight box around a rect in screen points (max 3 shown).
    func highlight(rect: CGRect, label: String) {
        guard let screen = NSScreen.main else { return }
        ensurePanel(on: screen)
        model.addBox(rect: rect, label: label)
        scheduleAutoHide()
    }

    func hide() {
        hideTask?.cancel()
        model.clear()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            model.clear()
        }
    }

    private func ensurePanel(on screen: NSScreen) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: screen.frame,
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
            panel.contentView = NSHostingView(rootView: AnnotationView(model: model))
            self.panel = panel
        }
        panel?.setFrame(screen.frame, display: true)
        panel?.orderFrontRegardless()
    }
}

@MainActor
final class PointerModel: ObservableObject {
    struct Box: Identifiable, Equatable {
        let id = UUID()
        let rect: CGRect
        let label: String
    }

    @Published var pointerTarget: CGPoint = .zero
    @Published var pointerLabel: String = ""
    @Published var pointerVisible = false
    @Published var boxes: [Box] = []

    func showPointer(target: CGPoint, label: String) {
        // First appearance enters from below the target so the motion has a
        // direction; subsequent points glide from the previous location.
        if !pointerVisible {
            pointerTarget = CGPoint(x: target.x, y: target.y + 120)
        }
        pointerLabel = label
        pointerVisible = true
        withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) {
            pointerTarget = target
        }
    }

    func addBox(rect: CGRect, label: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            boxes.append(Box(rect: rect, label: label))
            // Tour mode shows many highlights; cap to keep the screen legible.
            if boxes.count > 8 { boxes.removeFirst(boxes.count - 8) }
        }
    }

    func clear() {
        withAnimation(.easeOut(duration: 0.25)) {
            pointerVisible = false
            boxes = []
        }
    }
}

struct AnnotationView: View {
    @ObservedObject var model: PointerModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.boxes) { box in
                HighlightBox(box: box)
            }
            if model.pointerVisible {
                pointer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.25), value: model.pointerVisible)
    }

    private var pointer: some View {
        VStack(spacing: 4) {
            PointerTriangle()
                .fill(.teal)
                .frame(width: 26, height: 30)
                .shadow(color: .teal.opacity(0.6), radius: 8)
            if !model.pointerLabel.isEmpty {
                Text(model.pointerLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        // Offset so the triangle's tip lands on the target point.
        .position(x: model.pointerTarget.x, y: model.pointerTarget.y + 22)
        .transition(.opacity.combined(with: .scale(scale: 0.6)))
    }
}

private struct HighlightBox: View {
    let box: PointerModel.Box

    var body: some View {
        let rect = box.rect.insetBy(dx: -5, dy: -5)
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(.teal, lineWidth: 2.5)
            .shadow(color: .teal.opacity(0.55), radius: 8)
            .frame(width: rect.width, height: rect.height)
            .overlay(alignment: .topLeading) {
                if !box.label.isEmpty {
                    Text(box.label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.teal, in: Capsule())
                        .foregroundStyle(.black)
                        .offset(y: -24)
                }
            }
            .position(x: rect.midX, y: rect.midY)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

/// An upward-pointing triangle whose apex is the pointing tip.
struct PointerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY * 0.8))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
