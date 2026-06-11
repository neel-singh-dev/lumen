import AppKit
import SwiftUI

/// Borderless windows can't become key by default — which silently makes
/// every text field inside them dead to the keyboard. This is the standard
/// Spotlight-style fix: keyable, but still non-activating (clicking a field
/// grabs keyboard focus without bringing the whole app forward).
final class KeyableNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

extension View {
    /// macOS SwiftUI doesn't show the pointing hand on buttons by itself —
    /// every clickable element opts in.
    func handCursor() -> some View {
        onHover { inside in
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

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

    /// True while the panel holds keyboard focus (user typing in a field) —
    /// the hover-close must not yank the panel away mid-keystroke.
    var isPanelKey: (() -> Bool)?
}

/// Wiring from the settings panel back into the app.
struct NotchActions {
    var openHistory: () -> Void = {}
    var replay: () -> Void = {}
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

    init() {
        // Displays come and go (lid, docks, projectors) — re-anchor to the
        // notched screen whenever the configuration changes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let screen = NSScreen.lumen else { return }
                self.model.notchSize = Self.notchMetrics(for: screen)
                if let panel = self.panel {
                    self.position(panel, on: screen)
                }
            }
        }
    }

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

    /// Collapses everything — transcript, receipt, settings — back to the
    /// invisible handle.
    func clearOverlay() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            model.transcriptVisible = false
            model.transcript = ""
            model.isError = false
            model.receipt = nil
            model.phase = .idle
            model.showSettings = false
        }
        resize()
    }

    /// Folds the settings panel without touching anything else.
    func closeSettings() {
        guard model.showSettings else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            model.showSettings = false
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
        guard panel == nil, let screen = NSScreen.lumen else { return }
        model.notchSize = Self.notchMetrics(for: screen)
        let hosting = NSHostingView(rootView: NotchView(model: model, actions: actions))
        let panel = KeyableNotchPanel(
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
        model.isPanelKey = { [weak panel] in panel?.isKeyWindow ?? false }

        position(panel, on: screen)
        panel.orderFrontRegardless()
    }

    private func resize() {
        guard let panel, let hosting, let screen = NSScreen.lumen else { return }
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
    /// Active widths leave generous "ears" either side of the dead zone.
    private var bodyWidth: CGFloat {
        let base = model.notchSize.width
        if model.showSettings { return max(440, base + 220) }
        if model.transcriptVisible { return max(520, base + 240) }
        switch model.phase {
        case .idle: return base
        case .listening(let partial): return partial.isEmpty ? base + 200 : base + 360
        case .thinking, .speaking, .answering: return base + 220
        }
    }

    /// Visible strip either side of the physical notch.
    private var earWidth: CGFloat {
        max(0, (bodyWidth - model.notchSize.width) / 2)
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

    // MARK: Status row — Dynamic-Island ears.
    // The center of this row is the HARDWARE notch (dead pixels), so
    // content lives in the ears: label on the left, living icon on the
    // right, never behind the housing.

    @ViewBuilder
    private var statusRow: some View {
        if isSlim {
            Color.clear.frame(height: statusHeight)
        } else {
            HStack(spacing: 0) {
                leftEar
                    .padding(.leading, 16)
                    .frame(width: earWidth, alignment: .leading)
                Color.clear
                    .frame(width: model.notchSize.width)
                rightEar
                    .padding(.trailing, 16)
                    .frame(width: earWidth, alignment: .trailing)
            }
            .frame(height: statusHeight)
        }
    }

    private var statusHeight: CGFloat {
        model.notchSize.height
    }

    /// Left ear: what's happening, in words.
    @ViewBuilder
    private var leftEar: some View {
        switch model.phase {
        case .idle:
            if expanded {
                HStack(spacing: 6) {
                    Image(systemName: "rays")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accentGradient)
                    Text("Lumen")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
        case .listening(let partial):
            Text(partial.isEmpty ? "Listening…" : partial)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
        case .thinking:
            Text("Thinking…")
                .font(.caption.weight(.medium))
                .foregroundStyle(DT.Ink.primary)
        case .speaking:
            Text("Speaking")
                .font(.caption.weight(.medium))
                .foregroundStyle(DT.Ink.primary)
        case .answering:
            Text("Working")
                .font(.caption.weight(.medium))
                .foregroundStyle(DT.Ink.primary)
        }
    }

    /// Right ear: the living indicator.
    @ViewBuilder
    private var rightEar: some View {
        switch model.phase {
        case .idle:
            if expanded {
                Circle().fill(.teal).frame(width: 6, height: 6)
                    .shadow(color: .teal.opacity(0.8), radius: 3)
            }
        case .listening:
            Image(systemName: "waveform")
                .font(.body)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(accentGradient)
        case .thinking:
            Image(systemName: "sparkle")
                .font(.body)
                .symbolEffect(.pulse, options: .repeating)
                .foregroundStyle(accentGradient)
        case .speaking:
            Image(systemName: "speaker.wave.2.fill")
                .font(.body)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(accentGradient)
        case .answering:
            Image(systemName: "ellipsis")
                .font(.body)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(accentGradient)
        }
    }

    private var accentGradient: LinearGradient {
        DT.accent
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
                                .strokeBorder(DT.Ink.hairline, lineWidth: 1)
                        )
                    Text(model.receiptNote)
                        .font(.caption2)
                        .foregroundStyle(DT.Ink.secondary)
                        .lineLimit(2)
                }
                Rectangle().fill(DT.Ink.well).frame(height: 1)
            }
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 8) {
                    if model.isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(model.transcript.isEmpty ? "…" : model.transcript)
                        .font(.callout)
                        .foregroundStyle(DT.Ink.primary)
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
                // Never close while the user is typing in a field.
                guard !(model.isPanelKey?() ?? false) else { return }
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
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Provider cards
            HStack(spacing: 8) {
                providerCard(kind: ProviderKind.anthropic.rawValue, icon: "sparkle",
                             title: "Claude", subtitle: "api.anthropic.com")
                providerCard(kind: ProviderKind.openaiCompatible.rawValue, icon: "desktopcomputer",
                             title: "Local", subtitle: "on this Mac")
                providerCard(kind: ProviderKind.demo.rawValue, icon: "play.circle",
                             title: "Demo", subtitle: "offline")
            }

            // Inline credentials — no dialogs. Demo shows neither.
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
            } else if providerKind == ProviderKind.openaiCompatible.rawValue {
                VStack(alignment: .leading, spacing: 6) {
                    field(icon: "network", placeholder: "http://localhost:11434", secure: false, text: $baseURL) {}
                    field(icon: "cpu", placeholder: "qwen3-vl", secure: false, text: $localModel) {}
                    Text("Any OpenAI-compatible endpoint · localhost = nothing leaves this Mac")
                        .font(.caption2)
                        .foregroundStyle(DT.Ink.tertiary)
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
            .background(DT.Ink.well, in: RoundedRectangle(cornerRadius: 13))

            // Explore grid
            HStack(spacing: 8) {
                exploreButton("clock.arrow.circlepath", "History", action: actions.openHistory)
                exploreButton("memories", "Replay", action: actions.replay)
                exploreButton("sparkles", "Tour", action: actions.welcomeTour)
                exploreButton("wand.and.stars", "Agent", action: actions.agentPreview)
            }

            HStack {
                Text("on-device by default")
                    .font(.caption2)
                    .foregroundStyle(DT.Ink.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(DT.Ink.tertiary)
                    .accessibilityLabel("Quit Lumen")
                    .handCursor()
            }
        }
    }

    // MARK: pieces

    private var hairline: some View {
        Rectangle()
            .fill(DT.Ink.hairline)
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
                    .foregroundStyle(selected ? AnyShapeStyle(DT.accent) : AnyShapeStyle(DT.Ink.secondary))
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(selected ? DT.Ink.primary : DT.Ink.secondary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(selected ? DT.Ink.secondary : DT.Ink.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(selected ? Color.teal.opacity(0.14) : DT.Ink.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(selected ? Color.teal.opacity(0.55) : DT.Ink.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Provider: \(title)")
        .handCursor()
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
            .foregroundStyle(DT.Ink.primary)
            .focused($fieldFocused)
            .onSubmit(onSubmit)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(DT.Ink.well, in: RoundedRectangle(cornerRadius: DT.radiusWell))
        .overlay(
            RoundedRectangle(cornerRadius: DT.radiusWell)
                .strokeBorder(fieldFocused ? Color.teal.opacity(0.5) : DT.Ink.hairline, lineWidth: 1)
        )
    }

    private func toggleRow(_ icon: String, _ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.teal)
                .frame(width: 24, height: 24)
                .background(DT.Ink.well, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(DT.Ink.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(DT.Ink.tertiary)
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
        // The whole row is the control, not just the tiny switch.
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                binding.wrappedValue.toggle()
            }
        }
        .accessibilityLabel(title)
        .handCursor()
    }

    private func exploreButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(DT.accent)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(DT.Ink.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(DT.Ink.well, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DT.Ink.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .handCursor()
    }
}
