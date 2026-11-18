import XCTest
@testable import Titles
@testable import TitlesCore

/// Title ▸ Join Titles (⌘J): picked neighbouring titles become one.
@MainActor
final class JoinTests: XCTestCase {

    func testPickedNeighboursBecomeOneTitle() throws {
        let a = sub(1, 2, "Hello"), b = sub(2.5, 3.5, "there."), c = sub(5, 6, "Bye")
        let f = makeFixture([("en", [a, b, c])])
        f.model.focusTrack(f.en.id, edit: false)
        f.model.select(a.id)
        f.model.selectRange(to: b.id)
        XCTAssertEqual(f.model.multiSelection, [a.id, b.id])
        XCTAssertTrue(f.model.canJoin)

        f.model.joinSelected()
        XCTAssertEqual(f.en.doc.subtitles.count, 2)
        let joined = try XCTUnwrap(f.en.doc.subtitle(a.id))
        XCTAssertEqual(joined.start, 1)
        XCTAssertEqual(joined.end, 3.5)
        XCTAssertEqual(joined.text, "Hello there.")          // short enough for one line
        XCTAssertNil(f.en.doc.subtitle(b.id))
        XCTAssertTrue(f.model.multiSelection.isEmpty)
        XCTAssertEqual(f.en.doc.selectedID, a.id)

        // One undo step brings both back.
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitles.map(\.text), ["Hello", "there.", "Bye"])
    }

    func testLongTextIsBrokenIntoLinesByTheRules() throws {
        let a = sub(1, 3, "This is the first half of a sentence"),
            b = sub(3.2, 5, "and here is the second half.")
        let f = makeFixture([("en", [a, b])])
        f.model.multiSelection = [a.id, b.id]
        f.model.joinSelected()
        let text = try XCTUnwrap(f.en.doc.subtitle(a.id)).text
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, text)
        XCTAssertTrue(lines.allSatisfy { $0.count <= f.model.preset(for: f.en).maxCharsPerLine }, text)
    }

    func testOnlyTwoOrMoreNeighboursJoin() {
        let a = sub(1, 2, "A"), b = sub(3, 4, "B"), c = sub(5, 6, "C")
        let f = makeFixture([("en", [a, b, c])])
        f.model.multiSelection = [a.id]
        f.model.joinSelected()
        XCTAssertEqual(f.en.doc.subtitles.count, 3)
        // A and C with B between them: not neighbours.
        f.model.multiSelection = [a.id, c.id]
        XCTAssertFalse(f.model.canJoin)
        f.model.joinSelected()
        XCTAssertEqual(f.en.doc.subtitles.count, 3)
    }

    func testJoiningMasterTitlesJoinsALockedLanguagesPartners() throws {
        let a = sub(1, 2, "Hello"), b = sub(2.5, 3.5, "everyone.")
        let f = makeFixture([("en", [a, b]), ("hr", [sub(1, 2, "Bok"), sub(2.5, 3.5, "svima.")])])
        f.hr.locked = true
        f.model.enforceLocks(in: f.video)
        f.model.focusTrack(f.en.id, edit: false)
        f.model.multiSelection = [a.id, b.id]
        f.model.joinSelected()

        XCTAssertEqual(f.hr.doc.subtitles.count, 1)
        let partner = try XCTUnwrap(f.hr.doc.subtitles.first)
        XCTAssertEqual(partner.text, "Bok svima.")
        XCTAssertEqual(partner.link, a.id)
        XCTAssertEqual(partner.start, 1)
        XCTAssertEqual(partner.end, 3.5)
    }

    func testAFreeLanguagesTitlesFollowTheJoinedMasterTitle() {
        let a = sub(1, 2, "Hello"), b = sub(2.5, 3.5, "everyone.")
        let f = makeFixture([("en", [a, b]), ("hr", [sub(1, 2, "Bok"), sub(2.5, 3.5, "svima.")])])
        f.model.focusTrack(f.en.id, edit: false)
        f.model.multiSelection = [a.id, b.id]
        f.model.joinSelected()
        // Still two titles of their own, both now belonging to the joined master title.
        XCTAssertEqual(f.hr.doc.subtitles.map(\.text), ["Bok", "svima."])
        XCTAssertEqual(f.hr.doc.subtitles.map(\.link), [a.id, a.id])
    }

    func testALockedLanguageCantJoinItsOwnTitles() {
        let a = sub(1, 2, "Hello"), b = sub(2.5, 3.5, "everyone.")
        let f = makeFixture([("en", [a, b]), ("hr", [sub(1, 2, "Bok"), sub(2.5, 3.5, "svima.")])])
        f.hr.locked = true
        f.model.enforceLocks(in: f.video)
        f.model.focusTrack(f.hr.id, edit: false)
        f.model.multiSelection = Set(f.hr.doc.subtitles.map(\.id))
        f.model.joinSelected()
        XCTAssertEqual(f.hr.doc.subtitles.count, 2)
    }
}
