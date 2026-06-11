import Foundation

/// Durable conversation history — one JSON line per exchange, projected
/// from the same turn data that feeds the event log. The History window
/// reads this; nothing else depends on it.
struct ConversationEntry: Codable, Identifiable {
    var id = UUID()
    let ts: Date
    let question: String
    let answer: String
    let provider: String
}

final class ConversationStore {
    static let shared = ConversationStore()

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "in.neelmani.lumen.conversations")

    init() {
        fileURL = EventLog.supportDirectory.appendingPathComponent("conversations.jsonl")

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func append(question: String, answer: String, provider: String) {
        let entry = ConversationEntry(ts: Date(), question: question, answer: answer, provider: provider)
        queue.async { [encoder, fileURL] in
            guard var line = try? encoder.encode(entry) else { return }
            line.append(Data("\n".utf8))
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL)
            }
        }
    }

    func loadAll() -> [ConversationEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text
            .split(separator: "\n")
            .compactMap { try? decoder.decode(ConversationEntry.self, from: Data($0.utf8)) }
            .sorted { $0.ts > $1.ts }
    }
}
