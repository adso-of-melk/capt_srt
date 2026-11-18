import Foundation

/// What QC looks for in a title.
enum QCIssue: String, CaseIterable, Identifiable, Codable, Sendable {
    case spelling, readingSpeed, nearReadingSpeed, lineLength, lineCount, duration, overlap, gap, empty

    var id: String { rawValue }

    /// Short, for the QC bar.
    var label: String {
        switch self {
        case .spelling: return "Spelling"
        case .readingSpeed: return "CPS"
        case .nearReadingSpeed: return "Near CPS"
        case .lineLength: return "CPL"
        case .lineCount: return "Lines"
        case .duration: return "Duration"
        case .overlap: return "Overlap"
        case .gap: return "Gap"
        case .empty: return "Empty"
        }
    }

    /// For QC ▸ Check For.
    var menuLabel: String {
        switch self {
        case .spelling: return "Spelling"
        case .readingSpeed: return "Reading Speed Over the Limit"
        case .nearReadingSpeed: return "Reading Speed Near the Limit"
        case .lineLength: return "Lines Too Long"
        case .lineCount: return "Too Many Lines"
        case .duration: return "Too Short or Too Long"
        case .overlap: return "Overlaps"
        case .gap: return "Gaps Under the Minimum"
        case .empty: return "Empty Titles"
        }
    }

    /// What it means, for the bar's tooltips.
    var help: String {
        switch self {
        case .spelling: return "Words not in the dictionary"
        case .readingSpeed: return "Reading speed over the limit, by any amount"
        case .nearReadingSpeed: return "Reading speed close to the limit (amber on the card)"
        case .lineLength: return "A line longer than the characters-per-line limit"
        case .lineCount: return "More lines than allowed"
        case .duration: return "Shorter than the minimum or longer than the maximum duration"
        case .overlap: return "Overlaps another title"
        case .gap: return "Less than the minimum gap before the next title"
        case .empty: return "No text"
        }
    }
}

/// What clicking a title's issue tag offers to do about it.
enum QCFix: String, CaseIterable, Identifiable {
    case extend, widenGaps, rebreak

    var id: String { rawValue }

    var label: String {
        switch self {
        case .extend: return "Extend to Fit Reading Speed"
        case .widenGaps: return "Widen Gaps to the Minimum"
        case .rebreak: return "Re-break Lines"
        }
    }

    /// The fixes for a title's issues, in this order. Spelling, overlaps and empty titles
    /// have none: they need a person.
    static func fixes(for issues: Set<QCIssue>) -> [QCFix] {
        var out: [QCFix] = []
        if !issues.isDisjoint(with: [.readingSpeed, .duration]) { out.append(.extend) }
        if issues.contains(.gap) { out.append(.widenGaps) }
        if !issues.isDisjoint(with: [.lineLength, .lineCount]) { out.append(.rebreak) }
        return out
    }
}

/// QC's rules: what's wrong with a title, in words, and the timing fixes. Nothing here knows
/// about the window or the app's settings: the rules, the minimum gap and the frame length
/// are passed in.
enum QCRules {
    /// Everything QC finds in one title. `next` is the title after it; `overlapping`, the
    /// titles of its language that overlap another; `misspelled` checks the title's plain
    /// text (only asked when there is some).
    static func issues(of s: Subtitle, next: Subtitle?, overlapping: Set<UUID>, rules: TimingPreset,
                       gap minGap: Double, misspelled: (String) -> Bool) -> Set<QCIssue> {
        var found = Set<QCIssue>()
        let plain = Markup.plain(s.text)
        if plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.insert(.empty)
        } else if misspelled(plain) {
            found.insert(.spelling)
        }
        // Over the limit by any amount (even 17.02 CPS, shown as 17.0); amber: within 2 of it.
        if overReadingSpeed(s, rules: rules) { found.insert(.readingSpeed) }
        else if rules.cpsStatus(s) == .warn { found.insert(.nearReadingSpeed) }
        let lines = plain.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > rules.maxLines { found.insert(.lineCount) }
        if lines.contains(where: { $0.count > rules.maxCharsPerLine }) { found.insert(.lineLength) }
        if rules.durationStatus(s) != .ok { found.insert(.duration) }
        if overlapping.contains(s.id) { found.insert(.overlap) }
        if let next {
            let gap = next.start - s.end
            if gap >= -0.0005 && gap < minGap - 0.0005 { found.insert(.gap) }
        }
        return found
    }

    /// The issues of one title, in words.
    static func describe(_ issues: Set<QCIssue>, of s: Subtitle, rules: TimingPreset) -> String {
        QCIssue.allCases.filter(issues.contains).map { issue -> String in
            switch issue {
            case .readingSpeed:
                // Two decimals when one would hide that it's over (17.02 shows as 17.0).
                let shown = (s.cps * 10).rounded() / 10 > rules.maxCPS ? String(format: "%.1f", s.cps) : String(format: "%.2f", s.cps)
                return "\(shown) CPS (max \(String(format: "%g", rules.maxCPS)))"
            case .nearReadingSpeed: return String(format: "%.1f CPS, close to the max %g", s.cps, rules.maxCPS)
            case .lineLength: return "\(rules.longestLine(s)) characters on a line (max \(rules.maxCharsPerLine))"
            case .lineCount: return "too many lines (max \(rules.maxLines))"
            case .duration:
                return s.duration < rules.minDuration
                    ? String(format: "%.2f s, shorter than %.2f s", s.duration, rules.minDuration)
                    : String(format: "%.2f s, longer than %g s", s.duration, rules.maxDuration)
            case .spelling: return "spelling"
            case .overlap: return "overlaps"
            case .gap: return "gap to the next title under the minimum"
            case .empty: return "no text"
            }
        }.joined(separator: " · ")
    }

    // MARK: Reading speed

    /// Faster than the limit, by any amount.
    static func overReadingSpeed(_ s: Subtitle, rules: TimingPreset) -> Bool {
        s.characterCount > 0 && s.cps > rules.maxCPS + 1e-9
    }

    /// Over the reading speed or under the minimum duration.
    static func needsMoreTime(_ s: Subtitle, rules: TimingPreset) -> Bool {
        overReadingSpeed(s, rules: rules) || (s.characterCount > 0 && s.duration < rules.minDuration - 0.0005)
    }

    /// A title made long enough to read (the limit's reading speed, and at least the minimum
    /// duration, at most the maximum), as far as the room either side allows: its end moves
    /// first, up to the minimum gap before the next title; then its start, down to the minimum
    /// gap after the previous one. Times land on frames. A neighbour it overlaps leaves no room
    /// on that side.
    static func extended(_ s: Subtitle, prev: Subtitle?, next: Subtitle?, rules: TimingPreset,
                         gap: Double, frame: Double, videoEnd: Double) -> Subtitle {
        let chars = Double(s.characterCount)
        guard chars > 0 else { return s }
        // The reading speed is judged to one decimal, so aim a hair under the limit.
        let forSpeed = chars / max(0.1, rules.maxCPS - 0.04)
        let target = min(max(forSpeed, rules.minDuration), max(rules.maxDuration, s.duration))
        guard target > s.duration + 0.0005 else { return s }
        let upper: Double = {
            guard let next else { return videoEnd }
            return next.start >= s.end - 0.0005 ? max(s.end, next.start - gap) : s.end
        }()
        let lower: Double = {
            guard let prev else { return 0 }
            return prev.end <= s.start + 0.0005 ? min(s.start, prev.end + gap) : s.start
        }()
        var out = s
        func onFrame(_ t: Double, up: Bool) -> Double {
            guard frame > 0 else { return t }
            let n = t / frame
            return (up ? n.rounded(.up) : n.rounded(.down)) * frame
        }
        // End first: reading on after the words stop is easier on the eye than starting early.
        var end = min(upper, s.start + target)
        end = min(upper, max(s.end, onFrame(end - 0.0001, up: true)))
        out.end = end
        let missing = target - (out.end - out.start)
        if missing > 0.0005 {
            var start = max(lower, s.start - missing)
            start = max(lower, min(s.start, onFrame(start + 0.0001, up: false)))
            out.start = start
        }
        return out
    }

    // MARK: Gaps

    /// Gaps a little over the minimum close down to it ("Close Short Gaps"): under this long.
    static let closeGapsUnder = 0.5

    /// Keep Minimum Gap, after an edit: every gap next to a title that moved (or is new) and
    /// is under the minimum is fixed by `fixedGap`, the earlier title's end coming back first.
    /// Gaps between titles that didn't move stay as they are, and so do overlaps.
    static func keepGaps(before: [Subtitle], after subs: inout [Subtitle], rules: TimingPreset,
                         gap: Double, frame: Double) {
        guard subs.count > 1, gap > 0.0005 else { return }
        var old: [UUID: Subtitle] = [:]
        for s in before { old[s.id] = s }
        let moved = Set(subs.filter { s in
            guard let o = old[s.id] else { return true }
            return abs(o.start - s.start) > 0.0005 || abs(o.end - s.end) > 0.0005
        }.map(\.id))
        guard !moved.isEmpty else { return }
        for i in 0..<(subs.count - 1) where moved.contains(subs[i].id) || moved.contains(subs[i + 1].id) {
            let (a, b) = fixedGap(subs[i], subs[i + 1], rules: rules, gap: gap, frame: frame, closeUnder: nil)
            subs[i] = a
            subs[i + 1] = b
        }
    }

    /// How many gaps are under the minimum (overlaps don't count).
    static func shortGapCount(_ subs: [Subtitle], gap: Double) -> Int {
        guard subs.count > 1 else { return 0 }
        return (0..<(subs.count - 1)).filter { i in
            let g = subs[i + 1].start - subs[i].end
            return g >= -0.0005 && g < gap - 0.0005
        }.count
    }

    /// Two neighbouring titles with the gap between them fixed.
    ///
    /// Under the minimum gap: the first title's end comes back to the minimum gap before the
    /// second, but not so far that it gets shorter than the minimum duration; whatever is
    /// still missing comes from the second title's start moving on, again keeping it at
    /// least the minimum duration. A title already shorter than that doesn't get shorter.
    ///
    /// With `closeUnder`: a gap over the minimum but shorter than that closes down to the
    /// minimum by the first title's end moving on, unless that makes it longer than the
    /// maximum duration. Overlapping titles come back as they were.
    static func fixedGap(_ a: Subtitle, _ b: Subtitle, rules: TimingPreset, gap: Double, frame: Double,
                         closeUnder: Double?) -> (Subtitle, Subtitle) {
        let eps = 0.0005
        let g = b.start - a.end
        guard g >= -eps else { return (a, b) }
        var a2 = a, b2 = b
        if g < gap - eps {
            func onFrame(_ t: Double, up: Bool) -> Double {
                guard frame > 0 else { return t }
                let n = t / frame
                return (up ? (n - 0.001).rounded(.up) : (n + 0.001).rounded(.down)) * frame
            }
            // The shortest the first may get, and the latest the second may start.
            let shortestEnd = onFrame(a.start + rules.minDuration, up: true)
            let latestStart = onFrame(b.end - rules.minDuration, up: false)
            a2.end = min(a.end, max(b.start - gap, shortestEnd))
            if b2.start - a2.end < gap - eps {
                b2.start = max(b.start, min(a2.end + gap, latestStart))
            }
        } else if let closeUnder, g > gap + eps, g < closeUnder - eps {
            let end = b.start - gap
            if end - a.start <= rules.maxDuration + eps { a2.end = end }
        }
        return (a2, b2)
    }
}
