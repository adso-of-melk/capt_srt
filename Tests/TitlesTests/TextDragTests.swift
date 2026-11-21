import XCTest
@testable import Titles
@testable import TitlesCore

/// Words dragged out of the card being typed in and dropped on another card: they move there
/// (to the start of a later title, the end of an earlier one) in one undo step. The drag's
/// own text is handed in, so the tests never touch the system's drag pasteboard.
@MainActor
final class TextDragTests: XCTestCase {

    let long = "We should leave before it gets dark tonight"

    func testDraggedWordsMoveToTheStartOfALaterTitleInOneUndoStep() throws {
        // A title split in two: all its words stay in the first, the second is empty.
        let a = sub(1, 3, long), b = sub(3.5, 5, "")
        let f = makeFixture([("en", [a, b])])
        f.model.focusTrack(f.en.id, edit: false)
        f.model.beginTextDrag(from: a.id, track: f.en, piece: "dark tonight", rest: "We should leave before it gets ")
        XCTAssertTrue(f.model.acceptsTextDrop(on: b.id, dragged: "dark tonight"))
        XCTAssertTrue(f.model.dropText(on: b.id, in: f.en, copy: false, dragged: "dark tonight"))
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).text, "We should leave before it gets")
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).text, "dark tonight")
        XCTAssertNil(f.model.textDrag, "the drag is over")
        f.model.undo()
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).text, long)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).text, "")
    }

    func testDroppedOnAnEarlierTitleTheWordsGoAtItsEnd() throws {
        let a = sub(1, 2, "Come in,"), b = sub(3, 5, "she said. Sit down.")
        let f = makeFixture([("en", [a, b])])
        f.model.focusTrack(f.en.id, edit: false)
        f.model.beginTextDrag(from: b.id, track: f.en, piece: "she said.", rest: " Sit down.")
        XCTAssertTrue(f.model.dropText(on: a.id, in: f.en, copy: false, dragged: "she said."))
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).text, "Come in, she said.")
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).text, "Sit down.")
    }

    func testWithOptionOrIntoAnotherLanguageTheWordsAreCopied() throws {
        let a = sub(1, 3, long), b = sub(3.5, 5, "")
        let f = makeFixture([("en", [a, b]), ("hr", [sub(1, 3, "Trebali bismo")])])
        let other = try XCTUnwrap(f.hr.doc.subtitles.first)
        f.model.focusTrack(f.en.id, edit: false)
        f.model.beginTextDrag(from: a.id, track: f.en, piece: "dark tonight", rest: "We should leave before it gets ")
        XCTAssertTrue(f.model.dropText(on: b.id, in: f.en, copy: true, dragged: "dark tonight"))
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).text, long, "copied: still there too")
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).text, "dark tonight")
        // Into another language: always a copy (here at the end: the two start together).
        f.model.beginTextDrag(from: a.id, track: f.en, piece: "tonight", rest: "We should leave before it gets dark ")
        XCTAssertTrue(f.model.dropText(on: other.id, in: f.hr, copy: false, dragged: "tonight"))
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).text, long)
        XCTAssertEqual(try XCTUnwrap(f.hr.doc.subtitle(other.id)).text, "Trebali bismo tonight")
    }

    func testOnlyACardsOwnWordsAreTakenAndNotByThatCard() throws {
        let a = sub(1, 3, long), b = sub(3.5, 5, "")
        let f = makeFixture([("en", [a, b])])
        f.model.focusTrack(f.en.id, edit: false)
        XCTAssertFalse(f.model.dropText(on: b.id, in: f.en, copy: false, dragged: "dark"), "nothing dragged from a card")
        f.model.beginTextDrag(from: a.id, track: f.en, piece: "dark tonight", rest: "We should leave before it gets ")
        XCTAssertFalse(f.model.acceptsTextDrop(on: a.id, dragged: "dark tonight"), "not back onto itself")
        // Something else is being dragged (text from another app, say).
        XCTAssertFalse(f.model.dropText(on: b.id, in: f.en, copy: false, dragged: "Other words"))
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).text, long)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).text, "")
    }

    func testBothTitlesAreBrokenIntoLinesAgain() throws {
        let a = sub(1, 4, "It's late.\nThese words come from the first title"),
            b = sub(5, 9, "and end up in the second one.")
        let f = makeFixture([("en", [a, b])])
        f.model.focusTrack(f.en.id, edit: false)
        f.model.beginTextDrag(from: a.id, track: f.en, piece: "These words come from the first title",
                              rest: "It's late.\n")
        XCTAssertTrue(f.model.dropText(on: b.id, in: f.en, copy: false,
                                       dragged: "These words come from the first title"))
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).text, "It's late.")
        let joined = try XCTUnwrap(f.en.doc.subtitle(b.id)).text
        XCTAssertEqual(Markup.plain(joined).replacingOccurrences(of: "\n", with: " "),
                       "These words come from the first title and end up in the second one.")
        let lines = joined.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines.contains { $0.count > 42 })
    }

    // MARK: Putting the words together

    func testTheWordsJoinWithOneSpace() {
        XCTAssertEqual(AppModel.joined("dark tonight", into: "", atStart: true), "dark tonight")
        XCTAssertEqual(AppModel.joined(" dark tonight ", into: "Then", atStart: false), "Then dark tonight")
        XCTAssertEqual(AppModel.joined("Well,", into: "come in. ", atStart: true), "Well, come in.")
        // Italics carry over with the words.
        XCTAssertEqual(AppModel.joined("<i>dark</i>", into: "It's", atStart: false), "It's <i>dark</i>")
        XCTAssertEqual(AppModel.joined("<i>dark", into: "It's", atStart: false), "It's <i>dark</i>")
    }

    func testWhatIsLeftHasNoStraySpacesOrBlankLines() {
        XCTAssertEqual(AppModel.leftover("We should leave before it gets "), "We should leave before it gets")
        XCTAssertEqual(AppModel.leftover("We  should\n"), "We should")
        XCTAssertEqual(AppModel.leftover("One\n\nthree"), "One\nthree")
        XCTAssertEqual(AppModel.leftover("<i></i> and there"), "and there")
    }

    func testTheDragsTextMustBeTheCardsWords() {
        XCTAssertTrue(AppModel.sameWords("dark  tonight", "dark\ntonight"))
        XCTAssertFalse(AppModel.sameWords("dark", "dark tonight"))
        XCTAssertFalse(AppModel.sameWords("", ""))
    }
}
