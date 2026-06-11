import XCTest

final class AgentVerbTests: XCTestCase {
    func testRemindTagParsesAndStrips() {
        let raw = "I'll save that. [REMIND:Review the PR tomorrow]"
        let (display, annotations) = PointParser.process(raw)
        XCTAssertEqual(display, "I'll save that.")
        XCTAssertEqual(annotations, [.reminder("Review the PR tomorrow")])
    }

    func testNoteTagParsesTitleAndBodyWithColonsInBody() {
        let raw = "Saving a note. [NOTE:Meeting follow-ups:Call Sam at 3:30, then email the deck]"
        let (display, annotations) = PointParser.process(raw)
        XCTAssertEqual(display, "Saving a note.")
        XCTAssertEqual(annotations, [
            .note(title: "Meeting follow-ups", body: "Call Sam at 3:30, then email the deck"),
        ])
    }

    func testAgentVerbsAreNotVisual() {
        XCTAssertFalse(Annotation.reminder("x").isVisual)
        XCTAssertFalse(Annotation.note(title: "t", body: "b").isVisual)
        XCTAssertFalse(Annotation.openURL("u").isVisual)
        XCTAssertTrue(Annotation.elementBox(id: 1).isVisual)
    }

    func testPartialRemindTagIsHeldBack() {
        let raw = "Saving it now. [REMIND:Review the"
        let (display, _) = PointParser.process(raw)
        XCTAssertEqual(display, "Saving it now.")
    }
}
