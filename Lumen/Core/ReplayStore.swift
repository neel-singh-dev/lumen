import CoreGraphics
import Foundation

/// One annotation beat recovered from the event log.
struct ReplayStop: Equatable {
    enum Kind: String {
        case point, box, region
    }
    let kind: Kind
    let rect: CGRect
    let label: String
}

/// The last exchange, reconstructed from the durable logs: raw answer (tags
/// intact) from conversations.jsonl, resolved annotation rects from
/// events.jsonl. Replay is just a second consumer of the same streams.
struct ReplaySession {
    let question: String
    let rawAnswer: String
    let stops: [ReplayStop]
}

enum ReplayStore {
    static func loadLast(eventsURL: URL, conversationsURL: URL) -> ReplaySession? {
        guard let conv = try? String(contentsOf: conversationsURL, encoding: .utf8),
              let events = try? String(contentsOf: eventsURL, encoding: .utf8)
        else { return nil }
        return parse(
            conversationLines: conv.split(separator: "\n").map(String.init),
            eventLines: events.split(separator: "\n").map(String.init)
        )
    }

    static func parse(conversationLines: [String], eventLines: [String]) -> ReplaySession? {
        guard let lastLine = conversationLines.last,
              let object = try? JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any],
              let question = object["question"] as? String,
              let answer = object["answer"] as? String
        else { return nil }

        // Annotation events after the most recent summon's transcript.
        var current: [ReplayStop] = []
        for line in eventLines {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }
            if type == "transcript" {
                current = []
                continue
            }
            guard type.hasPrefix("annotate."),
                  let payload = event["payload"] as? [String: String],
                  let x = payload["rx"].flatMap(Double.init),
                  let y = payload["ry"].flatMap(Double.init),
                  let w = payload["rw"].flatMap(Double.init),
                  let h = payload["rh"].flatMap(Double.init)
            else { continue }

            let kind: ReplayStop.Kind
            switch type {
            case "annotate.region": kind = .region
            case "annotate.element_box": kind = .box
            default: kind = .point
            }
            current.append(ReplayStop(
                kind: kind,
                rect: CGRect(x: x, y: y, width: w, height: h),
                label: payload["label"] ?? ""
            ))
        }
        return ReplaySession(question: question, rawAnswer: answer, stops: current)
    }
}
