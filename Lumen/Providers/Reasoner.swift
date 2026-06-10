import Foundation

/// One past question/answer pair, replayed to the model for continuity.
/// Text only — screenshots are not re-sent (context economy).
struct Exchange {
    let question: String
    let answer: String
}

/// The reasoning provider seam. Lumen's BYOK story hangs off this protocol:
/// AnthropicReasoner today; an OpenAI-compatible implementation (which also
/// covers Ollama on localhost for fully-local mode) and a recorded-fixture
/// implementation for offline demos plug in beside it.
protocol Reasoner {
    /// Streams text deltas. `[POINT:x,y:label]` tags arrive inline.
    func stream(question: String, capture: ScreenCapture?, history: [Exchange]) -> AsyncThrowingStream<String, Error>
}

enum ReasonerError: LocalizedError {
    case missingAPIKey
    case api(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key set. Menu bar icon → “Set Anthropic API Key…”"
        case .api(let status, let body):
            return "API error \(status): \(body.prefix(200))"
        }
    }
}

final class AnthropicReasoner: Reasoner {
    static let defaultModel = "claude-opus-4-8"

    private let systemPrompt = """
    You are Lumen, a screen-aware assistant living on the user's Mac. The user \
    holds a hotkey, asks a question by voice, and you see a screenshot of their \
    screen taken at that moment.

    Rules:
    - Be terse: 1-3 short sentences, no preamble. The answer appears as an \
    on-screen caption, not a chat.
    - When your answer refers to a specific element visible in the screenshot, \
    append a pointing tag immediately after the relevant sentence: \
    [POINT:x,y:label] where x,y are pixel coordinates in the screenshot you \
    received and label is 1-3 words. Point at the center of the element.
    - Only point at things actually visible in the screenshot. At most 3 points.
    - If the question has nothing to do with the screen, just answer it.
    """

    func stream(question: String, capture: ScreenCapture?, history: [Exchange]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiKey = KeychainStore.load(account: "anthropic") else {
                        throw ReasonerError.missingAPIKey
                    }

                    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body(
                        question: question, capture: capture, history: history
                    ))

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        throw ReasonerError.api(
                            status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                            body: errorBody
                        )
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: "),
                              let data = line.dropFirst(6).data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if event["type"] as? String == "content_block_delta",
                           let delta = event["delta"] as? [String: Any],
                           delta["type"] as? String == "text_delta",
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func body(question: String, capture: ScreenCapture?, history: [Exchange]) -> [String: Any] {
        var messages: [[String: Any]] = []
        for exchange in history.suffix(6) {
            messages.append(["role": "user", "content": exchange.question])
            messages.append(["role": "assistant", "content": exchange.answer])
        }

        var content: [[String: Any]] = []
        if let capture {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": capture.jpegBase64,
                ],
            ])
        }
        content.append(["type": "text", "text": question])
        messages.append(["role": "user", "content": content])

        // No `thinking` param: omitted means no thinking on Opus 4.8 —
        // the right call for a latency-sensitive caption-length answer.
        return [
            "model": Self.defaultModel,
            "max_tokens": 1024,
            "stream": true,
            "system": systemPrompt,
            "messages": messages,
        ]
    }
}
