import XCTest
@testable import Titles
@testable import TitlesCore

/// QC ▸ Re-split to Fit.
@MainActor
final class RefitTests: XCTestCase {

    private let limits = Refit.Limits(rules: .general, gap: 0.08, frame: 0.04, language: "en")
    private func flat(_ s: Subtitle) -> String { Markup.plain(s.text).replacingOccurrences(of: "\n", with: " ") }

    func testATitleTooLongForItsLinesIsSplitAtTheSentencesEnd() throws {
        let s = Subtitle(start: 0, end: 8, text: "This is the first sentence of a rather long title. And here is the second sentence, which makes it far too long.")
        let change = try XCTUnwrap(Refit.change(for: 0, in: [s], limits: limits))
        XCTAssertEqual(change.range, 0..<1)
        XCTAssertEqual(change.titles.count, 2)
        let (a, b) = (change.titles[0], change.titles[1])
        XCTAssertEqual(a.id, s.id, "the first part is still the same title")
        XCTAssertEqual(flat(a), "This is the first sentence of a rather long title.")
        XCTAssertEqual(flat(b), "And here is the second sentence, which makes it far too long.")
        // The time shared by the length of the text, the minimum gap between, on frames.
        XCTAssertEqual(a.start, 0)
        XCTAssertEqual(a.end, 3.56, accuracy: 0.0001)
        XCTAssertEqual(b.start, 3.64, accuracy: 0.0001)
        XCTAssertEqual(b.end, 8)
        XCTAssertFalse(Refit.overflows(a.text, limits))
        XCTAssertFalse(Refit.overflows(b.text, limits))
    }

    func testItalicsRunningOverTheSplitAreClosedAndOpenedAgain() throws {
        let s = Subtitle(start: 0, end: 8, text: "{\\an8}<i>This is the first sentence of a rather long title. And here is the second sentence, which makes it far too long.</i>")
        let change = try XCTUnwrap(Refit.change(for: 0, in: [s], limits: limits))
        XCTAssertTrue(change.titles[0].text.hasPrefix("{\\an8}<i>This"), change.titles[0].text)
        XCTAssertTrue(change.titles[0].text.hasSuffix("title.</i>"), change.titles[0].text)
        XCTAssertTrue(change.titles[1].text.hasPrefix("{\\an8}<i>And"), change.titles[1].text)
        XCTAssertTrue(change.titles[1].text.hasSuffix("long.</i>"))
        XCTAssertFalse(TextChecks.hasBrokenTags(change.titles[0].text))
        XCTAssertFalse(TextChecks.hasBrokenTags(change.titles[1].text))
    }

    func testATooFastTitleSharesItsTimeWithItsNeighbour() throws {
        let a = Subtitle(start: 0, end: 1.5, text: "I can't believe you would do something like that to me.")
        let b = Subtitle(start: 1.6, end: 6, text: "Why not?")
        let change = try XCTUnwrap(Refit.change(for: 0, in: [a, b], limits: limits))
        XCTAssertEqual(change.range, 0..<2)
        let (x, y) = (change.titles[0], change.titles[1])
        // The words stay with their titles (the break is at the sentence's end); the time
        // between them moves only as far as the first one needs to be read.
        XCTAssertEqual(flat(x), "I can't believe you would do something like that to me.")
        XCTAssertEqual(flat(y), "Why not?")
        XCTAssertEqual(x.end, 3.2, accuracy: 0.0001)
        XCTAssertEqual(y.start, 3.28, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(x.cps, 17)
        XCTAssertLessThanOrEqual(y.cps, 17)
        XCTAssertEqual([x.id, y.id], [a.id, b.id])
    }

    func testATooFastTitleWithNoNeighbourCloseByIsLeftForExtend() {
        let a = Subtitle(start: 0, end: 1.5, text: "I can't believe you would do something like that to me.")
        let b = Subtitle(start: 4, end: 6, text: "Why not?")
        XCTAssertNil(Refit.change(for: 0, in: [a, b], limits: limits))
    }

    func testAShortTitleJoinsItsNeighbour() throws {
        let a = Subtitle(start: 0, end: 0.5, text: "Yes.")
        let b = Subtitle(start: 0.6, end: 2, text: "I know.")
        let change = try XCTUnwrap(Refit.change(for: 0, in: [a, b], limits: limits))
        XCTAssertEqual(change.range, 0..<2)
        XCTAssertEqual(change.titles.count, 1)
        XCTAssertEqual(change.titles[0].text, "Yes. I know.")
        XCTAssertEqual(change.titles[0].start, 0)
        XCTAssertEqual(change.titles[0].end, 2)
        XCTAssertEqual(change.titles[0].id, a.id)
    }

    func testATitleThatFitsIsLeftAlone() {
        XCTAssertNil(Refit.change(for: 0, in: [Subtitle(start: 0, end: 3, text: "Hello there.")], limits: limits))
    }

    func testReSplitAllIsOneUndoStep() {
        let f = makeFixture([("en", [
            sub(0, 8, "This is the first sentence of a rather long title. And here is the second sentence, which makes it far too long."),
            sub(10, 12, "Fine."),
        ])])
        f.model.resplitToFit(all: true)
        XCTAssertEqual(f.en.doc.subtitles.count, 3)
        XCTAssertEqual(f.en.doc.subtitles[2].text, "Fine.")
        f.en.doc.undo()
        XCTAssertEqual(f.en.doc.subtitles.count, 2)
    }

    func testTheIssueTagOffersIt() {
        XCTAssertTrue(QCFix.fixes(for: [.readingSpeed]).contains(.resplit))
        XCTAssertTrue(QCFix.resplit.changesTiming)
    }
}
