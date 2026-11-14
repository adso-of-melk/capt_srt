import Foundation

/// Keeps titles from running into each other while they're dragged on the waveform (a whole
/// title, a group of them, one edge, or a title being drawn).
///
/// A dragged title stops at the minimum gap from the next title in its way, however fast it
/// was dragged there. With overlapping titles enabled (Title menu), pulling on past that
/// point by `breakDistance` lets it through; the moment the two stop overlapping again, the
/// resistance is back, as strong as at first. With overlapping titles off, it never gives.
///
/// The title in the way is worked out afresh at every step from where the dragged title is
/// now, so a fast drag can't jump over one, and after passing a title (pulled through it)
/// the next one holds it in turn. Titles that already overlapped when the drag began can
/// go on overlapping until they come apart; from then on they hold like any other.
struct DragResistance {
    /// What the pointer moves.
    enum Mode: Equatable {
        /// Whole titles, all by the same amount. The value is how far they've moved (seconds).
        case move
        /// One edge of one title. The value is the edge's time.
        case edge(Edge)
        /// A title being drawn from a fixed point. The value is the time of its other end.
        case draw(from: Double)
    }

    struct Span: Equatable {
        var start: Double
        var end: Double
    }

    /// A dragged title (by its place in `original`) and a title it could run into.
    struct Contact: Hashable {
        let title: Int
        let neighbour: UUID
    }

    let mode: Mode
    let gap: Double
    let allowOverlap: Bool
    /// How far (in seconds) the pointer has to pull on past the stopping point before the
    /// title gives. The view sets it from the zoom, so it's always the same distance on screen.
    var breakDistance: Double
    /// Where the dragged titles were when the drag began.
    let original: [Span]
    /// The language's other titles: the ones that can be in the way.
    let others: [Subtitle]

    /// Where the dragged titles are now.
    private(set) var spans: [Span]
    /// The value after the last step.
    private(set) var value: Double
    /// The title just stopped against a neighbour, or just went through one (a trackpad tap).
    private(set) var bumped = false
    /// With overlapping titles off: the pointer pulled on as far as would have broken through.
    private(set) var refused = false

    /// Pairs allowed to overlap: they overlapped when the drag began, or the title was pulled
    /// through. A pair leaves this set (the resistance is back) as soon as they don't overlap.
    private var through: Set<Contact> = []
    /// Where the pointer was when a hold against a neighbour began (or the furthest back
    /// it has been since): pulling on past it by `breakDistance` goes through.
    private var heldAt: [Contact: Double] = [:]

    private static let eps = 0.0005

    init(mode: Mode, original: [Span], others: [Subtitle], gap: Double, allowOverlap: Bool,
         breakDistance: Double) {
        self.mode = mode
        self.original = original
        self.others = others
        self.gap = gap
        self.allowOverlap = allowOverlap
        self.breakDistance = breakDistance
        self.spans = original
        switch mode {
        case .move: value = 0
        case .edge(.start): value = original.first?.start ?? 0
        case .edge(.end): value = original.first?.end ?? 0
        case let .draw(from): value = from
        }
        for (i, span) in original.enumerated() {
            for o in others where Self.overlaps(span, o) {
                through.insert(Contact(title: i, neighbour: o.id))
            }
        }
    }

    /// The pointer asks for `wanted`; returns the value the drag goes to.
    @discardableResult
    mutating func drag(to wanted: Double) -> Double {
        bumped = false
        var v = resolve(wanted, from: spans) ?? value
        // Titles that no longer overlap hold again from here on: the title stops at the gap.
        for _ in 0..<4 {
            let at = spans(for: v)
            let apart = through.filter { c in
                guard let o = neighbour(c.neighbour) else { return true }
                return !Self.overlaps(at[c.title], o)
            }
            guard !apart.isEmpty else { break }
            through.subtract(apart)
            for c in apart { heldAt[c] = nil }
            if let again = resolve(wanted, from: at) {
                v = again
            } else {
                // No room to hold there (the gap is too small for the title): leave them be.
                through.formUnion(apart)
                break
            }
        }
        value = v
        spans = spans(for: v)
        return v
    }

    /// The drag ended up somewhere else than asked (say a minimum length kept an edge back).
    mutating func settle(at v: Double) {
        value = v
        spans = spans(for: v)
    }

    // MARK: Working it out

    private func neighbour(_ id: UUID) -> Subtitle? { others.first { $0.id == id } }

    /// Where the dragged titles are for a value.
    func spans(for v: Double) -> [Span] {
        switch mode {
        case .move:
            return original.map { Span(start: $0.start + v, end: $0.end + v) }
        case .edge(.start):
            return original.map { Span(start: v, end: $0.end) }
        case .edge(.end):
            return original.map { Span(start: $0.start, end: v) }
        case let .draw(from):
            return [Span(start: min(from, v), end: max(from, v))]
        }
    }

    static func overlaps(_ s: Span, _ o: Subtitle) -> Bool {
        s.start < o.end - eps && o.start < s.end - eps
    }

    /// How far a title's end may go towards a title after it: the minimum gap before that
    /// title. A title that was already closer than that when the drag began (but not over
    /// it) may come back to where it was, and no closer; it's never pushed away.
    private func endLimit(_ i: Int, _ o: Subtitle) -> Double {
        let limit = o.start - gap
        let was = original[i].end
        return was > limit && was <= o.start + Self.eps ? was : limit
    }

    private func startLimit(_ i: Int, _ o: Subtitle) -> Double {
        let limit = o.end + gap
        let was = original[i].start
        return was < limit && was >= o.end - Self.eps ? was : limit
    }

    private enum Side { case later, earlier }

    /// The tightest limit on the value from the titles in the way, on one side. Which titles
    /// are in the way comes from `from` (where the dragged titles are now), never from where
    /// the pointer asks them to go, so nothing is jumped over.
    private func limit(_ side: Side, from: [Span]) -> (value: Double, contact: Contact)? {
        var best: (value: Double, contact: Contact)?
        for (i, span) in from.enumerated() {
            for o in others {
                let c = Contact(title: i, neighbour: o.id)
                switch side {
                case .later:
                    // A title after this one, and the end moves.
                    guard o.start >= span.end - Self.eps, movesEnd else { continue }
                    let u: Double
                    switch mode {
                    case .move: u = endLimit(i, o) - original[i].end
                    default: u = endLimit(i, o)
                    }
                    if best == nil || u < best!.value, !through.contains(c) { best = (u, c) }
                case .earlier:
                    guard o.end <= span.start + Self.eps, movesStart else { continue }
                    let l: Double
                    switch mode {
                    case .move: l = startLimit(i, o) - original[i].start
                    default: l = startLimit(i, o)
                    }
                    if best == nil || l > best!.value, !through.contains(c) { best = (l, c) }
                }
            }
        }
        return best
    }

    private var movesEnd: Bool {
        if case .edge(.start) = mode { return false }
        return true
    }

    private var movesStart: Bool {
        if case .edge(.end) = mode { return false }
        return true
    }

    /// The value for `wanted`, held at the first title in the way (or through it, when pulled
    /// far enough with overlaps on). nil: the titles on either side leave no room.
    /// Pulled on `distance` past where a hold began: with overlaps on, far enough goes through.
    private mutating func pulledThrough(_ c: Contact, by distance: Double) -> Bool {
        guard heldAt[c] != nil, distance > breakDistance else { return false }
        guard allowOverlap else { refused = true; return false }
        heldAt = [:]
        through.insert(c)
        bumped = true
        return true
    }

    /// Held against one neighbour: the only hold there is (the title can't be held on both sides).
    private mutating func hold(_ c: Contact, at pointer: Double) {
        if heldAt[c] == nil { bumped = true }
        heldAt = [c: pointer]
    }

    private mutating func resolve(_ wanted: Double, from: [Span]) -> Double? {
        for _ in 0..<16 {
            let upper = limit(.later, from: from)
            let lower = limit(.earlier, from: from)
            if let u = upper, let l = lower, u < l - Self.eps { return nil }
            if let u = upper, wanted > u.value + Self.eps {
                if pulledThrough(u.contact, by: wanted - (heldAt[u.contact] ?? wanted)) { continue }
                hold(u.contact, at: heldAt[u.contact].map { min($0, wanted) } ?? wanted)
                return u.value
            }
            if let l = lower, wanted < l.value - Self.eps {
                if pulledThrough(l.contact, by: (heldAt[l.contact] ?? wanted) - wanted) { continue }
                hold(l.contact, at: heldAt[l.contact].map { max($0, wanted) } ?? wanted)
                return l.value
            }
            // Free on both sides: a hold that was waiting is over.
            heldAt = [:]
            return wanted
        }
        return value
    }
}
