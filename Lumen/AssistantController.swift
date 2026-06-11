import AppKit

/// The summon → listen → capture → reason → point loop.
///
/// Latency design: capture fires speculatively on chord-down (in parallel
/// with listening), so by chord-up the frame is usually already encoded and
/// the only remaining wait is the model itself — which streams.
@MainActor
final class AssistantController {
    private let hotkey = HotkeyMonitor()
    private let panel = OverlayPanelController()
    private let pointer = PointerOverlayController()
    private let capturer = ScreenCapturer()
    private let axReader = AXReader()
    private let transcriber = AppleSpeechTranscriber()
    private let log = EventLog()

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
        hotkey.onPushToTalkChanged = { [weak self] isDown in
            if isDown {
                self?.beginListening()
            } else {
                self?.finishListeningAndAnswer()
            }
        }
        hotkey.start()
        log.append("app.start")
    }

    func hideOverlays() {
        answerTask?.cancel()
        autoHideTask?.cancel()
        panel.hide()
        pointer.hide()
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
        pointer.hide()
        log.append("summon", transcriber.diagnostics())

        panel.show(state: .listening(partial: ""))
        transcriber.onPartial = { [weak self] text in
            Task { @MainActor in
                self?.panel.show(state: .listening(partial: text))
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
            panel.show(state: .error("Microphone unavailable: \(error.localizedDescription)"))
            return
        }

        // Speculative perception: both the screenshot AND the AX-tree
        // snapshot are in flight while the user is still speaking. The AX
        // read targets the frontmost app — which is still the user's app,
        // because the overlay never activates.
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
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Don't vanish silently — an empty transcript is the most common
            // symptom of a permissions problem, so say so.
            log.append("transcript.empty")
            panel.show(state: .error("Didn't catch any speech. Check System Settings → Privacy → Microphone and Speech Recognition for Lumen."))
            autoHideTask = Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled else { return }
                panel.hide()
            }
            return
        }
        log.append("transcript", ["text": question])

        let capture = await captureTask?.value
        let snapshot = await axTask?.value
        if let capture {
            log.append("capture", ["w": "\(capture.pixelWidth)", "h": "\(capture.pixelHeight)"])
        }
        if let snapshot {
            log.append("ax", ["elements": "\(snapshot.elements.count)", "app": snapshot.appName])
        }

        // The receipt discloses the FULL payload: pixels and element list.
        let elementCount = snapshot?.elements.count ?? 0
        panel.setNote(elementCount > 0
            ? "Sent: this frame + \(elementCount) UI elements from \(snapshot?.appName ?? "")"
            : "Sent to the model — exactly this frame")
        panel.show(state: .thinking(receipt: capture?.image))

        var buffer = ""
        var fired = 0
        let started = Date()

        do {
            for try await delta in reasoner.stream(
                question: question,
                capture: capture,
                elementsText: snapshot?.promptText,
                history: history
            ) {
                buffer += delta
                let (display, annotations) = PointParser.process(buffer)
                panel.show(state: .answering(text: display, receipt: capture?.image, done: false))

                if annotations.count > fired {
                    for annotation in annotations[fired...] {
                        apply(annotation, capture: capture, snapshot: snapshot)
                    }
                    fired = annotations.count
                }
            }

            let (display, _) = PointParser.process(buffer)
            guard !display.isEmpty || fired > 0 else {
                // A stream that completes with no visible output is a failure,
                // not an answer — say so (e.g. a thinking model that burned
                // its whole budget on hidden reasoning).
                log.append("answer.empty", ["latency_ms": "\(Int(Date().timeIntervalSince(started) * 1000))"])
                panel.show(state: .error("The model finished without producing an answer. If you're using a local thinking model, it may have spent its whole token budget reasoning."))
                autoHideTask = Task {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard !Task.isCancelled else { return }
                    panel.hide()
                }
                return
            }
            panel.show(state: .answering(text: display, receipt: capture?.image, done: true))
            history.append(Exchange(question: question, answer: buffer))
            if history.count > 6 { history.removeFirst() }
            log.append("answer", [
                "text": display,
                "latency_ms": "\(Int(Date().timeIntervalSince(started) * 1000))",
            ])

            autoHideTask = Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                panel.hide()
                pointer.hide()
            }
        } catch is CancellationError {
            // New summon interrupted this answer — expected.
        } catch {
            log.append("error", ["message": error.localizedDescription])
            panel.show(state: .error(error.localizedDescription))
            autoHideTask = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                panel.hide()
            }
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
            pointer.point(
                atScreenPoint: CGPoint(x: CGFloat(x) * scaleX, y: CGFloat(y) * scaleY),
                label: label
            )
            log.append("annotate.pixel", ["x": "\(x)", "y": "\(y)", "label": label])
        case .elementPoint(let id):
            guard let element = snapshot?.element(withID: id) else {
                log.append("annotate.miss", ["id": "E\(id)"])
                return
            }
            pointer.point(
                atScreenPoint: CGPoint(x: element.frame.midX, y: element.frame.midY),
                label: element.label.isEmpty ? element.roleName : element.label
            )
            log.append("annotate.element_point", ["id": "E\(id)", "label": element.label])
        case .elementBox(let id):
            guard let element = snapshot?.element(withID: id) else {
                log.append("annotate.miss", ["id": "E\(id)"])
                return
            }
            pointer.highlight(
                rect: element.frame,
                label: element.label.isEmpty ? element.roleName : element.label
            )
            log.append("annotate.element_box", ["id": "E\(id)", "label": element.label])
        }
    }

}
