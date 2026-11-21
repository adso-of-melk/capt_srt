import Foundation

/// Subtitle sites stamp their own adverts into the files they hand out ("www.tvsubtitles.net",
/// "Advertise your product or brand here"), often on a broken timecode. Importing leaves them out.
extension SubtitleFormats {
    /// Subtitle sites whose name in a title marks it as their advert.
    static let adSites = ["tvsubtitles", "opensubtitles", "subscene", "addic7ed", "podnapisi",
                          "yifysubtitles", "subdl.com", "titlovi.com", "legendas.tv", "subtitulos.es",
                          "napisy24", "osdb.link"]
    /// The words of the adverts those sites add.
    static let adPhrases = ["advertise your product or brand here", "become vip member",
                            "support us and become", "subtitles downloaded from"]

    /// Whether a title is a subtitle site's advert, not the film's words: it names a known
    /// subtitle site or uses an advert's words, or (`nearEdge`: among the first or last few
    /// titles) it's little more than a web address.
    static func isAd(_ s: Subtitle, nearEdge: Bool) -> Bool {
        let plain = Markup.plain(s.text).lowercased()
        if adSites.contains(where: { plain.contains($0) }) || adPhrases.contains(where: { plain.contains($0) }) {
            return true
        }
        guard nearEdge, let range = plain.range(of: #"(https?://|www\.)\S+"#, options: .regularExpression) else {
            return false
        }
        var rest = plain
        rest.removeSubrange(range)
        return rest.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).count <= 4
    }

    /// The titles without the subtitle sites' adverts.
    static func withoutAds(_ subs: [Subtitle]) -> [Subtitle] {
        let n = subs.count
        return subs.enumerated().filter { i, s in !isAd(s, nearEdge: i < 3 || i >= n - 3) }.map(\.element)
    }
}
