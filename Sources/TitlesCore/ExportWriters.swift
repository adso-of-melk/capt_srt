import Foundation

// MARK: - Styled text

extension Markup {
    /// A stretch of a line in one style.
    struct Run: Equatable, Sendable {
        var text: String
        var italic = false
        var bold = false
        var underline = false

        var styled: Bool { italic || bold || underline }
    }

    /// A title's lines, each as runs of text in one style. <i>, <b> and <u> are followed
    /// (also across lines); every other tag (font colours, {\an8}) is left out. <br> starts
    /// a new line.
    static func styledLines(_ text: String) -> [[Run]] {
        let ns = text as NSString
        var lines: [[Run]] = [[]]
        var italic = false, bold = false, underline = false

        func add(_ piece: String) {
            for (k, part) in piece.components(separatedBy: "\n").enumerated() {
                if k > 0 { lines.append([]) }
                guard !part.isEmpty else { continue }
                let i = lines.count - 1
                if let last = lines[i].last, last.italic == italic, last.bold == bold, last.underline == underline {
                    lines[i][lines[i].count - 1].text += part
                } else {
                    lines[i].append(Run(text: part, italic: italic, bold: bold, underline: underline))
                }
            }
        }

        var at = 0
        for m in tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > at { add(ns.substring(with: NSRange(location: at, length: m.range.location - at))) }
            at = m.range.location + m.range.length
            let name = m.range(at: 2)
            guard name.location != NSNotFound else { continue }
            let closing = m.range(at: 1).length > 0
            switch ns.substring(with: name).lowercased() {
            case "i": italic = !closing
            case "b": bold = !closing
            case "u": underline = !closing
            case "br": add("\n")
            default: break
            }
        }
        if at < ns.length { add(ns.substring(from: at)) }
        return lines
    }

    /// The title asks to be shown at the top of the picture ({\an7}, {\an8} or {\an9}).
    static func isTop(_ text: String) -> Bool {
        text.range(of: #"\{\\an[789]\}"#, options: .regularExpression) != nil
    }
}

// MARK: - Writers

extension SubtitleFormats {

    static func xmlEscaped(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }

    /// A title's text as TTML: lines joined by <br/>, styled runs in <span>s.
    static func ttmlContent(_ text: String) -> String {
        Markup.styledLines(text).map { line in
            line.map { run -> String in
                let body = xmlEscaped(run.text)
                guard run.styled else { return body }
                var attributes: [String] = []
                if run.italic { attributes.append(#"tts:fontStyle="italic""#) }
                if run.bold { attributes.append(#"tts:fontWeight="bold""#) }
                if run.underline { attributes.append(#"tts:textDecoration="underline""#) }
                return "<span \(attributes.joined(separator: " "))>\(body)</span>"
            }.joined()
        }.joined(separator: "<br/>")
    }

    private static let ttmlNamespaces = #"xmlns="http://www.w3.org/ns/ttml" xmlns:ttp="http://www.w3.org/ns/ttml#parameter" xmlns:tts="http://www.w3.org/ns/ttml#styling" xmlns:ttm="http://www.w3.org/ns/ttml#metadata""#

    /// TTML in the IMSC 1.1 Text profile (Netflix, Amazon, broadcasters): media time in
    /// hours:minutes:seconds.milliseconds, a bottom and a top region.
    static func ttml(_ subs: [Subtitle], context c: ExportContext) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt \(ttmlNamespaces) ttp:contentProfiles="http://www.w3.org/ns/ttml/profile/imsc1.1/text" ttp:timeBase="media" xml:lang="\(xmlEscaped(c.language))">
          <head>
            <metadata>
              <ttm:title>\(xmlEscaped(c.title))</ttm:title>
            </metadata>
            <styling>
              <style xml:id="default" tts:fontFamily="proportionalSansSerif" tts:fontSize="100%" tts:textAlign="center" tts:color="white"/>
            </styling>
            <layout>
              <region xml:id="bottom" tts:origin="10% 10%" tts:extent="80% 80%" tts:displayAlign="after"/>
              <region xml:id="top" tts:origin="10% 10%" tts:extent="80% 80%" tts:displayAlign="before"/>
            </layout>
          </head>
          <body style="default">
            <div>

        """
        for (s, text) in exportable(subs) {
            out += "      <p begin=\"\(Timecode.vtt(s.start))\" end=\"\(Timecode.vtt(s.end))\" region=\"\(Markup.isTop(text) ? "top" : "bottom")\">"
            out += ttmlContent(text) + "</p>\n"
        }
        out += "    </div>\n  </body>\n</tt>\n"
        return out
    }

    /// DFXP: TTML 1 as older platforms take it, times in ticks of a ten-millionth of a second.
    static func dfxp(_ subs: [Subtitle], context c: ExportContext) -> String {
        func ticks(_ t: Double) -> String { "\(Int64((max(0, t) * 10_000_000).rounded()))t" }
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt \(ttmlNamespaces) ttp:timeBase="media" ttp:tickRate="10000000" xml:lang="\(xmlEscaped(c.language))">
          <head>
            <metadata>
              <ttm:title>\(xmlEscaped(c.title))</ttm:title>
            </metadata>
            <styling>
              <style xml:id="s0" tts:fontFamily="sansSerif" tts:fontSize="100%" tts:textAlign="center" tts:color="white"/>
            </styling>
            <layout>
              <region xml:id="bottom" tts:origin="10% 10%" tts:extent="80% 80%" tts:displayAlign="after" tts:textAlign="center"/>
              <region xml:id="top" tts:origin="10% 10%" tts:extent="80% 80%" tts:displayAlign="before" tts:textAlign="center"/>
            </layout>
          </head>
          <body style="s0">
            <div>

        """
        for (s, text) in exportable(subs) {
            out += "      <p begin=\"\(ticks(s.start))\" end=\"\(ticks(s.end))\" region=\"\(Markup.isTop(text) ? "top" : "bottom")\">"
            out += ttmlContent(text) + "</p>\n"
        }
        out += "    </div>\n  </body>\n</tt>\n"
        return out
    }

    /// iTunes Timed Text: TTML with SMPTE time in frames (non-drop), as Apple asks.
    static func itt(_ subs: [Subtitle], context c: ExportContext) -> String {
        let nominal = max(1, Int(c.fps.rounded()))
        let pulldown = abs(c.fps - Double(nominal)) > 0.001
        let rate = "ttp:frameRate=\"\(nominal)\"" + (pulldown ? " ttp:frameRateMultiplier=\"1000 1001\"" : "")
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt \(ttmlNamespaces) ttp:timeBase="smpte" \(rate) ttp:dropMode="nonDrop" xml:lang="\(xmlEscaped(c.language))">
          <head>
            <styling>
              <style xml:id="normal" tts:fontFamily="sansSerif" tts:fontWeight="normal" tts:fontStyle="normal" tts:color="white" tts:fontSize="100%"/>
            </styling>
            <layout>
              <region xml:id="bottom" tts:origin="0% 85%" tts:extent="100% 15%" tts:textAlign="center" tts:displayAlign="after"/>
              <region xml:id="top" tts:origin="0% 0%" tts:extent="100% 15%" tts:textAlign="center" tts:displayAlign="before"/>
            </layout>
          </head>
          <body style="normal" region="bottom">
            <div>

        """
        for (s, text) in exportable(subs) {
            let place = Markup.isTop(text) ? " region=\"top\"" : ""
            out += "      <p begin=\"\(Timecode.frames(s.start, fps: c.fps))\" end=\"\(Timecode.frames(s.end, fps: c.fps))\"\(place)>"
            out += ttmlContent(text) + "</p>\n"
        }
        out += "    </div>\n  </body>\n</tt>\n"
        return out
    }

    /// 0:01:02.35: the SubStation Alpha time (hours, then hundredths of a second).
    static func assTime(_ t: Double) -> String {
        let cs = Int((max(0, t) * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", cs / 360_000, (cs / 6000) % 60, (cs / 100) % 60, cs % 100)
    }

    /// A title's text as SubStation override codes: {\i1}…{\i0}, lines joined by \N.
    /// `top` is the code that puts it at the top ({\an8}, or {\a6} in the older format).
    static func assText(_ text: String, top: String) -> String {
        var out = Markup.isTop(text) ? top : ""
        var lines: [String] = []
        for line in Markup.styledLines(text) {
            var i = false, b = false, u = false
            var l = ""
            for run in line {
                if run.italic != i { l += run.italic ? "{\\i1}" : "{\\i0}"; i = run.italic }
                if run.bold != b { l += run.bold ? "{\\b1}" : "{\\b0}"; b = run.bold }
                if run.underline != u { l += run.underline ? "{\\u1}" : "{\\u0}"; u = run.underline }
                l += run.text
            }
            if i { l += "{\\i0}" }
            if b { l += "{\\b0}" }
            if u { l += "{\\u0}" }
            lines.append(l)
        }
        out += lines.joined(separator: "\\N")
        return out
    }

    /// Advanced SubStation Alpha (v4+), at 1920 × 1080.
    static func ass(_ subs: [Subtitle], context c: ExportContext) -> String {
        var out = """
        [Script Info]
        ; Written by KPTN.SUB
        Title: \(c.title)
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        WrapStyle: 0
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,64,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,96,96,54,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        for (s, text) in exportable(subs) {
            out += "Dialogue: 0,\(assTime(s.start)),\(assTime(s.end)),Default,,0,0,0,,\(assText(text, top: "{\\an8}"))\n"
        }
        return out
    }

    /// SubStation Alpha (v4), for older players.
    static func ssa(_ subs: [Subtitle], context c: ExportContext) -> String {
        var out = """
        [Script Info]
        ; Written by KPTN.SUB
        Title: \(c.title)
        ScriptType: v4.00
        PlayResX: 1920
        PlayResY: 1080

        [V4 Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
        Style: Default,Arial,64,16777215,65535,65535,-2147483640,0,0,1,3,1,2,96,96,54,0,1

        [Events]
        Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        for (s, text) in exportable(subs) {
            out += "Dialogue: Marked=0,\(assTime(s.start)),\(assTime(s.end)),Default,,0000,0000,0000,,\(assText(text, top: "{\\a6}"))\n"
        }
        return out
    }

    /// 0:01:02.345: YouTube's time (hours not padded).
    static func sbvTime(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// The words of a title as they're read: no tags, lines kept.
    private static func spoken(_ text: String) -> String {
        Markup.plain(text).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// YouTube's SubViewer format: no numbers, no formatting.
    static func sbv(_ subs: [Subtitle]) -> String {
        exportable(subs).map { "\(sbvTime($0.0.start)),\(sbvTime($0.0.end))\n\(spoken($0.1))\n" }
            .joined(separator: "\n")
    }

    /// The words only, one title after another, a blank line between titles.
    static func plainText(_ subs: [Subtitle]) -> String {
        exportable(subs).map { spoken($0.1) + "\n" }.joined(separator: "\n")
    }

    /// A dialogue list: each title's number, in and out timecodes (frames, from the start
    /// timecode), then its words.
    static func dialogueList(_ subs: [Subtitle], context c: ExportContext) -> String {
        exportable(subs).enumerated().map { i, item in
            let tcIn = Timecode.frames(item.0.start + c.startTimecode, fps: c.fps)
            let tcOut = Timecode.frames(item.0.end + c.startTimecode, fps: c.fps)
            return "\(i + 1)\t\(tcIn)\t\(tcOut)\n\(spoken(item.1))\n"
        }.joined(separator: "\n")
    }

    /// Avid DS captions, as Media Composer's SubCap effect imports them.
    static func avid(_ subs: [Subtitle], context c: ExportContext) -> String {
        var out = "@ This file written with the Avid Caption plugin, version 1\n\n<begin subtitles>\n\n"
        for (s, text) in exportable(subs) {
            out += "\(Timecode.frames(s.start + c.startTimecode, fps: c.fps)) \(Timecode.frames(s.end + c.startTimecode, fps: c.fps))\n"
            out += spoken(text) + "\n\n"
        }
        out += "<end subtitles>\n"
        return out
    }
}
