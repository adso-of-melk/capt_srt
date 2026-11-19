import Foundation
import AppKit
@testable import TitlesCore

/// Words dragged from the card being typed in onto another card: after splitting a title
/// whose lines are too long, say, its last words can be dragged into the new, empty one.
extension AppModel {
    /// The words being dragged out of a card (see TitleTextView.dragSelection), and what's
    /// left of that card's text without them. Both with their tags, so italics carry over.
    struct TextDrag {
        let source: UUID
        let track: UUID
        let piece: String
        let rest: String
    }

    func beginTextDrag(from source: UUID, track: Track, piece: String, rest: String) {
        textDrag = TextDrag(source: source, track: track.id, piece: piece, rest: rest)
    }

    /// Can what's being dragged now be dropped on this title? Only words from a card's own
    /// text, onto another title. `dragged` is the drag's text (read from the drag itself
    /// when not given).
    func acceptsTextDrop(on target: UUID, dragged: String? = nil) -> Bool {
        guard let drag = textDrag, drag.source != target else { return false }
        let words = dragged ?? NSPasteboard(name: .drag).string(forType: .string) ?? ""
        return Self.sameWords(words, Markup.plain(drag.piece))
    }

    /// The dragged words dropped on a title: they go to the start of a later title, or the
    /// end of an earlier one (or of one starting at the same time, in another language), and leave the card they came from (with `copy`, or dropped in
    /// another language, they stay there too). Both titles' lines are broken again by the
    /// rules. One ⌘Z undoes it.
    @discardableResult
    func dropText(on target: UUID, in targetTrack: Track, copy: Bool, dragged: String? = nil) -> Bool {
        guard acceptsTextDrop(on: target, dragged: dragged), let drag = textDrag else { return false }
        textDrag = nil
        guard let sourceTrack = video?.tracks.first(where: { $0.id == drag.track }),
              let source = sourceTrack.doc.subtitle(drag.source),
              let dest = targetTrack.doc.subtitle(target) else { return false }
        let move = !copy && sourceTrack === targetTrack
        let destText = rebroken(Self.joined(drag.piece, into: dest.text, atStart: dest.start > source.start),
                                track: targetTrack)
        let restText = rebroken(Self.leftover(drag.rest), track: sourceTrack)
        targetTrack.doc.perform { subs in
            if let j = subs.firstIndex(where: { $0.id == target }) { subs[j].text = destText }
            if move, let i = subs.firstIndex(where: { $0.id == drag.source }) { subs[i].text = restText }
        }
        targetTrack.doc.endTextCoalescing()
        // The card the words came from stays open for typing: its editor picks up the
        // shorter text by itself.
        return true
    }

    /// The text broken into lines by the language's rules (when automatic line breaks are on).
    private func rebroken(_ text: String, track: Track) -> String {
        guard autoLineBreaks, !Markup.plain(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let rules = preset(for: track)
        return LineBreaker.breakLines(text, maxChars: rules.maxCharsPerLine, maxLines: rules.maxLines,
                                      language: track.language.code)
    }

    /// The dragged words put into a title's text: in front (`atStart`) or after it, with one
    /// space between. Into an empty title, just the words.
    static func joined(_ piece: String, into text: String, atStart: Bool) -> String {
        let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Markup.plain(t).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return p }
        if p.isEmpty { return t }
        return TextChecks.repairedTags(atStart ? p + " " + t : t + " " + p)
    }

    /// What's left of a title when words are taken out of it: no spaces at the ends, none
    /// doubled where the words were, no blank lines.
    static func leftover(_ rest: String) -> String {
        let lines = rest.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        return TextChecks.repairedTags(TextChecks.withoutBlankLines(lines.joined(separator: "\n")))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same words, give or take spaces and line breaks (a drag's text against the words
    /// the card said it was dragging).
    static func sameWords(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [Substring] { s.split(whereSeparator: { $0.isWhitespace }) }
        let wa = words(a)
        return !wa.isEmpty && wa == words(b)
    }
}
