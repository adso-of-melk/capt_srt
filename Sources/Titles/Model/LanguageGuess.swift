import Foundation
import NaturalLanguage

/// Guesses which language a subtitle file is in: from the end of its name first (Film.en.srt,
/// Film_HR.srt, Film ENG.srt, Film croatian.srt), otherwise from its text. A language word
/// elsewhere in the name is only a last resort, because it's usually part of the film's
/// title ("The English Patient", "The Rum Diary").
enum LanguageGuess {
    static let threeLetter: [String: String] = [
        "eng": "en", "hrv": "hr", "cro": "hr", "srp": "sr-Latn", "scc": "sr-Latn", "bos": "bs",
        "slv": "sl", "slo": "sl", "mkd": "mk", "mac": "mk", "alb": "sq", "sqi": "sq",
        "ger": "de", "deu": "de", "fre": "fr", "fra": "fr", "ita": "it", "spa": "es", "esp": "es",
        "por": "pt-PT", "nld": "nl", "dut": "nl", "swe": "sv", "dan": "da", "nor": "nb", "fin": "fi",
        "pol": "pl", "cze": "cs", "ces": "cs", "slk": "sk", "hun": "hu", "rum": "ro", "ron": "ro",
        "bul": "bg", "gre": "el", "ell": "el", "tur": "tr", "rus": "ru", "ukr": "uk", "ara": "ar",
        "heb": "he", "jpn": "ja", "kor": "ko", "chi": "zh-Hans", "zho": "zh-Hans"
    ]
    static let names: [String: String] = [
        "english": "en", "engleski": "en", "croatian": "hr", "hrvatski": "hr", "serbian": "sr-Latn",
        "srpski": "sr-Latn", "bosnian": "bs", "bosanski": "bs", "slovenian": "sl", "slovenski": "sl",
        "german": "de", "deutsch": "de", "njemacki": "de", "french": "fr", "francais": "fr",
        "italian": "it", "italiano": "it", "spanish": "es", "espanol": "es", "portuguese": "pt-PT",
        "dutch": "nl", "polish": "pl", "czech": "cs", "hungarian": "hu", "russian": "ru"
    ]

    /// A word of a file name that names a language: a three-letter code or a language's name
    /// ("eng", "croatian", "hrvatski"), lower case and without accents.
    static func isLanguageWord(_ word: String) -> Bool {
        threeLetter[word] != nil || names[word] != nil
    }

    static func language(of url: URL) -> Language? {
        let name = url.deletingPathExtension().lastPathComponent
        return fromName(name, lastWordOnly: true) ?? fromText(url) ?? fromName(name)
    }

    /// `lastWordOnly`: only the last word of the name counts (where a language is normally put).
    static func fromName(_ name: String, lastWordOnly: Bool = false) -> Language? {
        let tokens = name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split { !$0.isLetter }
            .map(String.init)
        guard !tokens.isEmpty else { return nil }
        let codes = Set(Language.common.map { $0.code.lowercased() })
        // A code with a region at the end: "Film.pt-BR", "Film_sr-Latn".
        if tokens.count >= 2 {
            let joined = tokens[tokens.count - 2] + "-" + tokens[tokens.count - 1]
            if codes.contains(joined) { return Language.named(joined) }
        }
        // Last word first ("Film.hr", "Film_EN"). A two-letter code only counts there, and
        // only when it's set apart by a dot, dash or underscore or written in capitals, so
        // a title like "What Is It" isn't taken for Italian.
        if let last = tokens.last {
            if last.count == 2, codes.contains(last) {
                let core = String(name.reversed().drop(while: { !$0.isLetter }).reversed())
                let tail = String(core.suffix(2))
                let before = core.dropLast(2).last
                let setApart = before.map { "._-([".contains($0) } ?? true
                let capitals = tail == tail.uppercased() && !(before?.isLetter ?? false)
                if setApart || capitals { return Language.named(last) }
            }
            if let code = threeLetter[last] ?? names[last] { return Language.named(code) }
        }
        if lastWordOnly { return nil }
        for token in tokens.reversed() {
            if let code = threeLetter[token] ?? names[token] { return Language.named(code) }
        }
        return nil
    }

    /// Reads the file's words and asks the system's language recogniser.
    static func fromText(_ url: URL) -> Language? {
        guard !ProjectStore.isDataless(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Subtitle files are small: a couple of megabytes covers any of them.
        guard let data = try? handle.read(upToCount: 2_000_000), !data.isEmpty,
              let raw = SubtitleFormats.decodeText(data),
              let found = SubtitleFormats.languageGuess(raw).code else { return nil }
        switch found {
        case "sr": return Language.named("sr-Latn")
        case "pt": return Language.named("pt-PT")
        case "no", "nb": return Language.named("nb")
        default: return Language.named(found)
        }
    }

    // MARK: Letters

    /// What a text's letters say: `code` when a letter only that language uses decides it,
    /// and `family`, the languages written in that script (for the recogniser to choose
    /// among when the letters don't decide).
    struct LetterVerdict: Equatable {
        var code: String?
        var family: [String]
    }

    /// Languages the system's recogniser mixes up or doesn't know, told apart by letters only
    /// they use. It has no Serbian or Macedonian (it hears Bulgarian or Kazakh), and often hears
    /// Persian as Urdu or Arabic. Nil when the text isn't mostly Cyrillic, Arabic or Hebrew.
    static func byLetters(_ text: String) -> LetterVerdict? {
        var cyrillic = 0, arabic = 0, hebrew = 0, all = 0
        var count: [UInt32: Int] = [:]
        for scalar in text.lowercased().unicodeScalars where scalar.properties.isAlphabetic {
            all += 1
            switch scalar.value {
            case 0x0400...0x04FF:
                cyrillic += 1
                count[scalar.value, default: 0] += 1
            case 0x0600...0x06FF, 0x0750...0x077F:
                arabic += 1
                count[scalar.value, default: 0] += 1
            case 0x0590...0x05FF:
                hebrew += 1
            default:
                break
            }
        }
        guard all > 0 else { return nil }
        /// How often these letters come, among the script's letters.
        func share(_ letters: String, of total: Int) -> Double {
            Double(letters.unicodeScalars.reduce(0) { $0 + (count[$1.value] ?? 0) }) / Double(max(1, total))
        }
        if cyrillic * 2 > all {
            let family = ["ru", "uk", "bg", "kk", "be", "mn"]
            func verdict(_ code: String?) -> LetterVerdict { LetterVerdict(code: code, family: family) }
            // ј љ њ џ: Serbian and Macedonian only (ђ ћ Serbian, ѓ ќ ѕ Macedonian).
            if share("ђћјљњџ", of: cyrillic) > 0.005 {
                return verdict(share("ѓќѕ", of: cyrillic) > share("ђћ", of: cyrillic) ? "mk" : "sr-Cyrl")
            }
            if share("әғқңұһ", of: cyrillic) > 0.005 { return verdict("kk") }
            if share("өү", of: cyrillic) > 0.005 { return verdict("mn") }
            if share("ў", of: cyrillic) > 0.002 { return verdict("be") }
            if share("їєґ", of: cyrillic) > 0.002 || (share("і", of: cyrillic) > 0.01 && share("ыэ", of: cyrillic) == 0) {
                return verdict("uk")
            }
            if share("ыэ", of: cyrillic) > 0.003 { return verdict("ru") }
            // ъ is everywhere in Bulgarian, rare in Russian.
            if share("ъ", of: cyrillic) > 0.005 { return verdict("bg") }
            return verdict(nil)
        }
        if arabic * 2 > all {
            let family = ["ar", "fa", "ur"]
            func verdict(_ code: String?) -> LetterVerdict { LetterVerdict(code: code, family: family) }
            // ٹ ڈ ڑ ں ے: Urdu. ټ ډ ړ ښ ږ: Pashto. ڕ ڵ ۆ ێ: Sorani Kurdish. پ چ ژ گ: Persian
            // (and the others above, checked first); Arabic has none of them.
            if share("ٹڈڑںے", of: arabic) > 0.005 { return verdict("ur") }
            if share("ټډړښږ", of: arabic) > 0.005 { return verdict("ps") }
            if share("ڕڵۆێ", of: arabic) > 0.005 { return verdict("ckb") }
            if share("پچژگ", of: arabic) > 0.005 { return verdict("fa") }
            // Persian's own ی and ک against Arabic's ي ك ة ى.
            return verdict(share("یک", of: arabic) > share("يكةى", of: arabic) ? "fa" : "ar")
        }
        if hebrew * 2 > all { return LetterVerdict(code: "he", family: ["he"]) }
        return nil
    }
}
