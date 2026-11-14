import XCTest
@testable import Titles

/// Dragging titles into each other: they stop at the minimum gap, and only go over a
/// neighbour when overlapping titles are enabled (Title menu), and then only when pulled on.
@MainActor
final class OverlapTests: XCTestCase {
    private let gap = 0.08
    private let pull = 0.4      // the break distance, in seconds, for these tests

    private func span(_ s: Double, _ e: Double) -> DragResistance.Span { .init(start: s, end: e) }

    private func resistance(_ mode: DragResistance.Mode, _ dragged: [DragResistance.Span], _ others: [Subtitle],
                            overlaps: Bool) -> DragResistance {
        DragResistance(mode: mode, original: dragged, others: others, gap: gap, allowOverlap: overlaps,
                       breakDistance: pull)
    }

    // MARK: Resistance

    func testAnEdgeStopsAtTheGapAndGivesOnlyWhenPulledOn() {
        let next = sub(4, 6)
        var r = resistance(.edge(.end), [span(1, 3)], [next], overlaps: true)
        XCTAssertEqual(r.drag(to: 3.5), 3.5, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 4.2), 4 - gap, accuracy: 1e-9)          // stops at the gap
        XCTAssertTrue(r.bumped)
        XCTAssertEqual(r.drag(to: 4.5), 4 - gap, accuracy: 1e-9)          // 0.3 further: still held
        XCTAssertFalse(r.bumped)
        XCTAssertEqual(r.drag(to: 4.7), 4.7, accuracy: 1e-9)              // 0.5 further: through
        XCTAssertTrue(r.bumped)
        XCTAssertEqual(r.drag(to: 5.5), 5.5, accuracy: 1e-9)              // overlapping, free
    }

    func testTheResistanceComesBackEveryTimeTheyStopOverlapping() {
        let next = sub(4, 6)
        var r = resistance(.edge(.end), [span(1, 3)], [next], overlaps: true)
        r.drag(to: 4.2)
        r.drag(to: 4.7)                                                    // through
        XCTAssertEqual(r.drag(to: 5), 5, accuracy: 1e-9)
        // Back out: the moment they're apart, it stops at the gap (not just anywhere).
        XCTAssertEqual(r.drag(to: 3.99), 4 - gap, accuracy: 1e-9)
        XCTAssertTrue(r.bumped)
        // In again: as hard as the first time.
        XCTAssertEqual(r.drag(to: 4.3), 4 - gap, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 4.35), 4 - gap, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 4.45), 4.45, accuracy: 1e-9)            // 0.46 past 3.99: through
        // And again.
        XCTAssertEqual(r.drag(to: 3.9), 3.9, accuracy: 1e-9)               // well clear: free
        XCTAssertEqual(r.drag(to: 4.1), 4 - gap, accuracy: 1e-9)
    }

    func testTheStartEdgeHoldsTheSameWay() {
        let before = sub(1, 2)
        var r = resistance(.edge(.start), [span(3, 4)], [before], overlaps: true)
        XCTAssertEqual(r.drag(to: 2.5), 2.5, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 1.9), 2 + gap, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 1.6), 2 + gap, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 1.4), 1.4, accuracy: 1e-9)               // through
        XCTAssertEqual(r.drag(to: 2.01), 2 + gap, accuracy: 1e-9)          // apart: held again
        XCTAssertEqual(r.drag(to: 1.7), 2 + gap, accuracy: 1e-9)
    }

    func testWithOverlapsOffATitleNeverGoesOverItsNeighbour() {
        let next = sub(4, 6)
        var r = resistance(.edge(.end), [span(1, 3)], [next], overlaps: false)
        XCTAssertEqual(r.drag(to: 4.5), 4 - gap, accuracy: 1e-9)
        XCTAssertFalse(r.refused)
        XCTAssertEqual(r.drag(to: 9), 4 - gap, accuracy: 1e-9)
        XCTAssertTrue(r.refused)                                           // pulled hard: say why
        XCTAssertEqual(r.drag(to: 3.2), 3.2, accuracy: 1e-9)
    }

    func testAFastDragCantJumpOverATitleAndTheNextOneHoldsInTurn() {
        let b = sub(3, 4), c = sub(5, 6)
        var r = resistance(.move, [span(1, 2)], [b, c], overlaps: true)
        // One big jump of the pointer: the title stops at b, not somewhere past it.
        XCTAssertEqual(r.drag(to: 10), 3 - gap - 2, accuracy: 1e-9)
        // Pulled on through b, it goes on only as far as c.
        XCTAssertEqual(r.drag(to: 10.5), 5 - gap - 2, accuracy: 1e-9)
        XCTAssertEqual(r.spans[0].end, 5 - gap, accuracy: 1e-9)

        var off = resistance(.move, [span(1, 2)], [b, c], overlaps: false)
        XCTAssertEqual(off.drag(to: 10), 3 - gap - 2, accuracy: 1e-9)
        XCTAssertEqual(off.drag(to: 20), 3 - gap - 2, accuracy: 1e-9)
    }

    func testPassingRightThroughATitleHoldsOnItsFarSide() {
        let b = sub(3, 4)
        var r = resistance(.move, [span(1, 2)], [b], overlaps: true)
        r.drag(to: 0.95)
        XCTAssertEqual(r.drag(to: 1.3), 0.92, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 1.4), 1.4, accuracy: 1e-9)               // through
        // Out the far side: it stops just past b, at the gap.
        XCTAssertEqual(r.drag(to: 3.02), 3.08, accuracy: 1e-9)
        XCTAssertEqual(r.spans[0].start, 4 + gap, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 2.9), 3.08, accuracy: 1e-9)              // back towards b: held
        XCTAssertEqual(r.drag(to: 2.5), 2.5, accuracy: 1e-9)               // pulled on: through again
    }

    func testTitlesThatAlreadyOverlapCanComeApartButNotGoBack() {
        let b = sub(3, 5)
        var r = resistance(.edge(.end), [span(1, 3.5)], [b], overlaps: false)
        XCTAssertEqual(r.drag(to: 4.5), 4.5, accuracy: 1e-9)               // it already overlapped
        XCTAssertEqual(r.drag(to: 2.95), 3 - gap, accuracy: 1e-9)          // apart: held at the gap
        XCTAssertEqual(r.drag(to: 3.6), 3 - gap, accuracy: 1e-9)           // and it stays apart
    }

    func testATitleAlreadyCloserThanTheGapIsntPushedAway() {
        let b = sub(3.03, 5)
        var r = resistance(.edge(.end), [span(1, 3)], [b], overlaps: false)
        XCTAssertEqual(r.drag(to: 3), 3, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 3.02), 3, accuracy: 1e-9)                // no closer
        XCTAssertEqual(r.drag(to: 2.5), 2.5, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 3.1), 3, accuracy: 1e-9)                 // back to where it was
    }

    func testAGroupStopsAtTheFirstTitleInTheWayOfAnyOfIt() {
        let y = sub(2.5, 3.5), x = sub(6, 7)        // y sits between the two picked titles
        var r = resistance(.move, [span(1, 2), span(4, 5)], [x, y], overlaps: false)
        XCTAssertEqual(r.drag(to: 3), 2.5 - gap - 2, accuracy: 1e-9)       // the first one meets y
        XCTAssertEqual(r.drag(to: -3), 3.5 + gap - 4, accuracy: 1e-9)      // the second one meets y
    }

    func testANewTitleStopsAtTheGapEitherWay() {
        let before = sub(1, 2), after = sub(5, 6)
        var r = resistance(.draw(from: 3), [span(3, 3)], [before, after], overlaps: false)
        XCTAssertEqual(r.drag(to: 4), 4, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 7), 5 - gap, accuracy: 1e-9)
        XCTAssertEqual(r.drag(to: 0), 2 + gap, accuracy: 1e-9)
    }

    // MARK: The setting

    func testOverlappingTitlesAreOffUnlessEnabled() {
        let f = makeFixture([("en", [sub(1, 2)])])
        XCTAssertFalse(f.model.allowOverlaps)
        // The choice is remembered for the next time KPTN.SUB opens.
        @MainActor func reopened() -> Bool {
            let m = AppModel(engine: FakeEngine())
            m.persists = false
            return m.allowOverlaps
        }
        f.model.allowOverlaps = true
        XCTAssertTrue(reopened())
        f.model.allowOverlaps = false
        XCTAssertFalse(reopened())
    }

    // MARK: Other ways titles are made or moved

    func testSpottingKeepsClearOfOtherTitlesWithOverlapsOff() throws {
        let a = sub(5, 8, "A"), b = sub(10, 12, "B")
        let f = makeFixture([("en", [a, b])])
        f.model.spotMode = .hold
        f.model.spotStartOffset = 0
        f.model.spotEndOffset = 0
        f.engine.isPlaying = true
        let gap = f.model.minGap

        // Inside a title: nothing is spotted.
        f.engine.currentTime = 6
        f.model.spotDown()
        XCTAssertFalse(f.model.isSpotting)
        XCTAssertEqual(f.en.doc.subtitles.count, 2)

        // From a gap: the title ends the minimum gap before the next one, however late the key is let go.
        f.engine.currentTime = 9
        f.model.spotDown()
        XCTAssertTrue(f.model.isSpotting)
        f.engine.currentTime = 11
        f.model.spotUp()
        let spotted = try XCTUnwrap(f.en.doc.subtitles.first { $0.id != a.id && $0.id != b.id })
        XCTAssertEqual(spotted.start, 9, accuracy: 0.0001)
        XCTAssertEqual(spotted.end, 10 - gap, accuracy: 0.0001)

        // With overlaps on, spotting goes over titles as before.
        f.model.allowOverlaps = true
        f.engine.currentTime = 6
        f.model.spotDown()
        XCTAssertTrue(f.model.isSpotting)
        f.engine.currentTime = 7
        f.model.spotUp()
        XCTAssertEqual(f.en.doc.subtitles.count, 4)
        f.model.allowOverlaps = false
    }

    func testTheRoomForANewTitleKeepsTheGap() throws {
        let subs = [sub(1, 2), sub(5, 6)]
        let free = try XCTUnwrap(AppModel.room(for: (2.5, 4.5), among: subs, gap: gap))
        XCTAssertEqual(free.start, 2.5, accuracy: 1e-9)
        XCTAssertEqual(free.end, 4.5, accuracy: 1e-9)
        let trimmed = try XCTUnwrap(AppModel.room(for: (1.5, 5.5), among: [sub(5, 6)], gap: gap))
        XCTAssertEqual(trimmed.start, 1.5, accuracy: 1e-9)
        XCTAssertEqual(trimmed.end, 5 - gap, accuracy: 1e-9)
        let both = try XCTUnwrap(AppModel.room(for: (1.5, 5.5), among: subs, gap: gap))
        XCTAssertEqual(both.start, 2 + gap, accuracy: 1e-9)
        XCTAssertEqual(both.end, 5 - gap, accuracy: 1e-9)
        XCTAssertNil(AppModel.room(for: (0.5, 2.5), among: subs, gap: gap))        // a title inside it
        XCTAssertNil(AppModel.room(for: (2.0, 2.1), among: subs, gap: gap))        // no room left
    }

    func testANewTitleInAnEmptySlotKeepsClearOfThisLanguagesOthers() throws {
        // The English title has no Croatian partner, but a Croatian title starts before it ends.
        let a = sub(1, 4, "A")
        let x = sub(3.4, 6, "x")
        let f = makeFixture([("en", [a]), ("hr", [x])])
        f.model.focusTrack(f.hr.id, edit: false)
        let key = try XCTUnwrap(f.model.rows.first { $0.cells[f.en.id]?.id == a.id && $0.cells[f.hr.id] == nil }?.key)
        f.model.createInRow(key)
        let made = try XCTUnwrap(f.hr.doc.subtitles.first { $0.id != x.id })
        XCTAssertEqual(made.start, 1, accuracy: 0.0001)
        XCTAssertEqual(made.end, 3.4 - f.model.minGap, accuracy: 0.0001)
        XCTAssertTrue(f.hr.doc.overlappingIDs.isEmpty)
    }

    func testShiftTitlesStopsAtTheNextTitleWithOverlapsOff() {
        let a = sub(1, 2, "A"), b = sub(3, 4, "B")
        let f = makeFixture([("en", [a, b])])
        f.model.select(a.id)
        f.model.shiftTitles(by: 2, onlySelected: true, allLanguages: false)
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.end ?? 0, 3 - f.model.minGap, accuracy: 0.0001)
        XCTAssertTrue(f.en.doc.overlappingIDs.isEmpty)

        f.model.allowOverlaps = true
        f.model.shiftTitles(by: 1, onlySelected: true, allLanguages: false)
        XCTAssertFalse(f.en.doc.overlappingIDs.isEmpty)
        f.model.allowOverlaps = false
    }
}
