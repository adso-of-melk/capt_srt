import Foundation

/// QC ▸ Re-split to Fit: titles reshaped at word boundaries until they fit the language's
/// limits.
/// - More text than its lines can hold: split in two (or more), the time shared by the
///   length of the text, at the best place (a sentence's end, then a comma, a new speaker,
///   the middle).
/// - Too fast to read, with a neighbour close by: the two re-split between them, at the
///   word where both read within the limit, the time shared by the length of the text.
/// - Shorter than the minimum duration: joined to a neighbour close by, when the two fit
///   in one title.
/// Formatting carries over a split (italics running on are closed and opened again).
enum Refit {
    /// The neighbours a title can share its words with: at most this far away.
    static let reach = 1.0

    struct Limits: Sendable {
        var rules: TimingPreset
        /// The minimum gap between titles, and the length of a frame (times land on frames).
        var gap: Double
        var frame: Double
        var language: String
        var style: LineBreaker.Style = .bottomHeavy
    }

    /// What happened to the titles `range` (indices into the titles given): these replace them.
    struct Change: Equatable {
        var range: Range<Int>
        var titles: [Subtitle]
    }

    // MARK: What needs it

    /// Visible characters, as reading speed counts them (line breaks and tags don't count).
    static func length(_ text: String) -> Int {
        Markup.plain(text).filter { $0 != "\n" && $0 != "\r" }.count
    }

    /// More text than fits on the language's lines, however it's broken.
    static func overflows(_ text: String, _ l: Limits) -> Bool {
        let broken = LineBreaker.breakLines(text, maxChars: l.rules.maxCharsPerLine, maxLines: l.rules.maxLines,
                                            language: l.language, style: l.style)
        let lines = Markup.plain(broken).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > l.rules.maxLines || lines.contains { $0.count > l.rules.maxCharsPerLine }
    }

    static func tooFast(_ chars: Int, _ duration: Double, _ l: Limits) -> Bool {
        chars > 0 && Double(chars) / max(0.001, duration) > l.rules.maxCPS + 1e-9
    }

    // MARK: Re-splitting

    /// How to put title `i` right, or nil when re-splitting can't (use Extend, or edit it).
    static func change(for i: Int, in subs: [Subtitle], limits l: Limits) -> Change? {
        guard subs.indices.contains(i) else { return nil }
        let s = subs[i]
        let chars = s.characterCount
        guard chars > 0 else { return nil }
        if overflows(s.text, l) {
            let parts = split(s, limits: l, depth: 3)
            return parts.count > 1 ? Change(range: i..<(i + 1), titles: parts) : nil
        }
        let prev = i > 0 ? subs[i - 1] : nil
        let next = i + 1 < subs.count ? subs[i + 1] : nil
        func close(_ a: Subtitle?, _ b: Subtitle?) -> Bool {
            guard let a, let b else { return false }
            let g = b.start - a.end
            return g >= -0.0005 && g <= reach
        }
        if tooFast(chars, s.duration, l) {
            // Share the words with whichever neighbour leaves both slowest.
            var best: (change: Change, cps: Double)?
            if close(s, next), let next, let pair = resplit(s, next, limits: l) {
                best = (Change(range: i..<(i + 2), titles: [pair.0, pair.1]), pair.cps)
            }
            if close(prev, s), let prev, let pair = resplit(prev, s, limits: l), pair.cps < (best?.cps ?? .infinity) {
                best = (Change(range: (i - 1)..<(i + 1), titles: [pair.0, pair.1]), pair.cps)
            }
            return best?.change
        }
        if s.duration < l.rules.minDuration - 0.0005 {
            // Join the nearer neighbour, when the two fit as one.
            var options: [(Change, Double)] = []
            if close(s, next), let next, let j = joined(s, next, limits: l) {
                options.append((Change(range: i..<(i + 2), titles: [j]), next.start - s.end))
            }
            if close(prev, s), let prev, let j = joined(prev, s, limits: l) {
                options.append((Change(range: (i - 1)..<(i + 1), titles: [j]), s.start - prev.end))
            }
            return options.min(by: { $0.1 < $1.1 })?.0
        }
        return nil
    }

    /// A title too long for its lines, in as many parts as it takes (up to `depth` splits
    /// deep). The first part keeps the title's identity (and its link to the master).
    static func split(_ s: Subtitle, limits l: Limits, depth: Int) -> [Subtitle] {
        guard depth > 0, overflows(s.text, l) else { return [s] }
        let words = self.words(s.text)
        // Time for two titles and the gap between them.
        guard words.count > 1, s.duration - l.gap >= 0.4 else { return [s] }
        guard let k = bestBreak(words, start: s.start, end: s.end, limits: l) else { return [s] }
        let (first, second) = parts(words, at: k, start: s.start, end: s.end, limits: l)
        let a = Subtitle(id: s.id, start: first.start, end: first.end, text: first.text, link: s.link)
        return split(a, limits: l, depth: depth - 1) + split(second, limits: l, depth: depth - 1)
    }

    /// Two neighbours' words re-split between them so both read within the limit. The
    /// time between them moves as little as it can from where it was (the speech is still
    /// there), words move from one to the other as few as they can, and the break goes where
    /// a sentence (or a clause, or a speaker) ends. Nil when no word does it.
    static func resplit(_ a: Subtitle, _ b: Subtitle, limits l: Limits) -> (Subtitle, Subtitle, cps: Double)? {
        let wa = words(a.text), wb = words(b.text)
        let all = wa + wb
        guard all.count > 1, l.rules.maxCPS > 0 else { return nil }
        let maxCPS = l.rules.maxCPS
        var best: (left: String, right: String, cut: Double, score: Double)?
        for k in 1..<all.count {
            let (left, right) = texts(all, at: k, limits: l)
            let la = length(left), lb = length(right)
            guard la > 0, lb > 0, !overflows(left, l), !overflows(right, l) else { continue }
            // The first must last long enough for its words, the second too.
            let earliest = a.start + Double(la) / maxCPS
            let latest = b.end - l.gap - Double(lb) / maxCPS
            guard earliest <= latest + 1e-9 else { continue }
            let wanted = min(max(a.end, earliest), latest)
            guard let cut = onFrame(wanted, within: earliest...max(earliest, latest), frame: l.frame) else { continue }
            let moved = k < wa.count ? wa[k...].joined(separator: " ") : wb[..<(k - wa.count)].joined(separator: " ")
            var score = abs(cut - a.end) * 10 + Double(length(moved)) * 0.5
            if let c = Markup.plain(all[k - 1]).last {
                if ".!?…".contains(c) { score -= 30 }
                else if ",;:—–".contains(c) { score -= 15 }
            }
            if Markup.plain(all[k]).hasPrefix("-") { score -= 25 }
            if cut - a.start < l.rules.minDuration - 0.0005 || b.end - cut - l.gap < l.rules.minDuration - 0.0005 {
                score += 25
            }
            if best == nil || score < best!.score { best = (left, right, cut, score) }
        }
        guard let best else { return nil }
        // A pause before the second stays, when its words still read in time without it.
        var secondStart = best.cut + l.gap
        if b.start > secondStart, Double(length(best.right)) / max(0.001, b.end - b.start) <= maxCPS + 1e-9 {
            secondStart = b.start
        }
        let x = Subtitle(id: a.id, start: a.start, end: best.cut, text: best.left, link: a.link)
        let y = Subtitle(id: b.id, start: secondStart, end: b.end, text: best.right, link: b.link)
        return (x, y, max(x.cps, y.cps))
    }

    /// `t` on a frame inside `range` (the nearest one to it), or nil when no frame is.
    static func onFrame(_ t: Double, within range: ClosedRange<Double>, frame: Double) -> Double? {
        guard frame > 0 else { return t }
        let down = (t / frame).rounded(.down) * frame, up = (t / frame).rounded(.up) * frame
        let fits = [down, up].filter { $0 >= range.lowerBound - 1e-9 && $0 <= range.upperBound + 1e-9 }
        return fits.min { abs($0 - t) < abs($1 - t) }
    }

    /// Two neighbours as one title, when it fits the lines and reads within the limit.
    static func joined(_ a: Subtitle, _ b: Subtitle, limits l: Limits) -> Subtitle? {
        let flat = words(a.text + "\n" + b.text).joined(separator: " ")
        guard !overflows(flat, l) else { return nil }
        let text = LineBreaker.breakLines(flat, maxChars: l.rules.maxCharsPerLine, maxLines: l.rules.maxLines,
                                          language: l.language, style: l.style)
        let j = Subtitle(id: a.id, start: a.start, end: b.end, text: text, link: a.link ?? b.link)
        return tooFast(j.characterCount, j.duration, l) ? nil : j
    }

    // MARK: Where to break

    /// The words of a title, tags kept on the words they touch.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The best word to start the second part with: both parts fitting their lines is best,
    /// then a sentence's end, a comma or a new speaker's dash, then the middle.
    static func bestBreak(_ words: [String], start: Double, end: Double, limits l: Limits) -> Int? {
        var best: (k: Int, score: Double)?
        let total = Double(length(words.joined(separator: " ")))
        for k in 1..<words.count {
            let (a, b) = parts(words, at: k, start: start, end: end, limits: l)
            let la = a.characterCount, lb = b.characterCount
            guard la > 0, lb > 0, a.duration >= 0.2, b.duration >= 0.2 else { continue }
            var score = abs(Double(la - lb)) / max(1, total) * 40
            // A part that still doesn't fit its lines is split again later: a fair cost.
            if overflows(a.text, l) { score += 60 }
            if overflows(b.text, l) { score += 60 }
            if a.duration < l.rules.minDuration - 0.0005 || b.duration < l.rules.minDuration - 0.0005 { score += 25 }
            let last = Markup.plain(words[k - 1])
            if let c = last.last {
                if ".!?…".contains(c) { score -= 30 }
                else if ",;:—–".contains(c) { score -= 15 }
            }
            if Markup.plain(words[k]).hasPrefix("-") { score -= 25 }
            if best == nil || score < best!.score { best = (k, score) }
        }
        return best?.k
    }

    /// The two titles from breaking before word `k`: the time between `start` and `end`
    /// shared by the length of their text, the minimum gap between them, on a frame. Each
    /// part's lines are broken by the rules; italics (or bold, underline) running over the
    /// break are closed and opened again, and a {\anN} position goes on both.
    static func parts(_ words: [String], at k: Int, start: Double, end: Double, limits l: Limits) -> (Subtitle, Subtitle) {
        let (left, right) = texts(words, at: k, limits: l)
        let la = Double(length(left)), lb = Double(length(right))
        let room = max(0, end - start - l.gap)
        var cut = start + room * la / max(1, la + lb)
        if l.frame > 0 { cut = (cut / l.frame).rounded() * l.frame }
        cut = min(max(cut, start + 0.1), end - l.gap - 0.1)
        return (Subtitle(start: start, end: cut, text: left), Subtitle(start: cut + l.gap, end: end, text: right))
    }

    /// The texts either side of a break before word `k`, each broken into lines by the
    /// rules. Formatting running over the break is closed and opened again; a {\anN}
    /// position at the start goes on both.
    static func texts(_ words: [String], at k: Int, limits l: Limits) -> (String, String) {
        var left = words[..<k].joined(separator: " ")
        var right = words[k...].joined(separator: " ")
        let open = openTags(at: left)
        left += open.reversed().map { "</\($0)>" }.joined()
        right = open.map { "<\($0)>" }.joined() + right
        if let position = left.range(of: #"^\{\\an[1-9]\}"#, options: .regularExpression),
           !right.hasPrefix(String(left[position])) {
            right = String(left[position]) + right
        }
        func broken(_ t: String) -> String {
            LineBreaker.breakLines(t, maxChars: l.rules.maxCharsPerLine, maxLines: l.rules.maxLines,
                                   language: l.language, style: l.style)
        }
        return (broken(left), broken(right))
    }

    /// The formatting tags (i, b, u) still open at the end of `text`, in the order opened.
    static func openTags(at text: String) -> [String] {
        let ns = text as NSString
        var open: [String] = []
        for m in Markup.tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = m.range(at: 2)
            guard name.location != NSNotFound else { continue }
            let tag = ns.substring(with: name).lowercased()
            guard ["i", "b", "u"].contains(tag) else { continue }
            if m.range(at: 1).length > 0 {
                if let at = open.lastIndex(of: tag) { open.remove(at: at) }
            } else {
                open.append(tag)
            }
        }
        return open
    }
}
