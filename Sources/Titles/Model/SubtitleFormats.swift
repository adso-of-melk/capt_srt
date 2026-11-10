import Foundation
import NaturalLanguage

/// SRT and WebVTT reading and writing.
enum SubtitleFormats {

    enum FormatError: LocalizedError {
        case unreadable
        var errorDescription: String? { "The file's text encoding could not be read." }
    }

    // MARK: Reading

    static func read(url: URL) throws -> [Subtitle] {
        let data = try Data(contentsOf: url)
        guard let text = decodeText(data) else { throw FormatError.unreadable }
        return parse(text)
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

        // Mostly letters outside ASCII: Cyrillic or Greek. Cyrillic text is full of а and я
        // (bytes E0 and FF), which Greek text doesn't use.
        if high > letters {
            let encoding: String.Encoding = cyrillicMarks * 50 > high ? .windowsCP1251 : .windowsCP1253
            return String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1)
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

    /// The Windows encoding old files in a language were saved in.
    static func legacyEncoding(for language: String) -> String.Encoding {
        switch language {
        case "hr", "bs", "sr", "sl", "cs", "sk", "pl", "hu", "ro", "sq": return .windowsCP1250
        case "tr": return .windowsCP1254
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

    /// The language the system's recogniser hears in a file's words, and how sure it is.
    static func languageGuess(_ decoded: String) -> (code: String?, confidence: Double) {
        let words = String(spokenText(String(decoded.prefix(40_000))).prefix(12_000))
        guard !words.trimmingCharacters(in: .whitespaces).isEmpty else { return (nil, 0) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(words)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).first,
              top.key != .undetermined else { return (nil, 0) }
        return (top.key.rawValue, top.value)
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
    /// breaks some players), and a blank line inside a title is closed up (it would end the
    /// cue early).
    static func exportable(_ subs: [Subtitle]) -> [(Subtitle, String)] {
        subs.compactMap { s in
            let lines = s.text.split(separator: "\n", omittingEmptySubsequences: true)
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

    /// A file's bytes: UTF-8 (optionally with a byte-order mark), CRLF or LF line endings.
    static func data(_ subs: [Subtitle], format: ExportFormat, bom: Bool, crlf: Bool) -> Data {
        var text = format == .srt ? srt(subs) : vtt(subs)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if crlf { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
        var data = Data()
        if bom { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(Data(text.utf8))
        return data
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
        let fps = max(1, fps)
        let nominal = max(1, Int(fps.rounded()))
        // The small allowance keeps a time that sits exactly on a frame from showing the
        // frame before it (13.28 s × 25 is 331.99999999999994 in floating point).
        let totalFrames = Int((max(0, t) * fps + 0.0005).rounded(.down))
        let f = totalFrames % nominal
        let secs = totalFrames / nominal
        return String(format: "%02d:%02d:%02d:%02d", secs / 3600, (secs / 60) % 60, secs % 60, f)
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
