import Foundation
import NaturalLanguage

/// SRT and WebVTT reading and writing.
enum SubtitleFormats {

    enum FormatError: LocalizedError {
        case unreadable
        var errorDescription: String? { "The file's text encoding could not be read." }
    }

    // MARK: Reading

    /// A subtitle file's titles, without the adverts subtitle sites add (`withoutAds`).
    static func read(url: URL) throws -> [Subtitle] {
        let data = try Data(contentsOf: url)
        guard let text = decodeText(data) else { throw FormatError.unreadable }
        return withoutAds(parse(text))
    }

    /// Tries UTF-8 (with or without BOM), UTF-16 with BOM, then the legacy Windows encodings.
    /// Old subtitle files don't say which one they use, so it's worked out from the bytes and
    /// from the language of the words.
    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let s = String(data: data, encoding: .utf8) { return s }

        var high = 0, letters = 0, cyrillicMarks = 0
        for b in data {
            if b >= 0x80 {
                high += 1
                if b == 0xE0 || b == 0xFF { cyrillicMarks += 1 }
            } else if (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) {
                letters += 1
            }
        }
        // UTF-8 with a few damaged bytes (a stray symbol saved by another program): keep it
        // as UTF-8 rather than turn every accented letter into nonsense.
        let lossy = String(decoding: data, as: UTF8.self)
        let damaged = lossy.unicodeScalars.reduce(0) { $1 == "\u{FFFD}" ? $0 + 1 : $0 }
        if damaged * 20 < high { return lossy }

        // Mostly letters outside ASCII: Cyrillic or Greek (Cyrillic text is full of а and я,
        // bytes E0 and FF, which Greek text doesn't use), Arabic (Persian, Urdu), Hebrew or
        // Thai. The same bytes are letters in each, so each reading is checked: its language
        // against the code page it's written in, and whether it reads like real text.
        if high > letters {
            let cyrillicOrGreek = cyrillicMarks * 50 > high ? "windows-1251" : "windows-1253"
            var best: (text: String, score: Double)?
            for name in [cyrillicOrGreek, "windows-1256", "windows-1255", "windows-874"] {
                guard let codePage = encoding(named: name), let text = String(data: data, encoding: codePage) else { continue }
                let guess = languageGuess(text)
                let fits = guess.code.map { legacyEncoding(for: $0) == codePage } ?? false
                let score = (fits ? 1 : 0) + guess.confidence + plausibility(text)
                if best == nil || score > best!.score + 0.0001 { best = (text, score) }
            }
            return best?.text ?? String(data: data, encoding: .isoLatin1)
        }

        // Latin script. Central European (č ć đ), Western (è æ ð) and Turkish files use the
        // same bytes for different letters, so the language decides. The recogniser hears
        // Croatian even when č ć đ were read as è æ ð, so each reading is checked against the
        // encoding its language is written in, and the one that agrees wins.
        var best: (text: String, score: Double)?
        for encoding in [String.Encoding.windowsCP1250, .windowsCP1252, .windowsCP1254] {
            guard let text = String(data: data, encoding: encoding) else { continue }
            let guess = languageGuess(text)
            let fits = guess.code.map { legacyEncoding(for: $0) == encoding } ?? false
            let score = (fits ? 1 : 0) + guess.confidence
            if best == nil || score > best!.score + 0.0001 { best = (text, score) }
        }
        return best?.text ?? String(data: data, encoding: .isoLatin1)
    }

    /// How much a reading of a file looks like real text (0…1): its letters in one script,
    /// mostly small letters where the script has capitals (Arabic read as Cyrillic comes out
    /// half in capitals), and in Thai, mostly consonants (other scripts read as Thai come out
    /// as vowel and tone signs).
    static func plausibility(_ text: String) -> Double {
        var blocks: [UInt32: Int] = [:]
        var letters = 0, lower = 0, upper = 0, thaiConsonants = 0
        for s in text.unicodeScalars where s.properties.isAlphabetic {
            letters += 1
            blocks[s.value >> 8, default: 0] += 1
            if s.properties.isLowercase { lower += 1 } else if s.properties.isUppercase { upper += 1 }
            if (0x0E01...0x0E2E).contains(s.value) { thaiConsonants += 1 }
        }
        guard letters > 0, let top = blocks.max(by: { $0.value < $1.value }) else { return 0 }
        var p = Double(top.value) / Double(letters)
        let cased = lower + upper
        if cased * 4 > letters { p *= 0.5 + 0.5 * min(1, Double(lower) / Double(cased) / 0.7) }
        if top.key == 0x0E { p *= min(1, Double(thaiConsonants) / Double(top.value) / 0.4) }
        return p
    }

    /// The Windows encoding old files in a language were saved in.
    static func legacyEncoding(for language: String) -> String.Encoding {
        switch language {
        case "hr", "bs", "sr", "sr-Latn", "sl", "cs", "sk", "pl", "hu", "ro", "sq": return .windowsCP1250
        case "tr": return .windowsCP1254
        case "ru", "uk", "bg", "sr-Cyrl", "mk", "kk", "be", "mn": return .windowsCP1251
        case "el": return .windowsCP1253
        case "ar", "fa", "ur", "ps", "ckb": return encoding(named: "windows-1256") ?? .windowsCP1252
        case "he", "yi": return encoding(named: "windows-1255") ?? .windowsCP1252
        case "th": return encoding(named: "windows-874") ?? .windowsCP1252
        default: return .windowsCP1252
        }
    }

    /// Only the words of a subtitle file: no numbers, timecodes or tags.
    static func spokenText(_ raw: String) -> String {
        // "\r\n" is a single character in Swift, so the line endings are evened out first;
        // otherwise a Windows file would count as one long line.
        Markup.plain(raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
            .split(separator: "\n")
            .filter { line in !line.contains("-->") && !line.allSatisfy { $0.isNumber || $0.isWhitespace } }
            .joined(separator: " ")
    }

    /// The language of a file's words, and how sure the system's recogniser is of it. The
    /// words come from all through the file. Languages the recogniser mixes up or doesn't
    /// know (Serbian and Bulgarian, Persian and Urdu…) are told apart by their own letters
    /// (`LanguageGuess.byLetters`).
    static func languageGuess(_ decoded: String) -> (code: String?, confidence: Double) {
        let pieces = samplePieces(spokenText(String(decoded.prefix(600_000))))
        let words = pieces.joined(separator: " ")
        guard !words.trimmingCharacters(in: .whitespaces).isEmpty else { return (nil, 0) }
        let top = vote(pieces, among: nil)
        let confidence = top?.share ?? 0
        guard let letters = LanguageGuess.byLetters(words) else { return (top?.code, confidence) }
        if let code = letters.code { return (code, confidence) }
        // The script is known but its letters don't decide: the recogniser, among that
        // script's languages only.
        return (vote(pieces, among: letters.family)?.code ?? top?.code, confidence)
    }

    /// The recogniser's pick over all the pieces: each piece is read on its own (the
    /// recogniser goes by the start of what it's given, so one long string would be judged
    /// by its first piece) and their likelihoods are added up. `share`: the winner's average
    /// likelihood. `among`: language codes to choose from (nil: any).
    static func vote(_ pieces: [String], among: [String]?) -> (code: String, share: Double)? {
        var total: [String: Double] = [:]
        var counted = 0
        let recognizer = NLLanguageRecognizer()
        for piece in pieces where !piece.trimmingCharacters(in: .whitespaces).isEmpty {
            recognizer.reset()
            if let among { recognizer.languageConstraints = among.map { NLLanguage(rawValue: $0) } }
            recognizer.processString(piece)
            counted += 1
            for (language, p) in recognizer.languageHypotheses(withMaximum: 3) where language != .undetermined {
                total[language.rawValue, default: 0] += p
            }
        }
        guard counted > 0, let best = total.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })
        else { return nil }
        return (best.key, best.value / Double(counted))
    }

    /// Words from all through a file, not only its start (where the credits, a subtitler's
    /// ad or a song in another language often sit), as one string: see `samplePieces`.
    static func sample(_ spoken: String, limit: Int = 24_000) -> String {
        samplePieces(spoken, limit: limit).joined(separator: " ")
    }

    /// Up to a dozen stretches of `limit / 12` characters, spread evenly through the text
    /// (end to end when it's short). Web and mail addresses are left out.
    static func samplePieces(_ spoken: String, limit: Int = 24_000) -> [String] {
        let text = spoken.split(separator: " ").filter { word in
            !["www", "http", ".com", ".org", ".net", "@"].contains { word.lowercased().contains($0) }
        }.joined(separator: " ")
        let most = 12, piece = limit / most
        guard text.count > piece else { return [text] }
        let chars = Array(text)
        let count = min(most, (chars.count + piece - 1) / piece)
        return (0..<count).map { k in
            let start = (chars.count - piece) * k / (count - 1)
            return String(chars[start..<(start + piece)])
        }
    }

    /// Parses SRT and WebVTT (cue identifiers optional, `,` or `.` before milliseconds).
    static func parse(_ raw: String) -> [Subtitle] {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // A separator line holding only spaces or tabs still separates titles.
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.allSatisfy { $0 == " " || $0 == "\t" } ? "" : String($0) }
            .joined(separator: "\n")

        var result: [Subtitle] = []
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTime(parts[0]),
                  let end = parseTime(parts[1].trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ").first ?? "") else { continue }
            let body = lines[(timeIndex + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(Subtitle(start: start, end: max(end, start), text: body))
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Accepts HH:MM:SS,mmm, HH:MM:SS.mmm and MM:SS.mmm.
    static func parseTime(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let comps = t.split(separator: ":").map(String.init)
        guard (2...3).contains(comps.count) else { return nil }
        var seconds = 0.0
        for (i, c) in comps.enumerated() {
            guard let v = Double(c) else { return nil }
            let power = comps.count - 1 - i
            seconds += v * pow(60, Double(power))
        }
        return seconds
    }

    // MARK: Writing

    /// The titles as they go into a file: titles with no text are left out (an empty cue
    /// breaks some players), a blank line inside a title is closed up (it would end the cue
    /// early), and broken formatting tags are repaired (`TextChecks.repairedTags`).
    static func exportable(_ subs: [Subtitle]) -> [(Subtitle, String)] {
        subs.compactMap { s in
            let text = TextChecks.repairedTags(TextChecks.withoutBlankLines(s.text))
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !Markup.plain(lines.joined()).trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (s, lines.joined(separator: "\n"))
        }
    }

    static func srt(_ subs: [Subtitle]) -> String {
        var out = ""
        for (i, item) in exportable(subs).enumerated() {
            out += "\(i + 1)\n"
            out += "\(Timecode.srt(item.0.start)) --> \(Timecode.srt(item.0.end))\n"
            out += item.1 + "\n\n"
        }
        return out
    }

    /// Older code pages a language can be exported in (Language Options), for clients whose
    /// systems still need one. nil is UTF-8.
    struct LegacyEncoding: Identifiable, Sendable {
        let name: String
        let title: String
        var id: String { name }
    }

    static let legacyEncodings: [LegacyEncoding] = [
        LegacyEncoding(name: "windows-1250", title: "Windows-1250 · Central European (Croatian, Bosnian, Serbian Latin, Slovenian, Polish, Czech, Hungarian)"),
        LegacyEncoding(name: "windows-1251", title: "Windows-1251 · Cyrillic (Serbian, Macedonian, Bulgarian, Russian, Ukrainian)"),
        LegacyEncoding(name: "windows-1252", title: "Windows-1252 · Western European"),
        LegacyEncoding(name: "windows-1253", title: "Windows-1253 · Greek"),
        LegacyEncoding(name: "windows-1254", title: "Windows-1254 · Turkish"),
        LegacyEncoding(name: "windows-1255", title: "Windows-1255 · Hebrew"),
        LegacyEncoding(name: "windows-1256", title: "Windows-1256 · Arabic, Persian"),
        LegacyEncoding(name: "windows-1257", title: "Windows-1257 · Baltic"),
        LegacyEncoding(name: "windows-874", title: "Windows-874 · Thai")
    ]

    /// Core Foundation's numbers for the Windows code pages, in case a name isn't recognised.
    private static let windowsCodePages: [String: CFStringEncoding] = [
        "windows-1250": 0x0501, "windows-1251": 0x0502, "windows-1252": 0x0500, "windows-1253": 0x0503,
        "windows-1254": 0x0504, "windows-1255": 0x0505, "windows-1256": 0x0506, "windows-1257": 0x0507,
        "windows-874": 0x041D
    ]

    /// The encoding for a charset name such as "windows-1250".
    static func encoding(named name: String) -> String.Encoding? {
        var cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        if cf == kCFStringEncodingInvalidId, let known = windowsCodePages[name.lowercased()] { cf = known }
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// Right-to-left text: a right-to-left mark (U+200F) at both ends of every line, so a
    /// line keeps its direction in any player and punctuation shows on the correct side.
    /// Marks already there are replaced, never doubled.
    static func withDirectionMarks(_ text: String) -> String {
        let controls = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}")
        return text.components(separatedBy: "\n").map { line -> String in
            let bare = String(String.UnicodeScalarView(line.unicodeScalars.filter { !controls.contains($0) }))
                .trimmingCharacters(in: .whitespaces)
            return bare.isEmpty ? bare : "\u{200F}" + bare + "\u{200F}"
        }.joined(separator: "\n")
    }

    /// A file's bytes, as a language's export options ask: UTF-8 (optionally with a
    /// byte-order mark) or an older code page, and right-to-left marks. `lost` counts
    /// characters the code page (or EBU STL's character table) can't hold (written as "?").
    static func encoded(_ subs: [Subtitle], format: ExportFormat, bom: Bool, crlf: Bool,
                        encoding name: String? = nil, directionMarks: Bool = false,
                        context: ExportContext = ExportContext()) -> (data: Data, lost: Int) {
        let marked = directionMarks ? subs.map { s -> Subtitle in var s = s; s.text = withDirectionMarks(s.text); return s } : subs
        if format == .stl { return EBUSTL.file(marked, context: context) }
        // WebVTT and the XML formats are UTF-8 by definition: a code page never applies to them.
        guard format.allowsCodePage, let name, let enc = encoding(named: name), enc != .utf8 else {
            return (data(marked, format: format, bom: bom, crlf: crlf, context: context), 0)
        }
        var text = self.text(marked, format: format, context: context)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if crlf { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
        if let exact = text.data(using: enc) { return (exact, 0) }
        // Each different character is tried once, however long the file.
        let unknown = Set(text).filter { String($0).data(using: enc) == nil }
        let lost = text.filter { unknown.contains($0) }.count
        return (text.data(using: enc, allowLossyConversion: true) ?? Data(text.utf8), lost)
    }

    /// A file's bytes: UTF-8 (optionally with a byte-order mark; never for XML), CRLF or LF
    /// line endings. EBU STL is bytes of its own.
    static func data(_ subs: [Subtitle], format: ExportFormat, bom: Bool, crlf: Bool,
                     context: ExportContext = ExportContext()) -> Data {
        if format == .stl { return EBUSTL.file(subs, context: context).data }
        var text = self.text(subs, format: format, context: context)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if crlf { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
        var data = Data()
        if bom && !format.isXML { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(Data(text.utf8))
        return data
    }

    /// A text format's contents (EBU STL is bytes: see `EBUSTL`).
    static func text(_ subs: [Subtitle], format: ExportFormat, context: ExportContext = ExportContext()) -> String {
        switch format {
        case .srt: return srt(subs)
        case .vtt: return vtt(subs)
        case .ttml: return ttml(subs, context: context)
        case .dfxp: return dfxp(subs, context: context)
        case .itt: return itt(subs, context: context)
        case .ass: return ass(subs, context: context)
        case .ssa: return ssa(subs, context: context)
        case .sbv: return sbv(subs)
        case .txt: return plainText(subs)
        case .list: return dialogueList(subs, context: context)
        case .avid: return avid(subs, context: context)
        case .stl: return ""
        }
    }

    static func vtt(_ subs: [Subtitle]) -> String {
        var out = "WEBVTT\n\n"
        for (i, item) in exportable(subs).enumerated() {
            out += "\(i + 1)\n"
            out += "\(Timecode.vtt(item.0.start)) --> \(Timecode.vtt(item.0.end))\n"
            out += item.1 + "\n\n"
        }
        return out
    }
}

enum Timecode {
    private static func split(_ t: Double) -> (h: Int, m: Int, s: Int, ms: Int) {
        let totalMs = Int((max(0, t) * 1000).rounded())
        return (totalMs / 3_600_000, (totalMs / 60_000) % 60, (totalMs / 1000) % 60, totalMs % 1000)
    }

    /// 00:01:02,345
    static func srt(_ t: Double) -> String {
        let p = split(t)
        return String(format: "%02d:%02d:%02d,%03d", p.h, p.m, p.s, p.ms)
    }

    /// 00:01:02.345
    static func vtt(_ t: Double) -> String {
        let p = split(t)
        return String(format: "%02d:%02d:%02d.%03d", p.h, p.m, p.s, p.ms)
    }

    /// 00:01:02:08 (hours:minutes:seconds:frames)
    /// Counted in whole frames, the way a burnt-in timecode counts (non-drop-frame):
    /// at 23.976 or 29.97 fps the seconds are 24 or 30 frames long.
    static func frames(_ t: Double, fps: Double) -> String {
        let p = frameParts(t, fps: fps)
        return String(format: "%02d:%02d:%02d:%02d", p.h, p.m, p.s, p.f)
    }

    /// The hours, minutes, seconds and frames of `frames(_:fps:)`. Hours wrap at 24.
    static func frameParts(_ t: Double, fps: Double) -> (h: Int, m: Int, s: Int, f: Int) {
        let fps = max(1, fps)
        let nominal = max(1, Int(fps.rounded()))
        // The small allowance keeps a time that sits exactly on a frame from showing the
        // frame before it (13.28 s × 25 is 331.99999999999994 in floating point).
        let totalFrames = Int((max(0, t) * fps + 0.0005).rounded(.down))
        let secs = totalFrames / nominal
        return ((secs / 3600) % 24, (secs / 60) % 60, secs % 60, totalFrames % nominal)
    }

    /// The time of a frame timecode: the opposite of `frames`.
    static func seconds(hours: Double, minutes: Double, seconds: Double, frames: Double, fps: Double) -> Double {
        let fps = max(1, fps)
        let nominal = Double(max(1, Int(fps.rounded())))
        return ((hours * 3600 + minutes * 60 + seconds) * nominal + frames) / fps
    }

    /// Short form for the ruler: 1:02 or 1:02.5
    static func ruler(_ t: Double, showTenths: Bool) -> String {
        let secs = Int(t)
        let base = secs >= 3600
            ? String(format: "%d:%02d:%02d", secs / 3600, (secs / 60) % 60, secs % 60)
            : String(format: "%d:%02d", secs / 60, secs % 60)
        if showTenths {
            let tenths = Int(((t - Double(secs)) * 10).rounded(.down))
            return base + ".\(tenths)"
        }
        return base
    }
}
