import XCTest
import SwiftUI
@testable import Titles
@testable import TitlesCore

/// QC mode: finding titles with issues, going from one to the next, and the automatic fixes
/// (extend to fit the reading speed, widen and close gaps). 25 frames a second, General
/// rules: 17 CPS, 42 characters a line, 2 lines, 0.833-7 s, a 2-frame (0.08 s) gap.
@MainActor
final class QCTests: XCTestCase {

    /// 35 characters: 35 CPS over one second, 17 CPS needs about 2.06 s.
    let sentence = "We should leave before it gets dark"

    // MARK: Finding issues

    func testAnyReadingSpeedOverTheLimitIsAnIssueAndAmberIsItsOwnKind() {
        // 17 characters over 0.999 s: 17.02 CPS, shown as 17.0 but still over.
        let a = sub(1, 1.999, "Seventeen letters"),
            b = sub(3, 4, "Sixteen letters."),           // 16 CPS: amber, close to the limit
            c = sub(6, 8, "Fine.")
        XCTAssertEqual(a.characterCount, 17)
        let f = makeFixture([("en", [a, b, c])])
        f.en.spellCheck = false
        let report = Dictionary(uniqueKeysWithValues: f.model.qcReport(for: f.en).map { ($0.id, $0.issues) })
        XCTAssertEqual(report[a.id], [.readingSpeed])
        XCTAssertEqual(report[b.id], [.nearReadingSpeed])
        XCTAssertNil(report[c.id])
        f.model.focusTrack(f.en.id, edit: false)
        XCTAssertTrue(f.model.describe([.readingSpeed], of: a, in: f.en).hasPrefix("17.02 CPS"))
        // Amber titles can be skipped like any other kind.
        f.model.qcKinds.remove(.nearReadingSpeed)
        f.model.select(c.id)
        XCTAssertEqual(f.model.nextIssue(1), a.id)
        XCTAssertEqual(f.model.nextIssue(1), a.id, "the amber title is skipped")
        f.model.qcKinds = Set(QCIssue.allCases)
        XCTAssertEqual(f.model.nextIssue(1), b.id)
    }

    func testEachKindOfIssueIsFound() throws {
        let a = sub(1, 2, "Hello there."),                        // 0.04 s before the next: gap
            b = sub(2.04, 2.5, "This one reads far too quickly."),  // CPS and duration
            c = sub(4, 7.5, "A line that is much too long for one subtitle line"),   // 50 characters
            d = sub(8, 10, "One\nTwo\nThree"),
            e = sub(11, 13, ""),
            g = sub(14, 16, "Fine."), h = sub(15.5, 17, "Over it.")
        let f = makeFixture([("en", [a, b, c, d, e, g, h])])
        f.en.spellCheck = false
        let report = Dictionary(uniqueKeysWithValues: f.model.qcReport(for: f.en).map { ($0.id, $0.issues) })
        XCTAssertEqual(report[a.id], [.gap])
        XCTAssertEqual(report[b.id], [.readingSpeed, .duration])
        XCTAssertEqual(report[c.id], [.lineLength])
        XCTAssertEqual(report[d.id], [.lineCount])
        XCTAssertEqual(report[e.id], [.empty])
        XCTAssertEqual(report[g.id], [.overlap])
        XCTAssertEqual(report[h.id], [.overlap])

        f.model.focusTrack(f.en.id, edit: false)
        let counts = f.model.qcCounts()
        XCTAssertEqual(counts[.overlap], 2)
        XCTAssertEqual(counts[.duration], 1)
        XCTAssertEqual(counts[.gap], 1)
        XCTAssertNil(counts[.spelling])
    }

    func testTitlesThatAreFineHaveNoIssues() {
        let a = sub(1, 3, "Hello there."), b = sub(3.08, 5, "How are you?")
        let f = makeFixture([("en", [a, b])])
        f.en.spellCheck = false
        XCTAssertTrue(f.model.qcReport(for: f.en).isEmpty)
    }

    // MARK: Going from issue to issue

    func testNextIssueGoesFromOneTitleWithAnIssueToTheNextAndWrapsRound() {
        let ok1 = sub(1, 3, "Hello there."),
            fast = sub(4, 5, sentence),
            ok2 = sub(6, 8, "Fine."),
            long = sub(9, 12, "A line that is much too long for one subtitle line")
        let f = makeFixture([("en", [ok1, fast, ok2, long])])
        f.en.spellCheck = false
        f.model.focusTrack(f.en.id, edit: false)
        f.model.select(ok1.id)

        XCTAssertEqual(f.model.nextIssue(1), fast.id)
        XCTAssertTrue(f.model.qcMode)                                  // turns QC mode on
        XCTAssertEqual(f.en.doc.selectedID, fast.id)
        XCTAssertEqual(f.engine.currentTime, 4, accuracy: 0.0001)    // playhead at its start
        XCTAssertEqual(f.model.nextIssue(1), long.id)
        XCTAssertEqual(f.model.nextIssue(1), fast.id)                 // round to the first again
        XCTAssertEqual(f.model.nextIssue(-1), long.id)                // and back
        XCTAssertEqual(f.model.nextIssue(-1), fast.id)

        // Only the kinds ticked in the QC bar.
        f.model.qcKinds = [.lineLength]
        f.model.select(ok1.id)
        XCTAssertEqual(f.model.nextIssue(1), long.id)
        XCTAssertEqual(f.model.nextIssue(1), long.id)                 // the only one
        f.model.qcKinds = [.empty]
        XCTAssertNil(f.model.nextIssue(1))
        XCTAssertEqual(f.en.doc.selectedID, long.id)                  // nothing moves
    }

    func testWithNothingSelectedTheNextIssueIsAfterThePlayhead() {
        let fast1 = sub(1, 2, sentence), ok = sub(3, 5, "Fine."), fast2 = sub(6, 7, sentence)
        let f = makeFixture([("en", [fast1, ok, fast2])])
        f.en.spellCheck = false
        f.model.focusTrack(f.en.id, edit: false)
        f.model.doc.selectedID = nil
        f.model.clock.time = 2.5
        XCTAssertEqual(f.model.nextIssue(1), fast2.id)
        f.model.doc.selectedID = nil
        f.model.clock.time = 5.5
        XCTAssertEqual(f.model.nextIssue(-1), fast1.id)
    }

    func testTabInQCModeGoesToTheNextIssueAndOutsideItToTheNextTitle() throws {
        let ok1 = sub(1, 3, "Hello there."), ok2 = sub(4, 6, "Fine."), fast = sub(7, 8, sentence)
        let f = makeFixture([("en", [ok1, ok2, fast])])
        f.en.spellCheck = false
        f.model.focusTrack(f.en.id, edit: false)
        f.model.select(ok1.id)
        let input = InputController(model: f.model)
        func tab(_ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: "\t",
                                           charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        }
        XCTAssertNil(input.keyDown(try tab(), flags: [], model: f.model))
        XCTAssertEqual(f.en.doc.selectedID, ok2.id)                   // plain: the next title

        f.model.select(ok1.id)
        f.model.qcMode = true
        XCTAssertNil(input.keyDown(try tab(), flags: [], model: f.model))
        XCTAssertEqual(f.en.doc.selectedID, fast.id)                  // QC mode: the next issue
        XCTAssertNil(input.keyDown(try tab(.shift), flags: [.shift], model: f.model))
        XCTAssertEqual(f.en.doc.selectedID, fast.id)                  // the only one, both ways
    }

    func testTheKindsLookedForAreRemembered() {
        let f = makeFixture([("en", [sub(1, 2)])])
        defer { f.model.qcKinds = Set(QCIssue.allCases) }
        f.model.qcKinds = [.gap, .overlap]
        let reopened = AppModel(engine: FakeEngine())
        reopened.persists = false
        XCTAssertEqual(reopened.qcKinds, [.gap, .overlap])
        XCTAssertFalse(reopened.qcMode)                                // QC mode itself starts off
    }

    func testTheCountsAreKeptUntilSomethingTheyDependOnChanges() {
        // 35 characters over one second: far too fast.
        let a = sub(1, 2, sentence), b = sub(4, 8, "Fine.")
        let f = makeFixture([("en", [a, b])])
        f.en.spellCheck = false
        f.model.focusTrack(f.en.id, edit: false)
        XCTAssertEqual(f.model.qcCounts(), [.readingSpeed: 1])
        XCTAssertNotNil(f.model.qcCountMemo)
        XCTAssertEqual(f.model.qcCounts(), [.readingSpeed: 1])
        // The language's own reading speed limit goes up: no longer too fast.
        f.model.setOverrides(f.en, maxCPS: .some(40))
        XCTAssertEqual(f.model.qcCounts(), [:])
        f.model.setOverrides(f.en, maxCPS: .some(nil))
        XCTAssertEqual(f.model.qcCounts(), [.readingSpeed: 1])
        // The text changes: nothing to read fast any more.
        f.en.doc.setText(a.id, "Go.")
        XCTAssertEqual(f.model.qcCounts(), [:])
    }

    // MARK: Marks outside QC mode

    func testTitlesShowTheirIssuesInQCModeOrNot() throws {
        let fast = sub(1, 2, sentence), fine = sub(4, 8, "Fine.")
        let f = makeFixture([("en", [fast, fine]), ("hr", [sub(1, 2, sentence)])])
        f.en.spellCheck = false
        f.hr.spellCheck = false
        f.model.focusTrack(f.en.id, edit: false)
        XCTAssertFalse(f.model.qcMode)
        let overlaps = f.en.doc.overlappingIDs
        XCTAssertEqual(f.model.visibleQCMarks(of: fast, in: f.en, overlapping: overlaps), [.readingSpeed])
        XCTAssertEqual(f.model.visibleQCMarks(of: fine, in: f.en, overlapping: overlaps), [])
        // Every language shows its own (the card shows them muted when it isn't focused).
        let other = try XCTUnwrap(f.hr.doc.subtitles.first)
        XCTAssertEqual(f.model.visibleQCMarks(of: other, in: f.hr, overlapping: overlaps), [.readingSpeed])
        // Its own overlaps, not the focused language's.
        let late = try XCTUnwrap(f.hr.doc.subtitle(f.hr.doc.add(start: 1.5, end: 3, text: "Late.", select: false)))
        XCTAssertEqual(f.model.visibleQCMarks(of: late, in: f.hr, overlapping: overlaps)?.contains(.overlap), true)
        // Kinds that aren't checked for aren't shown.
        f.model.qcKinds.remove(.readingSpeed)
        XCTAssertEqual(f.model.visibleQCMarks(of: fast, in: f.en, overlapping: overlaps), [])
        f.model.qcKinds = Set(QCIssue.allCases)
    }

    func testTheTitleBeingTypedInShowsNoTagUntilTheCursorLeavesIt() {
        let a = sub(1, 2, sentence), b = sub(4, 5, sentence)
        let f = makeFixture([("en", [a, b])])
        f.en.spellCheck = false
        f.model.focusTrack(f.en.id, edit: false)
        let overlaps = f.en.doc.overlappingIDs
        // Clicking into a card keeps its tag: nothing has been typed yet.
        f.model.textCursor(true, in: a.id)
        XCTAssertEqual(f.model.visibleQCMarks(of: a, in: f.en, overlapping: overlaps), [.readingSpeed])
        f.model.typed(in: a.id)
        XCTAssertNil(f.model.visibleQCMarks(of: a, in: f.en, overlapping: overlaps))
        XCTAssertEqual(f.model.visibleQCMarks(of: b, in: f.en, overlapping: overlaps), [.readingSpeed])
        // Tab on to the next card: the first one's tag is back.
        f.model.textCursor(true, in: b.id)
        f.model.textCursor(false, in: a.id)
        XCTAssertNil(f.model.typingIn)
        XCTAssertEqual(f.model.visibleQCMarks(of: a, in: f.en, overlapping: overlaps), [.readingSpeed])
        // Esc (the cursor leaves) after typing in the second one.
        f.model.typed(in: b.id)
        f.model.textCursor(false, in: b.id)
        XCTAssertEqual(f.model.visibleQCMarks(of: b, in: f.en, overlapping: overlaps), [.readingSpeed])
    }

    func testEachIssueGetsTheFixesThatApply() {
        XCTAssertEqual(QCFix.fixes(for: [.readingSpeed]), [.extend])
        XCTAssertEqual(QCFix.fixes(for: [.duration, .gap]), [.extend, .widenGaps])
        XCTAssertEqual(QCFix.fixes(for: [.lineLength, .lineCount]), [.rebreak])
        XCTAssertEqual(QCFix.fixes(for: [.spelling, .overlap, .empty, .nearReadingSpeed]), [])
    }

    func testATagsFixWorksOnItsTitleAloneInOneUndoStep() throws {
        let fast1 = sub(10, 11, sentence), long = sub(20, 24, "A line that is much too long for one subtitle line"),
            fast2 = sub(30, 31, sentence), close = sub(31.04, 34, "Next.")
        let f = makeFixture([("en", [fast1, long, fast2, close])])
        f.en.spellCheck = false
        f.model.focusTrack(f.en.id, edit: false)
        // Something else selected (and picked with Shift): the fix still goes to the tag's title.
        f.model.select(fast2.id)
        f.model.toggleMulti(long.id)
        f.model.applyQCFix(.extend, to: fast1.id)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(fast1.id)).end, 12.08, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(fast2.id)).end, 31, accuracy: 0.0001)
        XCTAssertEqual(f.en.doc.selectedID, fast1.id)
        XCTAssertTrue(f.model.multiSelection.isEmpty)
        f.model.undo()
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(fast1.id)).end, 11, accuracy: 0.0001)

        f.model.applyQCFix(.rebreak, to: long.id)
        let broken = try XCTUnwrap(f.en.doc.subtitle(long.id)).text
        XCTAssertTrue(broken.contains("\n"))
        XCTAssertFalse(broken.split(separator: "\n").contains { $0.count > 42 })
        f.model.undo()
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(long.id)).text, long.text)

        f.model.applyQCFix(.widenGaps, to: fast2.id)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(fast2.id)).end, 30.96, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(close.id)).start, 31.04, accuracy: 0.0001)
    }

    // MARK: Cards in QC mode

    func testACardsTagNamesItsIssuesInTheBarsOrder() {
        XCTAssertEqual(QCTag.text([.gap, .readingSpeed]), "CPS · GAP")
        XCTAssertEqual(QCTag.text([.nearReadingSpeed]), "NEAR CPS")
    }

    /// The tag hangs on the card's edge and takes no room, so the list of cards is laid out
    /// the same in and out of QC mode (cards that grew made the list jump while scrolling).
    func testACardIsTheSameHeightWithAndWithoutIssues() {
        let a = sub(1, 2, sentence)
        let f = makeFixture([("en", [a])])
        f.en.spellCheck = false
        func height(_ marks: Set<QCIssue>?) -> CGFloat {
            let card = CardView(model: f.model, track: f.en, sub: a, number: 1, isSelected: false,
                                inSelectedRow: false, isOverlapping: false, qcMarks: marks,
                                preset: .general, compact: false, width: 260, text: .constant(a.text))
            return NSHostingView(rootView: card.frame(width: 260)).fittingSize.height
        }
        let plain = height(nil)
        XCTAssertGreaterThan(plain, 60)
        XCTAssertEqual(height([]), plain, accuracy: 0.01)
        XCTAssertEqual(height([.readingSpeed, .gap, .spelling]), plain, accuracy: 0.01)
    }

    // MARK: Extend to fit reading speed

    let rules = TimingPreset.general

    private func extend(_ s: Subtitle, prev: Subtitle?, next: Subtitle?) -> Subtitle {
        QCRules.extended(s, prev: prev, next: next, rules: rules, gap: 0.08, frame: 0.04, videoEnd: 600)
    }

    func testTheEndMovesFirstOntoAFrame() {
        let s = extend(sub(10, 11, sentence), prev: sub(7, 8), next: sub(20, 21))
        XCTAssertEqual(s.start, 10, accuracy: 0.0001)
        XCTAssertEqual(s.end, 12.08, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(s.cps, 17)
    }

    func testWhenTheEndRunsOutOfRoomTheStartMovesBack() {
        // The next title starts at 11.5: the end stops at 11.42, the start makes up the rest.
        let s = extend(sub(10, 11, sentence), prev: sub(7, 8), next: sub(11.5, 13))
        XCTAssertEqual(s.end, 11.42, accuracy: 0.0001)
        XCTAssertEqual(s.start, 9.32, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(s.cps, 17)
    }

    func testAnOverlappingNeighbourLeavesNoRoomOnItsSide() {
        let s = extend(sub(10, 11, sentence), prev: sub(7, 8), next: sub(10.5, 13))
        XCTAssertEqual(s.end, 11, accuracy: 0.0001)
        XCTAssertEqual(s.start, 8.92, accuracy: 0.0001)
    }

    func testNoRoomEitherSideLeavesTheTitleAsItWas() {
        let t = sub(10, 11, sentence)
        let s = extend(t, prev: sub(8, 9.92), next: sub(11.08, 13))
        XCTAssertEqual(s, t)
    }

    func testNeverLongerThanTheMaximumDuration() {
        let s = extend(sub(10, 11, String(repeating: "x", count: 200)), prev: nil, next: sub(30, 31))
        XCTAssertEqual(s.end, 17, accuracy: 0.0001)
        XCTAssertTrue(QCRules.needsMoreTime(s, rules: rules))       // still too fast: no more time allowed
    }

    func testAShortTitleGetsTheMinimumDuration() {
        let s = extend(sub(10, 10.4, "Hi."), prev: sub(5, 6), next: sub(20, 21))
        XCTAssertEqual(s.end, 10.84, accuracy: 0.0001)
        XCTAssertFalse(QCRules.needsMoreTime(s, rules: rules))
    }

    func testExtendSelectedOrAllInOneUndoStep() throws {
        let fast1 = sub(10, 11, sentence), ok = sub(20, 22, "Fine."), fast2 = sub(30, 31, sentence)
        let f = makeFixture([("en", [fast1, ok, fast2])])
        f.model.focusTrack(f.en.id, edit: false)
        f.model.select(fast1.id)
        f.model.extendToFitReadingSpeed(all: false)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(fast1.id)).end, 12.08, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(fast2.id)).end, 31, accuracy: 0.0001)   // not selected
        f.model.undo()
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(fast1.id)).end, 11, accuracy: 0.0001)

        f.model.extendToFitReadingSpeed(all: true)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(fast1.id)).end, 12.08, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(fast2.id)).end, 32.08, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(ok.id)).end, 22, accuracy: 0.0001)
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitles.map(\.end), [11, 22, 31])
    }

    // MARK: Gaps

    private func gapFixed(_ a: Subtitle, _ b: Subtitle, close: Bool = false) -> (Subtitle, Subtitle) {
        QCRules.fixedGap(a, b, rules: rules, gap: 0.08, frame: 0.04, closeUnder: close ? 0.5 : nil)
    }

    func testAGapUnderTheMinimumWidensByTheFirstTitlesEnd() {
        let (a, b) = gapFixed(sub(1, 3), sub(3.04, 5))
        XCTAssertEqual(a.end, 2.96, accuracy: 0.0001)
        XCTAssertEqual(b.start, 3.04, accuracy: 0.0001)              // the start stays on its word
    }

    func testAtTheMinimumDurationTheSecondTitlesStartMovesInstead() {
        let (a, b) = gapFixed(sub(1, 1.84), sub(1.84, 4))
        XCTAssertEqual(a.end, 1.84, accuracy: 0.0001)
        XCTAssertEqual(b.start, 1.92, accuracy: 0.0001)
    }

    func testBothAtTheMinimumDurationStayAsTheyAre() {
        let a = sub(1, 1.84), b = sub(1.84, 2.68)
        let (a2, b2) = gapFixed(a, b)
        XCTAssertEqual(a2, a)
        XCTAssertEqual(b2, b)
    }

    func testShortGapsCloseToTheMinimumOnlyWhenAsked() {
        let (a, b) = gapFixed(sub(1, 3), sub(3.3, 5), close: true)
        XCTAssertEqual(a.end, 3.22, accuracy: 0.0001)
        XCTAssertEqual(b.start, 3.3, accuracy: 0.0001)
        XCTAssertEqual(gapFixed(sub(1, 3), sub(3.3, 5)).0.end, 3, accuracy: 0.0001)          // widen only
        XCTAssertEqual(gapFixed(sub(1, 3), sub(3.6, 5), close: true).0.end, 3, accuracy: 0.0001)  // over ½ s
        XCTAssertEqual(gapFixed(sub(1, 7.9), sub(8.2, 10), close: true).0.end, 7.9, accuracy: 0.0001)  // max duration
    }

    func testOverlappingTitlesAreLeftAlone() {
        let a = sub(1, 3), b = sub(2.5, 4)
        let (a2, b2) = gapFixed(a, b, close: true)
        XCTAssertEqual(a2, a)
        XCTAssertEqual(b2, b)
    }

    func testFixGapsAroundTheSelectedTitlesOrAllInOneUndoStep() throws {
        let a = sub(1, 3, "One."), b = sub(3.04, 5, "Two."), c = sub(5.04, 7, "Three."), d = sub(7.04, 9, "Four.")
        let f = makeFixture([("en", [a, b, c, d])])
        f.model.focusTrack(f.en.id, edit: false)
        f.model.select(a.id)
        func assertTimes(_ got: [Double], _ want: [Double], line: UInt = #line) {
            XCTAssertEqual(got.count, want.count, line: line)
            for (g, w) in zip(got, want) { XCTAssertEqual(g, w, accuracy: 0.0001, line: line) }
        }
        f.model.fixGaps(all: false, close: false)
        assertTimes(f.en.doc.subtitles.map(\.end), [2.96, 5, 7, 9])            // only the gap after A

        f.model.fixGaps(all: true, close: false)
        assertTimes(f.en.doc.subtitles.map(\.end), [2.96, 4.96, 6.96, 9])
        assertTimes(f.en.doc.subtitles.map(\.start), [1, 3.04, 5.04, 7.04])    // starts stay put
        f.model.undo()
        assertTimes(f.en.doc.subtitles.map(\.end), [2.96, 5, 7, 9])            // one step
    }

    func testALockedLanguageCantFixItsOwnTiming() {
        let f = makeFixture([("en", [sub(1, 3), sub(3.04, 5)]), ("hr", [sub(1, 3), sub(3.04, 5)])])
        f.hr.locked = true
        f.model.enforceLocks(in: f.video)
        f.model.focusTrack(f.hr.id, edit: false)
        f.model.fixGaps(all: true, close: false)
        f.model.extendToFitReadingSpeed(all: true)
        XCTAssertEqual(f.hr.doc.subtitles.map(\.end), [3, 5])
    }
}
