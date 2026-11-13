import Foundation
import AppKit

/// One place a search matched: a stretch of a title's visible text (tags left out).
struct FindMatch: Equatable {
    let trackID: UUID
    let titleID: UUID
    /// The title's start, so matches go in film order.
    let start: Double
    /// In the title's text without tags (`Markup.plain`).
    let range: NSRange
}

/// What the card editor highlights: the search, and which of its matches in this title is current.
struct FindHighlight: Equatable {
    var query: String
    var matchCase: Bool
    var wholeWord: Bool
    var current: Int?
}

enum FindScope: String, CaseIterable, Identifiable {
    case language = "This Language"
    case allLanguages = "All Open Languages"
    case selected = "Selected Titles"
    var id: String { rawValue }
}

/// Find and Replace over the titles: ⌘F, ⌥⌘F, ⌘G, ⇧⌘G. Searches what a viewer reads, so
/// tags never get in the way, and replacing keeps every tag (italics stay italic).
@MainActor
final class FindController: ObservableObject {
    private unowned let model: AppModel

    @Published var isShown = false
    @Published var showsReplace = false
    @Published var query = "" { didSet { if query != oldValue { current = nil; refresh() } } }
    @Published var replacement = ""
    @Published var matchCase = false { didSet { if matchCase != oldValue { refresh() } } }
    @Published var wholeWord = false { didSet { if wholeWord != oldValue { refresh() } } }
    @Published var scope: FindScope = .language {
        didSet { if scope != oldValue { captureSelection(); current = nil; refresh() } }
    }
    @Published private(set) var matches: [FindMatch] = []
    /// The match last gone to (an index into `matches`).
    @Published private(set) var current: Int?
    /// Bumped to put the cursor in the Find field.
    @Published private(set) var focusTick = 0

    /// The titles "Selected Titles" searches, taken when that scope was picked.
    private var scopeIDs: Set<UUID> = []
    private var byTitle: [UUID: [NSRange]] = [:]

    init(model: AppModel) { self.model = model }

    // MARK: Showing

    func show(replace: Bool) {
        if replace { showsReplace = true }
        if !isShown {
            isShown = true
            captureSelection()
            refresh()
        }
        focusTick &+= 1
    }

    func close() {
        guard isShown else { return }
        isShown = false
        current = nil
        model.mainWindow?.makeFirstResponder(nil)
        model.bump()
    }

    private func captureSelection() {
        guard scope == .selected else { return }
        scopeIDs = model.multiSelection.isEmpty ? Set([model.doc.selectedID].compactMap { $0 }) : model.multiSelection
    }

    /// "3 of 17", "17 found", "Not found".
    var countText: String {
        guard !query.isEmpty else { return "" }
        if matches.isEmpty { return "Not found" }
        if let current { return "\(current + 1) of \(matches.count)" }
        return matches.count == 1 ? "1 found" : "\(matches.count) found"
    }

    // MARK: Matching

    /// Where `query` appears in `text`. Case is ignored unless `matchCase`; accents always
    /// count (c is not č). A line break counts as a space, so a phrase broken over two
    /// lines is still found. `wholeWord`: not inside a longer word.
    static func ranges(of query: String, in text: String, matchCase: Bool, wholeWord: Bool,
                       locale: Locale? = nil) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let flat = text.replacingOccurrences(of: "\n", with: " ") as NSString
        let q = query.replacingOccurrences(of: "\n", with: " ")
        var options: NSString.CompareOptions = []
        if !matchCase { options.insert(.caseInsensitive) }
        var out: [NSRange] = []
        var from = 0
        while from < flat.length {
            let r = flat.range(of: q, options: options, range: NSRange(location: from, length: flat.length - from),
                               locale: locale)
            guard r.location != NSNotFound, r.length > 0 else { break }
            if !wholeWord || isWholeWord(r, in: flat) {
                out.append(r)
                from = r.location + r.length
            } else {
                from = r.location + flat.rangeOfComposedCharacterSequence(at: r.location).length
            }
        }
        return out
    }

    private static func isWholeWord(_ r: NSRange, in s: NSString) -> Bool {
        func isWordChar(_ i: Int) -> Bool {
            let c = s.substring(with: s.rangeOfComposedCharacterSequence(at: i))
            return c.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }
        if r.location > 0, isWordChar(r.location - 1) { return false }
        if r.location + r.length < s.length, isWordChar(r.location + r.length) { return false }
        return true
    }

    /// The tagged text with `plainRange` (a range in its visible text) replaced. Tags inside
    /// the replaced stretch stay, just after the new words, so formatting stays balanced.
    static func replace(_ plainRange: NSRange, in text: String, with replacement: String) -> String {
        let ns = text as NSString
        let tags = Markup.tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        // offsets[p]: where the p-th visible character sits in the tagged text.
        var offsets: [Int] = []
        var i = 0, t = 0
        while i < ns.length {
            if t < tags.count, tags[t].location == i { i += tags[t].length; t += 1; continue }
            offsets.append(i)
            i += 1
        }
        guard plainRange.location >= 0, plainRange.length > 0,
              plainRange.location + plainRange.length <= offsets.count else { return text }
        let start = offsets[plainRange.location]
        let end = offsets[plainRange.location + plainRange.length - 1] + 1
        let kept = tags.filter { $0.location >= start && $0.location + $0.length <= end }.map { ns.substring(with: $0) }
        let out = ns.substring(to: start) + replacement + kept.joined() + ns.substring(from: end)
        return tidy(out)
    }

    /// Drops style tags left with nothing between them (<i></i>).
    static func tidy(_ text: String) -> String {
        var s = text
        while let r = s.range(of: #"<(i|b|u)></\1>"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        return s
    }

    private func tracksInScope() -> [Track] {
        switch scope {
        case .language, .selected: return model.focusedTrack.map { [$0] } ?? []
        case .allLanguages: return model.openTracks
        }
    }

    /// Searches again (the text, the options or the focused language changed).
    func refresh() {
        let old = current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        var found: [FindMatch] = []
        if isShown, !query.isEmpty {
            let tracks = tracksInScope()
            let order = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($0.element.id, $0.offset) })
            for track in tracks {
                let locale = Locale(identifier: track.language.code)
                for s in track.doc.subtitles {
                    if scope == .selected, !scopeIDs.contains(s.id) { continue }
                    for r in Self.ranges(of: query, in: Markup.plain(s.text), matchCase: matchCase,
                                         wholeWord: wholeWord, locale: locale) {
                        found.append(FindMatch(trackID: track.id, titleID: s.id, start: s.start, range: r))
                    }
                }
            }
            found.sort {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.trackID != $1.trackID { return (order[$0.trackID] ?? 0) < (order[$1.trackID] ?? 0) }
                return $0.range.location < $1.range.location
            }
        }
        var index: [UUID: [NSRange]] = [:]
        for m in found { index[m.titleID, default: []].append(m.range) }
        let changed = found != matches
        matches = found
        byTitle = index
        // Stay on the same match (or the next one in the same title) when the text changes.
        if let old {
            current = found.firstIndex { $0.titleID == old.titleID && $0.range.location >= old.range.location }
        } else if current != nil, found.isEmpty {
            current = nil
        }
        if changed { model.bump() }
    }

    /// The matches in a title (to highlight on its card), and which of them is the current one.
    func highlights(in titleID: UUID) -> (ranges: [NSRange], current: Int?) {
        guard isShown, let ranges = byTitle[titleID] else { return ([], nil) }
        guard let c = current, matches.indices.contains(c), matches[c].titleID == titleID else { return (ranges, nil) }
        return (ranges, ranges.firstIndex(of: matches[c].range))
    }

    /// For the editor of a title: what to highlight in it, or nil.
    func editorHighlight(for titleID: UUID) -> FindHighlight? {
        guard isShown, !query.isEmpty else { return nil }
        return FindHighlight(query: query, matchCase: matchCase, wholeWord: wholeWord,
                             current: highlights(in: titleID).current)
    }

    // MARK: Going to matches

    func next() { step(1) }
    func previous() { step(-1) }

    private func step(_ dir: Int) {
        if query.isEmpty { show(replace: false); return }
        if !isShown { isShown = true; captureSelection(); refresh() }
        guard !matches.isEmpty else {
            NSSound.beep()
            model.flash("“\(query)” not found.")
            return
        }
        let n = matches.count
        if let c = current {
            current = ((c + dir) % n + n) % n
        } else {
            current = firstIndex(from: model.doc.selected, forward: dir > 0)
        }
        go()
    }

    /// The first match at or after the selected title (or before it, going back).
    private func firstIndex(from selected: Subtitle?, forward: Bool) -> Int {
        guard let selected else { return forward ? 0 : matches.count - 1 }
        if forward {
            return matches.firstIndex { $0.start >= selected.start } ?? 0
        }
        return matches.lastIndex { $0.start <= selected.start } ?? matches.count - 1
    }

    private func go() {
        guard let c = current, matches.indices.contains(c) else { return }
        let m = matches[c]
        if model.focusedTrack?.id != m.trackID { model.focusTrack(m.trackID, edit: false) }
        model.select(m.titleID, seekToStart: true)
        model.cardScrollTarget = m.titleID
        model.bump()
    }

    // MARK: Replacing

    /// Replaces the current match (going to the first one if none is current yet), then
    /// goes on to the next.
    func replaceCurrent() {
        guard !query.isEmpty else { return }
        if !isShown { isShown = true; refresh() }
        guard let c = current, matches.indices.contains(c) else { next(); return }
        let m = matches[c]
        guard let track = model.video?.track(m.trackID), let s = track.doc.subtitle(m.titleID) else { return }
        track.doc.endTextCoalescing()
        track.doc.setText(s.id, Self.replace(m.range, in: s.text, with: replacement))
        track.doc.endTextCoalescing()
        // Searching again: the replaced words may not match any more; carry on after them.
        let after = m.range.location + (replacement as NSString).length
        current = nil
        refresh()
        if matches.isEmpty { model.flash("Replaced the last one."); return }
        let order = Dictionary(uniqueKeysWithValues: tracksInScope().enumerated().map { ($0.element.id, $0.offset) })
        let column = order[m.trackID] ?? 0
        current = matches.firstIndex { x in
            if x.titleID == m.titleID { return x.range.location >= after }
            if x.start != m.start { return x.start > m.start }
            return (order[x.trackID] ?? 0) > column
        } ?? 0
        go()
    }

    /// Replaces every match, one undo step per language.
    @discardableResult
    func replaceAll() -> Int {
        guard !query.isEmpty else { return 0 }
        if !isShown { isShown = true }
        refresh()
        guard !matches.isEmpty else {
            NSSound.beep()
            model.flash("“\(query)” not found.")
            return 0
        }
        var count = 0, languages = 0
        let byTrack = Dictionary(grouping: matches, by: \.trackID)
        for (trackID, list) in byTrack {
            guard let track = model.video?.track(trackID) else { continue }
            let perTitle = Dictionary(grouping: list, by: \.titleID)
            track.doc.endTextCoalescing()
            track.doc.perform { subs in
                for i in subs.indices {
                    guard let ms = perTitle[subs[i].id] else { continue }
                    // Back to front, so earlier ranges stay where they were.
                    for m in ms.sorted(by: { $0.range.location > $1.range.location }) {
                        subs[i].text = Self.replace(m.range, in: subs[i].text, with: replacement)
                        count += 1
                    }
                }
            }
            track.doc.endTextCoalescing()
            languages += 1
        }
        current = nil
        refresh()
        let where_ = languages > 1 ? " in \(languages) languages" : ""
        model.flash("Replaced \(count) \(count == 1 ? "match" : "matches")\(where_). ⌘Z undoes it.")
        return count
    }
}
