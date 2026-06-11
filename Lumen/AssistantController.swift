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
    private let tourFX = TourFXController()
    private var tourTimeout: Task<Void, Never>?

    /// The onboarding is DIRECTED, not scripted: the user's own summons are
    /// the page-turns. Chapter 1 invites the first question; answering it
    /// triggers the X-Ray chapter (explained over the user's own timings);
    /// the second answer triggers the outro. Escape exits the tour.
    private enum TourStage {
        case none
        case awaitingFirstAsk
        case awaitingXRayAsk
    }
    private var tourStage: TourStage = .none
    /// Armed by a completed ANSWER (not by tour narration finishing), so
    /// the director only advances on real user turns.
    private var tourAdvanceArmed = false
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
                self.apply(annotation, capture: self.currentCapture, snapshot: self.currentSnapshot, immediate: true)
            }
        }
        narrator.onIdle = { [weak self] in
            guard let self else { return }
            self.xray.model.update("narrate", status: .done, ms: self.elapsedMs())
            self.notch.set(.idle)
            self.autoHideTask?.cancel()
            self.autoHideTask = Task {
                // Narration over → wrap up promptly. The user read along
                // with the voice; nothing left to wait for.
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                guard !Task.isCancelled else { return }
                self.notch.clearOverlay()
                self.pointer.hide()
            }
            if self.tourAdvanceArmed {
                self.tourAdvanceArmed = false
                Task {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    self.advanceTour()
                }
            }
        }
        hotkey.onPushToTalkChanged = { [weak self] isDown in
            if isDown {
                self?.beginListening()
            } else {
                self?.finishListeningAndAnswer()
            }
        }
        hotkey.onEscape = { [weak self] in
            self?.hideOverlays()
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

        notch.closeSettings()
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
                    self?.pointer.present(.init(
                        kind: .box,
                        rect: element.frame,
                        label: "Step \(index + 1) · \(element.label)"
                    ))
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
        answerTask?.cancel()
        narrator.stop()
        pointer.hide()
        autoHideTask?.cancel()
        tourTimeout?.cancel()
        notch.closeSettings()
        notch.setReceipt(nil, note: "")

        // The show: edge glow says "AI is present", ripples introduce the
        // notch, keycaps teach the chord — and the final beat is an
        // invitation, so the user's first real summon completes the tour.
        struct Beat {
            let text: String
            let fx: () -> Void
        }
        let beats = [
            Beat(text: "Hey — I'm Lumen. I live right here, in your notch.") { [weak self] in
                self?.tourFX.set(glow: true, ripples: true)
            },
            Beat(text: "I can see your screen — but only in the moment you ask. And I always show you exactly what I captured, with passwords blacked out before anything leaves this Mac.") { [weak self] in
                self?.tourFX.set(ripples: false)
            },
            Beat(text: "Hover me anytime for settings — and flip on X-Ray to literally watch my mind work.") { [weak self] in
                self?.tourFX.set(ripples: true)
            },
            Beat(text: "Now you. Hold Control and Option together… and ask what's on your screen.") { [weak self] in
                self?.tourFX.set(ripples: false, keycaps: true)
            },
        ]

        for beat in beats {
            narrator.enqueue(PointParser.Segment(text: beat.text, annotations: [])) { [weak self] in
                guard let self else { return }
                beat.fx()
                if NotchOverlayController.transcriptEnabled {
                    self.notch.showTranscript(beat.text)
                }
            }
        }

        // Keycaps + glow keep inviting until the first summon (which clears
        // them) or a timeout — never forever.
        tourStage = .awaitingFirstAsk
        tourAdvanceArmed = false
        tourTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            self?.tourFX.clear()
        }
        log.append("onboarding.tour")
    }

    // MARK: - Tour director

    private func advanceTour() {
        switch tourStage {
        case .none:
            return
        case .awaitingFirstAsk:
            tourStage = .awaitingXRayAsk
            runXRayChapter()
        case .awaitingXRayAsk:
            tourStage = .none
            runTourOutro()
        }
    }

    /// Chapter 2 — Lumen reacts to the user's first answer by opening
    /// X-Ray and explaining the stages of THAT answer: the auditability
    /// story taught with the user's own timings.
    private func runXRayChapter() {
        UserDefaults.standard.set(true, forKey: XRayOverlayController.enabledKey)
        xrayVisibilityChanged()
        log.append("onboarding.xray_chapter")

        let screenWidth = NSScreen.lumen?.frame.width ?? 1440
        let xrayRect = CGRect(x: screenWidth - 330, y: 8, width: 322, height: 500)

        struct Beat {
            let text: String
            let fx: () -> Void
        }
        let beats = [
            Beat(text: "Nice — that's the whole loop. Want to see what just happened under the hood?") { [weak self] in
                self?.tourFX.set(glow: true)
            },
            Beat(text: "This is X-Ray: every stage of the answer you just got — listening, capture, perception, reasoning, the stream — with the real timings.") { [weak self] in
                self?.pointer.present(.init(kind: .box, rect: xrayRect, label: "X-Ray"))
            },
            Beat(text: "It also shows exactly what left this Mac, and where it went. That part never turns off — you can always audit me.") { },
            Beat(text: "Ask me one more thing, and watch it run live.") { [weak self] in
                self?.tourFX.set(keycaps: true)
            },
        ]
        for beat in beats {
            narrator.enqueue(PointParser.Segment(text: beat.text, annotations: [])) { [weak self] in
                beat.fx()
                if NotchOverlayController.transcriptEnabled {
                    self?.notch.showTranscript(beat.text)
                }
            }
        }
        tourTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard !Task.isCancelled else { return }
            self?.tourFX.clear()
        }
    }

    /// Chapter 3 — wrap up and hand the keys over.
    private func runTourOutro() {
        log.append("onboarding.outro")
        struct Beat {
            let text: String
            let fx: () -> Void
        }
        let beats = [
            Beat(text: "And that's me.") { [weak self] in
                self?.tourFX.set(glow: true, keycaps: false)
            },
            Beat(text: "Hover the notch anytime: transcripts if you want text, History for everything we've said, and a preview of agent mode.") { },
            Beat(text: "Try asking me to walk you through your screen sometime. Talk soon.") { },
        ]
        for beat in beats {
            narrator.enqueue(PointParser.Segment(text: beat.text, annotations: [])) { [weak self] in
                beat.fx()
                if NotchOverlayController.transcriptEnabled {
                    self?.notch.showTranscript(beat.text)
                }
            }
        }
        tourTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 18_000_000_000)
            guard !Task.isCancelled else { return }
            self?.tourFX.clear()
        }
    }

    func hideOverlays() {
        answerTask?.cancel()
        autoHideTask?.cancel()
        tourTimeout?.cancel()
        tourStage = .none
        tourAdvanceArmed = false
        narrator.stop()
        pointer.hide()
        xray.hide()
        notch.clearOverlay()
        tourFX.clear()
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
        // The user acting clears the theater — but NOT the tour stage:
        // their question is the page-turn, not an exit.
        tourTimeout?.cancel()
        tourFX.clear()
        tourAdvanceArmed = false
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
           let screen = NSScreen.lumen {
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

            // A completed real answer is the tour's page-turn.
            if tourStage != .none {
                if speechOn {
                    tourAdvanceArmed = true
                } else {
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        self.advanceTour()
                    }
                }
            }
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
    /// `immediate` bypasses the timed pacer — used when speech is the pacer
    /// so highlights land exactly when their sentence is spoken.
    private func apply(_ annotation: Annotation, capture: ScreenCapture?, snapshot: AXReader.Snapshot?, immediate: Bool = false) {
        func deliver(_ stop: PointerOverlayController.TourStop) {
            if immediate {
                pointer.present(stop)
            } else {
                switch stop.kind {
                case .point: pointer.enqueuePoint(atScreenPoint: stop.rect.origin, label: stop.label)
                case .box: pointer.enqueueHighlight(rect: stop.rect, label: stop.label)
                case .region: pointer.enqueueRegion(rect: stop.rect, label: stop.label)
                }
            }
        }

        switch annotation {
        case .pixelPoint(let x, let y, let label):
            guard let capture, capture.pixelWidth > 0, capture.pixelHeight > 0,
                  let screen = NSScreen.lumen else { return }
            let scaleX = screen.frame.width / CGFloat(capture.pixelWidth)
            let scaleY = screen.frame.height / CGFloat(capture.pixelHeight)
            let target = CGPoint(x: CGFloat(x) * scaleX, y: CGFloat(y) * scaleY)
            deliver(.init(kind: .point, rect: CGRect(origin: target, size: .zero), label: label))
            log.append("annotate.pixel", [
                "x": "\(x)", "y": "\(y)", "label": label,
                "rx": "\(Int(target.x))", "ry": "\(Int(target.y))", "rw": "0", "rh": "0",
            ])
        case .elementPoint(let id):
            guard let element = snapshot?.element(withID: id) else {
                log.append("annotate.miss", ["id": "E\(id)"])
                return
            }
            let target = CGPoint(x: element.frame.midX, y: element.frame.midY)
            deliver(.init(kind: .point, rect: CGRect(origin: target, size: .zero),
                          label: element.label.isEmpty ? element.roleName : element.label))
            log.append("annotate.element_point", [
                "id": "E\(id)", "label": element.label,
                "rx": "\(Int(target.x))", "ry": "\(Int(target.y))", "rw": "0", "rh": "0",
            ])
        case .elementBox(let id):
            guard let element = snapshot?.element(withID: id) else {
                log.append("annotate.miss", ["id": "E\(id)"])
                return
            }
            deliver(.init(kind: .box, rect: element.frame,
                          label: element.label.isEmpty ? element.roleName : element.label))
            log.append("annotate.element_box", [
                "id": "E\(id)", "label": element.label,
                "rx": "\(Int(element.frame.minX))", "ry": "\(Int(element.frame.minY))",
                "rw": "\(Int(element.frame.width))", "rh": "\(Int(element.frame.height))",
            ])
        case .region(let x, let y, let w, let h, let label):
            // Section highlight — pixel space, scaled to screen points,
            // then clamped so a hallucinated rect can never vanish
            // off-screen or collapse to nothing.
            guard let capture, capture.pixelWidth > 0, capture.pixelHeight > 0,
                  let screen = NSScreen.lumen else { return }
            let scaleX = screen.frame.width / CGFloat(capture.pixelWidth)
            let scaleY = screen.frame.height / CGFloat(capture.pixelHeight)
            var rect = CGRect(
                x: CGFloat(x) * scaleX,
                y: CGFloat(y) * scaleY,
                width: CGFloat(w) * scaleX,
                height: CGFloat(h) * scaleY
            )
            let bounds = CGRect(origin: .zero, size: screen.frame.size).insetBy(dx: 4, dy: 4)
            rect = rect.intersection(bounds)
            guard !rect.isNull, rect.width > 6, rect.height > 6 else {
                log.append("annotate.region_invalid", ["label": label])
                return
            }
            if rect.width < 32 { rect = rect.insetBy(dx: (rect.width - 32) / 2, dy: 0) }
            if rect.height < 26 { rect = rect.insetBy(dx: 0, dy: (rect.height - 26) / 2) }
            deliver(.init(kind: .region, rect: rect, label: label))
            log.append("annotate.region", [
                "label": label, "w": "\(w)", "h": "\(h)",
                "rx": "\(Int(rect.minX))", "ry": "\(Int(rect.minY))",
                "rw": "\(Int(rect.width))", "rh": "\(Int(rect.height))",
            ])
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
