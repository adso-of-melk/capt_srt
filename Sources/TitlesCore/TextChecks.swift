import Foundation

/// Checks and repairs of a title's text itself: broken formatting tags, blank lines, and
/// words only partly in italics. QC flags them (`QCIssue.tags`, `.blankLine`, `.partItalic`)
/// and offers the fixes; export always writes repaired tags and no blank lines.
enum TextChecks {

    // MARK: Formatting tags

    /// The style tags whose pairs are checked. (Position and colour codes such as {\an8} and
    /// <font …> are left as written.)
    static let styleTags: Set<String> = ["i", "b", "u", "s"]

    /// Tags typed with stray spaces or a missing bracket: "< i >", "</ i>", "<i Hello",
    /// "Hello /i>". Group 1 is the "/", group 2 the tag's letter.
    private static let spacedTag = try! NSRegularExpression(
        pattern: #"<(?=[^<>]*\s[^<>]*>)\s*(/?)\s*([ibus])\s*>"#, options: [.caseInsensitive])
    /// "<i Hello": the space after it goes too. "Hello</i there": the space stays.
    private static let unclosedOpening = try! NSRegularExpression(
        pattern: #"<()([ibus])(?:[ \t]|(?=\n)|$)"#, options: [.caseInsensitive])
    private static let unclosedClosing = try! NSRegularExpression(
        pattern: #"<(/)([ibus])(?=\s|$)"#, options: [.caseInsensitive])
    private static let missingOpenBracket = try! NSRegularExpression(
        pattern: #"(?<=^|\s)(/?)([ibus])>"#, options: [.caseInsensitive])

    /// The text with every style tag in a proper pair: misspelt tags written properly, a
    /// closing tag with nothing open dropped, a second opening of a tag already open dropped,
    /// crossed tags (<i><b>…</i></b>) untangled, tags left open closed at the end, and empty
    /// pairs (<i></i>) taken out. Text that's already right comes back as it was.
    static func repairedTags(_ text: String) -> String {
        guard text.contains("<") || text.contains(">") else { return text }
        var t = normalisedTags(text)
        t = balancedTags(t)
        t = withoutEmptyPairs(t)
        return t
    }

    /// Does the text need `repairedTags`?
    static func hasBrokenTags(_ text: String) -> Bool {
        repairedTags(text) != text
    }

    /// How many of these titles' texts `repairedTags` changes.
    static func brokenTagCount(_ subs: [Subtitle]) -> Int {
        subs.filter { hasBrokenTags($0.text) }.count
    }

    private static func normalisedTags(_ text: String) -> String {
        var t = text
        for pattern in [spacedTag, unclosedOpening, unclosedClosing, missingOpenBracket] {
            let ns = t as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard pattern.firstMatch(in: t, range: range) != nil else { continue }
            // Lower-case the letter as it's rewritten, the way tags are usually written.
            var out = ""
            var last = 0
            for m in pattern.matches(in: t, range: range) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let slash = ns.substring(with: m.range(at: 1))
                let name = ns.substring(with: m.range(at: 2)).lowercased()
                out += "<\(slash)\(name)>"
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            t = out
        }
        return t
    }

    /// One style tag in the text: its range, its name, and whether it closes.
    private struct StyleTag {
        let range: NSRange
        let name: String
        let closing: Bool
    }

    private static func styleTagsIn(_ text: String) -> [StyleTag] {
        let ns = text as NSString
        return Markup.tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.range(at: 2).location != NSNotFound else { return nil }
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            guard styleTags.contains(name) else { return nil }
            let whole = ns.substring(with: m.range)
            if whole.hasSuffix("/>") { return nil }          // "<i/>": no effect either way
            return StyleTag(range: m.range, name: name, closing: m.range(at: 1).length > 0)
        }
    }

    private static func balancedTags(_ text: String) -> String {
        let tags = styleTagsIn(text)
        guard !tags.isEmpty else { return text }
        let ns = text as NSString
        var out = ""
        var open: [String] = []
        var last = 0
        for tag in tags {
            out += ns.substring(with: NSRange(location: last, length: tag.range.location - last))
            last = tag.range.location + tag.range.length
            let written = ns.substring(with: tag.range)
            if !tag.closing {
                if open.contains(tag.name) { continue }       // already open: a second <i> means nothing
                open.append(tag.name)
                out += written
            } else if let at = open.lastIndex(of: tag.name) {
                // Close the ones opened inside it first, then open them again after it.
                let inner = Array(open[(at + 1)...])
                for name in inner.reversed() { out += "</\(name)>" }
                out += written
                open.remove(at: at)
                open.removeLast(inner.count)
                for name in inner { out += "<\(name)>"; open.append(name) }
            }
            // A closing tag with nothing open is left out.
        }
        out += ns.substring(from: last)
        for name in open.reversed() { out += "</\(name)>" }
        return out
    }

    /// <i></i> and <i> </i> (just a space) come out; the space stays.
    private static let emptyPair = try! NSRegularExpression(
        pattern: #"<(i|b|u|s)>(\s*)</\1>"#, options: [.caseInsensitive])

    private static func withoutEmptyPairs(_ text: String) -> String {
        var t = text
        while true {
            let ns = t as NSString
            let next = emptyPair.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: ns.length),
                                                          withTemplate: "$2")
            if next == t { return t }
            t = next
        }
    }

    // MARK: Blank lines

    /// A line with nothing a viewer would read on it: empty, only spaces, or only tags.
    static func isBlankLine(_ line: Substring) -> Bool {
        Markup.plain(String(line)).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A title with text that has a blank line in it (before, between or after its lines).
    /// A title with no text at all is "empty" instead.
    static func hasBlankLine(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.contains(where: { !isBlankLine($0) }) else { return false }
        return lines.count > 1 && lines.contains(where: isBlankLine)
    }

    /// The text without its blank lines. Tags on a blank line move onto the next line (or the
    /// one before, at the end), so italics still start and stop where they did.
    static func withoutBlankLines(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1, lines.contains(where: { isBlankLine(Substring($0)) }) else { return text }
        var kept: [String] = []
        var carried = ""
        for line in lines {
            if isBlankLine(Substring(line)) {
                carried += tagsOnly(line)
            } else {
                kept.append(carried + line)
                carried = ""
            }
        }
        if !carried.isEmpty {
            if kept.isEmpty { kept.append(carried) } else { kept[kept.count - 1] += carried }
        }
        return kept.joined(separator: "\n")
    }

    /// The tags of a line, without its text.
    private static func tagsOnly(_ line: String) -> String {
        let ns = line as NSString
        return Markup.tagPattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }.joined()
    }

    // MARK: Words partly in italics

    /// The text in pieces: each character a viewer reads, with whether it's in italics, and
    /// every tag other than <i> kept as written.
    enum Piece: Equatable {
        case char(Character, italic: Bool)
        case tag(String)
    }

    static func pieces(_ text: String) -> [Piece] {
        let ns = text as NSString
        var out: [Piece] = []
        var depth = 0
        var last = 0
        func addText(_ s: String) {
            for c in s { out.append(.char(c, italic: depth > 0)) }
        }
        for m in Markup.tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            addText(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
            let isItalic = m.range(at: 2).location != NSNotFound && ns.substring(with: m.range(at: 2)).lowercased() == "i"
            if isItalic {
                if ns.substring(with: m.range).hasSuffix("/>") { continue }
                if m.range(at: 1).length > 0 { depth = max(0, depth - 1) } else { depth += 1 }
            } else {
                out.append(.tag(ns.substring(with: m.range)))
            }
        }
        addText(ns.substring(from: last))
        return out
    }

    /// Back to text: <i> tags where the italics start and stop (spaces and line breaks go on
    /// with whatever comes before them), other tags where they were.
    static func text(from pieces: [Piece]) -> String {
        var out = ""
        var open = false
        // Where the italics should be switched at each character: at the next one that isn't
        // a space or line break.
        for (k, p) in pieces.enumerated() {
            switch p {
            case .tag(let t):
                out += t
            case .char(let c, let italic):
                if c.isWhitespace {
                    // Close before a space only if nothing italic follows before the next word.
                    if open, !italic || !followingIsItalic(pieces, after: k) {
                        out += "</i>"
                        open = false
                    }
                    out.append(c)
                } else {
                    if italic != open {
                        out += italic ? "<i>" : "</i>"
                        open = italic
                    }
                    out.append(c)
                }
            }
        }
        if open { out += "</i>" }
        return repairedTags(out)
    }

    /// Is the next character that isn't a space in italics?
    private static func followingIsItalic(_ pieces: [Piece], after k: Int) -> Bool {
        for p in pieces[(k + 1)...] {
            if case .char(let c, let italic) = p, !c.isWhitespace { return italic }
        }
        return false
    }

    /// The words of the text as ranges of `pieces`: letters and digits, with an apostrophe
    /// between letters counting as part of the word (don't, l'homme). Hyphens split words.
    static func words(in pieces: [Piece]) -> [Range<Int>] {
        func isWordChar(_ i: Int) -> Bool {
            guard case .char(let c, _) = pieces[i] else { return false }
            return c.isLetter || c.isNumber
        }
        func isApostrophe(_ i: Int) -> Bool {
            guard case .char(let c, _) = pieces[i] else { return false }
            return c == "'" || c == "’"
        }
        var out: [Range<Int>] = []
        var i = 0
        while i < pieces.count {
            if isWordChar(i) {
                var j = i + 1
                while j < pieces.count {
                    if isWordChar(j) { j += 1; continue }
                    // Tags inside a word (<i>wor</i>d) don't end it.
                    if case .tag = pieces[j], j + 1 < pieces.count, isWordChar(j + 1) { j += 1; continue }
                    if isApostrophe(j), j + 1 < pieces.count, isWordChar(j + 1) { j += 1; continue }
                    break
                }
                out.append(i..<j)
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    /// The words with some letters in italics and some not.
    static func partItalicWords(_ pieces: [Piece]) -> [Range<Int>] {
        words(in: pieces).filter { r in
            var seen = Set<Bool>()
            for i in r {
                if case .char(let c, let italic) = pieces[i], c.isLetter || c.isNumber { seen.insert(italic) }
            }
            return seen.count > 1
        }
    }

    static func hasPartItalicWord(_ text: String) -> Bool {
        guard text.contains("<") else { return false }
        return !partItalicWords(pieces(text)).isEmpty
    }

    /// Every word that's partly in italics made wholly italic (`italic` true) or wholly plain.
    static func wholeWordItalics(_ text: String, italic: Bool) -> String {
        var p = pieces(text)
        let words = partItalicWords(p)
        guard !words.isEmpty else { return text }
        for r in words {
            for i in r { if case .char(let c, _) = p[i] { p[i] = .char(c, italic: italic) } }
        }
        return self.text(from: p)
    }
}
