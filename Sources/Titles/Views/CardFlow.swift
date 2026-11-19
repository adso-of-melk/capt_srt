import SwiftUI
import AppKit
@testable import TitlesCore

/// While the film plays, the title cards flow with it on every frame the screen shows,
/// instead of gliding from one title to the next: each row reaches the middle of the pane
/// just as its first title starts, and between rows the list moves on smoothly, quicker
/// through short titles, slower through long ones and the pauses between them. The rows'
/// places come from SwiftUI (`CardRowFramesKey`); RowsScrollObserverView moves the scroll
/// view itself, frame by frame. A scroll by hand, typing, spotting or a preview pause it.
enum CardFlow {
    /// The point of the list to have in the middle at time `t`, from the rows around it:
    /// each row's start time and the middle of its cards (in the list's own points, from
    /// the top). A curve through them that never runs backwards or overshoots a row (the
    /// tangents are the harmonic mean of the slopes either side: Fritsch and Butland).
    static func centre(at t: Double, points p: [(time: Double, y: CGFloat)]) -> CGFloat? {
        guard let first = p.first, let last = p.last else { return nil }
        if p.count == 1 || t <= first.time { return first.y }
        if t >= last.time { return last.y }
        guard let k = p.indices.dropLast().last(where: { p[$0].time <= t }) else { return first.y }
        let n = p.count
        func slope(_ i: Int) -> Double {
            Double(p[i + 1].y - p[i].y) / max(1e-6, p[i + 1].time - p[i].time)
        }
        func tangent(_ i: Int) -> Double {
            if i == 0 { return slope(0) }
            if i == n - 1 { return slope(n - 2) }
            let a = slope(i - 1), b = slope(i)
            guard a * b > 0 else { return 0 }
            return 2 * a * b / (a + b)
        }
        let h = max(1e-6, p[k + 1].time - p[k].time)
        let s = (t - p[k].time) / h
        let y0 = Double(p[k].y), y1 = Double(p[k + 1].y)
        let m0 = tangent(k) * h, m1 = tangent(k + 1) * h
        let s2 = s * s, s3 = s2 * s
        let v = (2 * s3 - 3 * s2 + 1) * y0 + (s3 - 2 * s2 + s) * m0 + (-2 * s3 + 3 * s2) * y1 + (s3 - s2) * m1
        return CGFloat(v)
    }

    /// The last row starting at or before `t` (-1: none yet). Rows are in time order.
    static func row(atOrBefore t: Double, in rows: [CardRow]) -> Int {
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].time <= t + 0.0005 { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    /// The rows the curve at `t` is drawn through: the one at or before it, the one before
    /// that, and two after, as far as their places are known (and one per start time).
    /// Nil when the two either side of `t` aren't laid out yet (the list is somewhere else).
    static func points(at t: Double, rows: [CardRow], frames: [UUID: CGRect]) -> [(time: Double, y: CGFloat)]? {
        guard !rows.isEmpty else { return nil }
        let i = row(atOrBefore: t, in: rows)
        let near = [max(0, i), min(rows.count - 1, i + 1)]
        guard near.allSatisfy({ frames[rows[$0].key] != nil }) else { return nil }
        var out: [(time: Double, y: CGFloat)] = []
        for k in max(0, i - 1)...min(rows.count - 1, max(0, i) + 2) {
            guard let f = frames[rows[k].key] else { continue }
            if let last = out.last, rows[k].time <= last.time + 1e-6 || f.midY < last.y { continue }
            out.append((rows[k].time, f.midY))
        }
        return out
    }

    /// Easing from where the list was to where the flow wants it: the share of the
    /// difference still left after `elapsed` of `duration` seconds.
    static func blendLeft(elapsed: Double, duration: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        let f = min(1, max(0, elapsed / duration))
        return CGFloat(1 - f * f * (3 - 2 * f))
    }
}

/// Where each row of cards is, in the list's own points (they don't change as it scrolls).
struct CardRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
