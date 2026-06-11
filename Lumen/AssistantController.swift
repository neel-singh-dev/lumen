import AppKit
import SwiftUI

/// The summon → listen → capture → reason → point loop.
///
/// Latency design: capture fires speculatively on chord-down (in parallel
/// with listening), so by chord-up the frame is usually already encoded and
/// the only remaining wait is the model itself — which streams.
@MainActor
final class AssistantController {
    private let hotkey = HotkeyMonitor()
    private let pointer = PointerOverlayController()
    private let capturer = ScreenCapturer()
    private let axReader = AXReader()
    private let transcriber = AppleSpeechTranscriber()
    private let narrator = Narrator()
    private let xray = XRayOverlayController()
    private let notch = NotchOverlayController()
    private let log = EventLog()
    private var turnStart = Date()

    private func elapsedMs() -> Int {
        Int(Date().timeIntervalSince(turnStart) * 1000)
    }

    /// Perception context for the in-flight turn, so speech-synced
    /// annotation delivery can resolve element ids when its beat arrives.
    private var currentCapture: ScreenCapture?
    private var currentSnapshot: AXReader.Snapshot?

    /// Resolved per request so a provider switch in the menu takes effect
    /// on the very next summon — including mid-demo hot-swaps.
    private var reasoner: Reasoner {
        switch ProviderSettings.kind {
        case .anthropic:
            return AnthropicReasoner()
        case .openaiCompatible:
            return OpenAICompatibleReasoner(
                baseURL: ProviderSettings.baseURL,
                model: ProviderSettings.model
            )
        }
    }

    private var history: [Exchange] = []
    private var captureTask: Task<ScreenCapture?, Never>?
    private var axTask: Task<AXReader.Snapshot?, Never>?
    private var answerTask: Task<Void, Never>?
    private var autoHideTask: Task<Void, Never>?

    func start() {
        AppleSpeechTranscriber.requestPermissions()
        notch.actions = NotchActions(
            openHistory: { [weak self] in self?.openHistory() },
            welcomeTour: { [weak self] in self?.runWelcomeTour() },
            agentPreview: { [weak self] in self?.runAgentPreview() },
            xrayChanged: { [weak self] in self?.xrayVisibilityChanged() }
        )
        notch.set(.idle)
        narrator.onSegmentStart = { [weak self] segment in
            guard let self else { return }
            // A new beat means narration is alive — no hiding mid-tour.
            self.autoHideTask?.cancel()
            self.notch.set(.speaking)
            for annotation in segment.annotations {
                self.apply(annotation, capture: self.currentCapture, snapshot: self.currentSnapshot)
            }
        }
        narrator.onIdle = { [weak self] in
            guard let self else { return }
            self.xray.model.update("narrate", status: .done, ms: self.elapsedMs())
            self.notch.set(.idle)
            self.autoHideTask?.cancel()
            self.autoHideTask = Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled else { return }
                self.notch.clearOverlay()
                self.pointer.hide()
            }
        }
        hotkey.onPushToTalkChanged = { [weak self] isDown in
            if isDown {
                self?.beginListening()
            } else {
                self?.finishListeningAndAnswer()
            }
        }
        hotkey.start()
        log.append("app.start")

        // First launch: Lumen introduces itself with its own machinery —
        // voice, pointer, highlights. The product demos the product.
        if !UserDefaults.standard.bool(forKey: "onboarding.done") {
            UserDefaults.standard.set(true, forKey: "onboarding.done")
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.runWelcomeTour()
            }
        }
    }

    /// Agent mode, the designed preview: a fully choreographed walkthrough
    /// of the trust protocol (plan preview → control handoff border →
    /// instant reclaim) over the REAL elements of the frontmost app. The
    /// execution layer is the deliberately mocked part — the trust UX is
    /// the design being demonstrated.
    func runAgentPreview() {
        answerTask?.cancel()
        narrator.stop()
        pointer.hide()
        autoHideTask?.cancel()
        log.append("agent.preview")

        notch.setReceipt(nil, note: "")
        let snapshotTask = Task.detached { [axReader] in
            axReader.snapshotFrontmostApp()
        }

        Task {
            let snapshot = await snapshotTask.value
            let targets = (snapshot?.elements ?? [])
                .filter { $0.roleName != "statictext" && !$0.label.isEmpty }
                .prefix(3)

            struct Beat {
                let text: String
                let action: () -> Void
            }
            var beats: [Beat] = [
                Beat(text: "This is a preview of agent mode — built on the same element grounding you've already seen.") { },
                Beat(text: "Before acting, I always show my full plan — every element I would touch, in order, before anything happens.") { },
            ]
            for (index, element) in targets.enumerated() {
                beats.append(Beat(text: "Step \(index + 1): \(element.label).") { [weak self] in
                    self?.pointer.enqueueHighlight(
                        rect: element.frame,
                        label: "Step \(index + 1) · \(element.label)"
                    )
                })
            }
            beats.append(Beat(text: "When you confirm, this border means I have the cursor. Touch the trackpad at any moment, and control is instantly yours again.") { [weak self] in
                self?.pointer.setControlBorder(true)
            })
            beats.append(Beat(text: "Every step is previewed, logged, and reversible. That's agent mode, the auditable way.") { [weak self] in
                self?.pointer.setControlBorder(false)
            })

            for beat in beats {
                narrator.enqueue(PointParser.Segment(text: beat.text, annotations: [])) { [weak self] in
                    beat.action()
                    if NotchOverlayController.transcriptEnabled {
                        self?.notch.showTranscript(beat.text)
                    }
                }
            }
        }
    }

    func runWelcomeTour() {
        guard let screen = NSScreen.main else { return }
        answerTask?.cancel()
        narrator.stop()
        pointer.hide()
        autoHideTask?.cancel()

        // Approximate menu-bar region (top-right) in screen points.
        let menuBarRect = CGRect(x: screen.frame.width - 290, y: 2, width: 270, height: 22)

        struct Beat {
            let text: String
            let highlight: CGRect?
        }
        let beats = [
            Beat(text: "Hi — I'm Lumen, your screen-aware assistant. I live up here in your menu bar.",
                 highlight: menuBarRect),
            Beat(text: "Hold Control and Option together, ask me anything about your screen, then let go.",
                 highlight: nil),
            Beat(text: "Before I answer, I always show you exactly what I captured — and between questions, I see nothing at all.",
                 highlight: nil),
            Beat(text: "Flip on X-Ray mode in my menu to watch my whole pipeline run live, timings and all. Let's get to work.",
                 highlight: menuBarRect),
        ]

        notch.setReceipt(nil, note: "")
        for beat in beats {
            narrator.enqueue(PointParser.Segment(text: beat.text, annotations: [])) { [weak self] in
                guard let self else { return }
                if NotchOverlayController.transcriptEnabled {
                    self.notch.showTranscript(beat.text)
                }
                if let rect = beat.highlight {
                    self.pointer.enqueueHighlight(rect: rect, label: "Lumen")
                }
            }
        }
        log.append("onboarding.tour")
    }

    func hideOverlays() {
        answerTask?.cancel()
        autoHideTask?.cancel()
        narrator.stop()
        pointer.hide()
        xray.hide()
        notch.clearOverlay()
    }

    private var historyWindow: NSWindow?

    func openHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView()))
            window.title = "Lumen — History"
            window.setContentSize(NSSize(width: 540, height: 480))
            window.isReleasedWhenClosed = false
            window.center()
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func xrayVisibilityChanged() {
        if XRayOverlayController.isEnabled {
            xray.model.reset(provider: ProviderSettings.displayName)
            xray.showIfEnabled()
        } else {
            xray.hide()
        }
    }

    func promptForAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Anthropic API Key"
        alert.informativeText = "Stored in your macOS Keychain — never written to disk or the repo."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            KeychainStore.save(field.stringValue.trimmingCharacters(in: .whitespaces), account: "anthropic")
            log.append("settings.api_key_set")
        }
    }

    func promptForLocalProvider() {
        let alert = NSAlert()
        alert.messageText = "Local / OpenAI-compatible Provider"
        alert.informativeText = """
        Works with Ollama (default), LM Studio, or any OpenAI-compatible \
        endpoint. For Ollama, pull a vision model first:  ollama pull qwen3-vl
        """
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 86))
        let urlLabel = NSTextField(labelWithString: "Base URL")
        urlLabel.frame = NSRect(x: 0, y: 62, width: 360, height: 16)
        let urlField = NSTextField(string: ProviderSettings.baseURL)
        urlField.frame = NSRect(x: 0, y: 38, width: 360, height: 24)
        urlField.placeholderString = "http://localhost:11434"
        let modelLabel = NSTextField(labelWithString: "Model")
        modelLabel.frame = NSRect(x: 0, y: 24, width: 360, height: 16)
        let modelField = NSTextField(string: ProviderSettings.model)
        modelField.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        modelField.placeholderString = "qwen3-vl"
        container.addSubview(urlLabel)
        container.addSubview(urlField)
        container.addSubview(modelLabel)
        container.addSubview(modelField)
        alert.accessoryView = container
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ProviderSettings.setLocal(
                baseURL: urlField.stringValue.trimmingCharacters(in: .whitespaces),
                model: modelField.stringValue.trimmingCharacters(in: .whitespaces)
            )
            UserDefaults.standard.set(ProviderKind.openaiCompatible.rawValue, forKey: ProviderSettings.kindKey)
            log.append("settings.local_provider", ["model": ProviderSettings.model])
        }
    }

    // MARK: - The loop

    private func beginListening() {
        answerTask?.cancel()
        autoHideTask?.cancel()
        narrator.stop()
        pointer.hide()
        turnStart = Date()
        xray.model.reset(provider: ProviderSettings.displayName)
        xray.showIfEnabled()
        xray.model.update("listen", status: .active)
        log.append("summon", transcriber.diagnostics())

        // Tactile + audible confirmation the instant the summon lands.
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        NSSound(named: "Pop")?.play()

        // Listening lives in the notch — the pill appears at the cursor
        // once there's something to show (receipt, then the answer).
        notch.set(.listening(""))
        transcriber.onPartial = { [weak self] text in
            Task { @MainActor in
                self?.notch.set(.listening(text))
            }
        }
        transcriber.onError = { [weak self] error in
            Task { @MainActor in
                self?.log.append("stt.error", ["message": error.localizedDescription])
            }
        }
        do {
            try transcriber.start()
        } catch {
            log.append("stt.start_failed", ["message": error.localizedDescription])
            notch.set(.idle)
            notch.showTranscript("Microphone unavailable: \(error.localizedDescription)", isError: true)
            scheduleOverlayClear(after: 6)
            return
        }

        // Speculative perception: both the screenshot AND the AX-tree
        // snapshot are in flight while the user is still speaking. The AX
        // read targets the frontmost app — which is still the user's app,
        // because the overlay never activates.
        xray.model.update("capture", status: .active)
        xray.model.update("perceive", status: .active)
        captureTask = Task { [capturer] in
            try? await capturer.captureMainDisplay()
        }
        axTask = Task.detached { [axReader] in
            axReader.snapshotFrontmostApp()
        }
    }

    private func finishListeningAndAnswer() {
        answerTask = Task { await answer() }
    }

    private func answer() async {
        let question = await transcriber.stop()
        notch.set(.thinking)
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Don't vanish silently — an empty transcript is the most common
            // symptom of a permissions problem, so say so.
            log.append("transcript.empty")
            notch.set(.idle)
            notch.showTranscript("Didn't catch any speech. Check System Settings → Privacy → Microphone and Speech Recognition for Lumen.", isError: true)
            scheduleOverlayClear(after: 6)
            return
        }
        log.append("transcript", ["text": question])
        xray.model.update("listen", status: .done, detail: "“\(question.prefix(28))…”", ms: elapsedMs())

        var capture = await captureTask?.value
        let snapshot = await axTask?.value
        if let raw = capture, let snapshot, !snapshot.secureFrames.isEmpty,
           let screen = NSScreen.main {
            capture = raw.redacting(snapshot.secureFrames, screenSize: screen.frame.size)
            log.append("redact", ["secure_fields": "\(snapshot.secureFrames.count)"])
        }
        if let capture {
            log.append("capture", ["w": "\(capture.pixelWidth)", "h": "\(capture.pixelHeight)"])
            xray.model.update("capture", status: .done,
                              detail: "\(capture.pixelWidth)×\(capture.pixelHeight) · self-excluded",
                              ms: elapsedMs())
            xray.model.receipt = capture.image
        } else {
            xray.model.update("capture", status: .failed, detail: "no frame")
        }
        if let snapshot {
            log.append("ax", ["elements": "\(snapshot.elements.count)", "app": snapshot.appName])
            xray.model.update("perceive", status: .done,
                              detail: "\(snapshot.elements.count) elements · \(snapshot.appName)",
                              ms: elapsedMs())
        } else {
            xray.model.update("perceive", status: .failed, detail: "no AX tree")
        }
        xray.model.update("reason", status: .active)

        // The receipt discloses the FULL payload: pixels and element list.
        // It renders in the notch transcript card — unless X-Ray is open
        // and already showing the same evidence.
        let elementCount = snapshot?.elements.count ?? 0
        let secureCount = snapshot?.secureFrames.count ?? 0
        var note = elementCount > 0
            ? "Sent: this frame + \(elementCount) UI elements from \(snapshot?.appName ?? "")"
            : "Sent to the model — exactly this frame"
        if secureCount > 0 {
            note += " · \(secureCount) secure field\(secureCount == 1 ? "" : "s") redacted"
        }
        notch.setReceipt(
            XRayOverlayController.isEnabled ? nil : capture?.image,
            note: note
        )

        currentCapture = capture
        currentSnapshot = snapshot

        var buffer = ""
        var fired = 0
        var deliveredSegments = 0
        let speechOn = Narrator.isEnabled
        let started = Date()

        do {
            for try await delta in reasoner.stream(
                question: question,
                capture: capture,
                elementsText: snapshot?.promptText,
                history: history
            ) {
                if buffer.isEmpty {
                    // First token: reasoning latency ends, streaming begins.
                    xray.model.update("reason", status: .done, detail: "first token", ms: elapsedMs())
                    xray.model.update("stream", status: .active)
                    if speechOn {
                        xray.model.update("narrate", status: .active)
                    } else {
                        notch.set(.answering)
                    }
                }
                buffer += delta
                let (display, annotations) = PointParser.process(buffer)
                if NotchOverlayController.transcriptEnabled {
                    notch.showTranscript(display)
                }

                if speechOn {
                    // Speech is the pacer: each completed sentence is voiced,
                    // and its annotations fire when its audio starts.
                    let segments = PointParser.segments(buffer, isFinal: false)
                    if segments.count > deliveredSegments {
                        for segment in segments[deliveredSegments...] {
                            narrator.enqueue(segment)
                            fired += segment.annotations.count
                        }
                        deliveredSegments = segments.count
                    }
                } else if annotations.count > fired {
                    for annotation in annotations[fired...] {
                        apply(annotation, capture: capture, snapshot: snapshot)
                    }
                    fired = annotations.count
                }
            }

            if speechOn {
                // Flush the trailing sentence the stream ended on.
                let segments = PointParser.segments(buffer, isFinal: true)
                if segments.count > deliveredSegments {
                    for segment in segments[deliveredSegments...] {
                        narrator.enqueue(segment)
                        fired += segment.annotations.count
                    }
                    deliveredSegments = segments.count
                }
            }

            let (display, _) = PointParser.process(buffer)
            guard !display.isEmpty || fired > 0 else {
                // A stream that completes with no visible output is a failure,
                // not an answer — say so (e.g. a thinking model that burned
                // its whole budget on hidden reasoning).
                log.append("answer.empty", ["latency_ms": "\(Int(Date().timeIntervalSince(started) * 1000))"])
                notch.showTranscript("The model finished without producing an answer. If you're using a local thinking model, it may have spent its whole token budget reasoning.", isError: true)
                scheduleOverlayClear(after: 8)
                return
            }
            xray.model.update("stream", status: .done,
                              detail: "\(buffer.count) chars · \(fired) annotations",
                              ms: elapsedMs())
            if !speechOn {
                xray.model.update("narrate", status: .done, detail: "muted")
                notch.set(.idle)
            }
            if NotchOverlayController.transcriptEnabled {
                notch.showTranscript(display)
            }
            ConversationStore.shared.append(
                question: question,
                answer: buffer,
                provider: ProviderSettings.displayName
            )
            history.append(Exchange(question: question, answer: buffer))
            if history.count > 6 { history.removeFirst() }
            log.append("answer", [
                "text": display,
                "latency_ms": "\(Int(Date().timeIntervalSince(started) * 1000))",
            ])

            if !speechOn {
                // With narration on, the hide countdown starts when the
                // narrator goes idle — never while the voice is mid-tour.
                scheduleOverlayClear(after: 15)
            }
        } catch is CancellationError {
            // New summon interrupted this answer — expected.
        } catch {
            log.append("error", ["message": error.localizedDescription])
            notch.set(.idle)
            notch.showTranscript(error.localizedDescription, isError: true)
            scheduleOverlayClear(after: 8)
        }
    }

    private func scheduleOverlayClear(after seconds: UInt64) {
        autoHideTask?.cancel()
        autoHideTask = Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            notch.clearOverlay()
            pointer.hide()
        }
    }

    /// Renders one annotation. Element-anchored tags use the AX frame as-is
    /// (already in screen points); pixel tags scale from screenshot space.
    private func apply(_ annotation: Annotation, capture: ScreenCapture?, snapshot: AXReader.Snapshot?) {
        switch annotation {
        case .pixelPoint(let x, let y, let label):
            guard let capture, capture.pixelWidth > 0, capture.pixelHeight > 0,
                  let screen = NSScreen.main else { return }
            let scaleX = screen.frame.width / CGFloat(capture.pixelWidth)
            let scaleY = screen.frame.height / CGFloat(capture.pixelHeight)
            pointer.enqueuePoint(
                atScreenPoint: CGPoint(x: CGFloat(x) * scaleX, y: CGFloat(y) * scaleY),
                label: label
            )
            log.append("annotate.pixel", ["x": "\(x)", "y": "\(y)", "label": label])
        case .elementPoint(let id):
            guard let element = snapshot?.element(withID: id) else {
                log.append("annotate.miss", ["id": "E\(id)"])
                return
            }
            pointer.enqueuePoint(
                atScreenPoint: CGPoint(x: element.frame.midX, y: element.frame.midY),
                label: element.label.isEmpty ? element.roleName : element.label
            )
            log.append("annotate.element_point", ["id": "E\(id)", "label": element.label])
        case .elementBox(let id):
            guard let element = snapshot?.element(withID: id) else {
                log.append("annotate.miss", ["id": "E\(id)"])
                return
            }
            pointer.enqueueHighlight(
                rect: element.frame,
                label: element.label.isEmpty ? element.roleName : element.label
            )
            log.append("annotate.element_box", ["id": "E\(id)", "label": element.label])
        case .region(let x, let y, let w, let h, let label):
            // Section highlight — pixel space, scaled to screen points.
            guard let capture, capture.pixelWidth > 0, capture.pixelHeight > 0,
                  let screen = NSScreen.main else { return }
            let scaleX = screen.frame.width / CGFloat(capture.pixelWidth)
            let scaleY = screen.frame.height / CGFloat(capture.pixelHeight)
            pointer.enqueueRegion(
                rect: CGRect(
                    x: CGFloat(x) * scaleX,
                    y: CGFloat(y) * scaleY,
                    width: CGFloat(w) * scaleX,
                    height: CGFloat(h) * scaleY
                ),
                label: label
            )
            log.append("annotate.region", ["label": label, "w": "\(w)", "h": "\(h)"])
        case .openURL(let raw):
            // Real agent action: open a page. Border = "I'm acting now."
            let normalized = raw.hasPrefix("http") ? raw : "https://\(raw)"
            guard let url = URL(string: normalized) else { return }
            pointer.setControlBorder(true)
            NSWorkspace.shared.open(url)
            log.append("agent.open", ["url": normalized])
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.pointer.setControlBorder(false)
            }
        case .launchApp(let name):
            let appURL = URL(fileURLWithPath: "/Applications/\(name).app")
            guard FileManager.default.fileExists(atPath: appURL.path) else {
                log.append("agent.launch_miss", ["app": name])
                return
            }
            pointer.setControlBorder(true)
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
            log.append("agent.launch", ["app": name])
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.pointer.setControlBorder(false)
            }
        }
    }

}
