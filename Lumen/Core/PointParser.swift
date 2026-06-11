import Foundation

/// Parses the model's spatial-pointing protocol out of a streaming buffer.
/// The model appends `[POINT:x,y:label]` tags with coordinates in the
/// screenshot's pixel space; we strip them from the visible caption and
/// surface them as pointer events.
struct PointTag: Equatable {
    let x: Int
    let y: Int
    let label: String
}

enum PointParser {
    private static let tagPattern = #/\[POINT:(\d+),(\d+):([^\]]*)\]/#

    private static let thinkPattern = #/<think>[\s\S]*?<\/think>/#

    /// Returns the user-visible caption (complete tags removed, a trailing
    /// incomplete tag held back) and every complete point tag in order.
    static func process(_ buffer: String) -> (display: String, points: [PointTag]) {
        // Some local thinking models (Qwen3 family) emit inline
        // <think>…</think> blocks even when thinking is switched off —
        // never show them, and hold back an unclosed block mid-stream.
        var buffer = buffer.replacing(thinkPattern, with: "")
        if let open = buffer.range(of: "<think>"),
           !buffer[open.upperBound...].contains("</think>") {
            buffer = String(buffer[..<open.lowerBound])
        }

        var points: [PointTag] = []
        for match in buffer.matches(of: tagPattern) {
            if let x = Int(match.1), let y = Int(match.2) {
                points.append(PointTag(x: x, y: y, label: String(match.3)))
            }
        }

        var display = buffer.replacing(tagPattern, with: "")

        // Hold back a partially-streamed tag so "[POIN" never flashes on screen.
        if let bracket = display.lastIndex(of: "["),
           !display[bracket...].contains("]") {
            display = String(display[..<bracket])
        }

        return (display.trimmingCharacters(in: .whitespacesAndNewlines), points)
    }
}
