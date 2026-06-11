import Foundation

/// Spatial annotations and agent actions the model can emit, in document order.
enum Annotation: Equatable {
    /// Pixel coordinates in the screenshot's space — the fallback when no
    /// AX element fits (canvas apps, images, video).
    case pixelPoint(x: Int, y: Int, label: String)
    /// Pointer anchored to an AX element's real center.
    case elementPoint(id: Int)
    /// Highlight box drawn around an AX element's real bounds.
    case elementBox(id: Int)
    /// Agent action: open a URL in the default browser.
    case openURL(String)
    /// Agent action: launch an application by name.
    case launchApp(String)
}

/// Parses the model's spatial protocol out of a streaming buffer:
///   [POINT:E12]      — point at element E12 (preferred, AX-grounded)
///   [BOX:E12]        — highlight box around element E12
///   [POINT:x,y:label] — pixel fallback in screenshot space
/// Tags are stripped from the visible caption; a partially-streamed tag
/// (or <think> block) is held back so it never flashes on screen.
enum PointParser {
    private static let pixelPattern = #/\[POINT:(\d+),(\d+):([^\]]*)\]/#
    private static let elementPointPattern = #/\[POINT:E(\d+)\]/#
    private static let elementBoxPattern = #/\[BOX:E(\d+)\]/#
    private static let openPattern = #/\[OPEN:([^\]]+)\]/#
    private static let launchPattern = #/\[LAUNCH:([^\]]+)\]/#
    private static let thinkPattern = #/<think>[\s\S]*?<\/think>/#

    static func process(_ raw: String) -> (display: String, annotations: [Annotation]) {
        let buffer = cleaned(raw)
        let found = collectTags(buffer)

        var display = buffer
            .replacing(pixelPattern, with: "")
            .replacing(elementPointPattern, with: "")
            .replacing(elementBoxPattern, with: "")
            .replacing(openPattern, with: "")
            .replacing(launchPattern, with: "")

        // Hold back a partially-streamed tag so "[POIN" never flashes.
        if let bracket = display.lastIndex(of: "["),
           !display[bracket...].contains("]") {
            display = String(display[..<bracket])
        }

        return (
            display.trimmingCharacters(in: .whitespacesAndNewlines),
            found.map(\.1)
        )
    }

    /// Strips hidden-reasoning blocks (complete and partially-streamed).
    static func cleaned(_ raw: String) -> String {
        var buffer = raw.replacing(thinkPattern, with: "")
        if let open = buffer.range(of: "<think>"),
           !buffer[open.upperBound...].contains("</think>") {
            buffer = String(buffer[..<open.lowerBound])
        }
        return buffer
    }

    /// All complete annotation tags with their ranges, in document order —
    /// stable across re-parses of a growing stream buffer.
    private static func collectTags(_ buffer: String) -> [(Range<String.Index>, Annotation)] {
        var found: [(Range<String.Index>, Annotation)] = []
        for match in buffer.matches(of: pixelPattern) {
            if let x = Int(match.1), let y = Int(match.2) {
                found.append((match.range, .pixelPoint(x: x, y: y, label: String(match.3))))
            }
        }
        for match in buffer.matches(of: elementPointPattern) {
            if let id = Int(match.1) {
                found.append((match.range, .elementPoint(id: id)))
            }
        }
        for match in buffer.matches(of: elementBoxPattern) {
            if let id = Int(match.1) {
                found.append((match.range, .elementBox(id: id)))
            }
        }
        for match in buffer.matches(of: openPattern) {
            found.append((match.range, .openURL(String(match.1).trimmingCharacters(in: .whitespaces))))
        }
        for match in buffer.matches(of: launchPattern) {
            found.append((match.range, .launchApp(String(match.1).trimmingCharacters(in: .whitespaces))))
        }
        found.sort { $0.0.lowerBound < $1.0.lowerBound }
        return found
    }

    // MARK: - Narration segments

    /// One narration beat: a sentence and the annotations attached to it.
    struct Segment: Equatable {
        let text: String
        let annotations: [Annotation]
    }

    /// Splits the stream into narration segments — sentence text plus the
    /// tags that immediately follow it. When `isFinal` is false, the
    /// trailing in-progress sentence is withheld (more text or tags may
    /// still arrive for it); earlier segments parse identically as the
    /// buffer grows, so callers can deliver `segments[deliveredCount...]`.
    static func segments(_ raw: String, isFinal: Bool) -> [Segment] {
        let buffer = cleaned(raw)
        let tags = collectTags(buffer)

        enum Part {
            case text(Substring)
            case tag(Annotation)
        }
        var parts: [Part] = []
        var cursor = buffer.startIndex
        for (range, annotation) in tags {
            if cursor < range.lowerBound {
                parts.append(.text(buffer[cursor..<range.lowerBound]))
            }
            parts.append(.tag(annotation))
            cursor = range.upperBound
        }
        if cursor < buffer.endIndex {
            parts.append(.text(buffer[cursor...]))
        }

        var segments: [Segment] = []
        var text = ""
        var annotations: [Annotation] = []
        var sentenceDone = false

        func close() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty || !annotations.isEmpty {
                segments.append(Segment(text: trimmed, annotations: annotations))
            }
            text = ""
            annotations = []
            sentenceDone = false
        }

        for part in parts {
            switch part {
            case .tag(let annotation):
                annotations.append(annotation)
            case .text(let chunk):
                var rest = chunk[...]
                while !rest.isEmpty {
                    if sentenceDone {
                        // New visible text after a finished sentence: the
                        // previous segment can no longer gain tags — close it.
                        if let firstNonWS = rest.firstIndex(where: { !$0.isWhitespace }) {
                            rest = rest[firstNonWS...]
                            close()
                        } else {
                            rest = rest[rest.endIndex...]
                        }
                        continue
                    }
                    if let terminator = rest.firstIndex(where: { ".!?".contains($0) }) {
                        text += rest[...terminator]
                        rest = rest[rest.index(after: terminator)...]
                        sentenceDone = true
                    } else {
                        text += rest
                        rest = rest[rest.endIndex...]
                    }
                }
            }
        }
        if isFinal { close() }
        return segments
    }
}
