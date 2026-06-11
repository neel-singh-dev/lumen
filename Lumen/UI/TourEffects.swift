import AppKit
import SwiftUI

/// Theater for the welcome tour — the "this is AI" ambience layer:
/// an Apple-Intelligence-style glow breathing around the screen edges,
/// sonar ripples emanating from the notch as it introduces itself, and
/// pulsing ⌃ ⌥ keycaps for the hotkey lesson. Full-screen, click-through,
/// cleared the moment the user acts (their first summon ends the show).
@MainActor
final class TourFXModel: ObservableObject {
    @Published var glow = false
    @Published var ripples = false
    @Published var keycaps = false
}

@MainActor
final class TourFXController {
    let model = TourFXModel()
    private var panel: NSPanel?

    func set(glow: Bool? = nil, ripples: Bool? = nil, keycaps: Bool? = nil) {
        ensurePanel()
        withAnimation(.easeInOut(duration: 0.5)) {
            if let glow { model.glow = glow }
            if let ripples { model.ripples = ripples }
            if let keycaps { model.keycaps = keycaps }
        }
        panel?.orderFrontRegardless()
    }

    func clear() {
        withAnimation(.easeOut(duration: 0.4)) {
            model.glow = false
            model.ripples = false
            model.keycaps = false
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.panel?.orderOut(nil)
        }
    }

    private func ensurePanel() {
        guard panel == nil, let screen = NSScreen.lumen else { return }
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
        panel.contentView = NSHostingView(rootView: TourFXView(model: model))
        panel.setFrame(screen.frame, display: true)
        self.panel = panel
    }
}

struct TourFXView: View {
    @ObservedObject var model: TourFXModel

    var body: some View {
        ZStack {
            if model.glow {
                EdgeGlowView()
                    .transition(.opacity)
            }
            if model.ripples {
                NotchRipplesView()
                    .transition(.opacity)
            }
            if model.keycaps {
                KeycapsView()
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

// MARK: - Edge glow (the "AI is present" ambience)

private struct EdgeGlowView: View {
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        if reduceMotion {
            glow(angle: 0, breathe: 0.8)
        } else {
            // Time-driven, transaction-free — repeatForever-in-onAppear
            // leaks into insertion transitions and breaks rendering.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let angle = (t * 45).truncatingRemainder(dividingBy: 360)
                let breathe = 0.45 + 0.4 * abs(sin(t * .pi / 2.2))
                glow(angle: angle, breathe: breathe)
            }
        }
    }

    private func glow(angle: Double, breathe: Double) -> some View {
        GeometryReader { geo in
            let gradient = AngularGradient(
                colors: [.teal, .blue, .purple, .mint, .teal],
                center: .center
            )
            ZStack {
                // Soft outer bloom
                gradient
                    .rotationEffect(.degrees(angle))
                    .frame(width: geo.size.width * 1.6, height: geo.size.height * 1.6)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .mask(
                        RoundedRectangle(cornerRadius: 26)
                            .stroke(lineWidth: 22)
                            .padding(8)
                    )
                    .blur(radius: 18)
                    .opacity(breathe)
                // Crisp inner line
                gradient
                    .rotationEffect(.degrees(angle))
                    .frame(width: geo.size.width * 1.6, height: geo.size.height * 1.6)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .mask(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(lineWidth: 3)
                            .padding(5)
                    )
                    .blur(radius: 1)
                    .opacity(min(1, breathe + 0.2))
            }
        }
    }
}

// MARK: - Sonar ripples from the notch

private struct NotchRipplesView: View {
    var body: some View {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            EmptyView()
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                GeometryReader { geo in
                    ZStack {
                        ForEach(0..<3, id: \.self) { index in
                            let progress = ((t + Double(index) * 0.8)
                                .truncatingRemainder(dividingBy: 2.4)) / 2.4
                            Circle()
                                .stroke(
                                    LinearGradient(colors: [.teal, .mint], startPoint: .top, endPoint: .bottom),
                                    lineWidth: 2
                                )
                                .frame(width: 70, height: 70)
                                .scaleEffect(0.4 + 4.1 * progress)
                                .opacity(0.8 * (1 - progress))
                        }
                    }
                    .position(x: geo.size.width / 2, y: 16)
                }
            }
        }
    }
}

// MARK: - Keycaps (the hotkey lesson)

private struct KeycapsView: View {
    var body: some View {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            caps(scale: 1)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                caps(scale: 1 - 0.05 * abs(sin(t * .pi / 0.9)))
            }
        }
    }

    private func caps(scale: Double) -> some View {
        GeometryReader { geo in
            HStack(spacing: 18) {
                keycap(symbol: "⌃", name: "control")
                Text("+")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.5))
                keycap(symbol: "⌥", name: "option")
            }
            .scaleEffect(scale)
            .position(x: geo.size.width / 2, y: geo.size.height * 0.62)
        }
    }

    private func keycap(symbol: String, name: String) -> some View {
        VStack(spacing: 5) {
            Text(symbol)
                .font(.system(size: 36, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
            Text(name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(width: 92, height: 92)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.16), Color(white: 0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    LinearGradient(
                        colors: [.teal.opacity(0.6), .white.opacity(0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
        )
        .shadow(color: .teal.opacity(0.35), radius: 16, y: 4)
    }
}
