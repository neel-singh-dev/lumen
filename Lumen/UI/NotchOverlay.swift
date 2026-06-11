import AppKit
import SwiftUI

/// Lumen's home — the notch. A slim black handle extends the notch at all
/// times; it expands into a status capsule while working (waveform + live
/// words → loader → speaker), optionally unfolds a transcript card while
/// answering, and clicking it opens the settings panel. Status, content,
/// and controls all live here; the menu bar remains as a fallback.
///
/// The panel is transparent and borderless — clicks land only on visible
/// pixels (AppKit hit-tests transparency), so the invisible margins pass
/// through to whatever is underneath.
@MainActor
final class NotchModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening(String)
        case thinking
        case speaking
        case answering
    }

    @Published var phase: Phase = .idle
    @Published var transcript = ""
    @Published var transcriptVisible = false
    @Published var isError = false
    @Published var receipt: NSImage?
    @Published var receiptNote = ""
    @Published var showSettings = false

    /// Called by the view when it toggles something that changes layout.
    var onLayoutChange: (() -> Void)?
}

/// Wiring from the settings panel back into the app.
struct NotchActions {
    var setAPIKey: () -> Void = {}
    var configureLocal: () -> Void = {}
    var openHistory: () -> Void = {}
    var welcomeTour: () -> Void = {}
    var agentPreview: () -> Void = {}
    var xrayChanged: () -> Void = {}
}

@MainActor
final class NotchOverlayController {
    static let transcriptKey = "transcript.enabled"

    static var transcriptEnabled: Bool {
        UserDefaults.standard.object(forKey: transcriptKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: transcriptKey)
    }

    let model = NotchModel()
    var actions = NotchActions()

    private var panel: NSPanel?
    private var hosting: NSHostingView<NotchView>?

    func set(_ phase: NotchModel.Phase) {
        ensurePanel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
            model.phase = phase
        }
        resize()
    }

    /// Streams answer text (or an error) into the notch transcript card.
    func showTranscript(_ text: String, isError: Bool = false) {
        ensurePanel()
        let becameVisible = !model.transcriptVisible
        model.transcript = text
        model.isError = isError
        model.transcriptVisible = true
        if becameVisible {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {}
            resize()
        }
    }

    func setReceipt(_ image: NSImage?, note: String) {
        model.receipt = image
        model.receiptNote = note
    }

    /// Collapses transcript and receipt back to the slim handle.
    func clearOverlay() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            model.transcriptVisible = false
            model.transcript = ""
            model.isError = false
            model.receipt = nil
            model.phase = .idle
        }
        resize()
    }

    // MARK: - Panel

    private func ensurePanel() {
        guard panel == nil, let screen = NSScreen.main else { return }
        let hosting = NSHostingView(rootView: NotchView(model: model, actions: actions))
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
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting

        model.onLayoutChange = { [weak self] in self?.resize() }

        position(panel, on: screen)
        panel.orderFrontRegardless()
    }

    private func resize() {
        guard let panel, let hosting, let screen = NSScreen.main else { return }
        let size = hosting.fittingSize
        guard abs(size.height - panel.frame.height) > 0.5
            || abs(size.width - panel.frame.width) > 0.5 else { return }
        panel.setContentSize(size)
        position(panel, on: screen)
    }

    private func position(_ panel: NSPanel, on screen: NSScreen) {
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - panel.frame.width / 2,
            y: screen.frame.maxY - panel.frame.height
        ))
    }
}

// MARK: - View

struct NotchView: View {
    @ObservedObject var model: NotchModel
    let actions: NotchActions

    var body: some View {
        VStack(spacing: 8) {
            capsule
            if model.showSettings {
                NotchSettingsView(model: model, actions: actions)
            } else if model.transcriptVisible {
                transcriptCard
            }
        }
        .padding(.bottom, 10)
        .frame(width: 560, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Capsule (the notch extension)

    @ViewBuilder
    private var capsule: some View {
        HStack(spacing: 9) {
            icon
            text
        }
        .padding(.horizontal, capsuleWidth > 140 ? 16 : 0)
        .frame(width: capsuleWidth, height: capsuleHeight)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                .fill(.black)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        )
        .contentShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
        .onTapGesture {
            model.showSettings.toggle()
            model.onLayoutChange?()
        }
    }

    private var capsuleWidth: CGFloat {
        switch model.phase {
        case .idle: return model.showSettings ? 200 : 132
        case .listening(let partial): return partial.isEmpty ? 240 : 460
        case .thinking: return 200
        case .speaking: return 220
        case .answering: return 220
        }
    }

    private var capsuleHeight: CGFloat {
        if case .idle = model.phase, !model.showSettings { return 14 }
        return 37
    }

    @ViewBuilder
    private var icon: some View {
        switch model.phase {
        case .idle:
            if model.showSettings {
                Image(systemName: "rays").foregroundStyle(.teal).font(.caption)
            }
        case .listening:
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(.teal)
        case .thinking:
            ProgressView().controlSize(.small).tint(.white)
        case .speaking:
            Image(systemName: "speaker.wave.2.fill")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(.teal)
        case .answering:
            Image(systemName: "text.alignleft").foregroundStyle(.teal)
        }
    }

    @ViewBuilder
    private var text: some View {
        switch model.phase {
        case .idle:
            if model.showSettings {
                Text("Lumen").font(.caption.weight(.medium)).foregroundStyle(.white)
            }
        case .listening(let partial):
            Text(partial.isEmpty ? "Listening…" : partial)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            Text("Thinking…").font(.caption).foregroundStyle(.white.opacity(0.85))
        case .speaking:
            Text("Lumen").font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.85))
        case .answering:
            Text("Answering…").font(.caption).foregroundStyle(.white.opacity(0.85))
        }
    }

    // MARK: Transcript card (opt-in, unfolds from the notch)

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Receipt strip — shown here only when X-Ray isn't already
            // showing the same evidence.
            if let receipt = model.receipt {
                HStack(spacing: 8) {
                    Image(nsImage: receipt)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(model.receiptNote)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
            }
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 8) {
                    if model.isError {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text(model.transcript.isEmpty ? "…" : model.transcript)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 150)
            Text("⌃⌥ ask again · click the notch for settings")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(14)
        .frame(width: 480)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.black.opacity(0.92))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Settings panel

private struct NotchSettingsView: View {
    @ObservedObject var model: NotchModel
    let actions: NotchActions

    @AppStorage(ProviderSettings.kindKey) private var providerKind = ProviderKind.anthropic.rawValue
    @AppStorage(Narrator.enabledKey) private var speakAnswers = true
    @AppStorage(NotchOverlayController.transcriptKey) private var showTranscript = true
    @AppStorage(XRayOverlayController.enabledKey) private var xrayMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Provider
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("PROVIDER")
                Picker("", selection: $providerKind) {
                    Text("Claude").tag(ProviderKind.anthropic.rawValue)
                    Text("Local · Ollama").tag(ProviderKind.openaiCompatible.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 8) {
                    smallButton("API Key…", action: actions.setAPIKey)
                    smallButton("Local endpoint…", action: actions.configureLocal)
                }
            }

            // Behavior
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("LUMEN")
                toggleRow("speaker.wave.2", "Speak answers", $speakAnswers)
                toggleRow("text.quote", "Show transcript", $showTranscript)
                toggleRow("waveform.path.ecg", "X-Ray pipeline", $xrayMode)
                    .onChange(of: xrayMode) { actions.xrayChanged() }
            }

            // Actions
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("EXPLORE")
                HStack(spacing: 8) {
                    smallButton("History", action: actions.openHistory)
                    smallButton("Welcome tour", action: actions.welcomeTour)
                    smallButton("Agent demo", action: actions.agentPreview)
                }
            }

            HStack {
                Spacer()
                Button("Quit Lumen") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.black.opacity(0.92))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.35))
    }

    private func toggleRow(_ icon: String, _ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.teal)
                    .frame(width: 16)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(.teal)
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
