import XCTest
import AppKit
@testable import Titles

/// Language Options: changing a column's language, its own limits, and spell check.
@MainActor
final class LanguageOptionsTests: XCTestCase {

    func testChangingALanguageTakesItsWordsAndExportNameAlong() {
        let f = makeFixture([("en", [sub(1, 2, "Hello")]), ("hr", [sub(1, 2, "Bok")])])
        f.model.addProjectWord("Zagreb", language: "hr")

        f.model.changeLanguage(f.hr, to: Language.named("sr-Latn"))

        XCTAssertEqual(f.hr.language, Language.named("sr-Latn"))
        XCTAssertEqual(f.model.project?.settings.spellingWords["sr-Latn"], ["Zagreb"])
        let names = f.model.exportItems(allLanguages: true, allVideos: false, format: .srt).map(\.name)
        XCTAssertTrue(names.contains("Film.sr-Latn.srt"), "\(names)")
        XCTAssertFalse(names.contains("Film.hr.srt"))
        // The master didn't change.
        XCTAssertEqual(f.model.project?.settings.masterLanguage, Language.named("en"))
    }

    func testAnyCodeAndNameCanBeTyped() {
        let f = makeFixture([("en", [sub(1, 2)]), ("hr", [sub(1, 2)])])
        f.model.changeLanguage(f.hr, to: Language(code: " cnr ", name: "Montenegrin "))
        XCTAssertEqual(f.hr.language, Language(code: "cnr", name: "Montenegrin"))
        // An empty code is never taken.
        f.model.changeLanguage(f.hr, to: Language(code: "  ", name: "Nothing"))
        XCTAssertEqual(f.hr.language.code, "cnr")
    }

    func testChangingTheMastersLanguageChangesTheProjectsMasterLanguage() {
        let f = makeFixture([("en", [sub(1, 2)])])
        f.model.changeLanguage(f.en, to: Language.named("en-GB"))
        XCTAssertEqual(f.model.project?.settings.masterLanguage, Language.named("en-GB"))
    }

    func testOptionsSetTheLanguagesOwnLimitsSpellCheckAndWords() {
        let f = makeFixture([("en", [sub(1, 2)]), ("hr", [sub(1, 2)])])
        f.model.addProjectWord("Zagreb", language: "hr")
        f.model.addProjectWord("Krapina", language: "hr")
        var o = LanguageOptions(f.hr, isMaster: false)
        XCTAssertTrue(o.spellCheck)
        XCTAssertNil(o.maxLines)
        o.maxCPS = 12
        o.maxLines = 1
        o.spellCheck = false
        o.removedWords = ["Zagreb"]

        f.model.applyLanguageOptions(f.hr, o)

        let rules = f.model.preset(for: f.hr)
        XCTAssertEqual(rules.maxCPS, 12)
        XCTAssertEqual(rules.maxLines, 1)
        XCTAssertEqual(rules.maxCharsPerLine, TimingPreset.general.maxCharsPerLine)
        XCTAssertFalse(f.model.checksSpelling(f.hr))
        XCTAssertTrue(f.model.checksSpelling(f.en))
        XCTAssertEqual(f.model.project?.settings.spellingWords["hr"], ["Krapina"])
        XCTAssertFalse(f.hr.locked)

        // Back to the project standard.
        o.maxCPS = nil
        o.maxLines = nil
        f.model.applyLanguageOptions(f.hr, o)
        XCTAssertEqual(f.model.preset(for: f.hr), TimingPreset.general)
    }

    func testOptionsCanMakeALanguageTheMaster() {
        let f = makeFixture([("en", [sub(1, 2)]), ("hr", [sub(1, 2)])])
        var o = LanguageOptions(f.hr, isMaster: false)
        o.makeMaster = true
        f.model.applyLanguageOptions(f.hr, o)
        XCTAssertEqual(f.video.masterTrackID, f.hr.id)
    }

    func testOlderProjectsOpenWithSpellCheckOnAndTheStandardLineCount() throws {
        let json = #"{"id":"\#(UUID().uuidString)","language":{"code":"hr","name":"Croatian"},"locked":false,"subtitles":[]}"#
        let file = try JSONDecoder().decode(TrackFile.self, from: Data(json.utf8))
        let track = Track(file)
        XCTAssertTrue(track.spellCheck)
        XCTAssertNil(track.maxLines)

        track.spellCheck = false
        track.maxLines = 3
        let again = Track(try JSONDecoder().decode(TrackFile.self, from: JSONEncoder().encode(track.file)))
        XCTAssertFalse(again.spellCheck)
        XCTAssertEqual(again.maxLines, 3)
    }
}
