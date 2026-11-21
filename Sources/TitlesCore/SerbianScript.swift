import Foundation

/// Serbian in either of its alphabets (Language Options ▸ Convert to Latin / Cyrillic).
/// Cyrillic to Latin is letter for letter. Latin to Cyrillic reads lj, nj and dž as one
/// letter (љ, њ, џ) except in the few words where they are two (injekcija, nadživeti).
/// Formatting tags are left alone, and so are words with q, w, x or y (Wi-Fi, New York)
/// and Roman numerals (II, XIV).
enum SerbianScript {
    enum Script: Sendable { case latin, cyrillic }

    /// The alphabet most of the letters are in (nil: no Serbian letters at all).
    static func dominant(in texts: [String]) -> Script? {
        var cyrillic = 0, latin = 0
        for text in texts {
            for scalar in Markup.plain(text).unicodeScalars {
                if (0x0400...0x04FF).contains(scalar.value) { cyrillic += 1 }
                else if CharacterSet.letters.contains(scalar), scalar.value < 0x0250 { latin += 1 }
            }
        }
        if cyrillic == 0 && latin == 0 { return nil }
        return cyrillic > latin ? .cyrillic : .latin
    }

    /// The language code for the other alphabet: sr-Cyrl ↔ sr-Latn (sr is Cyrillic).
    static func code(_ code: String, for script: Script) -> String {
        let parts = code.split(separator: "-").map(String.init)
        guard let base = parts.first else { return code }
        let rest = parts.dropFirst().filter { !["latn", "cyrl"].contains($0.lowercased()) }
        return ([base, script == .latin ? "Latn" : "Cyrl"] + rest).joined(separator: "-")
    }

    /// The languages written in both alphabets.
    static func applies(to code: String) -> Bool {
        let base = code.split(separator: "-").first.map { $0.lowercased() } ?? ""
        return ["sr", "bs", "cnr", "sh"].contains(base)
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"<[^>]*>|\{[^}]*\}"#)

    static func convert(_ text: String, to script: Script) -> String {
        // Tags ({\an8}, <i>) stay as they are; the text between them is converted.
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += convertPlain(ns.substring(with: NSRange(location: last, length: m.range.location - last)), to: script)
            out += ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += convertPlain(ns.substring(from: last), to: script)
        return out
    }

    // MARK: Words

    /// A word runs on through a hyphen, apostrophe, dot or slash between two letters or
    /// digits, so Wi-Fi and www.rts.rs are judged (and left alone) as a whole.
    private static func convertPlain(_ text: String, to script: Script) -> String {
        let chars = Array(text)
        var out = ""
        var word = ""
        func flush() {
            if !word.isEmpty { out += script == .latin ? toLatin(word) : toCyrillic(word) }
            word = ""
        }
        func isWordPart(_ ch: Character) -> Bool {
            ch.isLetter || ch.isNumber || ch.unicodeScalars.contains(where: { (0x0300...0x036F).contains($0.value) })
        }
        for (i, ch) in chars.enumerated() {
            if isWordPart(ch) {
                word.append(ch)
            } else if !word.isEmpty, "-'’./@:".contains(ch), i + 1 < chars.count, isWordPart(chars[i + 1]) {
                word.append(ch)
            } else {
                flush()
                out.append(ch)
            }
        }
        flush()
        return out
    }

    private static let latinOf: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ђ": "đ", "е": "e", "ж": "ž", "з": "z",
        "и": "i", "ј": "j", "к": "k", "л": "l", "љ": "lj", "м": "m", "н": "n", "њ": "nj", "о": "o",
        "п": "p", "р": "r", "с": "s", "т": "t", "ћ": "ć", "у": "u", "ф": "f", "х": "h", "ц": "c",
        "ч": "č", "џ": "dž", "ш": "š",
    ]

    private static func toLatin(_ word: String) -> String {
        let chars = Array(word)
        // A word in capitals keeps its digraphs in capitals: ЉУБАВ → LJUBAV, but Љубав → Ljubav.
        let allCaps = chars.filter(\.isLetter).count > 1 && !chars.contains(where: \.isLowercase)
        var out = ""
        for (i, ch) in chars.enumerated() {
            let lower = ch.lowercased()
            guard lower.count == 1, let latin = latinOf[Character(lower)] else { out.append(ch); continue }
            if ch.isUppercase {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if latin.count > 1 && !(allCaps || next?.isUppercase == true) {
                    out += latin.prefix(1).uppercased() + latin.dropFirst()
                } else {
                    out += latin.uppercased()
                }
            } else {
                out += latin
            }
        }
        return out
    }

    private static let cyrillicOf: [String: String] = [
        "a": "а", "b": "б", "c": "ц", "č": "ч", "ć": "ћ", "d": "д", "đ": "ђ", "e": "е", "f": "ф",
        "g": "г", "h": "х", "i": "и", "j": "ј", "k": "к", "l": "л", "m": "м", "n": "н", "o": "о",
        "p": "п", "r": "р", "s": "с", "š": "ш", "t": "т", "u": "у", "v": "в", "z": "з", "ž": "ж",
        "lj": "љ", "nj": "њ", "dž": "џ",
        // The one-character digraphs some keyboards and old files use.
        "ǆ": "џ", "ǅ": "џ", "Ǆ": "џ", "ǉ": "љ", "ǈ": "љ", "Ǉ": "љ", "ǌ": "њ", "ǋ": "њ", "Ǌ": "њ",
    ]

    /// Where lj, nj or dž are two letters, not one: prefixes before ž (nad-, pod-, od-) and
    /// borrowed words with n + j. Matched at the start of the word (lower case).
    private static let splitDigraphStarts = [
        "nadž", "podž", "predž", "odžal", "odživ", "odžub", "odžmur",
        "injek", "injun", "konjug", "konjunk", "konjekt", "vanjez", "vanjug", "tanjug",
    ]
    private static let splitDigraphInside = ["injekc", "konjug", "konjunk"]

    private static func toCyrillic(_ word: String) -> String {
        let lowerWord = word.lowercased()
        // Foreign words and Roman numerals stay in Latin letters.
        if lowerWord.contains(where: { "qwxy".contains($0) }) { return word }
        if word.count >= 2, word.allSatisfy({ "IVX".contains($0) }), word != "VI" { return word }
        // Already Cyrillic (or another script): nothing to do.
        guard word.unicodeScalars.contains(where: { $0.value < 0x0250 && CharacterSet.letters.contains($0) }) else { return word }

        let noDigraphs = splitDigraphStarts.contains(where: { lowerWord.hasPrefix($0) })
            || splitDigraphInside.contains(where: { lowerWord.contains($0) })
        // Precomposed letters only (č, not c + combining caron).
        let chars = Array(word.precomposedStringWithCanonicalMapping)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let lower = String(ch).lowercased()
            if !noDigraphs, i + 1 < chars.count {
                let pair = lower + String(chars[i + 1]).lowercased()
                if ["lj", "nj", "dž"].contains(pair), let c = cyrillicOf[pair] {
                    out += ch.isUppercase ? c.uppercased() : c
                    i += 2
                    continue
                }
            }
            if let c = cyrillicOf[lower] ?? cyrillicOf[String(ch)] {
                let upper = ch.isUppercase || "ǄǅǇǈǊǋ".contains(ch)
                out += upper ? c.uppercased() : c
            } else {
                out.append(ch)
            }
            i += 1
        }
        return out
    }
}
