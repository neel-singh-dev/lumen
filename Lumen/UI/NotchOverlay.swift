import AppKit
import SwiftUI

/// Lumen's home — the notch. One continuous black shape extends the
/// physical notch: a slim handle at rest, a status capsule while working
/// (waveform + your words live → loader → speaker), and on HOVER it
/// unfolds into the full control panel — provider, credentials, toggles,
/// actions — all inline, no dialogs, no popups. Answer text appears only
/// when the user opts into the transcript (off by default; Lumen speaks).
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

    /// The PHYSICAL notch's dimensions — at rest the handle matches them
    /// exactly, sitting invisibly inside the hardware dead zone, so any
    /// expansion appears to grow out of the notch itself.
    @Published var notchSize = CGSize(width: 200, height: 32)

    /// Called by the view when it toggles something that changes layout.
    var onLayoutChange: (() -> Void)?
}

/// Wiring from the settings panel back into the app.
struct NotchActions {
    var openHistory: () -> Void = {}
    var welcomeTour: () -> Void = {}
    var agentPreview: () -> Void = {}
    var xrayChanged: () -> Void = {}
}

@MainActor
final class NotchOverlayController {
    static let transcriptKey = "transcript.enabled"

    /// OFF by default — Lumen speaks; text is an opt-in.
    static var transcriptEnabled: Bool {
        UserDefaults.standard.bool(forKey: transcriptKey)
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

    /// Shows text below the notch. For answers this only happens when the
    /// transcript opt-in is on; errors always surface (rare, actionable).
    func showTranscript(_ text: String, isError: Bool = false) {
        ensurePanel()
        let becameVisible = !model.transcriptVisible
        model.transcript = text
        model.isError = isError
        model.transcriptVisible = true
        if becameVisible { resize() }
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

    /// Real hardware-notch geometry; a Dynamic-Island-sized tab elsewhere.
    private static func notchMetrics(for screen: NSScreen) -> CGSize {
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            let height = screen.safeAreaInsets.top
            return CGSize(width: width, height: max(height, 28))
        }
        return CGSize(width: 200, height: 30)
    }

    private func ensurePanel() {
        guard panel == nil, let screen = NSScreen.main else { return }
        model.notchSize = Self.notchMetrics(for: screen)
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
        panel.acceptsMouseMovedEvents = true
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

    @State private var hoverCloseTask: Task<Void, Never>?

    private var expanded: Bool {
        model.showSettings || model.transcriptVisible
    }

    var body: some View {
        VStack(spacing: 0) {
            notchBody
            Spacer(minLength: 0)
        }
        .frame(width: max(560, model.notchSize.width + 200), alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .fontDesign(.rounded)
    }

    /// One continuous shape growing out of the notch — never separate cards.
    private var notchBody: some View {
        VStack(spacing: 0) {
            statusRow
            if model.showSettings {
                NotchSettingsView(actions: actions)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            } else if model.transcriptVisible {
                transcriptBody
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .frame(width: bodyWidth)
        .background(notchShape)
        .contentShape(
            UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius)
        )
        .onHover { hover(inside: $0) }
    }

    /// At rest: exactly the hardware notch. Expanded: grown outward from it.
    private var bodyWidth: CGFloat {
        let base = model.notchSize.width
        if model.showSettings { return max(410, base + 120) }
        if model.transcriptVisible { return max(500, base + 160) }
        switch model.phase {
        case .idle: return base
        case .listening(let partial): return partial.isEmpty ? base + 60 : base + 260
        case .thinking, .speaking, .answering: return base + 40
        }
    }

    private var cornerRadius: CGFloat {
        expanded ? 24 : (isSlim ? 10 : 14)
    }

    private var isSlim: Bool {
        if case .idle = model.phase { return !expanded }
        return false
    }

    /// Pure black at rest — indistinguishable from the hardware. Depth cues
    /// (hairline, shadow, inner light) appear only once expanded, so the
    /// boundary never betrays itself while idle.
    private var notchShape: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius)
            .fill(.black)
            .overlay(
                UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(isSlim ? 0 : 0.05), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius)
                    .strokeBorder(.white.opacity(isSlim ? 0 : 0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isSlim ? 0 : 0.5), radius: 14, y: 6)
    }

    // MARK: Status row

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 9) {
            statusIcon
            statusText
        }
        .padding(.horizontal, isSlim ? 0 : 18)
        .frame(height: statusHeight)
        .frame(maxWidth: .infinity)
    }

    private var statusHeight: CGFloat {
        isSlim ? model.notchSize.height : model.notchSize.height + 12
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.phase {
        case .idle:
            if expanded {
                Image(systemName: "rays")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(accentGradient)
            }
        case .listening:
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(accentGradient)
        case .thinking:
            ProgressView().controlSize(.small).tint(.white)
        case .speaking:
            Image(systemName: "speaker.wave.2.fill")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(accentGradient)
        case .answering:
            Image(systemName: "ellipsis")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(accentGradient)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch model.phase {
        case .idle:
            if expanded {
                Text("Lumen")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Circle().fill(.teal).frame(width: 5, height: 5)
            }
        case .listening(let partial):
            Text(partial.isEmpty ? "Listening…" : partial)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            Text("Thinking…")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        case .speaking:
            Text("Speaking")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        case .answering:
            Text("Working")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var accentGradient: LinearGradient {
        LinearGradient(colors: [.teal, .mint], startPoint: .top, endPoint: .bottom)
    }

    // MARK: Transcript (opt-in; errors always)

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let receipt = model.receipt {
                HStack(spacing: 10) {
                    Image(nsImage: receipt)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        )
                    Text(model.receiptNote)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            }
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 8) {
                    if model.isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(model.transcript.isEmpty ? "…" : model.transcript)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: model.isError ? 60 : 150)
        }
    }

    // MARK: Hover

    /// Hover opens, leaving closes after a grace period (so the mouse can
    /// travel from the handle down into the panel without it collapsing).
    private func hover(inside: Bool) {
        hoverCloseTask?.cancel()
        if inside {
            if !model.showSettings {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    model.showSettings = true
                }
                model.onLayoutChange?()
            }
        } else {
            hoverCloseTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    model.showSettings = false
                }
                model.onLayoutChange?()
            }
        }
    }
}

// MARK: - Settings — everything inline, no popups

private struct NotchSettingsView: View {
    let actions: NotchActions

    @AppStorage(ProviderSettings.kindKey) private var providerKind = ProviderKind.anthropic.rawValue
    @AppStorage(ProviderSettings.baseURLKey) private var baseURL = "http://localhost:11434"
    @AppStorage(ProviderSettings.modelKey) private var localModel = "qwen3-vl"
    @AppStorage(Narrator.enabledKey) private var speakAnswers = true
    @AppStorage(NotchOverlayController.transcriptKey) private var showTranscript = false
    @AppStorage(XRayOverlayController.enabledKey) private var xrayMode = false

    @State private var apiKeyDraft = ""
    @State private var keySaved = KeychainStore.load(account: "anthropic") != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Provider cards
            HStack(spacing: 8) {
                providerCard(
                    kind: ProviderKind.anthropic.rawValue,
                    icon: "sparkle",
                    title: "Claude",
                    subtitle: "api.anthropic.com"
                )
                providerCard(
                    kind: ProviderKind.openaiCompatible.rawValue,
                    icon: "desktopcomputer",
                    title: "Local",
                    subtitle: "fully on this Mac"
                )
            }

            // Inline credentials — no dialogs.
            if providerKind == ProviderKind.anthropic.rawValue {
                VStack(alignment: .leading, spacing: 6) {
                    field(icon: "key.fill",
                          placeholder: keySaved ? "Saved in Keychain — paste to replace" : "Anthropic API key · press ⏎",
                          secure: true, text: $apiKeyDraft) {
                        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        KeychainStore.save(trimmed, account: "anthropic")
                        apiKeyDraft = ""
                        keySaved = true
                    }
                    if keySaved {
                        Label("Stored in your Keychain — never on disk", systemImage: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.teal.opacity(0.8))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    field(icon: "network", placeholder: "http://localhost:11434", secure: false, text: $baseURL) {}
                    field(icon: "cpu", placeholder: "qwen3-vl", secure: false, text: $localModel) {}
                    Text("Any OpenAI-compatible endpoint · localhost = nothing leaves this Mac")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            // Behavior well
            VStack(spacing: 0) {
                toggleRow("speaker.wave.2.fill", "Speak answers", "Voice narration, on-device", $speakAnswers)
                hairline
                toggleRow("text.quote", "Show transcript", "Answer text below the notch", $showTranscript)
                hairline
                toggleRow("waveform.path.ecg", "X-Ray", "Live pipeline & privacy evidence", $xrayMode)
                    .onChange(of: xrayMode) { actions.xrayChanged() }
            }
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13))

            // Explore grid
            HStack(spacing: 8) {
                exploreButton("clock.arrow.circlepath", "History", action: actions.openHistory)
                exploreButton("sparkles", "Tour", action: actions.welcomeTour)
                exploreButton("wand.and.stars", "Agent", action: actions.agentPreview)
            }

            HStack {
                Text("on-device by default")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.25))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    // MARK: pieces

    private var hairline: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 40)
    }

    private func providerCard(kind: String, icon: String, title: String, subtitle: String) -> some View {
        let selected = providerKind == kind
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                providerKind = kind
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(selected ? AnyShapeStyle(LinearGradient(colors: [.teal, .mint], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(.white.opacity(0.5)))
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.7))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(selected ? 0.5 : 0.3))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(selected ? .teal.opacity(0.14) : .white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(selected ? .teal.opacity(0.55) : .white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func field(icon: String, placeholder: String, secure: Bool, text: Binding<String>, onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.teal)
                .frame(width: 16)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.caption)
            .foregroundStyle(.white)
            .onSubmit(onSubmit)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func toggleRow(_ icon: String, _ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.teal)
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.92))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.teal)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func exploreButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(LinearGradient(colors: [.teal, .mint], startPoint: .top, endPoint: .bottom))
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
