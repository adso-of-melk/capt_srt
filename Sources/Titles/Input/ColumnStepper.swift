import Foundation
import CoreGraphics

/// Sideways scrolling over the title pane moves a whole language column at a time, so a
/// language always ends up at the pane's left edge (it never stops half in view).
/// A mouse wheel moves one column a notch; a trackpad swipe moves one column once it has
/// gone a little way, and one more for each longer stretch, so a long swipe can cross
/// several. Up-down scrolling is left alone.
struct ColumnStepper {
    /// How far a swipe goes before it moves a column, and how much further for each next one.
    static let firstStep: CGFloat = 24
    static let nextStep: CGFloat = 160
    /// A smooth-scrolling mouse (no swipe phases): a pause this long starts a new swipe.
    static let pause: TimeInterval = 0.3

    enum Phase { case none, began, changed, ended, momentum }

    struct Event {
        /// The scroll view's deltas: positive x moves the content right (back to the earlier
        /// languages), as NSEvent's scrollingDeltaX.
        var dx: CGFloat
        var dy: CGFloat
        /// A trackpad or smooth-scrolling mouse, not a wheel that clicks.
        var precise: Bool
        var phase: Phase
        var time: TimeInterval
    }

    private var travel: CGFloat = 0
    private var moved = 0
    /// The current swipe's direction, once its first movement shows it.
    private var sideways: Bool?
    private var lastTime: TimeInterval = -.infinity

    /// One scroll event. nil: it isn't sideways scrolling, let it through to the scroll view.
    /// Otherwise it's taken, and the result is how many columns to move now (+ towards the
    /// later languages on the right, - back), often 0.
    mutating func feed(_ e: Event) -> Int? {
        defer { lastTime = e.time }
        switch e.phase {
        case .began:
            reset()
            return swipe(e)
        case .changed:
            return swipe(e)
        case .ended:
            // Let the scroll view close its gesture; it moves nothing.
            return nil
        case .momentum:
            return sideways == true ? 0 : nil
        case .none:
            if e.precise {
                if e.time - lastTime > Self.pause { reset() }
                return swipe(e)
            }
            // A wheel that clicks: each notch decides for itself, and moves one column.
            guard e.dx != 0, abs(e.dx) > abs(e.dy) else { return nil }
            return e.dx > 0 ? -1 : 1
        }
    }

    private mutating func reset() {
        travel = 0
        moved = 0
        sideways = nil
    }

    private mutating func swipe(_ e: Event) -> Int? {
        if sideways == nil, e.dx != 0 || e.dy != 0 { sideways = abs(e.dx) > abs(e.dy) }
        guard sideways == true else { return nil }
        travel += e.dx
        let want = -Self.columns(for: travel)
        let move = want - moved
        moved = want
        return move
    }

    /// Columns for a swipe this far (in the scroll view's direction, signed).
    static func columns(for travel: CGFloat) -> Int {
        let a = abs(travel)
        guard a >= firstStep else { return 0 }
        let n = 1 + Int(((a - firstStep) / nextStep).rounded(.down))
        return travel > 0 ? n : -n
    }
}
