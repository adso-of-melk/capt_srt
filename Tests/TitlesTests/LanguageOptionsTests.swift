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

    // MARK: Export

    func testEveryOfferedCodePageIsKnown() {
        for e in SubtitleFormats.legacyEncodings {
            XCTAssertNotNil(SubtitleFormats.encoding(named: e.name), e.name)
        }
    }

    func testALanguageCanExportInAnOlderCodePage() throws {
        let f = makeFixture([("en", [sub(1, 2, "Hello")]), ("hr", [sub(1, 2, "Čađa i šljive")])])
        var o = LanguageOptions(f.hr, isMaster: false)
        o.exportEncoding = "windows-1250"
        f.model.applyLanguageOptions(f.hr, o)

        let items = f.model.exportItems(allLanguages: true, allVideos: false, format: .srt)
        let hr = try XCTUnwrap(items.first { $0.name == "Film.hr.srt" })
        let en = try XCTUnwrap(items.first { $0.name == "Film.en.srt" })
        XCTAssertEqual(hr.lost, 0)
        let text = try XCTUnwrap(String(data: hr.data, encoding: .windowsCP1250))
        XCTAssertTrue(text.contains("Čađa i šljive"))
        XCTAssertNil(String(data: hr.data, encoding: .utf8))          // really not UTF-8
        XCTAssertNotNil(String(data: en.data, encoding: .utf8))       // other languages unchanged
    }

    func testCharactersACodePageCantHoldAreCounted() {
        let out = SubtitleFormats.encoded([sub(1, 2, "Kyoto 京都")], format: .srt, bom: false, crlf: false,
                                          encoding: "windows-1250")
        XCTAssertEqual(out.lost, 2)
        XCTAssertTrue(String(decoding: out.data, as: UTF8.self).contains("Kyoto ??"))
    }

    func testRightToLeftMarksGoOnEveryLineOnce() {
        let rlm = "\u{200F}"
        let marked = SubtitleFormats.withDirectionMarks("שלום!\n\(rlm)מה שלומך?\(rlm) ")
        XCTAssertEqual(marked, "\(rlm)שלום!\(rlm)\n\(rlm)מה שלומך?\(rlm)")
        XCTAssertEqual(SubtitleFormats.withDirectionMarks(marked), marked)

        XCTAssertTrue(Language.named("ar").isRightToLeft)
        XCTAssertTrue(Language.named("he").isRightToLeft)
        XCTAssertTrue(Language.named("fa").isRightToLeft)
        XCTAssertFalse(Language.named("hr").isRightToLeft)

        // Only when asked, and only for a right-to-left language.
        let f = makeFixture([("en", [sub(1, 2, "Hi!")]), ("he", [sub(1, 2, "שלום!")])])
        let plain = f.model.exportItems(allLanguages: true, allVideos: false, format: .srt)
        XCTAssertFalse(plain.contains { String(decoding: $0.data, as: UTF8.self).contains(rlm) })
        f.video.tracks[1].directionMarks = true
        f.en.directionMarks = true
        let items = f.model.exportItems(allLanguages: true, allVideos: false, format: .srt)
        let he = items.first { $0.name == "Film.he.srt" }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        let en = items.first { $0.name == "Film.en.srt" }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        XCTAssertTrue(he.contains("\(rlm)שלום!\(rlm)"))
        XCTAssertFalse(en.contains(rlm))
    }

    func testOlderProjectsOpenWithSpellCheckOnAndTheStandardLineCount() throws {
        let json = #"{"id":"\#(UUID().uuidString)","language":{"code":"hr","name":"Croatian"},"locked":false,"subtitles":[]}"#
        let file = try JSONDecoder().decode(TrackFile.self, from: Data(json.utf8))
        let track = Track(file)
        XCTAssertTrue(track.spellCheck)
        XCTAssertNil(track.maxLines)

        XCTAssertNil(track.exportEncoding)
        XCTAssertFalse(track.directionMarks)

        track.spellCheck = false
        track.maxLines = 3
        track.exportEncoding = "windows-1250"
        track.directionMarks = true
        let again = Track(try JSONDecoder().decode(TrackFile.self, from: JSONEncoder().encode(track.file)))
        XCTAssertFalse(again.spellCheck)
        XCTAssertEqual(again.maxLines, 3)
        XCTAssertEqual(again.exportEncoding, "windows-1250")
        XCTAssertTrue(again.directionMarks)
    }
}
