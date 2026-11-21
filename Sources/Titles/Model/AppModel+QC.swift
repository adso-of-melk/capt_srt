import Foundation
@testable import TitlesCore

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

/// Everything one title's issues are worked out from (see AppModel.qcIssues).
struct QCIssueKey: Hashable {
    var sub: Subtitle
    var nextStart: Double?
    var overlaps: Bool
    var rules: TimingPreset
    var gap: Double
    var language: String
    /// The spelling dictionaries' and word lists' version; -1 with spell check off.
    var spelling: Int
}

// MARK: QC: finding issues

extension AppModel {
    /// Everything QC finds in one title of a language. `next` is the title after it.
    /// The rules are `QCRules.issues`; the spelling is the app's. Remembered while the title,
    /// its neighbour, the rules and the dictionaries stay the same: every card on screen asks
    /// each time it's drawn.
    func qcIssues(of s: Subtitle, in track: Track, next: Subtitle?, overlapping: Set<UUID>) -> Set<QCIssue> {
        let checks = checksSpelling(track)
        let code = track.language.code
        let rules = preset(for: track)
        let key = QCIssueKey(sub: s, nextStart: next?.start, overlaps: overlapping.contains(s.id), rules: rules,
                             gap: minGap, language: code, spelling: checks ? SpellService.shared.version : -1)
        if let known = qcIssueMemo[key] { return known }
        let found = QCRules.issues(of: s, next: next, overlapping: overlapping, rules: rules, gap: minGap,
                                   misspelled: { plain in
                                       checks && !SpellService.shared.misspelled(in: plain, language: code).isEmpty
                                   })
        if qcIssueMemo.count > 20000 { qcIssueMemo.removeAll(keepingCapacity: true) }
        qcIssueMemo[key] = found
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
        // Its place in the list: from its number when that's right (no search through the list).
        let numbered = numberOfSub[s.id].map { $0 - 1 }
        let here = numbered.flatMap { subs.indices.contains($0) && subs[$0].id == s.id ? $0 : nil }
            ?? subs.firstIndex { $0.id == s.id }
        let next = here.flatMap { $0 + 1 < subs.count ? subs[$0 + 1] : nil }
        return qcIssues(of: s, in: track, next: next, overlapping: overlapping).intersection(qcKinds)
    }

    /// The issue marks a title shows (a tag on its card, a bar over its waveform box), in QC
    /// mode or not, so titles can be checked while they're made. Every language shows them:
    /// the focused one in yellow-alert, the others in the quiet blue of their columns. Never
    /// on the title being typed in or spotted (it would flash on and off as the words go
    /// in): nil for those. QC mode adds the colours and Tab (in the focused language).
    /// `overlapping`: the focused language's overlapping titles (another language's are
    /// worked out here).
    func visibleQCMarks(of s: Subtitle, in track: Track, overlapping: Set<UUID>) -> Set<QCIssue>? {
        guard s.id != typingIn, s.id != spottingID else { return nil }
        let focused = track.id == video?.focusedTrackID
        return qcMarks(of: s, in: track, overlapping: focused ? overlapping : track.doc.overlappingIDs)
    }

    /// A card's text changed in its editor (typing, pasting, deleting).
    func typed(in id: UUID) {
        if typingIn != id { typingIn = id }
    }

    /// The issues of one title, in words.
    func describe(_ issues: Set<QCIssue>, of s: Subtitle, in track: Track) -> String {
        QCRules.describe(issues, of: s, rules: preset(for: track))
    }
}

// MARK: QC: fixing one title


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
        case .resplit: resplitToFit(all: false)
        case .removeBlankLines: rewriteText(of: id) { TextChecks.withoutBlankLines($0) }
        case .italicizeWords: rewriteText(of: id) { TextChecks.wholeWordItalics($0, italic: true) }
        case .unitalicizeWords: rewriteText(of: id) { TextChecks.wholeWordItalics($0, italic: false) }
        case .repairTags: rewriteText(of: id) { TextChecks.repairedTags($0) }
        }
    }

    /// Every title of the focused language put right by a text fix (Repair Formatting Tags,
    /// Remove Blank Lines), in one undo step. How many titles changed.
    @discardableResult
    func fixTextInAll(_ fix: QCFix) -> Int {
        let change: (String) -> String
        let what: String
        switch fix {
        case .repairTags: change = TextChecks.repairedTags; what = "Formatting tags repaired"
        case .removeBlankLines: change = TextChecks.withoutBlankLines; what = "Blank lines removed"
        default: return 0
        }
        var n = 0
        doc.perform { subs in
            for i in subs.indices {
                let after = change(subs[i].text)
                if after != subs[i].text { subs[i].text = after; n += 1 }
            }
        }
        doc.endTextCoalescing()
        flash(n == 0 ? "Nothing to fix" : "\(what) in \(n) title\(n == 1 ? "" : "s")")
        return n
    }

    /// A fix to one title's text, in one undo step.
    private func rewriteText(of id: UUID, _ change: (String) -> String) {
        doc.perform { subs in
            guard let i = subs.firstIndex(where: { $0.id == id }) else { return }
            let after = change(subs[i].text)
            if after != subs[i].text { subs[i].text = after }
        }
        doc.endTextCoalescing()
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
                guard QCRules.needsMoreTime(before, rules: rules) else { continue }
                let after = QCRules.extended(before, prev: i > 0 ? subs[i - 1] : nil,
                                             next: i + 1 < subs.count ? subs[i + 1] : nil,
                                             rules: rules, gap: minGap, frame: frameDuration, videoEnd: videoEnd)
                if after != before { subs[i] = after; extended += 1 }
                if QCRules.needsMoreTime(subs[i], rules: rules) { short += 1 }
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
}

// MARK: QC: fixing gaps

extension AppModel {
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
                let (a, b) = QCRules.fixedGap(subs[i], subs[i + 1], rules: rules, gap: minGap, frame: frameDuration,
                                              closeUnder: close ? QCRules.closeGapsUnder : nil)
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

    /// How many gaps in a language are under its minimum (overlaps don't count).
    func shortGapCount(in track: Track) -> Int {
        QCRules.shortGapCount(track.doc.subtitles, gap: Double(preset(for: track).minGapFrames) * frameDuration)
    }

    /// With Keep Minimum Gap on, after an import or a larger minimum: say how many gaps are
    /// short and what fixes them (they're left as they are until then, or until edited).
    func noteShortGaps(in track: Track) {
        guard keepMinGap else { return }
        let n = shortGapCount(in: track)
        guard n > 0 else { return }
        banner = "\(n) gap\(n == 1 ? " is" : "s are") under the minimum in \(track.language.name). "
            + "QC ▸ Widen All Gaps to the Minimum fixes them in one go (⌘Z to undo); each one is also fixed when you move one of its titles."
    }

}

// MARK: QC: re-splitting

extension AppModel {
    /// QC ▸ Re-split to Fit: titles with more text than their lines hold are split, titles
    /// too fast to read share their words with a neighbour close by, and titles shorter than
    /// the minimum duration join one (see `Refit`). The selected titles (or every title in
    /// the language), in one undo step.
    func resplitToFit(all: Bool) {
        guard let video, let track = focusedTrack, !refuseIfLocked() else { return }
        let picked: Set<UUID> = all ? Set(doc.subtitles.map(\.id)) : pickedTitleIDs
        guard !picked.isEmpty else {
            flash("Select the titles to re-split, or use Re-split All.")
            return
        }
        let limits = Refit.Limits(rules: preset(for: track), gap: minGap, frame: frameDuration,
                                  language: track.language.code, style: track.lineBreakStyle)
        var split = 0, shared = 0, joined = 0, left = 0
        track.doc.perform { subs in
            var i = 0
            while i < subs.count {
                guard picked.contains(subs[i].id) else { i += 1; continue }
                guard let change = Refit.change(for: i, in: subs, limits: limits) else {
                    if Self.wantsRefit(subs[i], limits: limits) { left += 1 }
                    i += 1
                    continue
                }
                let before = change.range.count, after = change.titles.count
                if after > before { split += 1 } else if after < before { joined += 1 } else { shared += 1 }
                subs.replaceSubrange(change.range, with: change.titles)
                i = change.range.lowerBound + change.titles.count
            }
        }
        track.doc.endTextCoalescing()
        clearMulti()
        enforceLocks(in: video)
        bump()
        var done: [String] = []
        if split > 0 { done.append("split \(split) title\(split == 1 ? "" : "s")") }
        if shared > 0 { done.append("re-split \(shared) pair\(shared == 1 ? "" : "s")") }
        if joined > 0 { done.append("joined \(joined) pair\(joined == 1 ? "" : "s")") }
        if done.isEmpty {
            flash(left > 0
                  ? "Re-splitting can't fix \(left == 1 ? "this title" : "these \(left) titles"): no neighbour close enough to share with (try Extend to Fit Reading Speed)."
                  : "Every \(all ? "" : "selected ")title already fits.")
        } else {
            let text = done.joined(separator: ", ")
            flash(text.prefix(1).uppercased() + text.dropFirst()
                  + (left > 0 ? "; \(left) left as they were (nothing close to share with)" : "") + " (⌘Z to undo)")
        }
    }

    /// Too much text for its lines, too fast, or too short.
    static func wantsRefit(_ s: Subtitle, limits l: Refit.Limits) -> Bool {
        s.characterCount > 0 && (Refit.overflows(s.text, l) || Refit.tooFast(s.characterCount, s.duration, l)
                                 || s.duration < l.rules.minDuration - 0.0005)
    }
}
