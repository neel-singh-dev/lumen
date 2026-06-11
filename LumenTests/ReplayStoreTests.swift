import XCTest

final class ReplayStoreTests: XCTestCase {
    func testParseExtractsLastExchangeAndStops() {
        let conv = [
            #"{"id":"X","ts":"2026-06-11T10:00:00Z","question":"old q","answer":"old a","provider":"p"}"#,
            #"{"id":"Y","ts":"2026-06-11T11:00:00Z","question":"What is this?","answer":"It is a window. [BOX:E2]","provider":"Claude"}"#,
        ]
        let events = [
            #"{"ts":"2026-06-11T10:59:00Z","type":"transcript","payload":{"text":"old q"}}"#,
            #"{"ts":"2026-06-11T10:59:01Z","type":"annotate.region","payload":{"label":"stale","rx":"1","ry":"1","rw":"5","rh":"5"}}"#,
            #"{"ts":"2026-06-11T11:00:00Z","type":"transcript","payload":{"text":"What is this?"}}"#,
            #"{"ts":"2026-06-11T11:00:02Z","type":"annotate.element_box","payload":{"id":"E2","label":"Window","rx":"100","ry":"200","rw":"300","rh":"150"}}"#,
        ]
        let session = ReplayStore.parse(conversationLines: conv, eventLines: events)
        XCTAssertEqual(session?.question, "What is this?")
        XCTAssertEqual(session?.rawAnswer, "It is a window. [BOX:E2]")
        XCTAssertEqual(session?.stops, [
            ReplayStop(kind: .box, rect: CGRect(x: 100, y: 200, width: 300, height: 150), label: "Window"),
        ])
    }

    func testParseReturnsNilWithoutConversations() {
        XCTAssertNil(ReplayStore.parse(conversationLines: [], eventLines: []))
    }
}
