import XCTest
import AppKit
@testable import Titles

/// Several languages in one project: locks, columns, the master, importing files, and how
/// they share the window.
@MainActor
final class LanguagesTests: XCTestCase {

    // MARK: Adding and locking

    func testANewLanguageStartsFromTheMastersTiming() {
        let a = sub(1, 2, "Hello"), b = sub(3, 4, "World")
        let f = makeFixture([("en", [a, b])])

        f.model.addLanguage(Language.named("hr"), locked: false, copyText: false)
        XCTAssertEqual(f.video.tracks.count, 2)
        XCTAssertEqual(f.hr.doc.subtitles.map(\.start), [1, 3])
        XCTAssertEqual(f.hr.doc.subtitles.map(\.end), [2, 4])
        XCTAssertEqual(f.hr.doc.subtitles.map(\.text), ["", ""])
        XCTAssertEqual(f.hr.doc.subtitles.compactMap(\.link), [a.id, b.id])
        XCTAssertEqual(f.video.openTrackIDs, [f.en.id, f.hr.id])
        XCTAssertEqual(f.video.focusedTrackID, f.hr.id)           // you go straight to it
        XCTAssertTrue(f.model.doc === f.hr.doc)
        XCTAssertEqual(f.model.rows.count, 2)

        f.model.addLanguage(Language.named("de"), locked: false, copyText: true)
        XCTAssertEqual(f.video.tracks[2].doc.subtitles.map(\.text), ["Hello", "World"])
    }

    func testALockedLanguageKeepsTheMastersTimingAndOnlyItsTextChanges() throws {
        let a = sub(1, 2, "Hello"), b = sub(3, 4, "World")
        let f = makeFixture([("en", [a, b])])
        f.model.addLanguage(Language.named("hr"), locked: true, copyText: false)
        let hr = f.hr
        XCTAssertTrue(f.model.focusedIsLocked)

        let first = hr.doc.subtitles[0]
        hr.doc.setText(first.id, "Bok")
        XCTAssertEqual(hr.doc.subtitle(first.id)?.text, "Bok")

        // Anything that would change the timing is refused.
        f.model.select(first.id)
        f.model.nudge(.end, by: 0.5)
        f.model.deleteSelected()
        f.model.splitTitle(first.id, at: 1.5)
        f.model.createTitle(start: 10, end: 11)
        f.model.shiftTitles(by: 1, onlySelected: false, allLanguages: false)
        XCTAssertEqual(hr.doc.subtitles.map(\.start), [1, 3])
        XCTAssertEqual(hr.doc.subtitles.map(\.end), [2, 4])

        // The master moves: the locked language moves with it and keeps its words.
        f.en.doc.update(a.id) { $0.start = 1.2; $0.end = 2.4 }
        let moved = try XCTUnwrap(hr.doc.subtitle(first.id))
        XCTAssertEqual(moved.start, 1.2)
        XCTAssertEqual(moved.end, 2.4)
        XCTAssertEqual(moved.text, "Bok")

        // A master title removed or added is removed or added here too.
        f.en.doc.delete(b.id)
        XCTAssertEqual(hr.doc.subtitles.count, 1)
        let added = f.en.doc.add(start: 5, end: 6, text: "New")
        XCTAssertEqual(hr.doc.subtitles.count, 2)
        XCTAssertEqual(hr.doc.subtitles[1].start, 5)
        XCTAssertEqual(hr.doc.subtitles[1].text, "")
        XCTAssertEqual(hr.doc.subtitles[1].link, added)

        // Moving every language moves the locked one through its master.
        f.model.shiftTitles(by: 1, onlySelected: false, allLanguages: true)
        XCTAssertEqual(f.en.doc.subtitles.map(\.start), [2.2, 6])
        XCTAssertEqual(hr.doc.subtitles.map(\.start), [2.2, 6])
        XCTAssertEqual(hr.doc.subtitles[0].text, "Bok")
    }

    func testAnUnlockedLanguageGoesItsOwnWay() throws {
        let a = sub(1, 2, "Hello")
        let f = makeFixture([("en", [a])])
        f.model.addLanguage(Language.named("hr"), locked: true, copyText: false)
        let hr = f.hr
        let first = hr.doc.subtitles[0]

        f.model.setLocked(hr, false)
        XCTAssertFalse(hr.locked)
        f.model.select(first.id)
        f.model.nudge(.end, by: 0.2)
        f.model.doc.commitLive()
        XCTAssertEqual(try XCTUnwrap(hr.doc.subtitle(first.id)).end, 2.2, accuracy: 0.0001)

        f.en.doc.update(a.id) { $0.start = 0.5 }
        XCTAssertEqual(hr.doc.subtitle(first.id)?.start, 1)
        // The master itself can't be locked.
        f.model.setLocked(f.en, true)
        XCTAssertFalse(f.en.locked)
    }

    func testAnotherLanguageCanBecomeTheMaster() {
        let a = sub(1, 2, "A"), b = sub(3, 4, "B")
        let ha = sub(1, 2, "a"), hb = sub(3, 4, "b"), only = sub(7, 8, "only here")
        let f = makeFixture([("en", [a, b]), ("hr", [ha, hb, only])])
        XCTAssertEqual(f.hr.doc.subtitles.compactMap(\.link), [a.id, b.id])

        f.model.setMaster(f.hr)
        XCTAssertEqual(f.video.masterTrackID, f.hr.id)
        XCTAssertTrue(f.hr.doc.subtitles.allSatisfy { $0.link == nil })
        XCTAssertEqual(f.en.doc.subtitles.compactMap(\.link), [ha.id, hb.id])
        XCTAssertEqual(f.model.rows.count, 3)
        XCTAssertFalse(f.en.doc.canUndo)                          // re-pointing links isn't an edit
    }

    // MARK: Columns

    func testOpeningClosingAndReorderingColumns() {
        let a = sub(1, 2, "A"), ha = sub(1, 2, "a"), hx = sub(5, 6, "x")
        let f = makeFixture([("en", [a]), ("hr", [ha, hx])])
        XCTAssertEqual(f.model.rows.count, 2)

        f.model.focusTrack(f.hr.id, edit: false)
        f.model.closeColumn(f.hr)
        XCTAssertEqual(f.video.openTrackIDs, [f.en.id])
        XCTAssertEqual(f.video.focusedTrackID, f.en.id)           // focus moves to a column that's still open
        XCTAssertTrue(f.model.doc === f.en.doc)
        XCTAssertEqual(f.model.rows.count, 1)                     // rows are built from the open columns
        XCTAssertEqual(f.video.tracks.count, 2)                   // closing a column deletes nothing

        f.model.closeColumn(f.en)                                 // the last column stays
        XCTAssertEqual(f.video.openTrackIDs, [f.en.id])

        f.model.openColumn(f.hr)
        XCTAssertEqual(f.video.openTrackIDs, [f.en.id, f.hr.id])
        XCTAssertEqual(f.video.focusedTrackID, f.hr.id)
        XCTAssertEqual(f.model.rows.count, 2)

        f.model.moveColumn(f.hr, by: -1)
        XCTAssertEqual(f.video.openTrackIDs, [f.hr.id, f.en.id])
        f.model.moveColumn(f.hr, by: -1)                          // already first
        XCTAssertEqual(f.video.openTrackIDs, [f.hr.id, f.en.id])
    }

    func testMovingFocusBetweenLanguages() {
        let a = sub(1, 2, "A"), b = sub(5, 6, "B"), ha = sub(1, 2, "a")
        let f = makeFixture([("en", [a, b]), ("hr", [ha])])
        f.model.select(a.id)
        f.model.focusAdjacentTrack(1)
        XCTAssertEqual(f.video.focusedTrackID, f.hr.id)
        XCTAssertEqual(f.hr.doc.selectedID, ha.id)                // same row, other language
        f.model.focusAdjacentTrack(1)                             // wraps around
        XCTAssertEqual(f.video.focusedTrackID, f.en.id)
        f.model.focusAdjacentTrack(-1)
        XCTAssertEqual(f.video.focusedTrackID, f.hr.id)
        f.model.focusTrack(atColumn: 0)
        XCTAssertEqual(f.video.focusedTrackID, f.en.id)
        f.model.focusTrack(atColumn: 7)                           // no such column
        XCTAssertEqual(f.video.focusedTrackID, f.en.id)

        // On a row the other language has no title for, its empty slot is selected.
        f.model.select(b.id)
        f.model.focusTrack(f.hr.id, edit: false)
        XCTAssertNil(f.hr.doc.selectedID)
        XCTAssertEqual(f.model.emptySlotRow, f.model.rowKey(ofSub: b.id))
        // Tab from an empty slot goes to the next title in this language.
        f.model.selectAdjacent(-1)
        XCTAssertEqual(f.hr.doc.selectedID, ha.id)
        XCTAssertNil(f.model.emptySlotRow)
    }

    // MARK: Languages on the waveform

    func testALanguageOpenedOnTheWaveformStaysOpenWhenYouClickIntoIt() {
        let f = makeFixture([("en", [sub(1, 2, "A")]), ("hr", [sub(1, 2, "a")])])
        XCTAssertFalse(f.model.allWaveBands)

        f.model.setWaveBand(f.hr.id, shown: true)
        // The language you were on is kept open too…
        XCTAssertEqual(f.model.waveBands, [f.en.id, f.hr.id])
        // …so it doesn't fold away when focus moves to the one just opened.
        f.model.focusTrack(f.hr.id, edit: false)
        XCTAssertTrue(f.model.waveBands.contains(f.en.id))
        XCTAssertTrue(f.model.allWaveBands)

        f.model.setWaveBand(f.en.id, shown: false)
        XCTAssertEqual(f.model.waveBands, [f.hr.id])
        f.model.allWaveBands = true
        XCTAssertEqual(f.model.waveBands, [f.en.id, f.hr.id])
        f.model.allWaveBands = false
        XCTAssertTrue(f.model.waveBands.isEmpty)
    }

    // MARK: Sharing the window

    private let wide = "I never thought I would see you again, ever"

    func testTheCardPaneNeverGetsNarrowerThanItsColumnsCanShrink() {
        let f = makeFixture([("en", [sub(1, 2, "Short")])])
        XCTAssertEqual(f.model.cardColumnMinWidth, 240)
        XCTAssertEqual(f.model.cardColumnFloor, 150)
        XCTAssertEqual(f.model.cardPaneMinWidth, 300)

        // A long line asks for a wider column at full size…
        let id = f.en.doc.subtitles[0].id
        f.en.doc.setText(id, wide)
        f.model.rebuildRows()
        let font = NSFont.systemFont(ofSize: CardView.baseFontSize, weight: .medium)
        let line = (wide as NSString).size(withAttributes: [.font: font]).width
        let full = min(440, max(240, ceil(line) + 44))
        XCTAssertEqual(f.model.cardColumnMinWidth, full, accuracy: 0.5)
        XCTAssertGreaterThan(full, 240)
        // …and may shrink to where that line fits at half size (measured, not halved).
        let small = NSFont.systemFont(ofSize: CardView.baseFontSize * 0.5, weight: .medium)
        let half = (wide as NSString).size(withAttributes: [.font: small]).width
        let floor = max(150, min(ceil(half) + 44, ((full - 44) * 0.6 + 44).rounded()))
        XCTAssertEqual(f.model.cardColumnFloor, floor, accuracy: 0.5)
        XCTAssertLessThan(f.model.cardColumnFloor, f.model.cardColumnMinWidth)
        // At that narrowest width the line still fits on one line in its card.
        let room = f.model.cardColumnFloor - 40
        let size = CardView.fittingSize(for: wide, width: room)
        let fitted = (wide as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)]).width
        XCTAssertLessThanOrEqual(fitted, room + 0.5)

        // Three languages side by side need three such columns and the gaps between them.
        f.model.addLanguage(Language.named("hr"), locked: false, copyText: true)
        f.model.addLanguage(Language.named("de"), locked: false, copyText: true)
        XCTAssertEqual(f.model.cardPaneMinWidth, 3 * f.model.cardColumnFloor + 2 * 8 + 24, accuracy: 0.5)
    }

    func testCardTextShrinksToKeepItsLinesButNotBelowHalfSize() {
        XCTAssertEqual(CardView.fittingSize(for: "Short", width: 200), 15)
        XCTAssertEqual(CardView.fittingSize(for: "", width: 200), 15)
        XCTAssertEqual(CardView.fittingSize(for: wide, width: 1000), 15)

        let squeezed = CardView.fittingSize(for: wide, width: 220)
        XCTAssertLessThan(squeezed, 15)
        XCTAssertGreaterThanOrEqual(squeezed, 7.5)
        XCTAssertEqual((squeezed * 2).rounded(), squeezed * 2)     // whole half points
        // At that size the line really fits the width (small text is spaced a little wider,
        // so shrinking in proportion alone would leave it too wide and it would wrap).
        let font = NSFont.systemFont(ofSize: squeezed, weight: .medium)
        XCTAssertLessThanOrEqual((wide as NSString).size(withAttributes: [.font: font]).width, 220)

        XCTAssertEqual(CardView.fittingSize(for: wide, width: 40), 7.5)
        // The longest line decides.
        XCTAssertEqual(CardView.fittingSize(for: "Hi\n" + wide, width: 220), squeezed)
    }

    // MARK: Importing subtitle files

    private let englishFile = "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n"
    private let croatianFile = "1\r\n00:00:01,100 --> 00:00:02,100\r\nBok\r\n\r\n2\r\n00:00:10,000 --> 00:00:11,000\r\nKasnije\r\n"

    func testImportingAFileAddsALanguageMatchedToTheMasterByTime() throws {
        let a = sub(1, 2, "Hello"), b = sub(3, 4, "World")
        let f = makeFixture([("en", [a, b])])
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try writeFile("Film.hr.srt", croatianFile, in: folder)

        let done = expectation(description: "imported")
        f.model.importLanguage(from: url, as: Language.named("hr")) { done.fulfill() }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(f.video.tracks.count, 2)
        XCTAssertEqual(f.hr.language.code, "hr")
        XCTAssertEqual(f.hr.doc.subtitles.map(\.text), ["Bok", "Kasnije"])
        XCTAssertEqual(f.hr.doc.subtitles[0].link, a.id)
        XCTAssertNil(f.hr.doc.subtitles[1].link)
        XCTAssertFalse(f.hr.locked)
        XCTAssertEqual(f.video.openTrackIDs, [f.en.id, f.hr.id])
        XCTAssertEqual(f.video.focusedTrackID, f.hr.id)
        XCTAssertEqual(f.model.rows.count, 3)
        XCTAssertNil(f.hr.doc.selectedID)
        XCTAssertFalse(f.hr.doc.canUndo)
    }

    func testImportingIntoAnEmptyLanguageFillsItInsteadOfAddingAnother() throws {
        let f = makeFixture([("en", []), ("hr", [])])
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let en = try writeFile("Film.en.srt", englishFile, in: folder)
        let hr = try writeFile("Film.hr.srt", croatianFile, in: folder)

        let first = expectation(description: "master imported")
        f.model.importLanguage(from: en, as: Language.named("en")) { first.fulfill() }
        wait(for: [first], timeout: 10)
        XCTAssertEqual(f.video.tracks.count, 2)
        XCTAssertEqual(f.en.doc.subtitles.map(\.text), ["Hello", "World"])
        XCTAssertTrue(f.en.doc.subtitles.allSatisfy { $0.link == nil })

        let second = expectation(description: "translation imported")
        f.model.importLanguage(from: hr, as: Language.named("hr")) { second.fulfill() }
        wait(for: [second], timeout: 10)
        XCTAssertEqual(f.video.tracks.count, 2)
        XCTAssertEqual(f.hr.doc.subtitles.map(\.text), ["Bok", "Kasnije"])
        XCTAssertEqual(f.hr.doc.subtitles[0].link, f.en.doc.subtitles[0].id)
    }

    func testANewProjectTakesSeveralSubtitleFilesAtOnce() throws {
        let (model, _) = makeModel()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let en = try writeFile("Film.en.srt", englishFile, in: folder)
        let hr = try writeFile("Film.hr.srt", croatianFile, in: folder)
        var settings = ProjectSettings()
        settings.masterLanguage = Language.named("en")

        // The translation is listed first on purpose: the master's file still fills the master.
        model.createProject(name: "Several: files?", folder: folder, video: nil, settings: settings,
                            subtitleFiles: [(url: hr, language: Language.named("hr")),
                                            (url: en, language: Language.named("en"))],
                            extraLanguages: [Language.named("de"), Language.named("hr")])
        let ready = waitUntil { model.video?.tracks.count == 3 }
        XCTAssertTrue(ready, "the files were not all imported")

        let video = try XCTUnwrap(model.video)
        XCTAssertEqual(model.project?.name, "Several- files-")
        XCTAssertEqual(video.tracks.map(\.language.code), ["en", "hr", "de"])
        XCTAssertEqual(video.master?.doc.subtitles.map(\.text), ["Hello", "World"])
        XCTAssertEqual(video.tracks[1].doc.subtitles.map(\.text), ["Bok", "Kasnije"])
        XCTAssertEqual(video.tracks[1].doc.subtitles[0].link, video.master?.doc.subtitles[0].id)
        // A language asked for without a file starts blank from the master's timing.
        XCTAssertEqual(video.tracks[2].doc.subtitles.map(\.start), [1, 3])
        XCTAssertEqual(video.tracks[2].doc.subtitles.map(\.text), ["", ""])
        XCTAssertEqual(video.openTrackIDs.count, 3)
        XCTAssertEqual(video.focusedTrackID, video.masterTrackID)
        XCTAssertFalse(model.showHome)
        // The tests never write a project to disk.
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["Film.en.srt", "Film.hr.srt"])
    }

    func testFilesStillLoadingNeverLandInAProjectOpenedMeanwhile() throws {
        let (model, _) = makeModel()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let en = try writeFile("Film.en.srt", englishFile, in: folder)
        let hr = try writeFile("Film.hr.srt", croatianFile, in: folder)
        model.createProject(name: "First", folder: folder, video: nil, settings: ProjectSettings(),
                            subtitleFiles: [(url: en, language: Language.named("en")),
                                            (url: hr, language: Language.named("hr"))])

        // Before those files have been read, another project is opened.
        let own = sub(20, 21, "Mine")
        let master = Track(language: Language.named("en"), subtitles: [own])
        let other = VideoItem(name: "Other", url: nil, master: master)
        model.load(Project(name: "Second", settings: ProjectSettings(), videos: [other], fileURL: nil),
                   currentVideoID: other.id)

        _ = waitUntil(timeout: 1.5) { false }                     // give the file reads time to finish
        XCTAssertEqual(model.project?.name, "Second")
        XCTAssertEqual(other.tracks.count, 1)
        XCTAssertEqual(master.doc.subtitles, [own])
    }
}
