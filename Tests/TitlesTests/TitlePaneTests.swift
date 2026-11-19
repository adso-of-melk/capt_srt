import XCTest
import SwiftUI
@testable import Titles
@testable import TitlesCore

/// The title pane: how wide it makes itself as languages open and close, how its columns
/// share it, and which columns step back.
@MainActor
final class TitlePaneTests: XCTestCase {

    private let total: CGFloat = 1500, divider: CGFloat = 8

    func testThePaneGrowsAndShrinksWithTheLanguages() {
        let f = makeFixture([("en", [sub(1, 2, "Short")])])
        XCTAssertEqual(f.model.cardColumnMinWidth, 240)
        // One language: a quarter of the window.
        XCTAssertEqual(f.model.cardPaneWidth(in: total, divider: divider), 375)
        // Two at full size fit within 40 % of the window: exactly as wide as they need.
        f.model.addLanguage(Language.named("hr"), locked: false, copyText: true)
        XCTAssertEqual(f.model.cardPaneWidth(in: total, divider: divider), 2 * 240 + 8 + 24)
        // Three don't: the pane stops at 40 % and the columns narrow.
        f.model.addLanguage(Language.named("de"), locked: false, copyText: true)
        XCTAssertEqual(f.model.cardPaneWidth(in: total, divider: divider), 600)
        f.model.addLanguage(Language.named("fr"), locked: false, copyText: true)
        XCTAssertEqual(f.model.cardPaneWidth(in: total, divider: divider), 600)
        // Closing languages shrinks it again.
        for track in f.model.openTracks.dropFirst() { f.model.closeColumn(track) }
        XCTAssertEqual(f.model.openTracks.count, 1)
        XCTAssertEqual(f.model.cardPaneWidth(in: total, divider: divider), 375)
    }

    func testAWidthDraggedByHandHoldsUntilALanguageOpensOrCloses() {
        let f = makeFixture([("en", [sub(1, 2, "Short")])])
        f.model.setCardPaneWidth(520, in: total, divider: divider)
        XCTAssertEqual(f.model.cardPaneWidth(in: total, divider: divider), 520)
        f.model.addLanguage(Language.named("hr"), locked: false, copyText: true)
        XCTAssertEqual(f.model.cardPaneWidth(in: total, divider: divider), 520)
        f.model.openColumnsChanged()       // what the window does when the count changes
        XCTAssertEqual(f.model.cardPaneWidth, 0)
        XCTAssertEqual(f.model.cardPaneWidth(in: total, divider: divider), 2 * 240 + 8 + 24)
    }

    func testThePictureAlwaysKeepsItsRoom() {
        let f = makeFixture([("en", [sub(1, 2, "Short")])])
        for code in ["hr", "de"] { f.model.addLanguage(Language.named(code), locked: false, copyText: true) }
        let small: CGFloat = 1000
        XCTAssertLessThanOrEqual(f.model.cardPaneWidth(in: small, divider: divider), small - AppModel.pictureMinWidth - divider)
    }

    func testTheWaveformDividerKeepsBothPanesTheirRoom() {
        let f = makeFixture([("en", [sub(1, 2, "Short")])])
        let height: CGFloat = 800
        // At first: the usual height.
        XCTAssertEqual(f.model.waveformPaneHeight(in: height, divider: divider), AppModel.waveformDefaultHeight)
        // Dragged, it holds.
        f.model.setWaveformPaneHeight(400, in: height, divider: divider)
        XCTAssertEqual(f.model.waveformPaneHeight(in: height, divider: divider), 400)
        // Never shorter than its minimum...
        f.model.setWaveformPaneHeight(20, in: height, divider: divider)
        XCTAssertEqual(f.model.waveformPaneHeight(in: height, divider: divider), AppModel.waveformMinHeight)
        // ...nor so tall that the picture gets less than its own.
        f.model.setWaveformPaneHeight(2000, in: height, divider: divider)
        XCTAssertEqual(f.model.waveformPaneHeight(in: height, divider: divider),
                       height - AppModel.videoMinHeight - divider)
        // A shorter window takes the room from the waveform, down to its minimum.
        XCTAssertEqual(f.model.waveformPaneHeight(in: 500, divider: divider), 500 - AppModel.videoMinHeight - divider)
        XCTAssertEqual(f.model.waveformPaneHeight(in: 300, divider: divider), AppModel.waveformMinHeight)
        // Double-click: back to the usual height.
        f.model.waveformPaneHeight = 0
        XCTAssertEqual(f.model.waveformPaneHeight(in: height, divider: divider), AppModel.waveformDefaultHeight)
    }

    func testDraggingADividerGrowsThePaneItMovesAwayFrom() {
        // Upright: the card pane on its left grows as the line goes right.
        XCTAssertEqual(PaneDivider.dragged(from: 500, to: 560, size: 400), 460)
        XCTAssertEqual(PaneDivider.dragged(from: 500, to: 450, size: 400), 350)
        // Lying flat: the waveform below it grows as the line goes up (window y grows upwards).
        XCTAssertEqual(PaneDivider.dragged(from: 300, to: 340, size: 260), 300)
        XCTAssertEqual(PaneDivider.dragged(from: 300, to: 250, size: 260), 210)
    }

    func testColumnsShareThePaneAndWholeColumnsFillItWhenTheyScroll() {
        // Three share 600 points (less the margins and gaps) equally.
        XCTAssertEqual(AppModel.cardColumnWidth(pane: 600, count: 3, floor: 150), (600 - 24 - 16) / 3, accuracy: 0.01)
        XCTAssertEqual(AppModel.cardColumnWidth(pane: 600, count: 1, floor: 150), 576, accuracy: 0.01)
        // Five would be narrower than the floor: three fill the pane, the others scroll.
        let five = AppModel.cardColumnWidth(pane: 600, count: 5, floor: 150)
        XCTAssertEqual(five, (600 - 24 - 16) / 3, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(five, 150)
        // Never narrower than the floor, however small the pane.
        XCTAssertEqual(AppModel.cardColumnWidth(pane: 100, count: 4, floor: 150), 150)
    }

    func testOnlyTheColumnsOutOfFocusStepBack() {
        let f = makeFixture([("en", [sub(1, 2, "Hello")])])
        XCTAssertFalse(f.model.columnStepsBack(f.en.id), "one language is always in focus")
        f.model.addLanguage(Language.named("hr"), locked: false, copyText: true)
        let focused = f.video.focusedTrackID
        for track in f.model.openTracks {
            XCTAssertEqual(f.model.columnStepsBack(track.id), track.id != focused)
        }
        f.model.focusTrack(f.en.id, edit: false)
        XCTAssertFalse(f.model.columnStepsBack(f.en.id))
        XCTAssertTrue(f.model.columnStepsBack(f.hr.id))
    }

    // MARK: The scroll bars

    func testTheScrollBarsReportWhereThePaneIs() {
        var m = CardScrollMetrics(offset: 0, content: 1000, viewport: 250)
        XCTAssertTrue(m.overflows)
        XCTAssertEqual(m.share, 0.25)
        XCTAssertEqual(m.position, 0)
        m.offset = 375
        XCTAssertEqual(m.position, 0.5)
        m.offset = 2000                      // past the end (a bounce): still the end
        XCTAssertEqual(m.position, 1)
        let fits = CardScrollMetrics(offset: 0, content: 200, viewport: 250)
        XCTAssertFalse(fits.overflows)
        XCTAssertEqual(fits.position, 0)
        XCTAssertEqual(fits.share, 1)
    }

    func testAPointOnTheBarGoesToTheRowThere() {
        // 100 rows, a quarter in view: the top of the bar is row 0, the middle row 38 (of the
        // 75 that can be at the top), the bottom the last row, at the bottom of the pane.
        XCTAssertEqual(CardScrollTracker.rowTarget(fraction: 0, count: 100, share: 0.25)?.index, 0)
        XCTAssertEqual(CardScrollTracker.rowTarget(fraction: -0.3, count: 100, share: 0.25)?.index, 0)
        XCTAssertEqual(CardScrollTracker.rowTarget(fraction: 0.5, count: 100, share: 0.25)?.index, 38)
        let end = CardScrollTracker.rowTarget(fraction: 1, count: 100, share: 0.25)
        XCTAssertEqual(end?.index, 99)
        XCTAssertEqual(end?.anchor, .bottom)
        XCTAssertNil(CardScrollTracker.rowTarget(fraction: 0.5, count: 0, share: 1))
    }
}
