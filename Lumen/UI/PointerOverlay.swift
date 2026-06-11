import AppKit
import SwiftUI

/// The annotation layer — a click-through, full-screen transparent panel
/// drawing Lumen's pointer and highlight boxes.
///
/// Annotations stream in faster than a human can follow, so they are NOT
/// rendered immediately: they enter a queue and a pacer presents them one
/// at a time. The current stop gets the labeled box and the pointer glides
/// to it; previous stops fade to faint unlabeled outlines — a visible
/// trail without the clutter.
@MainActor
final class PointerOverlayController {
    struct TourStop {
        enum Kind { case point, box }
        let kind: Kind
        let rect: CGRect      // screen points, top-left origin
        let label: String
    }

    private var panel: NSPanel?
    private let model = PointerModel()
    private var queue: [TourStop] = []
    private var pacer: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    /// Minimum time each stop holds the spotlight.
    private let dwellNanos: UInt64 = 1_700_000_000

    func enqueuePoint(atScreenPoint target: CGPoint, label: String) {
        enqueue(TourStop(kind: .point, rect: CGRect(origin: target, size: .zero), label: label))
    }

    func enqueueHighlight(rect: CGRect, label: String) {
        enqueue(TourStop(kind: .box, rect: rect, label: label))
    }

    func hide() {
        pacer?.cancel()
        pacer = nil
        queue.removeAll()
        hideTask?.cancel()
        model.clear()
    }

    // MARK: - Pacing

    private func enqueue(_ stop: TourStop) {
        guard let screen = NSScreen.main else { return }
        ensurePanel(on: screen)
        queue.append(stop)
        startPacerIfNeeded()
    }

    private func startPacerIfNeeded() {
        guard pacer == nil else { return }
        hideTask?.cancel()
        pacer = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let stop = self.queue.removeFirst()
                self.model.present(stop)
                try? await Task.sleep(nanoseconds: self.dwellNanos)
            }
            guard let self, !Task.isCancelled else { return }
            self.pacer = nil
            self.scheduleAutoHide()
        }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            self?.model.clear()
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

    @Published var currentBox: Box?
    @Published var passedBoxes: [Box] = []
    @Published var pointerTarget: CGPoint = .zero
    @Published var pointerLabel: String = ""
    @Published var pointerVisible = false

    func present(_ stop: PointerOverlayController.TourStop) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            // The spotlight moves on: previous stop becomes a faint trace.
            if let current = currentBox {
                passedBoxes.append(current)
                if passedBoxes.count > 8 { passedBoxes.removeFirst(passedBoxes.count - 8) }
                currentBox = nil
            }
            if stop.kind == .box {
                currentBox = Box(rect: stop.rect, label: stop.label)
            }
        }

        let target = stop.kind == .box
            ? CGPoint(x: stop.rect.midX, y: stop.rect.midY)
            : stop.rect.origin

        // First appearance enters from below the target so the motion has a
        // direction; subsequent stops glide from the previous location.
        if !pointerVisible {
            pointerTarget = CGPoint(x: target.x, y: target.y + 120)
        }
        pointerLabel = stop.kind == .point ? stop.label : ""
        pointerVisible = true
        withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) {
            pointerTarget = target
        }
    }

    func clear() {
        withAnimation(.easeOut(duration: 0.25)) {
            pointerVisible = false
            currentBox = nil
            passedBoxes = []
        }
    }
}

struct AnnotationView: View {
    @ObservedObject var model: PointerModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.passedBoxes) { box in
                HighlightBox(box: box, isCurrent: false)
            }
            if let current = model.currentBox {
                HighlightBox(box: current, isCurrent: true)
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
    let isCurrent: Bool

    var body: some View {
        let rect = box.rect.insetBy(dx: -5, dy: -5)
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(.teal.opacity(isCurrent ? 1 : 0.25), lineWidth: isCurrent ? 2.5 : 1.5)
            .shadow(color: .teal.opacity(isCurrent ? 0.55 : 0), radius: 8)
            .frame(width: rect.width, height: rect.height)
            .overlay(alignment: .topLeading) {
                // Label only on the current stop — passed boxes stay quiet.
                if isCurrent, !box.label.isEmpty {
                    Text(box.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.teal, in: Capsule())
                        .foregroundStyle(.black)
                        .offset(y: -26)
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
