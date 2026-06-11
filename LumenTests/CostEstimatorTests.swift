import XCTest

final class CostEstimatorTests: XCTestCase {
    func testEstimateBreakdownAndTotal() {
        let estimate = CostEstimator.estimate(
            imagePixelWidth: 1500, imagePixelHeight: 1000,
            elementChars: 4000, historyChars: 800, questionChars: 40
        )
        XCTAssertEqual(estimate.imageTokens, 2000)   // 1.5M px / 750
        XCTAssertEqual(estimate.elementTokens, 1000) // chars / 4
        XCTAssertEqual(estimate.historyTokens, 200)
        XCTAssertEqual(estimate.questionTokens, 10)
        XCTAssertEqual(estimate.total, 3210)
    }

    func testSummaryFormatsThousands() {
        let estimate = CostEstimator.estimate(
            imagePixelWidth: 1500, imagePixelHeight: 1000,
            elementChars: 0, historyChars: 0, questionChars: 0
        )
        XCTAssertTrue(estimate.summary.contains("2.0k"))
    }

    func testNoImage() {
        let estimate = CostEstimator.estimate(
            imagePixelWidth: nil, imagePixelHeight: nil,
            elementChars: 400, historyChars: 0, questionChars: 0
        )
        XCTAssertEqual(estimate.imageTokens, 0)
        XCTAssertEqual(estimate.total, 100)
    }
}
