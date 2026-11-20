import XCTest
@testable import Titles
@testable import TitlesCore

/// Match TC to Neighbour (pick titles, then click the title to match) and Match TC to
/// Linked Titles.
@MainActor
final class MatchTCTests: XCTestCase {

    private func fixture() -> Fixture {
        let f = makeFixture([
            ("en", [sub(1, 2, "A"), sub(3, 4, "B"), sub(5, 6, "C"), sub(10, 11, "D")]),
            ("hr", [sub(1.2, 2.2, "a"), sub(3.3, 4.1, "b"), sub(5.5, 6.3, "c")]),
        ])
        f.model.focusTrack(f.hr.id, edit: false)
        return f
    }

    private func times(_ s: Subtitle) -> [Double] { [s.start, s.end] }

    func testOneTitleTakesTheClickedTitlesStartAndEnd() {
        let f = fixture()
        let b = f.hr.doc.subtitles[1]
        f.model.select(b.id)
        f.model.beginMatchTC()
        XCTAssertEqual(f.model.matchPick?.ids, [b.id])

        XCTAssertTrue(f.model.matchTC(to: f.en.doc.subtitles[1].id, in: f.en.id))

        XCTAssertNil(f.model.matchPick)
        XCTAssertEqual(times(f.hr.doc.subtitles[1]), [3, 4])
        XCTAssertEqual(f.hr.doc.subtitles[1].text, "b")
        // One undo step.
        f.hr.doc.undo()
        XCTAssertEqual(times(f.hr.doc.subtitles[1]), [3.3, 4.1])
    }

    func testSeveralTitlesMoveTogetherKeepingLengthsAndGaps() {
        let f = fixture()
        let (a, b) = (f.hr.doc.subtitles[0], f.hr.doc.subtitles[1])
        f.model.multiSelection = [a.id, b.id]
        f.model.beginMatchTC()

        // Over title c to a free place: only where they land counts.
        f.model.matchTC(to: f.en.doc.subtitles[3].id, in: f.en.id)

        let moved = f.hr.doc.subtitles.filter { $0.id == a.id || $0.id == b.id }
        XCTAssertEqual(moved[0].start, 10, accuracy: 0.0001)
        XCTAssertEqual(moved[0].duration, a.duration, accuracy: 0.0001)
        XCTAssertEqual(moved[1].start - moved[0].end, b.start - a.end, accuracy: 0.0001)
        XCTAssertEqual(moved[1].duration, b.duration, accuracy: 0.0001)
        XCTAssertEqual(times(f.hr.doc.subtitles[0]), [5.5, 6.3], "c stays where it was")
    }

    func testAGroupThatWouldOverlapGoesToTheNearestFreePlace() {
        let f = fixture()
        let (a, b) = (f.hr.doc.subtitles[0], f.hr.doc.subtitles[1])
        f.model.multiSelection = [a.id, b.id]
        f.model.beginMatchTC()

        // Starting at 5 would put a over c (5.5–6.3): they stop the minimum gap before it.
        f.model.matchTC(to: f.en.doc.subtitles[2].id, in: f.en.id)

        let gap = f.model.minGap
        let movedA = try! XCTUnwrap(f.hr.doc.subtitle(a.id))
        let movedB = try! XCTUnwrap(f.hr.doc.subtitle(b.id))
        XCTAssertEqual(movedA.end, 5.5 - gap, accuracy: 0.0001)
        XCTAssertEqual(movedB.start - movedA.end, b.start - a.end, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(movedB.start, 6.3 + gap - 0.0001)
    }

    func testOneTitleIsShortenedToKeepClearOfItsNeighbours() {
        let f = fixture()
        let a = f.hr.doc.subtitles[0]
        f.model.select(a.id)
        f.model.beginMatchTC()

        // B is 3–4, but hr's b starts at 3.3.
        f.model.matchTC(to: f.en.doc.subtitles[1].id, in: f.en.id)

        let moved = try! XCTUnwrap(f.hr.doc.subtitle(a.id))
        XCTAssertEqual(moved.start, 3, accuracy: 0.0001)
        XCTAssertEqual(moved.end, 3.3 - f.model.minGap, accuracy: 0.0001)
    }

    func testOverlapsAllowedItTakesTheTimesExactly() {
        let f = fixture()
        f.model.allowOverlaps = true
        let a = f.hr.doc.subtitles[0]
        f.model.select(a.id)
        f.model.beginMatchTC()
        f.model.matchTC(to: f.en.doc.subtitles[1].id, in: f.en.id)
        XCTAssertEqual(times(try! XCTUnwrap(f.hr.doc.subtitle(a.id))), [3, 4])
        f.model.allowOverlaps = false
    }

    func testEscCancelsAndClickingAPickedTitleKeepsWaiting() {
        let f = fixture()
        let b = f.hr.doc.subtitles[1]
        f.model.select(b.id)
        f.model.beginMatchTC()

        XCTAssertFalse(f.model.matchTC(to: b.id, in: f.hr.id))
        XCTAssertNotNil(f.model.matchPick, "still waiting for another title")

        f.model.cancelMatchTC()
        XCTAssertNil(f.model.matchPick)
        XCTAssertFalse(f.model.matchTC(to: f.en.doc.subtitles[1].id, in: f.en.id))
        XCTAssertEqual(times(f.hr.doc.subtitles[1]), [3.3, 4.1])
    }

    func testALockedLanguageCantBeMatched() {
        let f = fixture()
        f.hr.locked = true
        f.model.select(f.hr.doc.subtitles[1].id)
        f.model.beginMatchTC()
        XCTAssertNil(f.model.matchPick)
    }

    func testMatchToLinkedTitlesTakesEachPartnersTimes() {
        let f = fixture()
        f.model.multiSelection = Set(f.hr.doc.subtitles.map(\.id))
        XCTAssertTrue(f.model.canMatchLinked)

        f.model.matchLinked()

        XCTAssertEqual(f.hr.doc.subtitles.map(times), [[1, 2], [3, 4], [5, 6]])
        f.hr.doc.undo()
        XCTAssertEqual(f.hr.doc.subtitles.map(times), [[1.2, 2.2], [3.3, 4.1], [5.5, 6.3]])
        // Not in the master itself.
        f.model.focusTrack(f.en.id, edit: false)
        f.model.multiSelection = [f.en.doc.subtitles[0].id]
        XCTAssertFalse(f.model.canMatchLinked)
    }
}
