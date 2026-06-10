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

    func stream(question: String, capture: ScreenCapture?, history: [Exchange]) -> AsyncThrowingStream<String, Error> {
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

    private func body(question: String, capture: ScreenCapture?, history: [Exchange]) -> [String: Any] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": LumenPrompt.system]
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
        content.append(["type": "text", "text": question])
        messages.append(["role": "user", "content": content])

        return [
            "model": model,
            "stream": true,
            "max_tokens": 1024,
            "messages": messages,
        ]
    }
}
