import Foundation

/// Splits a title into lines the way subtitle style guides ask (Netflix Timed Text Style
/// Guide, BBC Subtitle Guidelines):
/// - keep it on one line when it fits the characters-per-line limit;
/// - otherwise break after punctuation, or before a conjunction or preposition;
/// - never leave an article, determiner, possessive, subject pronoun, auxiliary, negation
///   or preposition at the end of a line (it belongs with the word after it);
/// - keep first and last names together;
/// - when there's a choice, prefer a bottom-heavy pyramid (shorter line on top).
/// Languages without a word list still get punctuation and balance.
enum LineBreaker {

    /// Breaks `text` into at most `maxLines` lines of `maxChars`. Existing line breaks are
    /// thrown away, so call it only when re-breaking is wanted.
    static func breakLines(_ text: String, maxChars: Int, maxLines: Int, language: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard len(flat) > maxChars, maxLines > 1 else { return flat }

        // Two speakers ("- Hi. - Hello."): one line each.
        if flat.hasPrefix("-"), let r = flat.range(of: " -", options: [], range: flat.index(after: flat.startIndex)..<flat.endIndex) {
            let a = String(flat[..<r.lowerBound])
            let b = String(flat[flat.index(after: r.lowerBound)...])
            return a + "\n" + b
        }

        let words = flat.split(separator: " ").map(String.init)
        guard words.count > 1 else { return flat }
        let rules = Rules.for(language)
        return split(words, maxChars: maxChars, linesLeft: maxLines, rules: rules).joined(separator: "\n")
    }

    /// Splits off the best first line, then the rest recursively if it's still too long.
    private static func split(_ words: [String], maxChars: Int, linesLeft: Int, rules: Rules) -> [String] {
        let whole = words.joined(separator: " ")
        if len(whole) <= maxChars || linesLeft <= 1 || words.count < 2 { return [whole] }

        var best: (k: Int, score: Double)?
        for k in 1..<words.count {
            let top = words[..<k].joined(separator: " ")
            let bottom = words[k...].joined(separator: " ")
            let s = score(top: top, bottom: bottom, last: words[k - 1], next: words[k],
                          prev: k >= 2 ? words[k - 2] : nil, maxChars: maxChars,
                          linesLeft: linesLeft, rules: rules)
            if best == nil || s < best!.score { best = (k, s) }
        }
        let k = best!.k
        let top = words[..<k].joined(separator: " ")
        return [top] + split(Array(words[k...]), maxChars: maxChars, linesLeft: linesLeft - 1, rules: rules)
    }

    /// Lower is better.
    private static func score(top: String, bottom: String, last: String, next: String, prev: String?,
                              maxChars: Int, linesLeft: Int, rules: Rules) -> Double {
        var s = 0.0
        let t = Double(len(top)), b = Double(len(bottom))

        // Lines that don't fit are a last resort. When more lines are left, the bottom may
        // run long because it will be split again.
        if len(top) > maxChars { s += 1000 + (t - Double(maxChars)) * 20 }
        let bottomLimit = maxChars * max(1, linesLeft - 1)
        if len(bottom) > bottomLimit { s += 1000 + (b - Double(bottomLimit)) * 20 }

        // Balance, leaning bottom-heavy: a longer top line costs more than a longer bottom.
        if linesLeft == 2 {
            s += abs(t - b) * 0.6
            if t > b { s += (t - b) * 0.6 }
        } else {
            // More than two lines: fill the top line well.
            s += (Double(maxChars) - t) * 0.3
        }

        // Punctuation is the best place to break.
        if let c = Markup.plain(last).last {
            if ".!?…".contains(c) { s -= 30 }
            else if ",;:—–)\"”»".contains(c) { s -= 20 }
        }

        let lastKey = key(last), nextKey = key(next)
        if rules.breakBefore.contains(nextKey) { s -= 10 }
        if rules.keepWithNext.contains(lastKey) { s += 35 }

        // First and last names: two capitalised words in a row, the first not starting a sentence.
        if isCapitalised(last), isCapitalised(next), !endsSentence(prev), rules.casedScript {
            s += 20
        }
        return s
    }

    /// Length as the viewer sees it (formatting tags don't count).
    private static func len(_ s: String) -> Int { Markup.plain(s).count }

    private static func key(_ word: String) -> String {
        Markup.plain(word).lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    private static func isCapitalised(_ word: String) -> Bool {
        guard let f = Markup.plain(word).first(where: \.isLetter) else { return false }
        return f.isUppercase
    }

    private static func endsSentence(_ word: String?) -> Bool {
        guard let c = word.map(Markup.plain)?.last else { return true }   // first word of the title
        return ".!?…:".contains(c)
    }

    // MARK: Word lists

    struct Rules {
        /// A line may start with these (conjunctions, prepositions, relative words).
        var breakBefore: Set<String> = []
        /// These belong with the word after them, so a line shouldn't end with them.
        var keepWithNext: Set<String> = []
        /// Scripts with capital letters, where the name heuristic applies.
        var casedScript = true

        static func `for`(_ language: String) -> Rules {
            let base = language.lowercased().split(separator: "-").first.map(String.init) ?? language
            switch base {
            case "en": return english
            case "hr", "bs", "sr", "sh", "cnr": return croatian
            default: return Rules()
            }
        }

        static let english: Rules = {
            let conj: Set<String> = ["and", "but", "or", "nor", "so", "yet", "because", "although", "though",
                                     "while", "when", "where", "which", "who", "whom", "whose", "that", "if",
                                     "unless", "until", "since", "as", "than", "whether", "after", "before", "once"]
            let prep: Set<String> = ["about", "above", "across", "against", "along", "among", "around", "at",
                                     "behind", "below", "beneath", "beside", "between", "beyond", "by", "despite",
                                     "during", "except", "for", "from", "in", "inside", "into", "like", "near",
                                     "of", "off", "on", "onto", "outside", "over", "past", "through", "throughout",
                                     "to", "toward", "towards", "under", "underneath", "upon", "with", "within", "without"]
            let keep: Set<String> = ["a", "an", "the", "this", "these", "those", "my", "your", "his", "her", "its",
                                     "our", "their", "some", "any", "no", "every", "each", "i", "you", "he", "she",
                                     "we", "they", "am", "is", "are", "was", "were", "be", "been", "being", "have",
                                     "has", "had", "do", "does", "did", "will", "would", "shall", "should", "can",
                                     "could", "may", "might", "must", "not", "don't", "doesn't", "didn't", "won't",
                                     "wouldn't", "can't", "couldn't", "shouldn't", "isn't", "aren't", "wasn't",
                                     "weren't", "haven't", "hasn't", "hadn't", "i'm", "you're", "he's", "she's",
                                     "it's", "we're", "they're", "i'll", "you'll", "we'll", "they'll", "i've",
                                     "you've", "we've", "they've", "i'd", "you'd", "we'd", "they'd",
                                     "mr", "mrs", "ms", "dr", "very", "too", "more", "most"]
            return Rules(breakBefore: conj.union(prep), keepWithNext: keep.union(prep))
        }()

        static let croatian: Rules = {
            let conj: Set<String> = ["i", "a", "ali", "ili", "pa", "te", "no", "nego", "već", "jer", "da", "kad",
                                     "kada", "ako", "dok", "što", "šta", "koji", "koja", "koje", "kojeg", "kojem",
                                     "kako", "gdje", "čim", "iako", "premda", "ni", "niti", "jer", "zato", "dakle"]
            let prep: Set<String> = ["u", "na", "s", "sa", "za", "od", "do", "iz", "k", "ka", "o", "po", "pri",
                                     "prema", "kroz", "nad", "pod", "pred", "među", "bez", "kod", "oko", "protiv",
                                     "preko", "između", "iza", "ispod", "iznad", "uz", "radi", "zbog", "nakon",
                                     "prije", "poslije", "umjesto", "unatoč", "usprkos", "osim", "duž", "van"]
            let keep: Set<String> = ["ne", "se", "si", "sam", "je", "smo", "ste", "su", "bi", "bih", "bismo",
                                     "biste", "ću", "ćeš", "će", "ćemo", "ćete", "neću", "nećeš", "neće",
                                     "nisam", "nisi", "nije", "nismo", "niste", "nisu", "moj", "moja", "moje",
                                     "tvoj", "tvoja", "tvoje", "njegov", "njegova", "njezin", "njezina", "naš",
                                     "naša", "naše", "vaš", "vaša", "vaše", "njihov", "njihova", "taj", "ta",
                                     "ovaj", "ova", "ovo", "onaj", "ja", "ti", "mi", "vi", "jako", "vrlo", "baš"]
            return Rules(breakBefore: conj.union(prep), keepWithNext: keep.union(prep))
        }()
    }
}
