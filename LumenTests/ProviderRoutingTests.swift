import XCTest

final class ProviderRoutingTests: XCTestCase {
    func testDemoSelectedRoutesToDemo() {
        XCTAssertEqual(ProviderRouting.resolve(kindRaw: "demo", hasAnthropicKey: true), .demo(.selected))
    }

    func testAnthropicWithKeyIsReal() {
        XCTAssertEqual(ProviderRouting.resolve(kindRaw: "anthropic", hasAnthropicKey: true), .anthropic)
    }

    func testAnthropicWithoutKeyFallsBackToDemo() {
        XCTAssertEqual(ProviderRouting.resolve(kindRaw: "anthropic", hasAnthropicKey: false), .demo(.missingKey))
    }

    func testLocalNeverFallsBack() {
        XCTAssertEqual(ProviderRouting.resolve(kindRaw: "openai-compatible", hasAnthropicKey: false), .openAICompatible)
    }
}
