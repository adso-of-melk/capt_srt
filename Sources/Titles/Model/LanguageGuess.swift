import Foundation
import NaturalLanguage

/// Guesses which language a subtitle file is in: from its name first (Film.en.srt,
/// Film_HR.srt, Film ENG.srt, Film croatian.srt), otherwise from its text.
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
        fromName(url.deletingPathExtension().lastPathComponent) ?? fromText(url)
    }

    static func fromName(_ name: String) -> Language? {
        let tokens = name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split { !$0.isLetter }
            .map(String.init)
        guard !tokens.isEmpty else { return nil }
        let twoLetter = Set(Language.common.map { $0.code.lowercased() })
        // Last word first ("Film.hr", "Film_EN"); a two-letter code only counts there, so
        // ordinary words like "it" or "no" earlier in a name aren't taken for languages.
        if let last = tokens.last {
            if twoLetter.contains(last) { return Language.named(last) }
            if let code = threeLetter[last] ?? names[last] { return Language.named(code) }
        }
        for token in tokens.reversed() {
            if let code = threeLetter[token] ?? names[token] { return Language.named(code) }
        }
        return nil
    }

    /// Reads the start of the file and asks the system's language recogniser.
    static func fromText(_ url: URL) -> Language? {
        guard !ProjectStore.isDataless(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 12_000), !data.isEmpty else { return nil }
        let raw = String(decoding: data, as: UTF8.self)
        // Only the words: no numbers, timecodes or arrows.
        let text = Markup.plain(raw)
            .split(separator: "\n")
            .filter { line in !line.contains("-->") && !line.allSatisfy { $0.isNumber || $0.isWhitespace } }
            .joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let found = recognizer.dominantLanguage, found != .undetermined else { return nil }
        switch found.rawValue {
        case "sr": return Language.named("sr-Latn")
        case "pt": return Language.named("pt-PT")
        case "no", "nb": return Language.named("nb")
        default: return Language.named(found.rawValue)
        }
    }
}
