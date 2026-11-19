import SwiftUI
@testable import TitlesCore

/// How tall the waveform pane is with several languages open on it: never so short that an
/// open language's boxes can't show two lines, and taller when a language is opened, as far
/// as the picture can give.
extension AppModel {
    /// Languages open as full bands on the waveform, and the others' slim lanes.
    var waveBandCounts: (bands: Int, lanes: Int) {
        let bands = waveBandTracks.count
        return (bands, max(0, openTracks.count - bands))
    }

    /// The waveform pane's least height (title bar included): two lines of text in every open
    /// language, the slim lanes of the rest, and never under `waveformMinHeight`.
    var waveformLeastHeight: CGFloat {
        let c = waveBandCounts
        return max(Self.waveformMinHeight, WaveLayout.minHeight(bands: c.bands, lanes: c.lanes))
    }

    /// The most the waveform pane can be: all the picture can give up (nil: the window hasn't
    /// been laid out yet).
    var waveformMostHeight: CGFloat? {
        guard editorHeight > 0 else { return nil }
        return max(Self.waveformMinHeight, editorHeight - Self.videoMinHeight - PaneDivider.thickness)
    }

    /// How many languages can be open on the waveform at once, each with room for two lines,
    /// with the pane as tall as the picture lets it be. Opening one more closes the lowest.
    var waveBandRoom: Int? {
        guard let most = waveformMostHeight else { return waveRoom }
        return Self.bandRoom(languages: openTracks.count, paneHeight: most)
    }

    /// How many of `languages` fit open in a pane this tall (the rest as slim lanes); at least one.
    static func bandRoom(languages: Int, paneHeight: CGFloat) -> Int {
        var k = max(1, languages)
        while k > 1, WaveLayout.minHeight(bands: k, lanes: languages - k) > paneHeight { k -= 1 }
        return k
    }

    /// A language was opened on the waveform: the pane grows (smoothly) until every open
    /// language has `WaveLayout.comfortableBand`, as far as the picture can give. A pane
    /// already that tall stays as it is.
    func growWaveformForBands(animated: Bool = true) {
        guard editorHeight > 0 else { return }
        let d = PaneDivider.thickness
        let now = waveformPaneHeight(in: editorHeight, divider: d)
        let c = waveBandCounts
        let want = WaveLayout.comfortableHeight(bands: c.bands, lanes: c.lanes)
        guard want > now + 0.5 else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) { setWaveformPaneHeight(want, in: editorHeight, divider: d) }
        } else {
            setWaveformPaneHeight(want, in: editorHeight, divider: d)
        }
    }
}
