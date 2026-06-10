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

    static func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioApplication.requestRecordPermission { _ in }
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

        task = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
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
