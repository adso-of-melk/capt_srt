import XCTest
@testable import Titles
@testable import TitlesCore

/// Title ▸ Keep Minimum Gap. On (the default): no gap goes under the project's minimum, and a
/// title that moves while it sits too close to a neighbour gets that gap fixed in the same
/// undo step. Off: the hold at the minimum gap gives when pulled on, down to touching.
/// 25 frames a second, General rules: a 2-frame (0.08 s) gap, 0.833 s minimum duration.
@MainActor
final class GapTests: XCTestCase {
    private let gap = 0.08
    private let pull = 0.4      // the break distance, in seconds, for these tests

    private func span(_ s: Double, _ e: Double) -> DragResistance.Span { .init(start: s, end: e) }

    private func resistance(_ dragged: DragResistance.Span, _ others: [Subtitle], overlaps: Bool,
                            keepGap: Bool) -> DragResistance {
        DragResistance(mode: .edge(.end), original: [dragged], others: others, gap: gap, allowOverlap: overlaps,
                       keepGap: keepGap, breakDistance: pull)
    }

    // MARK: Dragging

    func testWithTheGapKeptAHardPullSaysItsTheGapThatHolds() {
        var r = resistance(span(1, 3), [sub(4, 6)], overlaps: false, keepGap: true)
        XCTAssertEqual(r.drag(to: 4.5), 4 - gap, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 9), 4 - gap, accuracy: 1e-9)
        XCTAssertTrue(r.refused)
        XCTAssertTrue(r.refusedAtGap)
    }

    func testWithTheGapNotKeptAPullTakesATitleCloserDownToTouching() {
        var r = resistance(span(1, 3), [sub(4, 6)], overlaps: false, keepGap: false)
        XCTAssertEqual(r.drag(to: 4.2), 4 - gap, accuracy: 1e-9)          // held at the gap first
        XCTAssertEqual(r.drag(to: 4.5), 4 - gap, accuracy: 1e-9)          // 0.3 further: still held
        XCTAssertEqual(r.drag(to: 4.7), 4, accuracy: 1e-9)                // 0.5 further: closer, held at touching
        XCTAssertTrue(r.bumped)
        XCTAssertEqual(r.drag(to: 3.95), 3.95, accuracy: 1e-9)            // anywhere in the gap now
        // At touching it never goes over (overlapping titles are off), and says why.
        XCTAssertEqual(r.drag(to: 9), 4, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 9.5), 4, accuracy: 1e-9)
        XCTAssertTrue(r.refused)
        XCTAssertFalse(r.refusedAtGap)
        // Back out past the gap: the hold there is back.
        XCTAssertEqual(r.drag(to: 3.5), 3.5, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 4.3), 4 - gap, accuracy: 1e-9)
    }

    func testWithOverlapsOnTooASecondPullGoesOverTheNeighbour() {
        var r = resistance(span(1, 3), [sub(4, 6)], overlaps: true, keepGap: false)
        XCTAssertEqual(r.drag(to: 4.2), 4 - gap, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 4.7), 4, accuracy: 1e-9)                // touching
        XCTAssertEqual(r.drag(to: 5.0), 4, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 5.2), 5.2, accuracy: 1e-9)              // 0.5 past touching: over it
        XCTAssertFalse(r.refused)
    }

    // MARK: Nudging

    func testWithTheGapNotKeptANudgeFromTheMinimumGapGoesOnCloser() throws {
        let a = sub(1, 2, "A"), b = sub(2.5, 3.5, "B")
        let f = makeFixture([("en", [a, b])])
        f.model.keepMinGap = false
        f.model.select(a.id)
        f.model.nudge(.end, by: 1)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 2.42, accuracy: 0.0001)  // stops at the gap
        f.model.nudge(.end, frames: 1)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 2.46, accuracy: 0.0001)  // one more: closer
        f.model.nudge(.end, by: 1)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 2.5, accuracy: 0.0001)   // touching
        f.model.nudge(.end, by: 1)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 2.5, accuracy: 0.0001)   // never over it
    }

    func testANudgeNeverMakesATitleThatsTooCloseJumpAway() throws {
        let a = sub(1, 2.46, "A"), b = sub(2.5, 3.5, "B")   // 1 frame apart (an imported file)
        let f = makeFixture([("en", [a, b])])
        f.model.select(b.id)
        f.model.nudge(.start, frames: -1)
        // It can't come closer, and doesn't leap out to the minimum gap either.
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).start, 2.5, accuracy: 0.0001)
        // Its end moves on: B has moved, so when the nudges are done the short gap before it is
        // fixed too, A's end coming back to the minimum gap (B's start stays on its word).
        f.model.nudge(.end, frames: 1)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 2.46, accuracy: 0.0001)  // not while nudging
        f.en.doc.commitLive()
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 2.42, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).start, 2.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).end, 3.54, accuracy: 0.0001)
        XCTAssertEqual(f.model.shortGapCount(in: f.en), 0)
    }

    // MARK: Fixing gaps that were already short

    func testMovingATitleThatSitsTooCloseFixesItsGapInTheSameUndoStep() throws {
        let a = sub(1, 3, "A"), b = sub(3.04, 5, "B"), c = sub(7, 9, "C")
        let f = makeFixture([("en", [a, b, c])])
        f.model.focusTrack(f.en.id, edit: false)
        XCTAssertEqual(f.model.shortGapCount(in: f.en), 1)
        // Typing moves nothing, so nothing else changes.
        f.en.doc.setText(b.id, "Changed")
        f.en.doc.endTextCoalescing()
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 3, accuracy: 0.0001)
        // B's end moves: A's end comes back to the minimum gap before B, in the same step.
        f.en.doc.update(b.id) { $0.end = 5.2 }
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 2.96, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).start, 3.04, accuracy: 0.0001)   // B's start stays on its word
        XCTAssertEqual(f.model.shortGapCount(in: f.en), 0)
        f.model.undo()
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).end, 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).text, "Changed")

        // A drag or jog: fixed when it ends, not while it runs.
        f.en.doc.liveUpdate(b.id) { $0.end = 5.4 }
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 3, accuracy: 0.0001)
        f.en.doc.commitLive()
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 2.96, accuracy: 0.0001)
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitles.map(\.end), [3, 5, 9])
    }

    func testTitlesThatDontMoveAndOverlapsAreLeftAlone() throws {
        let a = sub(1, 3), b = sub(3.04, 5), c = sub(7, 9), d = sub(8.5, 10)   // a-b short, c-d overlap
        let f = makeFixture([("en", [a, b, c, d])])
        f.model.focusTrack(f.en.id, edit: false)
        f.en.doc.update(c.id) { $0.start = 6.9 }
        let subs = f.en.doc.subtitles
        XCTAssertEqual(subs.map(\.start), [1, 3.04, 6.9, 8.5])
        XCTAssertEqual(subs.map(\.end), [3, 5, 9, 10])
    }

    func testWithTheGapNotKeptShortGapsStayWhenTheirTitlesMove() throws {
        let a = sub(1, 3), b = sub(3.04, 5)
        let f = makeFixture([("en", [a, b])])
        f.model.keepMinGap = false
        f.en.doc.update(b.id) { $0.end = 5.2 }
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).end, 3, accuracy: 0.0001)
    }

    func testShortGapsAreCountedAndNamedAfterAnImportOrALargerMinimum() throws {
        let f = makeFixture([("en", [sub(1, 3), sub(3.04, 5), sub(5.08, 7), sub(7.2, 9)])])
        f.model.focusTrack(f.en.id, edit: false)
        XCTAssertEqual(f.model.shortGapCount(in: f.en), 1)
        f.model.noteShortGaps(in: f.en)
        XCTAssertEqual(f.model.banner?.hasPrefix("1 gap is under the minimum"), true)
        f.model.banner = nil

        // A 4-frame minimum (0.16 s): the 0.08 gap is short now too; the 0.2 gap isn't.
        var settings = try XCTUnwrap(f.model.project?.settings)
        settings.standard.minGapFrames = 4
        f.model.applySettings(settings, name: "")
        XCTAssertEqual(f.model.shortGapCount(in: f.en), 2)
        XCTAssertEqual(f.model.banner?.hasPrefix("2 gaps are under the minimum"), true)

        // With Keep Minimum Gap off, nothing is said.
        f.model.banner = nil
        f.model.keepMinGap = false
        f.model.noteShortGaps(in: f.en)
        XCTAssertNil(f.model.banner)
    }
}
