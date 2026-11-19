import AppKit

/// Heights in the waveform pane (its title bar included), shared by the waveform's own layout
/// and the model's rules for how tall the pane is: every language open on the waveform keeps
/// room for two lines of text in its boxes.
enum WaveLayout {
    /// The transport and zoom bar above the waveform.
    static let titleBar: CGFloat = 40
    /// The time ruler along the top of the waveform.
    static let ruler: CGFloat = 20
    /// The scroll bar along the bottom (the whole film).
    static let scrollBar: CGFloat = 12
    /// A language that isn't open: a slim lane under the open ones.
    static let lane: CGFloat = 20
    /// Everything in the pane besides the languages.
    static var chrome: CGFloat { titleBar + ruler + scrollBar }

    /// A box's height as a share of its language's band (overlapping titles, one lane up or
    /// down, are shorter: `shiftedBoxShare`).
    static let boxShare: CGFloat = 0.74
    static let shiftedBoxShare: CGFloat = 0.63
    /// The box text's size, and the room above and below it inside a box.
    static let textSize: CGFloat = 11
    static let textInset: CGFloat = 8

    /// The least height of an open language: two lines of box text, even in a box shifted
    /// down for an overlap.
    static let minBand: CGFloat = {
        let line = NSLayoutManager().defaultLineHeight(for: RichMarkup.font(size: textSize, italic: true, bold: true))
        return max(56, ((2 * line + textInset) / shiftedBoxShare).rounded(.up))
    }()

    /// What an open language gets when one is opened and there's room: its two lines with
    /// the waveform round them to breathe.
    static var comfortableBand: CGFloat { max(minBand, 90) }

    /// The pane's least height with `bands` languages open and `lanes` slim.
    static func minHeight(bands: Int, lanes: Int) -> CGFloat {
        chrome + CGFloat(max(0, lanes)) * lane + CGFloat(max(1, bands)) * minBand
    }

    /// The pane's height when every open language gets `comfortableBand`.
    static func comfortableHeight(bands: Int, lanes: Int) -> CGFloat {
        chrome + CGFloat(max(0, lanes)) * lane + CGFloat(max(1, bands)) * comfortableBand
    }

    /// The bands' heights in `area`, shared by their weights (the line between two bands can
    /// be dragged), with none under `minimum` while there's room for that; the last band
    /// takes what rounding leaves. Without room for every band's minimum, an equal share each.
    static func bandHeights(weights: [CGFloat], area: CGFloat, minimum: CGFloat) -> [CGFloat] {
        let n = weights.count
        guard n > 0 else { return [] }
        let area = max(0, area)
        var heights: [CGFloat]
        if area < minimum * CGFloat(n) {
            heights = Array(repeating: area / CGFloat(n), count: n)
        } else {
            let w = weights.map { max(0.001, $0) }
            var pinned = Set<Int>()
            while true {
                let free = area - minimum * CGFloat(pinned.count)
                let total = w.indices.filter { !pinned.contains($0) }.reduce(0) { $0 + w[$1] }
                heights = w.indices.map { pinned.contains($0) ? minimum : free * w[$0] / max(0.001, total) }
                let under = w.indices.filter { !pinned.contains($0) && heights[$0] < minimum - 0.001 }
                if under.isEmpty { break }
                pinned.formUnion(under)
            }
        }
        var out = heights.dropLast().map { $0.rounded() }
        out.append(max(0, area - out.reduce(0, +)))
        return out
    }
}
