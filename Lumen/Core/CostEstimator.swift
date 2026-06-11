import Foundation

/// Honest payload arithmetic — what this turn roughly costs in tokens,
/// shown in X-ray so context economy is a visible design property.
struct CostEstimate: Equatable {
    let imageTokens: Int
    let elementTokens: Int
    let historyTokens: Int
    let questionTokens: Int

    var total: Int {
        imageTokens + elementTokens + historyTokens + questionTokens
    }

    var summary: String {
        "~\(Self.format(total)) tok · img \(Self.format(imageTokens)) · elements \(Self.format(elementTokens)) · history \(Self.format(historyTokens))"
    }

    private static func format(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

enum CostEstimator {
    /// Anthropic's vision rule of thumb: tokens ≈ pixels / 750.
    /// Text: tokens ≈ chars / 4. Estimates, labeled as such.
    static func estimate(
        imagePixelWidth: Int?, imagePixelHeight: Int?,
        elementChars: Int, historyChars: Int, questionChars: Int
    ) -> CostEstimate {
        CostEstimate(
            imageTokens: (imagePixelWidth ?? 0) * (imagePixelHeight ?? 0) / 750,
            elementTokens: elementChars / 4,
            historyTokens: historyChars / 4,
            questionTokens: questionChars / 4
        )
    }
}
