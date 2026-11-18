import Foundation

/// Formatting tags inside subtitle text (<i>, <b>, <u>, <font …>, and {\an8}-style codes).
/// The text keeps its tags (they're exported as written); these helpers find the tags and
/// the characters a viewer reads. (Showing it formatted is the app's: `Markup.attributed`.)
enum Markup {
    /// Only real formatting tags count, written the way tags are written (no space after
    /// the "<"), so text like "a < b and c > d" or "I <3 you" is never mistaken for a tag
    /// and hidden. Group 1 is the "/" of a closing tag, group 2 the name of a style tag.
    static let tagPattern = try! NSRegularExpression(
        pattern: #"<(/?)(?:(i|b|u|s|ruby|rt|br)(?:\.[^<>\s]*)?\s*/?|(?:font|c|v|lang|span)\b[^<>]*)>|\{\\[^}]*\}"#,
        options: [.caseInsensitive])

    /// The text without any tags.
    static func plain(_ text: String) -> String {
        guard text.contains("<") || text.contains("{") else { return text }
        let ns = text as NSString
        return tagPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                                   withTemplate: "")
    }
}
