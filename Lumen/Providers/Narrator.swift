import AVFoundation

/// Speaks the tour. Segments queue up as they stream; each is voiced by the
/// on-device system synthesizer (nothing leaves the Mac), and the moment a
/// segment starts speaking, its annotations fire — so the highlight lands
/// exactly when the voice mentions it. Speech, not a timer, is the pacer.
@MainActor
final class Narrator: NSObject, AVSpeechSynthesizerDelegate {
    static let enabledKey = "speech.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: enabledKey)
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var pending: [PointParser.Segment] = []
    private var speaking = false

    /// Fired the instant a segment's audio begins.
    var onSegmentStart: ((PointParser.Segment) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func enqueue(_ segment: PointParser.Segment) {
        pending.append(segment)
        speakNextIfIdle()
    }

    func stop() {
        pending.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        speaking = false
    }

    private func speakNextIfIdle() {
        guard !speaking, !pending.isEmpty else { return }
        let segment = pending.removeFirst()
        speaking = true
        onSegmentStart?(segment)

        guard !segment.text.isEmpty else {
            // Annotation-only beat: hold the spotlight briefly, then move on.
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                self.speaking = false
                self.speakNextIfIdle()
            }
            return
        }

        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speaking = false
            self.speakNextIfIdle()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speaking = false
            self.speakNextIfIdle()
        }
    }
}
