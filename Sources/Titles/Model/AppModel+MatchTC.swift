import Foundation
@testable import TitlesCore

/// Match TC to Neighbour: the titles waiting for a click on the title they should match.
struct MatchPick: Equatable {
    let trackID: UUID
    let ids: Set<UUID>
}

extension AppModel {
    /// The titles a command acts on: the group picked (Shift-click), else the selected title.
    var pickedTitleIDs: Set<UUID> {
        multiSelection.isEmpty ? Set([doc.selectedID].compactMap { $0 }) : multiSelection
    }

    /// Right-click ▸ Match TC to Neighbour: the next click on a title, in any language (a
    /// card, a waveform box, a slim lane), gives the picked titles its timing. Esc, or a
    /// click on empty waveform, cancels.
    func beginMatchTC() {
        guard let track = focusedTrack, !refuseIfLocked() else { return }
        let ids = pickedTitleIDs
        guard !ids.isEmpty else {
            flash("Select a title first (Shift-click to pick several).")
            return
        }
        matchPick = MatchPick(trackID: track.id, ids: ids)
        flash(ids.count == 1
              ? "Click the title whose timecodes it should take, in any language (Esc cancels)"
              : "Click the title the first of these \(ids.count) should start with, in any language (Esc cancels)")
        bump()
    }

    func cancelMatchTC() {
        guard matchPick != nil else { return }
        matchPick = nil
        flash("Match TC cancelled")
        bump()
    }

    /// The click that ends the pick. One title takes the clicked title's start and end;
    /// several move together so the first starts where the clicked one starts, keeping their
    /// lengths and the gaps between them. One undo step. With overlapping titles off, the
    /// titles stop at the minimum gap from a title of their own language in the way.
    @discardableResult
    func matchTC(to targetID: UUID, in targetTrackID: UUID) -> Bool {
        guard let pick = matchPick else { return false }
        guard let video, let track = video.track(pick.trackID),
              let target = video.track(targetTrackID)?.doc.subtitle(targetID) else {
            matchPick = nil
            bump()
            return false
        }
        if targetTrackID == pick.trackID, pick.ids.contains(targetID) {
            flash("That's one of the titles being matched: click another title (Esc cancels).")
            return false
        }
        matchPick = nil
        defer { bump() }
        let picked = track.doc.subtitles.filter { pick.ids.contains($0.id) }.sorted { $0.start < $1.start }
        guard let first = picked.first else { return false }
        let others = track.doc.subtitles.filter { !pick.ids.contains($0.id) }
        let gap = keepMinGap ? minGap : 0
        var times: [UUID: (start: Double, end: Double)] = [:]
        var note = ""

        if picked.count == 1 {
            var start = max(0, target.start), end = target.end
            if !allowOverlaps {
                // Titles of its own language in the way: it starts after them, or ends before.
                for o in others.sorted(by: { $0.start < $1.start }) where o.end > start - gap + 0.0005 && o.start < end + gap - 0.0005 {
                    if o.start <= start { start = max(start, o.end + gap) } else { end = min(end, o.start - gap) }
                }
                if end - start < 0.1 {
                    flash("No room there: titles of \(track.language.name) are in the way, and titles can't overlap (Title ▸ Enable Overlapping Titles).")
                    return false
                }
                if abs(start - target.start) > 0.0005 || abs(end - target.end) > 0.0005 {
                    note = ", shortened to keep clear of its neighbours (titles can't overlap)"
                }
            }
            times[first.id] = (start, end)
        } else {
            var offset = target.start - first.start
            if first.start + offset < 0 { offset = -first.start }
            if !allowOverlaps {
                // Moved by `off`, would any of them overlap (or come closer than the minimum
                // gap to) a title of their language that stays put?
                func blocked(_ off: Double) -> Bool {
                    picked.contains { p in
                        others.contains { o in o.end > p.start + off - gap + 0.0005 && o.start < p.end + off + gap - 0.0005 }
                    }
                }
                if blocked(offset) {
                    // The nearest place they fit: just before or just after a title in the way.
                    var candidates: [Double] = []
                    for p in picked {
                        for o in others { candidates += [o.start - gap - p.end, o.end + gap - p.start] }
                    }
                    let want = offset
                    guard let nearest = candidates.filter({ first.start + $0 >= 0 && !blocked($0) })
                        .min(by: { abs($0 - want) < abs($1 - want) }) else {
                        flash("No room there: titles of \(track.language.name) are in the way, and titles can't overlap (Title ▸ Enable Overlapping Titles).")
                        return false
                    }
                    offset = nearest
                    note = ", moved to the nearest place clear of the titles in the way (titles can't overlap)"
                }
            }
            for s in picked { times[s.id] = (s.start + offset, s.end + offset) }
        }

        track.doc.perform { subs in
            for i in subs.indices {
                guard let t = times[subs[i].id] else { continue }
                subs[i].start = t.start
                subs[i].end = t.end
            }
        }
        enforceLocks(in: video)
        let source = video.track(targetTrackID).map { $0.id == track.id ? "" : " in \($0.language.name)" } ?? ""
        let number = numberOfSub[targetID].map { " \($0)" } ?? ""
        flash("Matched \(picked.count == 1 ? "1 title" : "\(picked.count) titles") to title\(number)\(source)\(note) (⌘Z to undo)")
        return true
    }

    /// Whether Match TC to Linked Titles can act: a language other than the master, not
    /// locked, with picked titles that have a partner in the master.
    var canMatchLinked: Bool {
        guard let video, let track = focusedTrack, !track.locked, track.id != video.masterTrackID,
              let master = video.track(video.masterTrackID) else { return false }
        let ids = pickedTitleIDs
        return track.doc.subtitles.contains { s in ids.contains(s.id) && s.link.flatMap({ master.doc.subtitle($0) }) != nil }
    }

    /// Title ▸ Match TC to Linked Titles: each picked title takes the start and end of the
    /// master title it translates (the one beside it in the cards). No click. One undo step.
    /// Titles of this language that would end up overlapping keep their own timing.
    func matchLinked() {
        guard let video, let track = focusedTrack, !refuseIfLocked(),
              let master = video.track(video.masterTrackID), track.id != master.id else { return }
        let ids = pickedTitleIDs
        var times: [UUID: (start: Double, end: Double)] = [:]
        for s in track.doc.subtitles where ids.contains(s.id) {
            if let m = s.link.flatMap({ master.doc.subtitle($0) }) { times[s.id] = (m.start, m.end) }
        }
        guard !times.isEmpty else {
            flash("These titles have no partner in the master (\(master.language.name)).")
            return
        }
        var skipped = 0
        if !allowOverlaps {
            // The new timing must not overlap any title of the language (moved or not).
            let gap = keepMinGap ? minGap : 0
            let after = track.doc.subtitles.map { s -> (id: UUID, start: Double, end: Double) in
                let t = times[s.id]
                return (s.id, t?.start ?? s.start, t?.end ?? s.end)
            }
            for (id, t) in times where after.contains(where: { $0.id != id && $0.end > t.start - gap + 0.0005 && $0.start < t.end - 0.0005 + gap }) {
                times[id] = nil
                skipped += 1
            }
        }
        guard !times.isEmpty else {
            flash("Every one of them would overlap a title of \(track.language.name) (Title ▸ Enable Overlapping Titles).")
            return
        }
        track.doc.perform { subs in
            for i in subs.indices {
                guard let t = times[subs[i].id] else { continue }
                subs[i].start = t.start
                subs[i].end = t.end
            }
        }
        enforceLocks(in: video)
        bump()
        flash("Matched \(times.count) title\(times.count == 1 ? "" : "s") to \(master.language.name)"
              + (skipped > 0 ? "; \(skipped) kept their timing, as they'd overlap a neighbour" : "") + " (⌘Z to undo)")
    }
}
