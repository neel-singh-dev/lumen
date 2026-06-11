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

    func testStopsDroppedWhenTrailingTranscriptIsFromAFailedTurn() {
        let conv = [
            #"{"id":"Y","ts":"2026-06-11T11:00:00Z","question":"What is this?","answer":"It is a window. [BOX:E2]","provider":"Claude"}"#,
        ]
        let events = [
            #"{"ts":"2026-06-11T11:00:00Z","type":"transcript","payload":{"text":"What is this?"}}"#,
            #"{"ts":"2026-06-11T11:00:02Z","type":"annotate.element_box","payload":{"id":"E2","label":"Window","rx":"100","ry":"200","rw":"300","rh":"150"}}"#,
            #"{"ts":"2026-06-11T11:05:00Z","type":"transcript","payload":{"text":"failed question"}}"#,
            #"{"ts":"2026-06-11T11:05:01Z","type":"annotate.region","payload":{"label":"partial","rx":"5","ry":"5","rw":"50","rh":"50"}}"#,
        ]
        let session = ReplayStore.parse(conversationLines: conv, eventLines: events)
        XCTAssertEqual(session?.rawAnswer, "It is a window. [BOX:E2]")
        XCTAssertEqual(session?.stops, [])   // failed turn's stops must NOT attach to the older answer
    }

    func testMalformedLinesAreSkipped() {
        let conv = [
            "not json at all",
            #"{"id":"Y","ts":"2026-06-11T11:00:00Z","question":"Q","answer":"A.","provider":"p"}"#,
        ]
        let events = [
            "garbage{{{",
            #"{"ts":"t","type":"transcript","payload":{"text":"Q"}}"#,
            #"{"no_type_field":true}"#,
            #"{"ts":"t","type":"annotate.element_box","payload":{"id":"E1","label":"L","rx":"1","ry":"2","rw":"3","rh":"4"}}"#,
        ]
        let session = ReplayStore.parse(conversationLines: conv, eventLines: events)
        XCTAssertEqual(session?.question, "Q")
        XCTAssertEqual(session?.stops.count, 1)
    }
}
