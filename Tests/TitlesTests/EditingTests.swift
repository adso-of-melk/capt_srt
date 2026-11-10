import XCTest
import AppKit
@testable import Titles

/// Editing through the app's own actions: selection, Tab, nudging, splitting, undo across
/// languages, line breaks, locks and export. A fake player stands in for the video.
@MainActor
final class EditingTests: XCTestCase {

    // MARK: Opening

    func testOpeningAProjectFocusesTheMasterAndBuildsTheRows() {
        let a = sub(1, 2, "A"), b = sub(5, 6, "B")
        let f = makeFixture([("en", [a, b]), ("hr", [sub(1, 2, "a"), sub(3, 4, "x")])])
        XCTAssertFalse(f.model.showHome)
        XCTAssertEqual(f.video.focusedTrackID, f.en.id)
        XCTAssertTrue(f.model.doc === f.en.doc)
        XCTAssertEqual(f.model.openTracks.count, 2)
        XCTAssertEqual(f.model.rows.count, 3)
        XCTAssertNil(f.model.doc.selectedID)
        XCTAssertEqual(f.model.fps, 25)
        XCTAssertEqual(f.model.minGap, 0.08, accuracy: 0.0001)
        XCTAssertEqual(f.model.windowTitle, "Test")
    }

    func testEachLanguageIsNumberedOnItsOwn() {
        let a = sub(1, 2, "A"), b = sub(5, 6, "B")
        let ha = sub(1, 2, "a"), hx = sub(3, 4, "x"), hb = sub(5, 6, "b")
        let f = makeFixture([("en", [a, b]), ("hr", [ha, hx, hb])])
        XCTAssertEqual(f.model.rowNumber(of: a.id), 1)
        XCTAssertEqual(f.model.rowNumber(of: b.id), 2)
        XCTAssertEqual(f.model.rowNumber(of: hx.id), 2)
        XCTAssertEqual(f.model.rowNumber(of: hb.id), 3)
        XCTAssertEqual(f.model.rowKey(ofSub: b.id), f.model.rowKey(ofSub: hb.id))
        XCTAssertNotEqual(f.model.rowKey(ofSub: a.id), f.model.rowKey(ofSub: hx.id))
    }

    func testGoingHomeClosesEverything() {
        let f = makeFixture([("en", [sub(1, 2, "A")])])
        f.model.editingTimecode = true
        f.model.goHome()
        XCTAssertTrue(f.model.showHome)
        XCTAssertNil(f.model.project)
        XCTAssertNil(f.model.video)
        XCTAssertTrue(f.model.rows.isEmpty)
        XCTAssertFalse(f.model.hasMedia)
        XCTAssertFalse(f.model.editingTimecode)
        XCTAssertFalse(f.model.doc === f.en.doc)
    }

    // MARK: Tab

    func testTabSkipsRowsWhereTheFocusedLanguageHasNoTitle() {
        let a = sub(1, 2, "A"), b = sub(5, 6, "B"), c = sub(9, 10, "C")
        let ha = sub(1, 2, "a"), hx = sub(3, 4, "x"), hc = sub(9, 10, "c")
        let f = makeFixture([("en", [a, b, c]), ("hr", [ha, hx, hc])])
        XCTAssertEqual(f.model.rows.count, 4)

        f.model.select(a.id)
        f.model.selectAdjacent(1)
        XCTAssertEqual(f.model.doc.selectedID, b.id)
        XCTAssertEqual(f.engine.currentTime, 5, accuracy: 0.0001)      // the playhead goes to its start
        f.model.selectAdjacent(1)
        XCTAssertEqual(f.model.doc.selectedID, c.id)
        f.model.selectAdjacent(1)                                      // nothing after the last title
        XCTAssertEqual(f.model.doc.selectedID, c.id)
        f.model.selectAdjacent(-1)
        XCTAssertEqual(f.model.doc.selectedID, b.id)
        f.model.selectAdjacent(-1)
        XCTAssertEqual(f.model.doc.selectedID, a.id)
        f.model.selectAdjacent(-1)                                     // nothing before the first
        XCTAssertEqual(f.model.doc.selectedID, a.id)

        // The other language steps through its own titles.
        f.model.focusTrack(f.hr.id, edit: false)
        XCTAssertEqual(f.hr.doc.selectedID, ha.id)                     // focus stays on the same row
        f.model.selectAdjacent(1)
        XCTAssertEqual(f.hr.doc.selectedID, hx.id)
        f.model.selectAdjacent(1)
        XCTAssertEqual(f.hr.doc.selectedID, hc.id)
        XCTAssertEqual(f.engine.currentTime, 9, accuracy: 0.0001)
    }

    func testTabWithAGroupSelectedLetsTheGroupGoAndMovesOn() {
        let a = sub(1, 2, "A"), b = sub(3, 4, "B"), c = sub(5, 6, "C"), d = sub(7, 8, "D")
        let f = makeFixture([("en", [a, b, c, d])])
        f.model.select(b.id)
        f.model.addToMulti([b.id, c.id])
        f.model.selectAdjacent(1)
        XCTAssertTrue(f.model.multiSelection.isEmpty)
        XCTAssertEqual(f.model.doc.selectedID, d.id)

        f.model.select(b.id)
        f.model.addToMulti([b.id, c.id])
        f.model.selectAdjacent(-1)
        XCTAssertTrue(f.model.multiSelection.isEmpty)
        XCTAssertEqual(f.model.doc.selectedID, a.id)
    }

    func testTabWithNothingSelectedStartsFromThePlayhead() {
        let a = sub(1, 2, "A"), b = sub(5, 6, "B")
        let f = makeFixture([("en", [a, b]), ("hr", [sub(3, 4, "x")])])
        f.model.clock.time = 3.5
        f.model.selectAdjacent(1)
        XCTAssertEqual(f.model.doc.selectedID, b.id)

        f.model.doc.selectedID = nil
        f.model.clock.time = 3.5
        f.model.selectAdjacent(-1)
        XCTAssertEqual(f.model.doc.selectedID, a.id)
    }

    func testTabStopsPlaybackAndCanKeepTyping() {
        let a = sub(1, 2, "A"), b = sub(5, 6, "B")
        let f = makeFixture([("en", [a, b])])
        f.model.select(a.id)
        f.engine.isPlaying = true
        f.model.selectAdjacent(1, keepEditing: true)
        XCTAssertFalse(f.engine.isPlaying)
        XCTAssertEqual(f.model.doc.selectedID, b.id)
        XCTAssertEqual(f.model.focusRequest, b.id)
    }

    // MARK: Selection and the playhead

    func testPlacingThePlayheadSelectsTheTitleUnderIt() {
        let a = sub(1, 2, "A"), b = sub(5, 6, "B")
        let f = makeFixture([("en", [a, b])])
        f.model.placePlayhead(5.5)
        XCTAssertEqual(f.model.doc.selectedID, b.id)
        XCTAssertEqual(f.model.cardScrollTarget, b.id)
        // In a gap: nothing selected, the cards scroll to the title before it.
        f.model.placePlayhead(3)
        XCTAssertNil(f.model.doc.selectedID)
        XCTAssertEqual(f.model.cardScrollTarget, a.id)
        XCTAssertEqual(f.engine.currentTime, 3, accuracy: 0.0001)
    }

    func testGroupSelection() {
        let a = sub(1, 2, "A"), b = sub(3, 4, "B"), c = sub(5, 6, "C")
        let f = makeFixture([("en", [a, b, c])])
        f.model.select(a.id)
        f.model.toggleMulti(c.id)
        XCTAssertEqual(f.model.multiSelection, [a.id, c.id])
        f.model.toggleMulti(c.id)
        XCTAssertEqual(f.model.multiSelection, [a.id])
        f.model.selectAllTitles()
        XCTAssertEqual(f.model.multiSelection.count, 3)
        f.model.clearMulti()
        XCTAssertTrue(f.model.multiSelection.isEmpty)
        // Changing language lets a group go: it belongs to one language.
        f.model.addToMulti([a.id, b.id])
        f.model.addLanguage(Language.named("hr"), locked: false, copyText: false)
        XCTAssertTrue(f.model.multiSelection.isEmpty)
    }

    // MARK: Nudging an edge

    func testNudgingStopsAtTheMinimumGap() throws {
        let a = sub(1, 2, "A"), b = sub(2.5, 3.5, "B")
        let f = makeFixture([("en", [a, b])])

        f.model.select(a.id)
        f.model.nudge(.end, by: 1)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 2.42, accuracy: 0.0001)   // 2 frames before B
        XCTAssertEqual(f.engine.currentTime, 2.42, accuracy: 0.0001)                          // the picture follows

        f.model.select(b.id)
        f.model.nudge(.start, by: -1)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).start, 2.5, accuracy: 0.0001)   // A now ends 2 frames before
    }

    func testNudgingTheStartStopsAtTheTitleBefore() throws {
        let a = sub(1, 2, "A"), b = sub(2.5, 3.5, "B")
        let f = makeFixture([("en", [a, b])])
        f.model.select(b.id)
        f.model.nudge(.start, by: -1)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).start, 2.08, accuracy: 0.0001)
        // The first title can go all the way to zero, and no further.
        f.model.select(a.id)
        f.model.nudge(.start, by: -5)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).start, 0, accuracy: 0.0001)
    }

    func testATitleNeverGetsShorterThanATenthOfASecond() throws {
        let a = sub(1, 2, "A")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        f.model.nudge(.end, by: -5)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 1.1, accuracy: 0.0001)
        f.model.nudge(.start, by: 5)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).start, 1.0, accuracy: 0.0001)
    }

    func testNudgeSteps() throws {
        let a = sub(1, 2, "A")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        f.model.nudge(.end, steps: 3, of: .ms10)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 2.03, accuracy: 0.0001)
        f.model.nudge(.end, frames: 2)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 2.11, accuracy: 0.0001)
        f.model.nudge(.start, steps: -5, of: .ms1)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).start, 0.995, accuracy: 0.0001)
        f.model.nudge(.start, steps: 1, of: .frame)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).start, 1.035, accuracy: 0.0001)

        // A run of nudges is one undo step.
        f.model.doc.commitLive()
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitles, [a])
        XCTAssertFalse(f.en.doc.canUndo)
    }

    func testAnOverlappingNeighbourDoesNotBlockANudge() throws {
        let a = sub(1, 3, "A"), b = sub(2, 4, "B")
        let f = makeFixture([("en", [a, b])])
        f.model.select(b.id)
        f.model.nudge(.start, by: -0.5)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).start, 1.5, accuracy: 0.0001)
    }

    func testThePreviewAfterANudgeWaitsForTheModifierKey() {
        let a = sub(1, 2, "A")
        let f = makeFixture([("en", [a])])
        f.model.replayAfterJog = true
        f.model.pendingPreview = (edge: .end, id: a.id)
        XCTAssertTrue(f.engine.ranges.isEmpty)
        f.model.modifiersReleased()
        XCTAssertNil(f.model.pendingPreview)
        XCTAssertEqual(f.engine.ranges.count, 1)
        XCTAssertEqual(f.engine.ranges.first?.from ?? -1, 0, accuracy: 0.0001)      // a second before the title
        XCTAssertEqual(f.engine.ranges.first?.to ?? -1, 2.25, accuracy: 0.0001)     // to just after it
        XCTAssertTrue(f.model.isPreviewing)
        // Nothing waiting: letting go of the key plays nothing.
        f.model.modifiersReleased()
        XCTAssertEqual(f.engine.ranges.count, 1)
    }

    // MARK: Creating, splitting, moving

    func testATitleDrawnInATranslationBelongsToTheMasterTitleUnderIt() throws {
        let a = sub(1, 2, "A"), b = sub(5, 6, "B")
        let f = makeFixture([("en", [a, b]), ("hr", [])])
        f.model.focusTrack(f.hr.id, edit: false)
        f.model.createTitle(start: 1.1, end: 1.9)
        let made = try XCTUnwrap(f.hr.doc.subtitles.first)
        XCTAssertEqual(made.link, a.id)
        XCTAssertEqual(f.model.focusRequest, made.id)
        XCTAssertEqual(f.hr.doc.selectedID, made.id)
        // Away from any master title: no link.
        f.model.createTitle(start: 8, end: 9)
        XCTAssertNil(try XCTUnwrap(f.hr.doc.subtitles.last).link)
    }

    func testTypingOnAnEmptySlotCreatesTheTitleThere() throws {
        let a = sub(1, 2, "Hello")
        let f = makeFixture([("en", [a]), ("hr", [])])
        f.model.select(a.id)
        f.model.focusTrack(f.hr.id, edit: false)
        XCTAssertNil(f.hr.doc.selectedID)
        XCTAssertEqual(f.model.emptySlotRow, f.model.rows.first?.key)
        XCTAssertTrue(f.model.hasTypingTarget)

        f.model.typeIntoSelected("B")
        let made = try XCTUnwrap(f.hr.doc.subtitles.first)
        XCTAssertEqual(made.text, "B")
        XCTAssertEqual(made.start, 1)
        XCTAssertEqual(made.end, 2)
        XCTAssertEqual(made.link, a.id)
        XCTAssertEqual(f.model.focusRequest, made.id)
        XCTAssertNil(f.model.emptySlotRow)

        // Typing with a title selected adds to it.
        f.model.focusRequest = nil
        f.model.typeIntoSelected("o")
        XCTAssertEqual(f.hr.doc.subtitle(made.id)?.text, "Bo")
        XCTAssertEqual(f.model.focusRequest, made.id)
    }

    func testSplittingATitle() throws {
        let a = sub(1, 3, "Hello there\nGeneral Kenobi")
        let f = makeFixture([("en", [a])])
        f.model.splitTitle(a.id, at: 2)
        let parts = f.en.doc.subtitles
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].id, a.id)
        XCTAssertEqual(parts[0].end, 1.96, accuracy: 0.0001)        // the minimum gap is left between them
        XCTAssertEqual(parts[1].start, 2.04, accuracy: 0.0001)
        XCTAssertEqual(parts[1].end, 3, accuracy: 0.0001)
        // The left title keeps all of the text; the right one starts empty.
        XCTAssertEqual(parts[0].text, "Hello there\nGeneral Kenobi")
        XCTAssertEqual(parts[1].text, "")
        XCTAssertEqual(f.model.doc.selectedID, parts[1].id)

        // Too close to an edge: refused.
        f.model.splitTitle(a.id, at: 1.05)
        XCTAssertEqual(f.en.doc.subtitles.count, 2)

        // One undo puts the title back.
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitles, [a])
    }

    func testSplittingAtThePlayhead() {
        let a = sub(1, 3, "One two three four")
        let f = makeFixture([("en", [a])])
        f.engine.currentTime = 5
        f.model.splitAtPlayhead()                                   // not over a title
        XCTAssertEqual(f.en.doc.subtitles.count, 1)
        f.engine.currentTime = 2
        f.model.splitAtPlayhead()
        XCTAssertEqual(f.en.doc.subtitles.map(\.text), ["One two three four", ""])
    }

    func testSplittingNeverDividesTheText() {
        // However the split falls, all the words stay in the left title, formatting included.
        for t in [1.2, 2.0, 2.8] {
            let a = sub(1, 3, "<i>First</i> line\nSecond line here")
            let f = makeFixture([("en", [a])])
            f.model.splitTitle(a.id, at: t)
            XCTAssertEqual(f.en.doc.subtitles.map(\.text), ["<i>First</i> line\nSecond line here", ""])
        }
        // An empty title splits into two empty titles.
        let e = sub(1, 3, "")
        let g = makeFixture([("en", [e])])
        g.model.splitTitle(e.id, at: 2)
        XCTAssertEqual(g.en.doc.subtitles.map(\.text), ["", ""])
    }

    func testMovingTitlesInTime() {
        let a = sub(1, 2, "A"), b = sub(3, 4, "B")
        let ha = sub(1, 2, "a"), hb = sub(3, 4, "b")
        let f = makeFixture([("en", [a, b]), ("hr", [ha, hb])])

        // Only the selected title, only this language.
        f.model.select(b.id)
        f.model.shiftTitles(by: 0.5, onlySelected: true, allLanguages: false)
        XCTAssertEqual(f.en.doc.subtitles.map(\.start), [1, 3.5])
        XCTAssertEqual(f.en.doc.subtitles.map(\.end), [2, 4.5])
        XCTAssertEqual(f.hr.doc.subtitles.map(\.start), [1, 3])

        // Everything, every language. Nothing goes before zero, and lengths are kept.
        f.model.shiftTitles(by: -2, onlySelected: false, allLanguages: true)
        XCTAssertEqual(f.en.doc.subtitles.map(\.start), [0, 1.5])
        XCTAssertEqual(f.en.doc.subtitles.map(\.end), [1, 2.5])
        XCTAssertEqual(f.hr.doc.subtitles.map(\.start), [0, 1])

        // Each language undoes on its own.
        f.model.undo()
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitles.map(\.start), [1, 3.5])
        XCTAssertEqual(f.hr.doc.subtitles.map(\.start), [1, 3])
    }

    func testOffsetsCanBeTypedAsSecondsOrTimecode() throws {
        let f = makeFixture([("en", [sub(1, 2, "A")])])
        XCTAssertEqual(try XCTUnwrap(f.model.parseOffset("+1.5")), 1.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.model.parseOffset("-0,25")), -0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.model.parseOffset(" 2 ")), 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.model.parseOffset("-00:00:01:12")), -1.48, accuracy: 0.0001)   // 12 frames at 25
        XCTAssertEqual(try XCTUnwrap(f.model.parseOffset("1:30")), 90, accuracy: 0.0001)
        XCTAssertNil(f.model.parseOffset("soon"))
        XCTAssertNil(f.model.parseOffset("1:2:3:4:5"))
    }

    func testDeletingTheSelectedTitle() {
        let a = sub(1, 2, "A"), b = sub(3, 4, "B")
        let f = makeFixture([("en", [a, b])])
        f.model.deleteSelected()                                    // nothing selected: nothing happens
        XCTAssertEqual(f.en.doc.subtitles.count, 2)
        f.model.select(a.id)
        f.model.deleteSelected()
        XCTAssertEqual(f.en.doc.subtitles, [b])
        XCTAssertEqual(f.model.doc.selectedID, b.id)
    }

    // MARK: Undo across languages

    func testUndoGoesBackThroughTheLanguagesInOrder() {
        let a = sub(1, 2, "Hello"), ha = sub(1, 2, "Bok")
        let f = makeFixture([("en", [a]), ("hr", [ha])])
        f.en.doc.setText(a.id, "Hello there")
        f.hr.doc.setText(ha.id, "Bok svima")

        f.model.undo()
        XCTAssertEqual(f.hr.doc.subtitle(ha.id)?.text, "Bok")
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "Hello there")
        XCTAssertEqual(f.video.focusedTrackID, f.hr.id)             // and it takes you there
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "Hello")
        XCTAssertEqual(f.video.focusedTrackID, f.en.id)
        f.model.undo()                                              // nothing left: nothing happens
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "Hello")

        f.model.redo()
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "Hello there")
        f.model.redo()
        XCTAssertEqual(f.hr.doc.subtitle(ha.id)?.text, "Bok svima")
        XCTAssertEqual(f.video.focusedTrackID, f.hr.id)
    }

    func testUndoTakesThePlayheadToWhatChanged() {
        let a = sub(1, 2, "A"), b = sub(30, 31, "B")
        let f = makeFixture([("en", [a, b])])
        f.en.doc.update(b.id) { $0.end = 32 }
        f.engine.currentTime = 0
        f.model.undo()
        XCTAssertEqual(f.engine.currentTime, 30, accuracy: 0.0001)
        XCTAssertEqual(f.model.doc.selectedID, b.id)
    }

    // MARK: Line breaks

    private let long = "I never thought I would see you again after all these years."
    private let longBroken = "I never thought I would see\nyou again after all these years."

    func testALongTitleIsBrokenWhenYouLeaveTheCard() {
        let a = sub(1, 4, "")
        let f = makeFixture([("en", [a])])
        f.en.doc.setText(a.id, "I never")
        f.en.doc.setText(a.id, long)
        f.model.autoBreak(a.id)
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, longBroken)

        // Typing and the break that follows are one undo step.
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "")
    }

    func testYourOwnLineBreaksAreLeftAlone() {
        let mine = "I never thought\nI would see you again after all these years."
        let a = sub(1, 4, mine), short = sub(5, 6, "Hello\nthere")
        let f = makeFixture([("en", [a, short])])
        f.model.autoBreak(a.id)
        f.model.autoBreak(short.id)
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, mine)
        XCTAssertEqual(f.en.doc.subtitle(short.id)?.text, "Hello\nthere")
        // Lines that were wrapped for you while typing are evened out.
        f.model.autoBreak(a.id, rebalance: true)
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, longBroken)
    }

    func testAutomaticLineBreaksCanBeSwitchedOff() {
        let a = sub(1, 4, long)
        let f = makeFixture([("en", [a])])
        f.model.autoLineBreaks = false
        f.model.autoBreak(a.id)
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, long)
        XCTAssertNil(f.model.liveBreak(long, track: f.en))
        f.model.autoLineBreaks = true
    }

    func testLinesBreakWhileTyping() {
        let f = makeFixture([("en", [sub(1, 4, "")])])
        XCTAssertNil(f.model.liveBreak("A short line", track: f.en))
        XCTAssertNil(f.model.liveBreak("Two short\nlines", track: f.en))
        XCTAssertEqual(f.model.liveBreak(long, track: f.en), longBroken)
        // A space just typed is kept, so the next word doesn't stick to the last one.
        XCTAssertEqual(f.model.liveBreak(long + " ", track: f.en), longBroken + " ")
        // The language's own line length counts.
        f.en.maxCharsPerLine = 20
        XCTAssertNotNil(f.model.liveBreak("This line is longer than twenty", track: f.en))
    }

    func testReBreakingEveryLineInTheFocusedLanguage() {
        let a = sub(1, 4, long), b = sub(5, 8, "I never\nthought I would see you again after all these years.")
        let c = sub(9, 10, "Short")
        let hr = sub(1, 4, "Nisam znao da ćeš doći, ali drago mi je što si ovdje.")
        let f = makeFixture([("en", [a, b, c]), ("hr", [hr])])
        f.model.rebreakAll()
        XCTAssertEqual(f.en.doc.subtitles.map(\.text), [longBroken, longBroken, "Short"])
        XCTAssertEqual(f.hr.doc.subtitles[0].text, hr.text)         // the other language is untouched
        f.model.undo()                                              // one step for the lot
        XCTAssertEqual(f.en.doc.subtitles.map(\.text), [a.text, b.text, "Short"])

        f.model.select(a.id)
        f.model.rebreakSelected()
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, longBroken)
        XCTAssertEqual(f.en.doc.subtitle(b.id)?.text, b.text)
    }

    func testPastedTextIsBroken() {
        let a = sub(1, 4, "Already\nbroken badly because it was pasted in from somewhere else")
        let f = makeFixture([("en", [a])])
        f.model.autoBreakAfterPaste(a.id)
        let text = f.en.doc.subtitle(a.id)?.text ?? ""
        XCTAssertEqual(shownLines(text).count, 2)
        XCTAssertTrue(shownLines(text).allSatisfy { $0.count <= 42 }, text)
    }

    // MARK: Timecodes on screen

    func testTimesAreShownInFramesOrMilliseconds() {
        let f = makeFixture([("en", [sub(1, 2, "A")])])
        XCTAssertEqual(f.model.tc(13.28), "00:00:13:07")
        f.model.project?.settings.startTimecode = 36000             // the picture starts at 10:00:00:00
        XCTAssertEqual(f.model.tc(13.28), "10:00:13:07")
        f.model.project?.settings.timecodeDisplay = .milliseconds
        XCTAssertEqual(f.model.tc(13.28), "10:00:13,280")
        // The project's frame rate wins over the video's.
        f.model.project?.settings.frameRate = 50
        XCTAssertEqual(f.model.fps, 50)
        XCTAssertEqual(f.model.minGap, 0.04, accuracy: 0.0001)
    }

    // MARK: Export

    func testExportNamesAndContents() {
        let f = makeFixture([("en", [sub(1, 2, "Hello"), sub(3, 4, "")]), ("hr", [sub(1, 2, "Bok")])])
        let all = f.model.exportItems(allLanguages: true, allVideos: false, format: .srt)
        XCTAssertEqual(all.map(\.name), ["Film.en.srt", "Film.hr.srt"])
        XCTAssertEqual(String(decoding: all[0].data, as: UTF8.self),
                       "1\r\n00:00:01,000 --> 00:00:02,000\r\nHello\r\n\r\n")      // the empty title is left out

        let one = f.model.exportItems(allLanguages: false, allVideos: false, format: .vtt)
        XCTAssertEqual(one.map(\.name), ["Film.en.vtt"])
        XCTAssertTrue(String(decoding: one[0].data, as: UTF8.self).hasPrefix("WEBVTT"))

        f.model.project?.settings.namingPattern = "{project}-{video}-{lang}"
        f.model.project?.settings.utf8BOM = true
        f.model.focusTrack(f.hr.id, edit: false)
        let named = f.model.exportItems(allLanguages: false, allVideos: false, format: .srt)
        XCTAssertEqual(named.map(\.name), ["Test-Film-hr.srt"])
        XCTAssertEqual(Array(named[0].data.prefix(3)), [0xEF, 0xBB, 0xBF])
    }
}
