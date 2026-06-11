import Foundation

/// Spatial annotations the model can emit, in document order.
enum Annotation: Equatable {
    /// Pixel coordinates in the screenshot's space — the fallback when no
    /// AX element fits (canvas apps, images, video).
    case pixelPoint(x: Int, y: Int, label: String)
    /// Pointer anchored to an AX element's real center.
    case elementPoint(id: Int)
    /// Highlight box drawn around an AX element's real bounds.
    case elementBox(id: Int)
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
    private static let thinkPattern = #/<think>[\s\S]*?<\/think>/#

    static func process(_ raw: String) -> (display: String, annotations: [Annotation]) {
        // Some local thinking models (Qwen3 family) emit inline
        // <think>…</think> blocks even when thinking is switched off.
        var buffer = raw.replacing(thinkPattern, with: "")
        if let open = buffer.range(of: "<think>"),
           !buffer[open.upperBound...].contains("</think>") {
            buffer = String(buffer[..<open.lowerBound])
        }

        // Collect all annotations with their positions, then sort into
        // document order so streaming fire-once indexes stay stable.
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
        found.sort { $0.0.lowerBound < $1.0.lowerBound }

        var display = buffer
            .replacing(pixelPattern, with: "")
            .replacing(elementPointPattern, with: "")
            .replacing(elementBoxPattern, with: "")

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
}
