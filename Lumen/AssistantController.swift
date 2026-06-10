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
        endpoint. For Ollama, pull a vision model first:  ollama pull qwen2.5vl
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
        modelField.placeholderString = "qwen2.5vl"
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
        log.append("summon")

        panel.show(state: .listening(partial: ""))
        transcriber.onPartial = { [weak self] text in
            Task { @MainActor in
                self?.panel.show(state: .listening(partial: text))
            }
        }
        do {
            try transcriber.start()
        } catch {
            panel.show(state: .error("Microphone unavailable: \(error.localizedDescription)"))
            return
        }

        // Speculative pre-capture: the screenshot is in flight while the
        // user is still speaking.
        captureTask = Task { [capturer] in
            try? await capturer.captureMainDisplay()
        }
    }

    private func finishListeningAndAnswer() {
        answerTask = Task { await answer() }
    }

    private func answer() async {
        let question = await transcriber.stop()
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            panel.hide()
            return
        }
        log.append("transcript", ["text": question])

        let capture = await captureTask?.value
        if let capture {
            log.append("capture", ["w": "\(capture.pixelWidth)", "h": "\(capture.pixelHeight)"])
        }
        panel.show(state: .thinking(receipt: capture?.image))

        var buffer = ""
        var firedPoints = 0
        let started = Date()

        do {
            for try await delta in reasoner.stream(question: question, capture: capture, history: history) {
                buffer += delta
                let (display, points) = PointParser.process(buffer)
                panel.show(state: .answering(text: display, receipt: capture?.image, done: false))

                if let capture, points.count > firedPoints {
                    for tag in points[firedPoints...] {
                        pointer.point(at: tag, captureSize: (capture.pixelWidth, capture.pixelHeight))
                        log.append("point", ["x": "\(tag.x)", "y": "\(tag.y)", "label": tag.label])
                    }
                    firedPoints = points.count
                }
            }

            let (display, _) = PointParser.process(buffer)
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
        }
    }
}
