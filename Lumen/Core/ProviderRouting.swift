import Foundation

/// Effective-provider resolution, kept pure for testability.
/// Zero-setup rule: Anthropic selected with no key ⇒ demo fixture, so the
/// first-run tour's invited asks work before any configuration.
enum EffectiveProvider: Equatable {
    enum DemoReason: Equatable {
        case selected
        case missingKey
    }
    case anthropic
    case openAICompatible
    case demo(DemoReason)
}

enum ProviderRouting {
    static func resolve(kindRaw: String, hasAnthropicKey: Bool) -> EffectiveProvider {
        switch kindRaw {
        case "demo":
            return .demo(.selected)
        case "openai-compatible":
            return .openAICompatible
        default: // "anthropic" and anything unrecognized
            return hasAnthropicKey ? .anthropic : .demo(.missingKey)
        }
    }
}
