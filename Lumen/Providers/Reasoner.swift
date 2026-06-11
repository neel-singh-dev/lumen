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
    /// Streams text deltas. Spatial tags ([POINT:E…], [BOX:E…],
    /// [POINT:x,y:label]) arrive inline. `elementsText` is the AX-tree
    /// element list when available — the grounding half of perception.
    func stream(question: String, capture: ScreenCapture?, elementsText: String?, history: [Exchange]) -> AsyncThrowingStream<String, Error>
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

/// The shared system prompt — provider-independent, so every Reasoner
/// implementation speaks the same [POINT] protocol.
enum LumenPrompt {
    static let system = """
    You are Lumen, a screen-aware assistant living on the user's Mac. The user \
    holds a hotkey, asks a question by voice, and you see a screenshot of their \
    screen taken at that moment.

    Rules:
    - Be terse: 1-3 short sentences, no preamble. The answer appears as an \
    on-screen caption, not a chat.
    - You may receive a list of UI elements with ids and their exact on-screen \
    frames. When you refer to one of those elements, anchor your answer with a \
    tag right after the relevant sentence: [POINT:E12] places a pointer on \
    element E12; [BOX:E12] draws a highlight box around it. Use [BOX] when \
    guiding the user to click or interact with something, [POINT] when merely \
    referring to it. ALWAYS prefer element ids — they are exact.
    - Only when no listed element fits (canvas content, images, video), fall \
    back to [POINT:x,y:label] with pixel coordinates in the screenshot and a \
    1-3 word label.
    - Only annotate things actually visible. At most 3 annotations per answer.
    - If the question has nothing to do with the screen, just answer it.
    """
}

final class AnthropicReasoner: Reasoner {
    static let defaultModel = "claude-opus-4-8"

    func stream(question: String, capture: ScreenCapture?, elementsText: String?, history: [Exchange]) -> AsyncThrowingStream<String, Error> {
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
                        question: question, capture: capture, elementsText: elementsText, history: history
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

    private func body(question: String, capture: ScreenCapture?, elementsText: String?, history: [Exchange]) -> [String: Any] {
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
        let text = elementsText.map { "\($0)\n\nQuestion: \(question)" } ?? question
        content.append(["type": "text", "text": text])
        messages.append(["role": "user", "content": content])

        // No `thinking` param: omitted means no thinking on Opus 4.8 —
        // the right call for a latency-sensitive caption-length answer.
        return [
            "model": Self.defaultModel,
            "max_tokens": 1024,
            "stream": true,
            "system": LumenPrompt.system,
            "messages": messages,
        ]
    }
}
