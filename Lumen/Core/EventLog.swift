import Foundation

/// Append-only interaction log — the spine everything projects from:
/// cross-session memory, deterministic replay, and the X-ray timeline all
/// read this stream. One write path, many consumers.
struct LogEvent: Codable {
    let ts: Date
    let type: String
    let payload: [String: String]
}

final class EventLog {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let queue = DispatchQueue(label: "in.neelmani.lumen.eventlog")

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("events.jsonl")

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    func append(_ type: String, _ payload: [String: String] = [:]) {
        let event = LogEvent(ts: Date(), type: type, payload: payload)
        queue.async { [encoder, fileURL] in
            guard var line = try? encoder.encode(event) else { return }
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
}
