import XCTest
import Combine
@testable import Titles
@testable import TitlesCore

/// The title pane scrolling: sideways a whole language at a time, gliding with playback, and
/// not redrawing the window each time the playhead reaches a title.
@MainActor
final class PaneScrollingTests: XCTestCase {

    private func wheel(_ dx: CGFloat, _ dy: CGFloat = 0, at time: TimeInterval = 0) -> ColumnStepper.Event {
        .init(dx: dx, dy: dy, precise: false, phase: .none, time: time)
    }

    private func swipe(_ phase: ColumnStepper.Phase, _ dx: CGFloat, _ dy: CGFloat = 0,
                       precise: Bool = true, at time: TimeInterval = 0) -> ColumnStepper.Event {
        .init(dx: dx, dy: dy, precise: precise, phase: phase, time: time)
    }

    // MARK: Sideways, a language at a time

    func testAWheelNotchMovesOneColumn() {
        var stepper = ColumnStepper()
        // Shift and the wheel down (or a sideways wheel to the right): on to the next language.
        XCTAssertEqual(stepper.feed(wheel(-3)), 1)
        XCTAssertEqual(stepper.feed(wheel(-1)), 1)
        // The other way: back one.
        XCTAssertEqual(stepper.feed(wheel(2)), -1)
        // Up-down scrolling goes through to the list.
        XCTAssertNil(stepper.feed(wheel(0, -3)))
        XCTAssertNil(stepper.feed(wheel(1, -6)))
    }

    func testASwipeMovesOneColumnThenOneMoreForEachLongerStretch() {
        var stepper = ColumnStepper()
        XCTAssertEqual(stepper.feed(swipe(.began, -5)), 0, "taken, but too short to move yet")
        XCTAssertEqual(stepper.feed(swipe(.changed, -25)), 1, "past the first step: one column on")
        XCTAssertEqual(stepper.feed(swipe(.changed, -100)), 0)
        XCTAssertEqual(stepper.feed(swipe(.changed, -60)), 1, "a long swipe crosses another")
        XCTAssertNil(stepper.feed(swipe(.ended, 0)), "the scroll view closes its gesture")
        XCTAssertEqual(stepper.feed(swipe(.momentum, -40)), 0, "the coasting after it is taken too")
        // A new swipe back.
        XCTAssertEqual(stepper.feed(swipe(.began, 30)), -1)
        XCTAssertEqual(ColumnStepper.columns(for: 23), 0)
        XCTAssertEqual(ColumnStepper.columns(for: -24), -1)
        XCTAssertEqual(ColumnStepper.columns(for: 24 + 160), 2)
    }

    func testAnUpDownSwipeIsLeftAlone() {
        var stepper = ColumnStepper()
        XCTAssertNil(stepper.feed(swipe(.began, 0, -10)))
        // It drifts sideways later on: still the list's.
        XCTAssertNil(stepper.feed(swipe(.changed, -50, -5)))
        XCTAssertNil(stepper.feed(swipe(.momentum, -20, -2)))
    }

    func testASmoothScrollingMouseCountsAPauseAsANewSwipe() {
        var stepper = ColumnStepper()
        XCTAssertEqual(stepper.feed(swipe(.none, -30, at: 0)), 1)
        XCTAssertEqual(stepper.feed(swipe(.none, -30, at: 0.05)), 0, "same movement, still one column")
        XCTAssertEqual(stepper.feed(swipe(.none, -30, at: 1)), 1, "after a pause: the next column")
    }

    func testThePaneStopsWithAWholeColumnAtItsLeftEdge() {
        // Two 240-point columns fill a 512-point pane (with its 24 points of margins and a gap).
        XCTAssertEqual(ColumnStops.fitting(width: 240, gap: 8, viewport: 512), 2)
        XCTAssertEqual(ColumnStops.last(count: 5, width: 240, gap: 8, viewport: 512), 3)
        XCTAssertEqual(ColumnStops.last(count: 2, width: 240, gap: 8, viewport: 512), 0)
        XCTAssertEqual(ColumnStops.current(offset: 496, width: 240, gap: 8), 2)
        XCTAssertEqual(ColumnStops.current(offset: 130, width: 240, gap: 8), 1)
        XCTAssertEqual(ColumnStops.current(offset: -20, width: 240, gap: 8), 0)
        // Focusing a language out of view brings it in, moving as little as it can.
        XCTAssertEqual(ColumnStops.revealing(4, from: 0, fit: 2, last: 3), 3)
        XCTAssertEqual(ColumnStops.revealing(1, from: 3, fit: 2, last: 3), 1)
        XCTAssertEqual(ColumnStops.revealing(2, from: 1, fit: 2, last: 3), 1, "already in view")
    }

    func testQuickStepsCountOnFromTheLastOneAskedFor() {
        let tracker = CardScrollTracker()
        let t = Date()
        XCTAssertEqual(tracker.columnStop(move: 1, current: 0, last: 3, now: t), 1)
        // The pane is still on its way there: the next notch goes one further, not to 1 again.
        XCTAssertEqual(tracker.columnStop(move: 1, current: 0, last: 3, now: t.addingTimeInterval(0.1)), 2)
        XCTAssertEqual(tracker.columnStop(move: 5, current: 1, last: 3, now: t.addingTimeInterval(0.2)), 3, "never past the last")
        XCTAssertNil(tracker.columnStop(move: 1, current: 3, last: 3, now: t.addingTimeInterval(0.3)), "already there")
        // Later, it counts from where the pane is.
        XCTAssertEqual(tracker.columnStop(move: -1, current: 3, last: 3, now: t.addingTimeInterval(2)), 2)
        XCTAssertEqual(tracker.columnStop(move: -9, current: 2, last: 3, now: t.addingTimeInterval(4)), 0)
    }

    func testDraggingTheSidewaysBarGoesToWholeColumns() {
        XCTAssertEqual(CardScrollBarH.stop(fraction: 0, last: 3), 0)
        XCTAssertEqual(CardScrollBarH.stop(fraction: -0.4, last: 3), 0)
        XCTAssertEqual(CardScrollBarH.stop(fraction: 0.5, last: 3), 2)
        XCTAssertEqual(CardScrollBarH.stop(fraction: 0.3, last: 3), 1)
        XCTAssertEqual(CardScrollBarH.stop(fraction: 1, last: 3), 3)
        XCTAssertEqual(CardScrollBarH.stop(fraction: 1.4, last: 3), 3)
    }

    // MARK: Following the playhead

    func testTheCardsGlideForAboutHalfTheTimeToTheNextTitle() {
        XCTAssertEqual(AppModel.glideDuration(untilNext: nil), 0.6)
        XCTAssertEqual(AppModel.glideDuration(untilNext: 0.4), 0.3, accuracy: 0.001)
        XCTAssertEqual(AppModel.glideDuration(untilNext: 1.2), 0.6, accuracy: 0.001)
        XCTAssertEqual(AppModel.glideDuration(untilNext: 6), 0.9, accuracy: 0.001)
        let a = sub(1, 2, "One"), b = sub(2.2, 3, "Two")
        let f = makeFixture([("en", [a, b])])
        XCTAssertEqual(f.model.glideDuration(to: a.id), 0.6, accuracy: 0.001)
        XCTAssertEqual(f.model.glideDuration(to: b.id), 0.6, accuracy: 0.001, "the last title: the usual glide")
    }

    func testReachingATitleDoesNotRedrawTheWholeWindow() {
        let a = sub(1, 2, "One"), b = sub(3, 4, "Two")
        let f = makeFixture([("en", [a, b])])
        var redraws = 0
        let watch = f.model.objectWillChange.sink { _ in redraws += 1 }
        f.model.doc.selectedID = b.id
        f.model.doc.selectedID = a.id
        XCTAssertEqual(redraws, 0)
        // A selected empty slot is still let go when a title is selected.
        f.model.emptySlotRow = UUID()
        f.model.doc.selectedID = b.id
        XCTAssertNil(f.model.emptySlotRow)
        withExtendedLifetime(watch) {}
    }

    func testCardTextSizesAreRemembered() {
        let wide = "A line much too long to fit in a narrow card at full size"
        let first = CardView.fittingSize(for: wide, width: 180)
        XCTAssertLessThan(first, CardView.baseFontSize)
        XCTAssertEqual(CardView.fittingSize(for: wide, width: 180), first)
        XCTAssertEqual(CardView.fittingSize(for: wide, width: 2000), CardView.baseFontSize, "each width on its own")
    }
}
