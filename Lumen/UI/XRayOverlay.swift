import AppKit
import Combine
import SwiftUI

/// X-ray mode — the Glass Pipeline. A toggleable overlay where Lumen
/// renders its own architecture running live: every stage of the current
/// turn (listen → capture → perceive → reason → stream → narrate) with
/// real timing badges, driven by actual pipeline events. The architecture
/// diagram and the demo are the same artifact, and the timings are honest
/// because they ARE the implementation.
@MainActor
final class XRayModel: ObservableObject {
    enum Status {
        case pending, active, done, failed
    }

    struct Stage: Identifiable {
        let id: String
        let title: String
        let subsystem: String
        var detail: String = ""
        var status: Status = .pending
        var ms: Int?
    }

    @Published var stages: [Stage] = []
    @Published var headline = ""
    @Published var destination = ""
    @Published var receipt: NSImage?
    @Published var costLine = ""

    func reset(provider: String) {
        headline = provider
        receipt = nil
        costLine = ""
        switch ProviderRouting.resolve(
            kindRaw: ProviderSettings.kind.rawValue,
            hasAnthropicKey: KeychainStore.load(account: "anthropic") != nil
        ) {
        case .anthropic:
            destination = "api.anthropic.com · TLS"
        case .openAICompatible:
            destination = ProviderSettings.baseURL.contains("localhost") || ProviderSettings.baseURL.contains("127.0.0.1")
                ? "localhost — fully local, nothing leaves this Mac"
                : ProviderSettings.baseURL
        case .demo:
            destination = "no network — offline demo fixture"
        }
        stages = [
            Stage(id: "listen", title: "Listen", subsystem: "Apple Speech · on-device"),
            Stage(id: "capture", title: "Capture", subsystem: "ScreenCaptureKit"),
            Stage(id: "perceive", title: "Perceive", subsystem: "AXUIElement tree"),
            Stage(id: "reason", title: "Reason", subsystem: provider),
            Stage(id: "stream", title: "Stream", subsystem: "SSE → caption + tags"),
            Stage(id: "narrate", title: "Narrate", subsystem: "AVSpeechSynthesizer · on-device"),
        ]
    }

    func update(_ id: String, status: Status, detail: String? = nil, ms: Int? = nil) {
        guard let index = stages.firstIndex(where: { $0.id == id }) else { return }
        stages[index].status = status
        if let detail { stages[index].detail = detail }
        if let ms { stages[index].ms = ms }
    }
}

@MainActor
final class XRayOverlayController {
    static let enabledKey = "xray.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    let model = XRayModel()
    private var panel: NSPanel?
    private var hosting: NSHostingView<XRayView>?
    private var resizeSubscription: AnyCancellable?

    func showIfEnabled() {
        guard Self.isEnabled, let screen = NSScreen.lumen else {
            hide()
            return
        }
        if panel == nil {
            makePanel(on: screen)
        }
        resizeToFit()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The card's content changes mid-turn (timings, the receipt image) —
    /// keep the panel sized to fit, ALWAYS pinned to the screen's top-right.
    /// (Positioning must run even when the size didn't change: a freshly
    /// created panel is born at AppKit's origin — bottom-left.)
    private func resizeToFit() {
        guard let panel, let hosting, let screen = NSScreen.lumen else { return }
        let size = hosting.fittingSize
        if abs(size.height - panel.frame.height) > 0.5 {
            panel.setContentSize(size)
        }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - panel.frame.width - 16,
            y: frame.maxY - panel.frame.height - 16
        ))
    }

    private func makePanel(on screen: NSScreen) {
        let hosting = NSHostingView(rootView: XRayView(model: model) { [weak self] in
            // The ✕ — turn the mode off, not just hide the panel.
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            self?.hide()
        })
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

        resizeSubscription = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resizeToFit() }
            }
    }
}

struct XRayView: View {
    @ObservedObject var model: XRayModel
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .foregroundStyle(.teal)
                Text("X-Ray — live pipeline")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close X-Ray mode")
                .handCursor()
            }
            Text(model.headline)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.stages.enumerated()), id: \.element.id) { index, stage in
                    StageRow(stage: stage, isLast: index == model.stages.count - 1)
                }
            }

            if !model.costLine.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("EST. PAYLOAD")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(model.costLine)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if let receipt = model.receipt {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WHAT LEFT THIS MAC")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Image(nsImage: receipt)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 132)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.teal.opacity(0.4), lineWidth: 1)
                        )
                }
            }

            // The guarantees, stated where the evidence is.
            VStack(alignment: .leading, spacing: 5) {
                Text("PRIVACY")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                PrivacyRow(icon: "mic", text: "Voice transcribed on-device — audio never leaves this Mac")
                PrivacyRow(icon: "camera.viewfinder", text: "Captures only while ⌃⌥ is held — nothing in between")
                PrivacyRow(icon: "network", text: model.destination)
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .topLeading)
        .background(background)
    }

    @ViewBuilder
    private var background: some View {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 18)
                .fill(.clear)
                .glassEffect(in: .rect(cornerRadius: 18))
        } else {
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
        }
    }
}

private struct PrivacyRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.teal)
                .frame(width: 14)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StageRow: View {
    let stage: XRayModel.Stage
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                statusIcon
                    .frame(width: 16, height: 16)
                if !isLast {
                    Rectangle()
                        .fill(.secondary.opacity(0.25))
                        .frame(width: 1.5, height: 26)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(stage.title)
                        .font(.callout.weight(stage.status == .active ? .semibold : .regular))
                        .foregroundStyle(stage.status == .pending ? .secondary : .primary)
                    Spacer()
                    if let ms = stage.ms {
                        Text("\(ms) ms")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.teal)
                    }
                }
                Text(stage.detail.isEmpty ? stage.subsystem : stage.detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch stage.status {
        case .pending:
            Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1.5)
        case .active:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.teal)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }
}
