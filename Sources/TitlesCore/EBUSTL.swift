import Foundation

/// EBU STL (EBU Tech 3264), the binary subtitle file of European broadcast: a 1024-byte
/// General Subtitle Information block, then one 128-byte Text and Timing Information block
/// per title (more when its text doesn't fit in one). Written for level-1 teletext:
/// double-height boxed lines, centred, the last line on row 22.
enum EBUSTL {
    static let gsiSize = 1024
    static let ttiSize = 128
    static let textFieldSize = 112

    /// The character table a language's text is written in (CCT in the header).
    enum CharacterTable: String, Sendable {
        case latin = "00", cyrillic = "01", arabic = "02", greek = "03", hebrew = "04"

        /// ISO 8859 for the upper half of the non-Latin tables.
        var isoName: String? {
            switch self {
            case .latin: return nil
            case .cyrillic: return "iso-8859-5"
            case .arabic: return "iso-8859-6"
            case .greek: return "iso-8859-7"
            case .hebrew: return "iso-8859-8"
            }
        }

        /// The table that holds the most of the titles' letters.
        static func best(for text: String) -> CharacterTable {
            var cyrillic = 0, arabic = 0, greek = 0, hebrew = 0, latin = 0
            for s in text.unicodeScalars where s.properties.isAlphabetic {
                switch s.value {
                case 0x0400...0x04FF: cyrillic += 1
                case 0x0600...0x06FF: arabic += 1
                case 0x0370...0x03FF: greek += 1
                case 0x0590...0x05FF: hebrew += 1
                default: latin += 1
                }
            }
            let counts: [(CharacterTable, Int)] = [(.latin, latin), (.cyrillic, cyrillic), (.arabic, arabic),
                                                   (.greek, greek), (.hebrew, hebrew)]
            return counts.max { $0.1 < $1.1 }.map { $0.1 > 0 ? $0.0 : .latin } ?? .latin
        }
    }

    /// The file and the number of characters its table couldn't hold (written as "?").
    static func file(_ subs: [Subtitle], context c: ExportContext) -> (data: Data, lost: Int) {
        let items = SubtitleFormats.exportable(subs)
        let table = CharacterTable.best(for: items.map(\.1).joined(separator: " "))
        let thirty = (29.5...30.5).contains(c.fps) || (59...61).contains(c.fps)
        // STL counts 25 or 30 frames a second. At 29.97 the video's own (non-drop) frame
        // count is kept; any other rate is counted at 25, so the times stay right in seconds.
        let countFPS = thirty ? (c.fps > 45 ? c.fps / 2 : c.fps) : 25

        var blocks: [[UInt8]] = []
        var lost = 0
        for (n, item) in items.enumerated() {
            let lines = Markup.styledLines(item.1).filter { !$0.isEmpty }
            var text: [UInt8] = []
            for (k, line) in lines.enumerated() {
                if k > 0 { text += [0x8A, 0x8A] }          // a blank row between double-height lines
                text += [0x0D, 0x0B, 0x0B]                   // double height, start box
                var italic = false, underline = false
                for run in line {
                    if run.italic != italic { text.append(run.italic ? 0x80 : 0x81); italic = run.italic }
                    if run.underline != underline { text.append(run.underline ? 0x82 : 0x83); underline = run.underline }
                    let encoded = encode(run.text, table: table)
                    text += encoded.bytes
                    lost += encoded.lost
                }
                if italic { text.append(0x81) }
                if underline { text.append(0x83) }
                text += [0x0A, 0x0A]                         // end box
            }
            let rows = max(1, lines.count)
            let row = Markup.isTop(item.1) ? 1 : max(1, 22 - 2 * (rows - 1))
            let tcIn = timecode(item.0.start + c.startTimecode, fps: countFPS)
            let tcOut = timecode(item.0.end + c.startTimecode, fps: countFPS)
            // Text longer than one block's field goes on in extension blocks.
            let chunks = stride(from: 0, to: max(1, text.count), by: textFieldSize).map {
                Array(text[min($0, text.count)..<min($0 + textFieldSize, text.count)])
            }
            for (e, chunk) in chunks.enumerated() {
                var tti: [UInt8] = []
                tti.append(0)                                                  // subtitle group
                tti += [UInt8(truncatingIfNeeded: n + 1), UInt8(truncatingIfNeeded: (n + 1) >> 8)]  // number
                tti.append(e == chunks.count - 1 ? 0xFF : UInt8(e))            // extension block number
                tti.append(0)                                                  // cumulative status
                tti += tcIn + tcOut
                tti.append(UInt8(row))                                         // vertical position
                tti.append(2)                                                  // centred
                tti.append(0)                                                  // not a comment
                tti += chunk + Array(repeating: 0x8F, count: textFieldSize - chunk.count)
                blocks.append(tti)
            }
        }

        let first = items.first.map { timecodeString($0.0.start + c.startTimecode, fps: countFPS) } ?? "00000000"
        var data = Data(gsi(context: c, table: table, thirty: thirty, blocks: blocks.count, titles: items.count,
                            start: timecodeString(c.startTimecode, fps: countFPS), first: first))
        for b in blocks { data.append(contentsOf: b) }
        return (data, lost)
    }

    /// Hours, minutes, seconds, frames as four bytes.
    static func timecode(_ t: Double, fps: Double) -> [UInt8] {
        let p = Timecode.frameParts(t, fps: fps)
        return [UInt8(p.h), UInt8(p.m), UInt8(p.s), UInt8(p.f)]
    }

    /// "HHMMSSFF", as the header writes times.
    static func timecodeString(_ t: Double, fps: Double) -> String {
        let p = Timecode.frameParts(t, fps: fps)
        return String(format: "%02d%02d%02d%02d", p.h, p.m, p.s, p.f)
    }

    /// The General Subtitle Information block.
    static func gsi(context c: ExportContext, table: CharacterTable, thirty: Bool, blocks: Int, titles: Int,
                    start: String, first: String) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMdd"
        let date = formatter.string(from: c.date)
        var g: [UInt8] = []
        func field(_ s: String, _ size: Int) {
            // Code page 850 here; plain ASCII is safe everywhere (accents are dropped).
            let ascii = s.folding(options: .diacriticInsensitive, locale: nil)
            var bytes = Array(ascii.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 }.map { UInt8($0.value) }.prefix(size))
            bytes += Array(repeating: 0x20, count: size - bytes.count)
            g += bytes
        }
        field("850", 3)                                  // code page of this block
        field(thirty ? "STL30.01" : "STL25.01", 8)        // disk format
        field("1", 1)                                    // level-1 teletext
        field(table.rawValue, 2)                         // character table
        field(languageCode(c.language), 2)
        field(c.title, 32)                               // original programme title
        field("", 32)                                    // original episode title
        field(c.title, 32)                               // translated programme title
        field("", 32)                                    // translated episode title
        field("", 32)                                    // translator's name
        field("", 32)                                    // translator's contact
        field("", 16)                                    // subtitle list reference
        field(date, 6)                                   // created
        field(date, 6)                                   // revised
        field("00", 2)                                   // revision number
        field(String(format: "%05d", min(blocks, 99_999)), 5)
        field(String(format: "%05d", min(titles, 99_999)), 5)
        field("001", 3)                                  // subtitle groups
        field("40", 2)                                   // characters per row
        field("23", 2)                                   // rows
        field("1", 1)                                    // time codes are for use
        field(start, 8)                                  // start of programme
        field(first, 8)                                  // first title
        field("1", 1)                                    // disks
        field("1", 1)                                    // this disk
        field("", 3)                                     // country
        field("", 32)                                    // publisher
        field("", 32)                                    // editor
        field("", 32)                                    // editor's contact
        field("", 75)                                    // spare
        field("", 576)                                   // user-defined area
        return g
    }

    /// The language codes of EBU Tech 3264 (appendix 3), as two hex digits.
    static func languageCode(_ code: String) -> String {
        let base = code.lowercased().split(separator: "-").first.map(String.init) ?? ""
        let codes: [String: String] = [
            "sq": "01", "br": "02", "ca": "03", "hr": "04", "cy": "05", "cs": "06", "da": "07", "de": "08",
            "en": "09", "es": "0A", "eo": "0B", "et": "0C", "eu": "0D", "fo": "0E", "fr": "0F", "fy": "10",
            "ga": "11", "gd": "12", "gl": "13", "is": "14", "it": "15", "se": "16", "la": "17", "lv": "18",
            "lb": "19", "lt": "1A", "hu": "1B", "mt": "1C", "nl": "1D", "nb": "1E", "nn": "1E", "no": "1E",
            "oc": "1F", "pl": "20", "pt": "21", "ro": "22", "rm": "23", "sr": "24", "sk": "25", "sl": "26",
            "fi": "27", "sv": "28", "tr": "29", "bs": "54", "sh": "54",
            "zu": "45", "vi": "46", "uz": "47", "ur": "48", "uk": "49", "th": "4A", "te": "4B", "tt": "4C",
            "ta": "4D", "tg": "4E", "sw": "4F", "so": "51", "si": "52", "sn": "53", "ru": "56", "qu": "57",
            "ps": "58", "pa": "59", "fa": "5A", "or": "5C", "ne": "5D", "mr": "5F", "mo": "60", "ms": "61",
            "mg": "62", "mk": "63", "lo": "64", "ko": "65", "km": "66", "kk": "67", "kn": "68", "ja": "69",
            "id": "6A", "hi": "6B", "he": "6C", "ha": "6D", "gu": "6F", "el": "70", "ka": "71", "ff": "72",
            "zh": "75", "my": "76", "bg": "77", "bn": "78", "be": "79", "az": "7B", "as": "7C", "hy": "7D",
            "ar": "7E", "am": "7F"
        ]
        return codes[base] ?? "00"
    }

    /// Text in an STL character table. Latin is ISO 6937: an accented letter is its accent
    /// byte followed by the plain letter. The other tables hold ISO 8859 in their upper half.
    static func encode(_ text: String, table: CharacterTable) -> (bytes: [UInt8], lost: Int) {
        var out: [UInt8] = []
        var lost = 0
        let iso = table.isoName.flatMap(SubtitleFormats.encoding(named:))
        for ch in text {
            if let a = ch.asciiValue, a >= 0x20, a < 0x7F {
                out.append(table == .latin && a == 0x24 ? 0xA4 : a)   // ISO 6937 keeps "$" at A4
                continue
            }
            if let iso {
                if let d = String(ch).data(using: iso), d.count == 1, let b = d.first, b >= 0xA0 {
                    out.append(b)
                } else if let fallback = latinFallback[ch] {
                    out += Array(fallback.utf8)
                } else {
                    out.append(0x3F); lost += 1
                }
                continue
            }
            if let special = iso6937[ch] { out.append(special); continue }
            if let fallback = latinFallback[ch] { out += Array(fallback.utf8); continue }
            // A letter with an accent: the accent byte, then the letter.
            let parts = String(ch).decomposedStringWithCanonicalMapping.unicodeScalars
            if parts.count == 2, let base = parts.first, base.isASCII, let last = parts.last,
               let accent = accents[last.value] {
                out += [accent, UInt8(base.value)]
            } else {
                out.append(0x3F); lost += 1
            }
        }
        return (out, lost)
    }

    /// Combining accents and their ISO 6937 bytes.
    private static let accents: [UInt32: UInt8] = [
        0x0300: 0xC1, 0x0301: 0xC2, 0x0302: 0xC3, 0x0303: 0xC4, 0x0304: 0xC5, 0x0306: 0xC6,
        0x0307: 0xC7, 0x0308: 0xC8, 0x030A: 0xCA, 0x0327: 0xCB, 0x030B: 0xCD, 0x0328: 0xCE, 0x030C: 0xCF
    ]

    /// ISO 6937 characters that aren't a letter plus an accent.
    private static let iso6937: [Character: UInt8] = [
        "¡": 0xA1, "¢": 0xA2, "£": 0xA3, "¥": 0xA5, "§": 0xA7, "‘": 0xA9, "“": 0xAA, "«": 0xAB,
        "°": 0xB0, "±": 0xB1, "²": 0xB2, "³": 0xB3, "×": 0xB4, "µ": 0xB5, "¶": 0xB6, "·": 0xB7,
        "÷": 0xB8, "’": 0xB9, "”": 0xBA, "»": 0xBB, "¼": 0xBC, "½": 0xBD, "¾": 0xBE, "¿": 0xBF,
        "―": 0xD0, "¹": 0xD1, "®": 0xD2, "©": 0xD3, "™": 0xD4, "♪": 0xD5, "¬": 0xD6, "¦": 0xD7,
        "Ω": 0xE0, "Æ": 0xE1, "Đ": 0xE2, "ª": 0xE3, "Ħ": 0xE4, "Ĳ": 0xE6, "Ŀ": 0xE7, "Ł": 0xE8,
        "Ø": 0xE9, "Œ": 0xEA, "º": 0xEB, "Þ": 0xEC, "Ŧ": 0xED, "Ŋ": 0xEE, "ŉ": 0xEF,
        "ĸ": 0xF0, "æ": 0xF1, "đ": 0xF2, "ð": 0xF3, "ħ": 0xF4, "ı": 0xF5, "ĳ": 0xF6, "ŀ": 0xF7,
        "ł": 0xF8, "ø": 0xF9, "œ": 0xFA, "ß": 0xFB, "þ": 0xFC, "ŧ": 0xFD, "ŋ": 0xFE, "\u{00AD}": 0xFF
    ]

    /// Characters no table holds, written the nearest plain way.
    private static let latinFallback: [Character: String] = [
        "–": "-", "—": "-", "…": "...", "„": "\"", "‚": "'", "\u{00A0}": " ", "\u{200E}": "", "\u{200F}": "",
        "♫": "#"
    ]
}
