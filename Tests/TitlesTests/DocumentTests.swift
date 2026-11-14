import XCTest
@testable import Titles

/// One language's list of titles: order, selection, undo and gestures.
@MainActor
final class DocumentTests: XCTestCase {

    private func document(_ subs: [Subtitle]) -> SubtitleDocument {
        let doc = SubtitleDocument()
        doc.replaceAll(subs)
        return doc
    }

    func testTitlesStayInTimeOrder() {
        let doc = SubtitleDocument()
        let late = doc.add(start: 10, end: 11, text: "Late")
        let early = doc.add(start: 1, end: 2, text: "Early")
        let middle = doc.add(start: 5, end: 6, text: "Middle")
        XCTAssertEqual(doc.subtitles.map(\.text), ["Early", "Middle", "Late"])
        XCTAssertEqual(doc.number(of: early), 1)
        XCTAssertEqual(doc.number(of: middle), 2)
        XCTAssertEqual(doc.number(of: late), 3)
        XCTAssertEqual(doc.selectedID, middle)

        // Moving a title past its neighbour re-sorts the list.
        doc.update(late) { $0.start = 0; $0.end = 0.5 }
        XCTAssertEqual(doc.subtitles.map(\.text), ["Late", "Early", "Middle"])
        XCTAssertEqual(doc.previous(of: early)?.text, "Late")
        XCTAssertEqual(doc.next(of: early)?.text, "Middle")
        XCTAssertNil(doc.next(of: middle))
    }

    func testANewTitleIsNeverShorterThanATenthOfASecond() throws {
        let doc = SubtitleDocument()
        let id = doc.add(start: 3, end: 3)
        XCTAssertEqual(try XCTUnwrap(doc.subtitle(id)).end, 3.1, accuracy: 0.0001)
    }

    func testUndoAndRedo() {
        let a = sub(1, 2, "One")
        let doc = document([a])
        XCTAssertFalse(doc.canUndo)
        XCTAssertFalse(doc.isDirty)

        doc.update(a.id) { $0.end = 3 }
        doc.add(start: 5, end: 6, text: "Two")
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.subtitles.count, 2)

        doc.undo()
        XCTAssertEqual(doc.subtitles.count, 1)
        XCTAssertEqual(doc.subtitles[0].end, 3)
        doc.undo()
        XCTAssertEqual(doc.subtitles, [a])
        XCTAssertFalse(doc.canUndo)
        XCTAssertTrue(doc.canRedo)

        doc.redo()
        doc.redo()
        XCTAssertEqual(doc.subtitles.count, 2)
        XCTAssertFalse(doc.canRedo)

        // A new change after an undo clears what could be redone.
        doc.undo()
        doc.update(a.id) { $0.text = "Changed" }
        XCTAssertFalse(doc.canRedo)
    }

    func testAChangeThatChangesNothingIsNotAnUndoStep() {
        let a = sub(1, 2, "One")
        let doc = document([a])
        doc.update(a.id) { $0.end = 2 }
        doc.setText(a.id, "One")
        XCTAssertFalse(doc.canUndo)
        XCTAssertFalse(doc.isDirty)
    }

    func testTypingInOneTitleIsOneUndoStep() {
        let a = sub(1, 2, ""), b = sub(3, 4, "")
        let doc = document([a, b])
        doc.setText(a.id, "H")
        doc.setText(a.id, "He")
        doc.setText(a.id, "Hey")
        doc.setText(b.id, "Y")
        doc.setText(b.id, "Yo")

        doc.undo()
        XCTAssertEqual(doc.subtitle(b.id)?.text, "")
        XCTAssertEqual(doc.subtitle(a.id)?.text, "Hey")
        doc.undo()
        XCTAssertEqual(doc.subtitle(a.id)?.text, "")
        XCTAssertFalse(doc.canUndo)
    }

    func testComingBackToATitleStartsANewUndoStep() {
        let a = sub(1, 2, "")
        let doc = document([a])
        doc.setText(a.id, "First")
        doc.endTextCoalescing()      // the card was left
        doc.setText(a.id, "First, then more")

        doc.undo()
        XCTAssertEqual(doc.subtitle(a.id)?.text, "First")
        doc.undo()
        XCTAssertEqual(doc.subtitle(a.id)?.text, "")
    }

    func testPastedWindowsLineEndingsBecomeOrdinaryLineBreaks() {
        let a = sub(1, 3, "")
        let doc = document([a])
        doc.setText(a.id, "One\r\nTwo\rThree")
        XCTAssertEqual(doc.subtitle(a.id)?.text, "One\nTwo\nThree")
        XCTAssertEqual(doc.subtitle(a.id)?.characterCount, 11)
        XCTAssertEqual(TimingPreset.general.longestLine(doc.subtitles[0]), 5)
    }

    func testADragIsOneUndoStep() {
        let a = sub(1, 2, "One")
        let doc = document([a])
        doc.beginLive()
        for step in 1...20 {
            doc.liveUpdate(a.id) { $0.start = 1 + Double(step) * 0.04; $0.end = 2 + Double(step) * 0.04 }
        }
        XCTAssertTrue(doc.isLive)
        XCTAssertFalse(doc.canUndo)
        doc.commitLive()
        XCTAssertFalse(doc.isLive)
        XCTAssertEqual(doc.subtitles[0].start, 1.8, accuracy: 0.0001)

        doc.undo()
        XCTAssertEqual(doc.subtitles, [a])
        XCTAssertFalse(doc.canUndo)
    }

    func testACancelledDragLeavesNoTrace() {
        let a = sub(1, 2, "One")
        let doc = document([a])
        doc.liveUpdate(a.id) { $0.start = 1.5 }
        doc.cancelLive()
        XCTAssertEqual(doc.subtitles, [a])
        XCTAssertFalse(doc.canUndo)
        XCTAssertFalse(doc.isDirty)
    }

    func testADragBackToWhereItStartedIsNotAnUndoStep() {
        let a = sub(1, 2, "One")
        let doc = document([a])
        doc.liveUpdate(a.id) { $0.start = 1.5 }
        doc.liveUpdate(a.id) { $0.start = 1 }
        doc.commitLive()
        XCTAssertFalse(doc.canUndo)
    }

    func testAnEditDuringADragKeepsBothAsSeparateSteps() {
        let a = sub(1, 2, "One")
        let doc = document([a])
        doc.liveUpdate(a.id) { $0.end = 2.5 }
        doc.setText(a.id, "Edited")
        XCTAssertFalse(doc.isLive)
        doc.undo()
        XCTAssertEqual(doc.subtitles[0].text, "One")
        XCTAssertEqual(doc.subtitles[0].end, 2.5)
        doc.undo()
        XCTAssertEqual(doc.subtitles, [a])
    }

    func testDeletingSelectsTheNextTitleOrTheLastOne() {
        let a = sub(1, 2, "A"), b = sub(3, 4, "B"), c = sub(5, 6, "C")
        let doc = document([a, b, c])
        doc.delete(b.id)
        XCTAssertEqual(doc.selectedID, c.id)
        doc.delete(c.id)
        XCTAssertEqual(doc.selectedID, a.id)
        doc.delete(a.id)
        XCTAssertNil(doc.selectedID)
        XCTAssertTrue(doc.subtitles.isEmpty)
    }

    func testALostSelectionFallsBackToTheTitleBeforeThePlayhead() {
        let a = sub(1, 2, "A"), b = sub(3, 4, "B"), c = sub(5, 6, "C")
        let doc = document([a, b])
        doc.playheadTime = { 3.5 }
        doc.perform { $0.append(c) }
        doc.selectedID = c.id
        doc.undo()                    // c is gone again
        XCTAssertEqual(doc.selectedID, b.id)
    }

    func testOverlaps() {
        let a = sub(1, 3), b = sub(2, 4), c = sub(4, 5), d = sub(6, 7)
        XCTAssertEqual(document([a, b, c, d]).overlappingIDs, [a.id, b.id])
        // Touching titles don't overlap.
        XCTAssertTrue(document([sub(1, 2), sub(2, 3)]).overlappingIDs.isEmpty)
        // A long title overlaps everything inside it, not only the next one.
        let long = sub(1, 10), first = sub(2, 3), second = sub(4, 5)
        XCTAssertEqual(document([long, first, second]).overlappingIDs, [long.id, first.id, second.id])
    }

    func testTheTitleShowingAtATime() {
        let a = sub(1, 3, "A"), b = sub(2, 4, "B")
        let doc = document([a, b])
        XCTAssertNil(doc.active(at: 0.5))
        XCTAssertEqual(doc.active(at: 1.5)?.id, a.id)
        XCTAssertEqual(doc.active(at: 2.5)?.id, b.id)   // the later one wins where they overlap
        XCTAssertEqual(doc.active(at: 1)?.id, a.id)     // the start counts
        XCTAssertNil(doc.active(at: 4))                 // the end doesn't
    }

    func testLoadingAFileStartsCleanAndReplacingWithoutUndoKeepsHistory() {
        let a = sub(1, 2, "A")
        let doc = document([a])
        doc.update(a.id) { $0.end = 3 }
        doc.replaceAll([sub(5, 6, "Later"), sub(1, 2, "Earlier")])
        XCTAssertEqual(doc.subtitles.map(\.text), ["Earlier", "Later"])
        XCTAssertFalse(doc.canUndo)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(doc.selectedID, doc.subtitles.first?.id)

        doc.update(doc.subtitles[0].id) { $0.text = "Changed" }
        doc.syncReplace([sub(9, 10, "Synced")])
        XCTAssertEqual(doc.subtitles.map(\.text), ["Synced"])
        XCTAssertTrue(doc.canUndo)
        doc.markSaved()
        XCTAssertFalse(doc.isDirty)
    }

    func testChangeAndUndoStepCallbacks() {
        let a = sub(1, 2, "A")
        let doc = document([a])
        var changes = 0, steps = 0
        doc.onChange = { changes += 1 }
        doc.onUndoStep = { steps += 1 }

        doc.update(a.id) { $0.end = 3 }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(steps, 1)
        doc.undo()
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(steps, 1)      // undo itself is not a new step
        doc.liveUpdate(a.id) { $0.end = 2.5 }
        doc.liveUpdate(a.id) { $0.end = 2.6 }
        doc.commitLive()
        XCTAssertEqual(changes, 4)
        XCTAssertEqual(steps, 2)
    }

    func testUndoHistoryIsLimited() {
        let a = sub(0, 1, "A")
        let doc = document([a])
        for i in 1...510 { doc.update(a.id) { $0.end = 1 + Double(i) } }
        var undone = 0
        while doc.canUndo { doc.undo(); undone += 1 }
        XCTAssertEqual(undone, 500)
        XCTAssertEqual(doc.subtitles[0].end, 11)
    }
}
