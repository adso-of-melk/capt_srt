import AppKit
import NaturalLanguage
import CHunspell

/// A Hunspell dictionary (.aff + .dic), the format LibreOffice, Firefox and Chrome use.
final class HunspellDictionary {
    private let handle: OpaquePointer
    /// The dictionary's own character set (most are UTF-8; some older ones aren't).
    let encoding: String.Encoding

    init?(aff: URL, dic: URL) {
        guard FileManager.default.fileExists(atPath: aff.path), FileManager.default.fileExists(atPath: dic.path),
              let h = Hunspell_create(aff.path, dic.path) else { return nil }
        handle = h
        encoding = Hunspell_get_dic_encoding(h).map { Self.encoding(named: String(cString: $0)) } ?? .utf8
    }

    /// A dictionary's SET line as a text encoding. Hunspell writes some names its own way
    /// (ISO8859-2, microsoft-cp1251, TIS620-2533).
    static func encoding(named raw: String) -> String.Encoding {
        var name = raw.trimmingCharacters(in: .whitespaces)
        let lower = name.lowercased()
        if lower.hasPrefix("iso8859") { name = "ISO-8859" + name.dropFirst(7) }
        else if lower.hasPrefix("microsoft-cp") { name = "windows-" + name.dropFirst(12) }
        else if lower.hasPrefix("tis620") { name = "TIS-620" }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    deinit { Hunspell_destroy(handle) }

    func isCorrect(_ word: String) -> Bool {
        // A word the dictionary's character set can't even write isn't in it.
        guard let c = word.cString(using: encoding) else { return false }
        return Hunspell_spell(handle, c) != 0
    }

    func suggestions(for word: String) -> [String] {
        guard let c = word.cString(using: encoding) else { return [] }
        var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        let n = Hunspell_suggest(handle, &list, c)
        defer { if n > 0 { Hunspell_free_list(handle, &list, n) } }
        guard n > 0, let list else { return [] }
        return (0..<Int(n)).compactMap { i in list[i].flatMap { String(cString: $0, encoding: encoding) } }
    }
}

/// Spell checking per language. The Mac's own checker where it knows the language (Polish,
/// Portuguese, German and about 40 more); otherwise a Hunspell dictionary from the
/// Dictionaries folder (Croatian, Serbian, Bosnian, Persian, Thai…). Japanese and Chinese
/// have no word-level spell check.
@MainActor
final class SpellService {
    static let shared = SpellService()

    enum Engine {
        case system(String)
        case hunspell(HunspellDictionary)
    }

    /// False in the automated tests: learned words are never written to the Mac.
    var persists = true
    /// Bumped whenever a dictionary or word list changes, so views check again.
    private(set) var version = 0
    /// The film's own words (names, places), per language. Saved in the project.
    var projectWords: [String: Set<String>] = [:] { didSet { changed() } }
    private var personal: [String: Set<String>] = [:]
    private var engines: [String: Engine?] = [:]
    private var cache: [String: [NSRange]] = [:]
    /// Extra folders to look for dictionaries in first (the tests use this).
    var extraFolders: [URL] = []

    /// ~/Library/Application Support/KPTN.SUB/Dictionaries — put hr.aff and hr.dic there, and so on.
    static var dictionariesFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KPTN.SUB/Dictionaries", isDirectory: true)
    }

    /// Dictionaries that came inside the app (a packaged test build).
    static var bundledFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Dictionaries", isDirectory: true)
    }

    static var wordsFolder: URL {
        dictionariesFolder.deletingLastPathComponent().appendingPathComponent("Words", isDirectory: true)
    }

    /// File names tried for a language, most specific first: sr-Latn, then sr for sr-Cyrl.
    static func dictionaryNames(for code: String) -> [String] {
        let parts = code.split(separator: "-").map(String.init)
        var names = [code, code.replacingOccurrences(of: "-", with: "_")]
        if let base = parts.first, parts.count > 1 {
            let sub = parts[1].lowercased()
            // A script other than Cyrillic must not fall back to a Cyrillic "sr" (or the like).
            if sub != "latn" { names.append(base) }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// The macOS checker's name for a language, if it has one.
    static func systemLanguage(for code: String) -> String? {
        let available = Set(NSSpellChecker.shared.availableLanguages)
        let parts = code.split(separator: "-").map(String.init)
        var candidates = [code.replacingOccurrences(of: "-", with: "_")]
        if let base = parts.first, parts.count > 1 {
            let sub = parts[1]
            // Script subtags (Latn, Cyrl, Hans…) mean a different alphabet: no fallback.
            if sub.count != 4 { candidates.append(base) }
        }
        return candidates.first { available.contains($0) }
    }

    func engine(for code: String) -> Engine? {
        if let known = engines[code] { return known }
        var found: Engine?
        let folders = extraFolders + [Self.dictionariesFolder] + [Self.bundledFolder].compactMap { $0 }
        search: for folder in folders {
            for name in Self.dictionaryNames(for: code) {
                if let d = HunspellDictionary(aff: folder.appendingPathComponent(name + ".aff"),
                                              dic: folder.appendingPathComponent(name + ".dic")) {
                    found = .hunspell(d)
                    break search
                }
            }
        }
        if found == nil, let lang = Self.systemLanguage(for: code) { found = .system(lang) }
        engines[code] = found
        return found
    }

    func hasDictionary(for code: String) -> Bool { engine(for: code) != nil }

    /// Forget what was found, so new files in the Dictionaries folder (and changed word
    /// lists) are picked up.
    func reloadDictionaries() {
        engines.removeAll()
        personal.removeAll()
        changed()
    }

    private func changed() {
        cache.removeAll()
        version += 1
    }

    // MARK: Checking

    /// The words of `text` that aren't spelled right, as ranges in it. Formatting tags in the
    /// text ({\an8}, <font …>) are skipped, and so are words with digits in them.
    func misspelled(in text: String, language code: String) -> [NSRange] {
        guard !text.isEmpty, let engine = engine(for: code) else { return [] }
        let key = code + "\u{1}" + text
        if let hit = cache[key] { return hit }
        let ns = text as NSString
        let tags = Markup.tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        var out: [NSRange] = []
        for r in Self.words(in: text, language: code) {
            if tags.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
            let word = ns.substring(with: r)
            if word.rangeOfCharacter(from: .decimalDigits) != nil { continue }
            if !isCorrect(word, language: code, engine: engine) { out.append(r) }
        }
        if cache.count > 4000 { cache.removeAll() }
        cache[key] = out
        return out
    }

    /// The words of a text, split the way the language splits them (Thai and Japanese
    /// have no spaces between words).
    static func words(in text: String, language code: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if let base = code.split(separator: "-").first {
            tokenizer.setLanguage(NLLanguage(rawValue: String(base)))
        }
        var out: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let r = NSRange(range, in: text)
            let word = (text as NSString).substring(with: r)
            if word.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) { out.append(r) }
            return true
        }
        return out
    }

    func isCorrect(_ word: String, language code: String) -> Bool {
        guard let engine = engine(for: code) else { return true }
        return isCorrect(word, language: code, engine: engine)
    }

    private func isCorrect(_ word: String, language code: String, engine: Engine) -> Bool {
        if known(word, language: code) { return true }
        // A word written with a typographic apostrophe is checked as typed and with a plain one.
        let variants = word.contains("’") ? [word, word.replacingOccurrences(of: "’", with: "'")] : [word]
        for w in variants {
            switch engine {
            case let .hunspell(d):
                if d.isCorrect(w) { return true }
            case let .system(lang):
                let r = NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false,
                                                            inSpellDocumentWithTag: 0, wordCount: nil)
                if r.location == NSNotFound { return true }
            }
        }
        return false
    }

    func suggestions(for word: String, language code: String) -> [String] {
        guard let engine = engine(for: code) else { return [] }
        switch engine {
        case let .hunspell(d):
            return d.suggestions(for: word)
        case let .system(lang):
            return NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length),
                                                 in: word, language: lang, inSpellDocumentWithTag: 0) ?? []
        }
    }

    // MARK: Word lists

    private func known(_ word: String, language code: String) -> Bool {
        let lists = [personalWords(code), projectWords[code] ?? []]
        return lists.contains { $0.contains(word) || $0.contains(word.lowercased()) }
    }

    private func personalWords(_ code: String) -> Set<String> {
        if let words = personal[code] { return words }
        var words = Set<String>()
        if persists, let text = try? String(contentsOf: Self.wordsFolder.appendingPathComponent(code + ".txt"), encoding: .utf8) {
            words = Set(text.split(whereSeparator: \.isNewline).map(String.init))
        }
        personal[code] = words
        return words
    }

    /// Learn Spelling: the word is right in every project, from now on.
    func learn(_ word: String, language code: String) {
        var words = personalWords(code)
        words.insert(word)
        personal[code] = words
        changed()
        guard persists else { return }
        let folder = Self.wordsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? words.sorted().joined(separator: "\n").write(to: folder.appendingPathComponent(code + ".txt"),
                                                         atomically: true, encoding: .utf8)
    }
}
