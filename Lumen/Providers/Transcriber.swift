import AVFoundation
import Speech

/// On-device speech-to-text via Apple's Speech framework. Audio never leaves
/// the Mac — chosen over cloud STT deliberately: it strengthens the
/// auditability thesis and the demo works with zero API keys configured.
final class AppleSpeechTranscriber {
    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var transcript = ""

    var onPartial: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    static func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioApplication.requestRecordPermission { _ in }
    }

    /// Diagnostic snapshot of everything speech needs — logged on each
    /// summon so permission failures are visible instead of silent.
    func diagnostics() -> [String: String] {
        let speechAuth: String
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: speechAuth = "notDetermined"
        case .denied: speechAuth = "denied"
        case .restricted: speechAuth = "restricted"
        case .authorized: speechAuth = "authorized"
        @unknown default: speechAuth = "unknown"
        }
        let micAuth: String
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: micAuth = "undetermined"
        case .denied: micAuth = "denied"
        case .granted: micAuth = "granted"
        @unknown default: micAuth = "unknown"
        }
        return [
            "speech_auth": speechAuth,
            "mic_auth": micAuth,
            "recognizer_available": "\(recognizer?.isAvailable ?? false)",
            "on_device": "\(recognizer?.supportsOnDeviceRecognition ?? false)",
            "locale": recognizer?.locale.identifier ?? "nil",
        ]
    }

    func start() throws {
        transcript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error { self.onError?(error) }
            guard let result else { return }
            self.transcript = result.bestTranscription.formattedString
            self.onPartial?(self.transcript)
        }
    }

    /// Stops capture and returns the final transcript, giving the recognizer
    /// a brief window to finalize the last words.
    func stop() async -> String {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        try? await Task.sleep(nanoseconds: 400_000_000)
        task?.finish()
        request = nil
        task = nil
        return transcript
    }
}
