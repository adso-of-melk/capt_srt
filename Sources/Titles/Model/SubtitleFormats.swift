import Foundation

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

    /// Tries UTF-8 (with or without BOM), UTF-16 with BOM, then the common legacy encodings.
    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Parses SRT and WebVTT (cue identifiers optional, `,` or `.` before milliseconds).
    static func parse(_ raw: String) -> [Subtitle] {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

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

    static func srt(_ subs: [Subtitle]) -> String {
        var out = ""
        for (i, s) in subs.enumerated() {
            out += "\(i + 1)\n"
            out += "\(Timecode.srt(s.start)) --> \(Timecode.srt(s.end))\n"
            out += s.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        return out
    }

    static func vtt(_ subs: [Subtitle]) -> String {
        var out = "WEBVTT\n\n"
        for (i, s) in subs.enumerated() {
            out += "\(i + 1)\n"
            out += "\(Timecode.vtt(s.start)) --> \(Timecode.vtt(s.end))\n"
            out += s.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
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
    static func frames(_ t: Double, fps: Double) -> String {
        let fps = max(1, fps)
        let totalFrames = Int((max(0, t) * fps).rounded(.down))
        let f = totalFrames % Int(fps.rounded())
        let secs = Int(max(0, t))
        return String(format: "%02d:%02d:%02d:%02d", secs / 3600, (secs / 60) % 60, secs % 60, f)
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
