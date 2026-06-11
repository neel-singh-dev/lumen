import Foundation

/// Reasoner for any OpenAI-compatible /v1/chat/completions endpoint.
/// One implementation, many backends — most importantly Ollama on
/// localhost, which turns Lumen into a fully-local assistant: screen,
/// voice, and reasoning all stay on the Mac.
final class OpenAICompatibleReasoner: Reasoner {
    private let baseURL: String
    private let model: String

    init(baseURL: String, model: String) {
        self.baseURL = baseURL
        self.model = model
    }

    func stream(question: String, capture: ScreenCapture?, elementsText: String?, history: [Exchange]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
                        throw ReasonerError.api(status: -1, body: "Invalid base URL: \(baseURL)")
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    // Ollama ignores auth; real OpenAI-compatible clouds need a key.
                    let key = KeychainStore.load(account: "openai-compatible") ?? "ollama"
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.timeoutInterval = 120
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
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst(6)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = event["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let text = delta["content"] as? String
                        else { continue }
                        continuation.yield(text)
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
        // "/no_think" is Qwen3's soft switch to disable thinking mode.
        // Without it, qwen3-vl spends the entire token budget on a hidden
        // `reasoning` field and `content` arrives empty. Ollama's OpenAI
        // endpoint ignores the `think:false` parameter, so the prompt-level
        // switch is the reliable path; other models treat it as a no-op.
        var messages: [[String: Any]] = [
            ["role": "system", "content": "/no_think " + LumenPrompt.system]
        ]
        for exchange in history.suffix(6) {
            messages.append(["role": "user", "content": exchange.question])
            messages.append(["role": "assistant", "content": exchange.answer])
        }

        var content: [[String: Any]] = []
        if let capture {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(capture.jpegBase64)"],
            ])
        }
        // Qwen3's thinking switch follows the MOST RECENT instruction, so a
        // system-prompt /no_think loses force once history accumulates —
        // attach it to every user turn for consistency.
        let text = elementsText.map { "\($0)\n\nQuestion: \(question)" } ?? question
        content.append(["type": "text", "text": text + " /no_think"])
        messages.append(["role": "user", "content": content])

        return [
            "model": model,
            "stream": true,
            // Generous budget so that even if a thinking model reasons
            // anyway, visible content still arrives before the cap.
            "max_tokens": 4096,
            "messages": messages,
        ]
    }
}
