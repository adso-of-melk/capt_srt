import Foundation

/// Formatting tags inside subtitle text (<i>, <b>, <u>, <font …>, and {\an8}-style codes).
/// The text keeps its tags (they're exported as written); these helpers show it formatted
/// and count only the characters a viewer reads.
enum Markup {
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"<\s*(/?)\s*([a-zA-Z]+)[^>]*>|\{\\[^}]*\}"#)

    /// The text without any tags.
    static func plain(_ text: String) -> String {
        guard text.contains("<") || text.contains("{") else { return text }
        let ns = text as NSString
        return tagPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                                   withTemplate: "")
    }

    /// The text with <i>, <b> and <u> applied, and every tag hidden.
    static func attributed(_ text: String) -> AttributedString {
        let ns = text as NSString
        var out = AttributedString()
        var italic = 0, bold = 0, underline = 0
        var cursor = 0
        func append(_ piece: String) {
            guard !piece.isEmpty else { return }
            var a = AttributedString(piece)
            var intent: InlinePresentationIntent = []
            if italic > 0 { intent.insert(.emphasized) }
            if bold > 0 { intent.insert(.stronglyEmphasized) }
            if !intent.isEmpty { a.inlinePresentationIntent = intent }
            if underline > 0 { a.underlineStyle = .single }
            out += a
        }
        for m in tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            cursor = m.range.location + m.range.length
            guard m.range(at: 2).location != NSNotFound else { continue }
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let step = closing ? -1 : 1
            switch ns.substring(with: m.range(at: 2)).lowercased() {
            case "i": italic = max(0, italic + step)
            case "b": bold = max(0, bold + step)
            case "u": underline = max(0, underline + step)
            default: break
            }
        }
        append(ns.substring(from: cursor))
        return out
    }
}
