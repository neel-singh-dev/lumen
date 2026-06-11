import Foundation

/// The offline voice: no key, no network, no model — same pipeline.
/// Streams a canned answer with realistic pacing; its REGION tag resolves
/// against the live capture, so highlights land on the real screen.
/// Powers the zero-setup tour and is the live-demo safety net.
final class FixtureReasoner: Reasoner {
    static let script = """
    This is Lumen's offline demo voice — no network, no model, but the very \
    same pipeline. Your screen was captured and perceived exactly as usual. \
    [REGION:80,60,1120,140:Top of your screen] That highlight is drawn from \
    the live capture of this screen, right now. Add an API key or a local \
    model in my panel, and this same loop answers anything for real.
    """

    func stream(question: String, capture: ScreenCapture?, elementsText: String?, history: [Exchange]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for word in Self.script.split(separator: " ", omittingEmptySubsequences: false) {
                    guard !Task.isCancelled else { break }
                    try? await Task.sleep(nanoseconds: 45_000_000)
                    continuation.yield(String(word) + " ")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
