import XCTest

final class SmokeTests: XCTestCase {
    func testPointParserStripsTagsAndCollectsAnnotations() {
        let raw = "Click here. [BOX:E3] Then the sidebar. [REGION:10,20,300,400:Sidebar]"
        let (display, annotations) = PointParser.process(raw)
        XCTAssertFalse(display.contains("["))
        XCTAssertEqual(annotations, [
            .elementBox(id: 3),
            .region(x: 10, y: 20, w: 300, h: 400, label: "Sidebar"),
        ])
    }

    func testSegmentsAttachTagsToTheirSentence() {
        let raw = "First thing. [BOX:E1] Second thing. [BOX:E2] Tail"
        let segments = PointParser.segments(raw, isFinal: true)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].annotations, [.elementBox(id: 1)])
        XCTAssertEqual(segments[1].annotations, [.elementBox(id: 2)])
    }
}
