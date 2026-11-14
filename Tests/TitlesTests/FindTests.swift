import XCTest
import AppKit
@testable import Titles

/// Find and Replace: matching what the viewer reads, keeping tags, going from match to
/// match, and replacing with undo.
@MainActor
final class FindTests: XCTestCase {

    private func strings(_ ranges: [NSRange], in text: String) -> [String] {
        ranges.map { (text as NSString).substring(with: $0) }
    }

    // MARK: Matching

    func testCaseIsIgnoredUnlessAskedFor() {
        let t = "Hello, hello. HELLO!"
        XCTAssertEqual(FindController.ranges(of: "hello", in: t, matchCase: false, wholeWord: false).count, 3)
        XCTAssertEqual(strings(FindController.ranges(of: "hello", in: t, matchCase: true, wholeWord: false), in: t), ["hello"])
    }

    func testWholeWordSkipsWordsThatOnlyContainIt() {
        let t = "cat concat cat. category"
        let r = FindController.ranges(of: "cat", in: t, matchCase: false, wholeWord: true)
        XCTAssertEqual(r.map(\.location), [0, 11])
        XCTAssertEqual(FindController.ranges(of: "cat", in: t, matchCase: false, wholeWord: false).count, 4)
    }

    func testAPhraseBrokenOverTwoLinesIsFound() {
        let t = "I said hello\nworld to him"
        let r = FindController.ranges(of: "hello world", in: t, matchCase: false, wholeWord: false)
        XCTAssertEqual(r, [NSRange(location: 7, length: 11)])
    }

    func testAccentsCount() {
        XCTAssertTrue(FindController.ranges(of: "cokolada", in: "čokolada", matchCase: false, wholeWord: false).isEmpty)
        XCTAssertEqual(FindController.ranges(of: "ČOKOLADA", in: "čokolada", matchCase: false, wholeWord: false).count, 1)
    }

    // MARK: Replacing inside tagged text

    func testReplacingKeepsFormatting() {
        XCTAssertEqual(FindController.replace(NSRange(location: 0, length: 5), in: "<i>Hello</i> world", with: "Bye"),
                       "<i>Bye</i> world")
        // Across the start of italics: the tag stays, just after the new words.
        XCTAssertEqual(FindController.replace(NSRange(location: 3, length: 6), in: "Hello <i>world</i>", with: "X"),
                       "HelX<i>ld</i>")
        XCTAssertEqual(FindController.replace(NSRange(location: 0, length: 5), in: "{\\an8}Hello there", with: "Hi"),
                       "{\\an8}Hi there")
        // Replaced with nothing: no empty <i></i> is left behind.
        XCTAssertEqual(FindController.replace(NSRange(location: 0, length: 3), in: "<i>Oh,</i> there", with: ""),
                       " there")
        // A range past the end changes nothing.
        XCTAssertEqual(FindController.replace(NSRange(location: 4, length: 9), in: "Short", with: "x"), "Short")
    }

    // MARK: Through the app

    private func fixture() -> (Fixture, [Subtitle]) {
        let subs = [sub(1, 2, "The cat sat"), sub(3, 4, "A dog"), sub(5, 6, "<i>Cat</i> and cat")]
        let f = makeFixture([("en", subs), ("hr", [sub(1, 2, "Mačka"), sub(5, 6, "cat i cat")])])
        return (f, subs)
    }

    func testFindGoesFromMatchToMatch() {
        let (f, subs) = fixture()
        let find = f.model.find
        find.show(replace: false)
        find.query = "cat"
        XCTAssertEqual(find.matches.count, 3)
        XCTAssertEqual(find.countText, "3 found")
        find.next()
        XCTAssertEqual(find.countText, "1 of 3")
        XCTAssertEqual(f.model.doc.selectedID, subs[0].id)
        XCTAssertEqual(f.engine.currentTime, 1, accuracy: 0.001)
        find.next()
        XCTAssertEqual(f.model.doc.selectedID, subs[2].id)
        find.next()
        find.next()
        XCTAssertEqual(find.countText, "1 of 3", "it wraps round")
        find.previous()
        XCTAssertEqual(find.countText, "3 of 3")
        XCTAssertEqual(find.highlights(in: subs[2].id).ranges.count, 2)
        XCTAssertEqual(find.highlights(in: subs[2].id).current, 1)
        find.close()
        XCTAssertTrue(find.highlights(in: subs[2].id).ranges.isEmpty)
    }

    func testFindStartsFromTheSelectedTitle() {
        let (f, subs) = fixture()
        f.model.select(subs[1].id)
        f.model.find.show(replace: false)
        f.model.find.query = "cat"
        f.model.find.next()
        XCTAssertEqual(f.model.doc.selectedID, subs[2].id)
    }

    func testNothingFoundSaysSo() {
        let (f, _) = fixture()
        f.model.find.show(replace: false)
        f.model.find.query = "zebra"
        XCTAssertEqual(f.model.find.countText, "Not found")
        f.model.find.next()
        XCTAssertTrue(f.model.statusMessage?.contains("not found") ?? false)
    }

    func testFindFollowsTheTextAsItChanges() {
        let (f, subs) = fixture()
        let find = f.model.find
        find.show(replace: false)
        find.query = "cat"
        f.en.doc.setText(subs[1].id, "A cat")
        f.model.rebuildRows()
        XCTAssertEqual(find.matches.count, 4)
    }

    func testAllOpenLanguages() {
        let (f, subs) = fixture()
        let find = f.model.find
        find.show(replace: false)
        find.scope = .allLanguages
        find.query = "cat"
        XCTAssertEqual(find.matches.count, 5)
        find.next(); find.next(); find.next(); find.next()
        // Same time: the master's matches come first, then the translation's.
        XCTAssertEqual(f.model.focusedTrack?.id, f.hr.id)
        XCTAssertNotEqual(f.model.doc.selectedID, subs[2].id)
    }

    func testSelectedTitlesOnly() {
        let (f, subs) = fixture()
        f.model.multiSelection = [subs[2].id]
        let find = f.model.find
        find.show(replace: false)
        find.scope = .selected
        find.query = "cat"
        XCTAssertEqual(find.matches.count, 2)
        XCTAssertTrue(find.matches.allSatisfy { $0.titleID == subs[2].id })
    }

    func testReplaceOneThenGoOn() {
        let (f, subs) = fixture()
        let find = f.model.find
        find.show(replace: true)
        find.query = "cat"
        find.replacement = "dog"
        find.next()
        find.replaceCurrent()
        XCTAssertEqual(f.en.doc.subtitle(subs[0].id)?.text, "The dog sat")
        XCTAssertEqual(find.matches.count, 2)
        XCTAssertEqual(find.countText, "1 of 2")
        XCTAssertEqual(f.model.doc.selectedID, subs[2].id)
        find.replaceCurrent()
        XCTAssertEqual(f.en.doc.subtitle(subs[2].id)?.text, "<i>dog</i> and cat", "italics kept")
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitle(subs[2].id)?.text, "<i>Cat</i> and cat")
        XCTAssertEqual(f.en.doc.subtitle(subs[0].id)?.text, "The dog sat", "each replace is its own undo step")
    }

    func testReplaceAllIsOneUndoPerLanguage() {
        let (f, subs) = fixture()
        let find = f.model.find
        find.show(replace: true)
        find.scope = .allLanguages
        find.query = "cat"
        find.replacement = "dog"
        XCTAssertEqual(find.replaceAll(), 5)
        XCTAssertEqual(f.en.doc.subtitle(subs[0].id)?.text, "The dog sat")
        XCTAssertEqual(f.en.doc.subtitle(subs[2].id)?.text, "<i>dog</i> and dog")
        XCTAssertEqual(f.hr.doc.subtitles.last?.text, "dog i dog")
        XCTAssertTrue(find.matches.isEmpty)
        f.model.undo()
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitle(subs[2].id)?.text, "<i>Cat</i> and cat")
        XCTAssertEqual(f.hr.doc.subtitles.last?.text, "cat i cat")
    }

    func testWholeWordReplaceAll() {
        let a = sub(1, 2, "cat concat cat")
        let f = makeFixture([("en", [a])])
        let find = f.model.find
        find.show(replace: true)
        find.wholeWord = true
        find.query = "cat"
        find.replacement = "dog"
        XCTAssertEqual(find.replaceAll(), 2)
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "dog concat dog")
    }
}
