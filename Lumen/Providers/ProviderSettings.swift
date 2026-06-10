import Foundation

enum ProviderKind: String {
    case anthropic
    case openaiCompatible = "openai-compatible"
}

/// BYOK provider selection. Non-secret config lives in UserDefaults;
/// API keys stay in the Keychain (see KeychainStore).
///
/// The OpenAI-compatible provider is one implementation that covers many
/// backends: Ollama on localhost (fully-local mode — nothing leaves the Mac),
/// LM Studio, OpenAI, Groq, Mistral, etc. — they share the same wire format.
enum ProviderSettings {
    static let kindKey = "provider.kind"
    static let baseURLKey = "provider.baseURL"
    static let modelKey = "provider.model"

    static var kind: ProviderKind {
        ProviderKind(rawValue: UserDefaults.standard.string(forKey: kindKey) ?? "") ?? .anthropic
    }

    /// Ollama's OpenAI-compatible endpoint by default.
    static var baseURL: String {
        UserDefaults.standard.string(forKey: baseURLKey) ?? "http://localhost:11434"
    }

    /// Qwen2.5-VL by default — strong at coordinate grounding, which is
    /// exactly what the [POINT] protocol needs from a local model.
    static var model: String {
        UserDefaults.standard.string(forKey: modelKey) ?? "qwen2.5vl"
    }

    static func setLocal(baseURL: String, model: String) {
        UserDefaults.standard.set(baseURL, forKey: baseURLKey)
        UserDefaults.standard.set(model, forKey: modelKey)
    }

    static var displayName: String {
        switch kind {
        case .anthropic: return "Claude (\(AnthropicReasoner.defaultModel))"
        case .openaiCompatible: return "\(model) @ \(baseURL)"
        }
    }
}
