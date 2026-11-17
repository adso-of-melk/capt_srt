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

/// Everything the QC bar's counts are worked out from. While none of it changes, the counts
/// are kept (the bar asks for them every time anything in the window changes).
struct QCCountKey: Equatable {
    var track: UUID
    var language: String
    var subtitles: [Subtitle]
    var rules: TimingPreset
    var gap: Double
    /// The spelling dictionaries' and word lists' version; -1 with spell check off.
    var spelling: Int
}

// MARK: QC: finding issues

extension AppModel {
    /// Everything QC finds in one title of a language. `next` is the title after it.
    func qcIssues(of s: Subtitle, in track: Track, next: Subtitle?, overlapping: Set<UUID>) -> Set<QCIssue> {
        var found = Set<QCIssue>()
        let rules = preset(for: track)
        let plain = Markup.plain(s.text)
        if plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.insert(.empty)
        } else if checksSpelling(track),
                  !SpellService.shared.misspelled(in: plain, language: track.language.code).isEmpty {
            found.insert(.spelling)
        }
        // Over the limit by any amount (even 17.02 CPS, shown as 17.0); amber: within 2 of it.
        if Self.overReadingSpeed(s, rules: rules) { found.insert(.readingSpeed) }
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

    /// Every title of a language with an issue, in time order.
    func qcReport(for track: Track) -> [(id: UUID, issues: Set<QCIssue>)] {
        let subs = track.doc.subtitles
        let overlapping = track.doc.overlappingIDs
        var out: [(id: UUID, issues: Set<QCIssue>)] = []
        for (i, s) in subs.enumerated() {
            let issues = qcIssues(of: s, in: track, next: i + 1 < subs.count ? subs[i + 1] : nil,
                                  overlapping: overlapping)
            if !issues.isEmpty { out.append((s.id, issues)) }
        }
        return out
    }

    /// How many titles of the focused language have each kind of issue. Worked out once for
    /// a given set of titles and rules: see `QCCountKey`.
    func qcCounts() -> [QCIssue: Int] {
        guard let track = focusedTrack else { return [:] }
        let key = QCCountKey(track: track.id, language: track.language.code, subtitles: track.doc.subtitles,
                             rules: preset(for: track), gap: minGap,
                             spelling: checksSpelling(track) ? SpellService.shared.version : -1)
        if let memo = qcCountMemo, memo.key == key { return memo.counts }
        var counts: [QCIssue: Int] = [:]
        for entry in qcReport(for: track) {
            for issue in entry.issues { counts[issue, default: 0] += 1 }
        }
        qcCountMemo = (key, counts)
        return counts
    }

    /// Tab / Shift-Tab in QC mode, and QC ▸ Next Issue / Previous Issue: the next title
    /// (after the selected one, or after the playhead, wrapping round) with an issue of a
    /// kind ticked in the QC bar. Turns QC mode on. With `keepEditing`, its card opens for typing.
    @discardableResult
    func nextIssue(_ delta: Int = 1, keepEditing: Bool = false) -> UUID? {
        if !qcMode { qcMode = true }
        guard let track = focusedTrack else { return nil }
        let subs = track.doc.subtitles
        guard !subs.isEmpty else {
            flash("No titles in \(track.language.name) yet.")
            return nil
        }
        let wanted = qcKinds
        guard !wanted.isEmpty else {
            flash("Tick at least one kind of issue in the QC bar.")
            return nil
        }
        let overlapping = track.doc.overlappingIDs
        let step = delta >= 0 ? 1 : -1
        let first: Int
        if let id = track.doc.selectedID, let here = subs.firstIndex(where: { $0.id == id }) {
            first = here + step
        } else {
            // Nothing selected (the playhead is in a gap): from the playhead.
            let t = clock.time
            first = step > 0 ? (subs.firstIndex { $0.start > t + 0.0005 } ?? 0)
                             : (subs.lastIndex { $0.start < t - 0.0005 } ?? subs.count - 1)
        }
        for k in 0..<subs.count {
            let i = ((first + k * step) % subs.count + subs.count) % subs.count
            let s = subs[i]
            let issues = qcIssues(of: s, in: track, next: i + 1 < subs.count ? subs[i + 1] : nil,
                                  overlapping: overlapping).intersection(wanted)
            guard !issues.isEmpty else { continue }
            if engine.isPlaying { engine.pause() }
            clearMulti()
            emptySlotRow = nil
            select(s.id, seekToStart: true)
            cardScrollTarget = s.id
            if keepEditing { focusRequest = s.id }
            flash("#\(rowNumber(of: s.id) ?? i + 1): " + describe(issues, of: s, in: track))
            return s.id
        }
        flash("No \(wanted.count == QCIssue.allCases.count ? "" : "ticked ")issues in \(track.language.name).")
        return nil
    }

    /// The issues of one title of the focused language, of the kinds ticked in the QC bar
    /// (for marking cards and waveform boxes in QC mode).
    func qcMarks(of s: Subtitle, in track: Track, overlapping: Set<UUID>) -> Set<QCIssue> {
        let subs = track.doc.subtitles
        let next = subs.firstIndex { $0.id == s.id }.flatMap { $0 + 1 < subs.count ? subs[$0 + 1] : nil }
        return qcIssues(of: s, in: track, next: next, overlapping: overlapping).intersection(qcKinds)
    }

    /// The issue marks a title shows (yellow tag on its card, yellow bar over its waveform
    /// box), in QC mode or not, so titles can be checked while they're made. Only the focused
    /// language's titles, and never the one being typed in or spotted (it would flash on and
    /// off as the words go in): nil for those. QC mode adds the colours and Tab.
    func visibleQCMarks(of s: Subtitle, in track: Track, overlapping: Set<UUID>) -> Set<QCIssue>? {
        guard track.id == video?.focusedTrackID, s.id != typingIn, s.id != spottingID else { return nil }
        return qcMarks(of: s, in: track, overlapping: overlapping)
    }

    /// A card's text changed in its editor (typing, pasting, deleting).
    func typed(in id: UUID) {
        if typingIn != id { typingIn = id }
    }

    /// The issues of one title, in words.
    func describe(_ issues: Set<QCIssue>, of s: Subtitle, in track: Track) -> String {
        let rules = preset(for: track)
        return QCIssue.allCases.filter(issues.contains).map { issue -> String in
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
}

// MARK: QC: fixing one title

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

extension AppModel {
    /// One fix for one title (from its issue tag): the title is selected first, alone, so the
    /// fix works on it as the QC menu's "Selected" commands would. One undo step.
    func applyQCFix(_ fix: QCFix, to id: UUID) {
        guard doc.subtitle(id) != nil else { return }
        clearMulti()
        emptySlotRow = nil
        select(id)
        switch fix {
        case .extend: extendToFitReadingSpeed(all: false)
        case .widenGaps: fixGaps(all: false, close: false)
        case .rebreak:
            rebreakSelected()
            doc.endTextCoalescing()
        }
    }
}

// MARK: QC: fixing reading speed

extension AppModel {
    /// QC ▸ Extend to Fit Reading Speed: titles that read too fast (or are shorter than the
    /// minimum duration) get longer, into the free room after them first and then before
    /// them, keeping the minimum gap and never past the maximum duration. The selected titles
    /// (or every title in the language), in one undo step.
    func extendToFitReadingSpeed(all: Bool) {
        guard let track = focusedTrack, !refuseIfLocked() else { return }
        let picked: Set<UUID> = all ? Set(doc.subtitles.map(\.id))
            : (multiSelection.isEmpty ? Set([doc.selectedID].compactMap { $0 }) : multiSelection)
        guard !picked.isEmpty else {
            flash("Select the titles to extend, or use Extend All.")
            return
        }
        let rules = preset(for: track)
        let videoEnd = engine.duration > 0 ? engine.duration : Double.greatestFiniteMagnitude
        var extended = 0, short = 0
        doc.perform { subs in
            for i in subs.indices where picked.contains(subs[i].id) {
                let before = subs[i]
                guard Self.needsMoreTime(before, rules: rules) else { continue }
                let after = Self.extended(before, prev: i > 0 ? subs[i - 1] : nil,
                                          next: i + 1 < subs.count ? subs[i + 1] : nil,
                                          rules: rules, gap: minGap, frame: frameDuration, videoEnd: videoEnd)
                if after != before { subs[i] = after; extended += 1 }
                if Self.needsMoreTime(subs[i], rules: rules) { short += 1 }
            }
        }
        doc.endTextCoalescing()
        if extended == 0 && short == 0 {
            flash("Every \(all ? "" : "selected ")title is within the reading speed and minimum duration.")
        } else {
            flash("Extended \(extended) title\(extended == 1 ? "" : "s")"
                  + (short > 0 ? "; \(short) still too fast or short (no room left)" : "") + " (⌘Z to undo)")
        }
    }

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
}

// MARK: QC: fixing gaps

extension AppModel {
    /// Gaps a little over the minimum close down to it ("Close Short Gaps"): under this long.
    static let closeGapsUnder = 0.5

    /// QC ▸ Widen Gaps to the Minimum, and (with `close`) Close Short Gaps to the Minimum.
    /// Titles closer together than the minimum gap move apart to it; with `close`, gaps
    /// shorter than half a second close down to it too. Starts stay where they are whenever
    /// they can (they usually sit on the first word): see `fixedGap`. Overlapping titles are
    /// left alone (QC shows them). The gaps either side of the selected titles (or every gap
    /// in the language), in one undo step.
    func fixGaps(all: Bool, close: Bool) {
        guard let track = focusedTrack, !refuseIfLocked() else { return }
        let picked: Set<UUID> = all ? Set(doc.subtitles.map(\.id))
            : (multiSelection.isEmpty ? Set([doc.selectedID].compactMap { $0 }) : multiSelection)
        guard !picked.isEmpty else {
            flash("Select the titles whose gaps to fix, or use the All command.")
            return
        }
        let rules = preset(for: track)
        var fixed = 0, stuck = 0
        doc.perform { subs in
            guard subs.count > 1 else { return }
            for i in 0..<(subs.count - 1) where picked.contains(subs[i].id) || picked.contains(subs[i + 1].id) {
                let (a, b) = Self.fixedGap(subs[i], subs[i + 1], rules: rules, gap: minGap, frame: frameDuration,
                                           closeUnder: close ? Self.closeGapsUnder : nil)
                if a != subs[i] || b != subs[i + 1] { subs[i] = a; subs[i + 1] = b; fixed += 1 }
                let g = b.start - a.end
                if g >= -0.0005 && g < minGap - 0.0005 { stuck += 1 }
            }
        }
        doc.endTextCoalescing()
        if fixed == 0 && stuck == 0 {
            flash("Every \(all ? "" : "selected ")gap is " + (close ? "at the minimum or over half a second." : "at least the minimum."))
        } else {
            flash("Fixed \(fixed) gap\(fixed == 1 ? "" : "s")"
                  + (stuck > 0 ? "; \(stuck) left (no room without going under the minimum duration)" : "")
                  + " (⌘Z to undo)")
        }
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
