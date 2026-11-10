import XCTest
@testable import Titles

/// How titles from different languages line up side by side.
@MainActor
final class RowsTests: XCTestCase {

    private func video(_ master: [Subtitle], _ other: [Subtitle]) -> VideoItem {
        let en = Track(language: Language.named("en"), subtitles: master)
        let item = VideoItem(name: "Film", url: nil, master: en)
        let hr = Track(language: Language.named("hr"), subtitles: other)
        item.tracks.append(hr)
        item.openTrackIDs.append(hr.id)
        return item
    }

    func testTitlesAtTheSameTimeShareARow() {
        XCTAssertTrue(RowBuilder.sameRow(sub(1, 2), sub(1.2, 2.5)))      // start within a quarter second
        XCTAssertTrue(RowBuilder.sameRow(sub(1, 3), sub(1.5, 3)))        // overlap most of the shorter one
        XCTAssertTrue(RowBuilder.sameRow(sub(1, 5), sub(3, 4)))          // one inside the other
        XCTAssertFalse(RowBuilder.sameRow(sub(1, 2), sub(1.8, 4)))       // only brush each other
        XCTAssertFalse(RowBuilder.sameRow(sub(1, 2), sub(2, 3)))         // one after the other
        XCTAssertFalse(RowBuilder.sameRow(sub(1, 2), sub(5, 6)))
    }

    func testRowsFollowTimeAndPairTheLanguages() {
        let a = sub(1, 2, "A"), b = sub(5, 6, "B"), c = sub(9, 10, "C")
        let ha = sub(1.1, 2.1, "a"), hx = sub(3, 4, "x"), hc = sub(9, 10, "c")
        let item = video([a, b, c], [ha, hx, hc])
        let en = item.tracks[0].id, hr = item.tracks[1].id
        let rows = RowBuilder.rows(for: item, tracks: item.openTracks)

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].cells[en]?.id, a.id)
        XCTAssertEqual(rows[0].cells[hr]?.id, ha.id)
        XCTAssertNil(rows[1].cells[en])
        XCTAssertEqual(rows[1].cells[hr]?.id, hx.id)
        XCTAssertEqual(rows[2].cells[en]?.id, b.id)
        XCTAssertNil(rows[2].cells[hr])
        XCTAssertEqual(rows[3].cells.count, 2)
        XCTAssertEqual(rows.map(\.time), rows.map(\.time).sorted())
    }

    func testTwoTitlesOfOneLanguageNeverShareARow() {
        let a = sub(1, 2, "A"), overlapping = sub(1.1, 1.8, "A2")
        let item = video([a, overlapping], [sub(1, 2, "a")])
        let rows = RowBuilder.rows(for: item, tracks: item.openTracks)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.cells.count }, 3)
    }

    func testOnlyTheGivenLanguagesAreLaidOut() {
        let item = video([sub(1, 2, "A")], [sub(1, 2, "a"), sub(3, 4, "b")])
        let rows = RowBuilder.rows(for: item, tracks: [item.tracks[0]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(RowBuilder.rows(for: item, tracks: []).isEmpty)
    }

    // MARK: Matching an imported language to the master

    func testImportedTitlesAreMatchedToTheMasterByTime() {
        let m1 = sub(1, 2), m2 = sub(3, 4), m3 = sub(6, 8)
        let linked = RowBuilder.linkByOverlap([sub(1.1, 2.2), sub(2.9, 3.5), sub(10, 11), sub(6.5, 7)],
                                              master: [m1, m2, m3])
        XCTAssertEqual(linked.map(\.start), [1.1, 2.9, 6.5, 10])
        XCTAssertEqual(linked[0].link, m1.id)
        XCTAssertEqual(linked[1].link, m2.id)
        XCTAssertEqual(linked[2].link, m3.id)
        XCTAssertNil(linked[3].link)
    }

    func testAMasterTitleIsMatchedOnlyOnce() {
        let m = sub(1, 3)
        let linked = RowBuilder.linkByOverlap([sub(1, 1.9), sub(2, 3)], master: [m])
        XCTAssertEqual(linked[0].link, m.id)
        XCTAssertNil(linked[1].link)

        // Master titles that already have a partner are skipped.
        let skipped = RowBuilder.linkByOverlap([sub(1, 3)], master: [m], skip: [m.id])
        XCTAssertNil(skipped[0].link)
    }

    func testABarelyTouchingTitleIsNotMatched() {
        let m = sub(1, 3)
        let linked = RowBuilder.linkByOverlap([sub(2.9, 5)], master: [m])
        XCTAssertNil(linked[0].link)
    }

    func testTheBestOverlapWins() {
        let m1 = sub(1, 2), m2 = sub(2, 4)
        let linked = RowBuilder.linkByOverlap([sub(1.5, 3.5)], master: [m1, m2])
        XCTAssertEqual(linked[0].link, m2.id)
    }
}
