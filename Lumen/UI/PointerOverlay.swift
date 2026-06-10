import AppKit
import SwiftUI

/// The pointing layer — a click-through, full-screen transparent panel that
/// draws Lumen's animated pointer at model-specified coordinates. This is
/// Clicky's signature mechanic; here it is the first consumer of what will
/// become the reusable AnnotationLayer.
@MainActor
final class PointerOverlayController {
    private var panel: NSPanel?
    private let model = PointerModel()
    private var hideTask: Task<Void, Never>?

    /// Points at a coordinate given in the *screenshot's* pixel space;
    /// scales into the main screen's view space.
    func point(at tag: PointTag, captureSize: (width: Int, height: Int)) {
        guard let screen = NSScreen.main, captureSize.width > 0, captureSize.height > 0 else { return }

        let scaleX = screen.frame.width / CGFloat(captureSize.width)
        let scaleY = screen.frame.height / CGFloat(captureSize.height)
        let target = CGPoint(x: CGFloat(tag.x) * scaleX, y: CGFloat(tag.y) * scaleY)

        ensurePanel(on: screen)
        model.show(target: target, label: tag.label)

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            model.visible = false
        }
    }

    func hide() {
        hideTask?.cancel()
        model.visible = false
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
            panel.contentView = NSHostingView(rootView: PointerView(model: model))
            self.panel = panel
        }
        panel?.setFrame(screen.frame, display: true)
        panel?.orderFrontRegardless()
    }
}

@MainActor
final class PointerModel: ObservableObject {
    @Published var target: CGPoint = .zero
    @Published var label: String = ""
    @Published var visible = false

    func show(target: CGPoint, label: String) {
        // First appearance enters from below the target so the motion has a
        // direction; subsequent points glide from the previous location.
        if !visible {
            self.target = CGPoint(x: target.x, y: target.y + 120)
        }
        self.label = label
        visible = true
        withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) {
            self.target = target
        }
    }
}

struct PointerView: View {
    @ObservedObject var model: PointerModel

    var body: some View {
        GeometryReader { _ in
            if model.visible {
                VStack(spacing: 4) {
                    PointerTriangle()
                        .fill(.teal)
                        .frame(width: 26, height: 30)
                        .shadow(color: .teal.opacity(0.6), radius: 8)
                    if !model.label.isEmpty {
                        Text(model.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.75), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                // Offset so the triangle's tip lands on the target point.
                .position(x: model.target.x, y: model.target.y + 22)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.visible)
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
