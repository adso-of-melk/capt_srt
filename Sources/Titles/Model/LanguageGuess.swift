import Foundation

/// Guesses which language a subtitle file is in: from the end of its name first (Film.en.srt,
/// Film_HR.srt, Film ENG.srt, Film croatian.srt), otherwise from its text. A language word
/// elsewhere in the name is only a last resort, because it's usually part of the film's
/// title ("The English Patient", "The Rum Diary").
enum LanguageGuess {
    private static let threeLetter: [String: String] = [
        "eng": "en", "hrv": "hr", "cro": "hr", "srp": "sr-Latn", "scc": "sr-Latn", "bos": "bs",
        "slv": "sl", "slo": "sl", "mkd": "mk", "mac": "mk", "alb": "sq", "sqi": "sq",
        "ger": "de", "deu": "de", "fre": "fr", "fra": "fr", "ita": "it", "spa": "es", "esp": "es",
        "por": "pt-PT", "nld": "nl", "dut": "nl", "swe": "sv", "dan": "da", "nor": "nb", "fin": "fi",
        "pol": "pl", "cze": "cs", "ces": "cs", "slk": "sk", "hun": "hu", "rum": "ro", "ron": "ro",
        "bul": "bg", "gre": "el", "ell": "el", "tur": "tr", "rus": "ru", "ukr": "uk", "ara": "ar",
        "heb": "he", "jpn": "ja", "kor": "ko", "chi": "zh-Hans", "zho": "zh-Hans"
    ]
    private static let names: [String: String] = [
        "english": "en", "engleski": "en", "croatian": "hr", "hrvatski": "hr", "serbian": "sr-Latn",
        "srpski": "sr-Latn", "bosnian": "bs", "bosanski": "bs", "slovenian": "sl", "slovenski": "sl",
        "german": "de", "deutsch": "de", "njemacki": "de", "french": "fr", "francais": "fr",
        "italian": "it", "italiano": "it", "spanish": "es", "espanol": "es", "portuguese": "pt-PT",
        "dutch": "nl", "polish": "pl", "czech": "cs", "hungarian": "hu", "russian": "ru"
    ]

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
}
