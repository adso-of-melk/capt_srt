import XCTest
import AppKit
@testable import Titles
@testable import TitlesCore

/// Several languages open on the waveform: each keeps room for two lines of text in its
/// boxes, the pane grows when one is opened, and the languages you're not in step back as
/// their columns do in the title pane.
@MainActor
final class WaveformRoomTests: XCTestCase {

    private let divider = PaneDivider.thickness

    private func threeLanguages() -> (Fixture, Track) {
        let f = makeFixture([("en", [sub(1, 2, "Hi")]), ("hr", [sub(1, 2, "Bok")]), ("de", [sub(1, 2, "Hallo")])])
        f.model.focusTrack(f.en.id, edit: false)
        return (f, f.video.tracks[2])
    }

    // MARK: The least height

    func testTwoLinesOfBoxTextFitInTheSmallestBand() {
        let line = NSLayoutManager().defaultLineHeight(for: RichMarkup.font(size: WaveLayout.textSize, italic: true, bold: true))
        // Even a box shifted down for an overlap (the shortest) holds two lines.
        XCTAssertGreaterThanOrEqual(WaveLayout.minBand * WaveLayout.shiftedBoxShare - WaveLayout.textInset, 2 * line)
        XCTAssertGreaterThanOrEqual(WaveLayout.comfortableBand, WaveLayout.minBand)
    }

    func testThePaneNeverSqueezesTheOpenLanguagesBelowTwoLines() {
        let (f, de) = threeLanguages()
        let height: CGFloat = 1000
        // One open, two slim: about the usual minimum.
        XCTAssertEqual(f.model.waveformLeastHeight,
                       max(AppModel.waveformMinHeight, WaveLayout.minHeight(bands: 1, lanes: 2)))
        // All three open: room for two lines in each, plus the bar, ruler and scroll bar.
        f.model.allWaveBands = true
        XCTAssertEqual(f.model.waveBandTracks.map(\.id), [f.en.id, f.hr.id, de.id])
        let least = WaveLayout.chrome + 3 * WaveLayout.minBand
        XCTAssertEqual(f.model.waveformLeastHeight, least)
        f.model.setWaveformPaneHeight(20, in: height, divider: divider)
        XCTAssertEqual(f.model.waveformPaneHeight(in: height, divider: divider), least)
        // The picture's own minimum still comes first in a short window.
        XCTAssertEqual(f.model.waveformPaneHeight(in: 450, divider: divider), 450 - AppModel.videoMinHeight - divider)
    }

    // MARK: Opening a language

    func testOpeningALanguageGrowsThePaneWhenThereIsRoom() {
        let (f, de) = threeLanguages()
        f.model.editorHeight = 1000
        f.model.toggleWaveBand(f.hr.id)
        // Two open, one slim: the usual height already gives each its room.
        let two = WaveLayout.comfortableHeight(bands: 2, lanes: 1)
        XCTAssertEqual(f.model.waveformPaneHeight(in: 1000, divider: divider), max(two, AppModel.waveformDefaultHeight))
        // A third: the pane grows to make room for it.
        f.model.toggleWaveBand(de.id)
        XCTAssertEqual(f.model.waveBandTracks.count, 3)
        XCTAssertEqual(f.model.waveformPaneHeight(in: 1000, divider: divider),
                       WaveLayout.comfortableHeight(bands: 3, lanes: 0))
        // Closing one leaves the pane as it is.
        let grown = f.model.waveformPaneHeight(in: 1000, divider: divider)
        f.model.toggleWaveBand(de.id)
        XCTAssertEqual(f.model.waveformPaneHeight(in: 1000, divider: divider), grown)
    }

    func testThePaneGrowsOnlyAsFarAsThePictureCanGive() {
        let (f, de) = threeLanguages()
        let most = WaveLayout.minHeight(bands: 3, lanes: 0) + 10      // room for three, not comfortably
        f.model.editorHeight = most + AppModel.videoMinHeight + divider
        f.model.toggleWaveBand(f.hr.id)
        f.model.toggleWaveBand(de.id)
        XCTAssertEqual(f.model.waveBandTracks.count, 3)
        XCTAssertEqual(f.model.waveformPaneHeight(in: f.model.editorHeight, divider: divider), most)
    }

    func testWithNoRoomForTwoLinesEachTheLowestOpenLanguageCloses() {
        let (f, de) = threeLanguages()
        // Room for two open languages (and a slim lane), not three.
        let most = WaveLayout.minHeight(bands: 3, lanes: 0) - 1
        XCTAssertEqual(AppModel.bandRoom(languages: 3, paneHeight: most), 2)
        XCTAssertEqual(AppModel.bandRoom(languages: 3, paneHeight: most + 1), 3)
        XCTAssertEqual(AppModel.bandRoom(languages: 3, paneHeight: 10), 1, "always one")
        f.model.editorHeight = most + AppModel.videoMinHeight + divider
        XCTAssertEqual(f.model.waveBandRoom, 2)
        f.model.toggleWaveBand(f.hr.id)
        f.model.toggleWaveBand(de.id)
        XCTAssertEqual(f.model.waveBandTracks.map(\.id), [f.en.id, de.id], "Croatian, the lowest not in use, closed")
    }

    // MARK: Sharing the height between the open languages

    func testTheOpenLanguagesShareTheHeightButNoneGoesUnderTwoLines() {
        XCTAssertEqual(WaveLayout.bandHeights(weights: [1, 1, 1], area: 300, minimum: 56), [100, 100, 100])
        XCTAssertEqual(WaveLayout.bandHeights(weights: [1, 1, 1], area: 100, minimum: 20), [33, 33, 34],
                       "the last takes what rounding leaves")
        // Dragged apart (3 to 1): the smaller one keeps its two lines.
        XCTAssertEqual(WaveLayout.bandHeights(weights: [3, 1], area: 200, minimum: 56), [144, 56])
        XCTAssertEqual(WaveLayout.bandHeights(weights: [1, 6, 1], area: 300, minimum: 56), [56, 188, 56])
        // No room for every minimum: an equal share each.
        XCTAssertEqual(WaveLayout.bandHeights(weights: [3, 1, 1], area: 120, minimum: 56), [40, 40, 40])
        XCTAssertEqual(WaveLayout.bandHeights(weights: [], area: 120, minimum: 56), [])
    }

    // MARK: Stepping back

    func testAnotherLanguagesColoursStepBackAsItsColumnDoes() throws {
        let red = try XCTUnwrap(Palette.red.usingColorSpace(.sRGB))
        let back = try XCTUnwrap(Palette.steppedBack(Palette.red).usingColorSpace(.sRGB))
        let rim = try XCTUnwrap(Palette.steppedBack(Palette.red, saturation: StepBack.rimSaturation).usingColorSpace(.sRGB))
        func luminance(_ c: NSColor) -> CGFloat { 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent }
        // Less colour, the same brightness, fainter.
        XCTAssertEqual(luminance(back), luminance(red), accuracy: 0.001)
        XCTAssertEqual(back.redComponent - back.blueComponent,
                       (red.redComponent - red.blueComponent) * CGFloat(StepBack.saturation), accuracy: 0.001)
        XCTAssertEqual(back.alphaComponent, CGFloat(StepBack.opacity), accuracy: 0.001)
        // A warning rim keeps a little more.
        XCTAssertGreaterThan(rim.redComponent - rim.blueComponent, back.redComponent - back.blueComponent)
        XCTAssertGreaterThan(StepBack.rimSaturation, StepBack.saturation)
    }

    func testOverTheLimitDrawsMoreNoticeThanNearItInAnotherLanguage() {
        let over = Chip.muted("18.2 CPS", status: .bad, size: 10)
        let near = Chip.muted("15.9 CPS", status: .warn, size: 10)
        let fine = Chip.muted("9.0 CPS", status: .ok, size: 10)
        XCTAssertGreaterThan(over.rimWidth, near.rimWidth)
        XCTAssertNotNil(over.tint)
        XCTAssertNil(near.tint)
        XCTAssertNil(fine.outline)
        XCTAssertNotNil(near.outline)
    }
}
