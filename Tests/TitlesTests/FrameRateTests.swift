import XCTest
@testable import Titles
@testable import TitlesCore

/// Title ▸ Change Frame Rate…: titles made for a copy of the film at another rate.
@MainActor
final class FrameRateTests: XCTestCase {

    func testPALTitlesAreStretchedToAFilmCopy() {
        let f = makeFixture([("en", [sub(1, 2, "A"), sub(600, 603, "B")]),
                             ("hr", [sub(1, 2, "a"), sub(600, 603, "b")])])
        f.model.changeFrameRate(from: 25, to: 23.976, allLanguages: false)
        // 25 / (24000/1001) = 1.0427083…: ten minutes in, 25.6 s later.
        XCTAssertEqual(f.en.doc.subtitles.map(\.start), [1.043, 625.625])
        XCTAssertEqual(f.en.doc.subtitles.map(\.end), [2.085, 628.753])
        XCTAssertEqual(f.hr.doc.subtitles.map(\.start), [1, 600], "only this language")

        // One undo step.
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitles.map(\.start), [1, 600])
        XCTAssertEqual(f.en.doc.subtitles.map(\.end), [2, 603])
    }

    func testEveryLanguageAndBack() {
        let f = makeFixture([("en", [sub(10, 12, "A"), sub(1000, 1002, "B")]),
                             ("hr", [sub(10, 12, "a"), sub(1000, 1002, "b")])])
        f.model.changeFrameRate(from: 23.976, to: 25, allLanguages: true)
        XCTAssertEqual(f.en.doc.subtitles[1].start, 959.041, accuracy: 0.0005)
        XCTAssertEqual(f.hr.doc.subtitles[1].start, 959.041, accuracy: 0.0005)
        f.model.changeFrameRate(from: 25, to: 23.976, allLanguages: true)
        XCTAssertEqual(f.en.doc.subtitles[1].start, 1000, accuracy: 0.002)
        XCTAssertEqual(f.hr.doc.subtitles[0].end, 12, accuracy: 0.002)
    }

    func testTheSameRateChangesNothing() {
        let f = makeFixture([("en", [sub(1, 2, "A")])])
        f.model.changeFrameRate(from: 25, to: 25, allLanguages: false)
        XCTAssertEqual(f.en.doc.subtitles.map(\.start), [1])
        XCTAssertFalse(f.en.doc.canUndo)
    }

    func testALockedLanguageFollowsItsMaster() {
        let f = makeFixture([("en", [sub(100, 102, "Hello")])])
        f.model.addLanguage(Language.named("hr"), locked: true, copyText: false)
        XCTAssertTrue(f.model.focusedIsLocked)
        f.model.changeFrameRate(from: 25, to: 23.976, allLanguages: false)
        XCTAssertEqual(f.hr.doc.subtitles.map(\.start), [100], "refused: the language is locked")
        f.model.changeFrameRate(from: 25, to: 23.976, allLanguages: true)
        XCTAssertEqual(f.en.doc.subtitles[0].start, 104.271, accuracy: 0.0005)
        XCTAssertEqual(f.hr.doc.subtitles[0].start, f.en.doc.subtitles[0].start)
    }

    func testRoundedNTSCRatesAreTheExactOnes() {
        XCTAssertEqual(AppModel.exactRate(23.976), 24000 / 1001)
        XCTAssertEqual(AppModel.exactRate(29.97), 30000 / 1001)
        XCTAssertEqual(AppModel.exactRate(59.94), 60000 / 1001)
        XCTAssertEqual(AppModel.exactRate(25), 25)
    }
}
