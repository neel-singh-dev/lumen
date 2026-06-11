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
        enum Kind { case point, box, region }
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

    /// Dashed-border highlight for an arbitrary screen area (a section,
    /// a panel, canvas content) — Clicky's signature region treatment.
    func enqueueRegion(rect: CGRect, label: String) {
        enqueue(TourStop(kind: .region, rect: rect, label: label))
    }

    func hide() {
        pacer?.cancel()
        pacer = nil
        queue.removeAll()
        hideTask?.cancel()
        model.clear()
    }

    /// Agent-mode control handoff border ("I have the cursor").
    func setControlBorder(_ active: Bool) {
        guard let screen = NSScreen.main else { return }
        ensurePanel(on: screen)
        model.setControlBorder(active)
        if active { hideTask?.cancel() }
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
        enum Style { case element, region }
        let id = UUID()
        let rect: CGRect
        let label: String
        let style: Style
    }

    @Published var currentBox: Box?
    @Published var passedBoxes: [Box] = []
    @Published var pointerX: CGFloat = 0
    @Published var pointerY: CGFloat = 0
    @Published var pointerLabel: String = ""
    @Published var pointerVisible = false
    /// Agent-mode "I have the cursor" border around the whole screen.
    @Published var controlBorderActive = false

    /// Honors the system Reduce Motion setting — springs collapse to
    /// simple fades for users who asked for less movement.
    private func animate(_ animation: Animation, _ changes: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.easeOut(duration: 0.15), changes)
        } else {
            withAnimation(animation, changes)
        }
    }

    func setControlBorder(_ active: Bool) {
        animate(.easeInOut(duration: 0.4)) {
            controlBorderActive = active
        }
    }

    func present(_ stop: PointerOverlayController.TourStop) {
        animate(.spring(response: 0.45, dampingFraction: 0.8)) {
            // The spotlight moves on: previous stop becomes a faint trace.
            if let current = currentBox {
                passedBoxes.append(current)
                if passedBoxes.count > 8 { passedBoxes.removeFirst(passedBoxes.count - 8) }
                currentBox = nil
            }
            switch stop.kind {
            case .box:
                currentBox = Box(rect: stop.rect, label: stop.label, style: .element)
            case .region:
                currentBox = Box(rect: stop.rect, label: stop.label, style: .region)
            case .point:
                break
            }
        }

        let target = stop.kind == .point
            ? stop.rect.origin
            : CGPoint(x: stop.rect.midX, y: stop.rect.midY)

        // First appearance enters from below the target so the motion has a
        // direction; subsequent stops glide from the previous location.
        if !pointerVisible {
            pointerX = target.x
            pointerY = target.y + 130
        }
        pointerLabel = stop.kind == .point ? stop.label : ""
        pointerVisible = true
        // Different spring timing per axis bends the path into an arc —
        // the swooping travel that makes the pointer feel alive.
        animate(.spring(response: 0.62, dampingFraction: 0.82)) {
            pointerX = target.x
        }
        animate(.spring(response: 0.38, dampingFraction: 0.72)) {
            pointerY = target.y
        }
    }

    func clear() {
        animate(.easeOut(duration: 0.25)) {
            pointerVisible = false
            currentBox = nil
            passedBoxes = []
            controlBorderActive = false
        }
    }
}

struct AnnotationView: View {
    @ObservedObject var model: PointerModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let current = model.currentBox {
                // Spotlight: everything except the subject dims slightly.
                SpotlightDim(cutout: current.rect.insetBy(dx: -8, dy: -8))
            }
            if model.controlBorderActive {
                // "I have the cursor" — unambiguous, screen-wide.
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.teal.opacity(0.8), lineWidth: 5)
                    .padding(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
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
        .animation(.easeOut(duration: 0.3), value: model.currentBox)
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
        .position(x: model.pointerX, y: model.pointerY + 22)
        .transition(.opacity.combined(with: .scale(scale: 0.6)))
    }
}

/// Dims the whole screen except the highlighted subject — gentle theater
/// lighting that directs attention without hiding context.
private struct SpotlightDim: View {
    let cutout: CGRect

    var body: some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRoundedRect(in: cutout, cornerSize: CGSize(width: 12, height: 12))
            context.fill(path, with: .color(.black.opacity(0.16)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

private struct HighlightBox: View {
    let box: PointerModel.Box
    let isCurrent: Bool
    @State private var dashPhase: CGFloat = 0

    private var accent: Color {
        box.style == .region ? .yellow : .teal
    }

    var body: some View {
        let rect = box.rect.insetBy(dx: -5, dy: -5)
        shape(for: rect)
            .frame(width: rect.width, height: rect.height)
            .overlay(alignment: .topLeading) {
                // Label only on the current stop — passed boxes stay quiet.
                // Near the top of the screen the label flips below the box
                // so it never clips off-screen.
                if isCurrent, !box.label.isEmpty {
                    Text(box.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accent, in: Capsule())
                        .foregroundStyle(.black)
                        .offset(y: rect.minY < 44 ? rect.height + 6 : -26)
                }
            }
            .position(x: rect.midX, y: rect.midY)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    @ViewBuilder
    private func shape(for rect: CGRect) -> some View {
        if box.style == .region {
            // Dashed marching-ants border — the section treatment.
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    accent.opacity(isCurrent ? 0.95 : 0.25),
                    style: StrokeStyle(lineWidth: isCurrent ? 2.5 : 1.5, dash: [9, 6], dashPhase: dashPhase)
                )
                .shadow(color: accent.opacity(isCurrent ? 0.45 : 0), radius: 7)
                .onAppear {
                    guard isCurrent,
                          !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                    withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: false)) {
                        dashPhase = -15
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(accent.opacity(isCurrent ? 1 : 0.25), lineWidth: isCurrent ? 2.5 : 1.5)
                .shadow(color: accent.opacity(isCurrent ? 0.55 : 0), radius: 8)
        }
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
