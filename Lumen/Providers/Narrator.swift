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
    private var pending: [(PointParser.Segment, (() -> Void)?)] = []
    private var speaking = false

    /// The best English voice installed — premium > enhanced > default.
    /// Voice quality is half the polished feel; still fully on-device.
    private static let voice: AVSpeechSynthesisVoice? = {
        let english = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        return english.first { $0.quality == .premium }
            ?? english.first { $0.quality == .enhanced }
    }()

    /// Fired the instant a segment's audio begins.
    var onSegmentStart: ((PointParser.Segment) -> Void)?

    /// Fired when the queue drains and the last utterance finishes —
    /// the cue that overlays may begin their hide countdown.
    var onIdle: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func enqueue(_ segment: PointParser.Segment) {
        pending.append((segment, nil))
        speakNextIfIdle()
    }

    /// Enqueues a scripted beat with a custom on-start action — used by the
    /// onboarding tour, where the choreography isn't model-driven.
    func enqueue(_ segment: PointParser.Segment, onStart: @escaping () -> Void) {
        pending.append((segment, onStart))
        speakNextIfIdle()
    }

    func stop() {
        pending.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        speaking = false
    }

    private func speakNextIfIdle() {
        guard !speaking, !pending.isEmpty else { return }
        let (segment, hook) = pending.removeFirst()
        speaking = true
        hook?()
        onSegmentStart?(segment)

        guard !segment.text.isEmpty else {
            // Annotation-only beat: hold the spotlight briefly, then move on.
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                self.speaking = false
                if self.pending.isEmpty { self.onIdle?() } else { self.speakNextIfIdle() }
            }
            return
        }

        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let voice = Self.voice {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speaking = false
            if self.pending.isEmpty { self.onIdle?() } else { self.speakNextIfIdle() }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speaking = false
            if self.pending.isEmpty { self.onIdle?() } else { self.speakNextIfIdle() }
        }
    }
}
