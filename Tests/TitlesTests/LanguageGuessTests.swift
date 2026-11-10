import XCTest
@testable import Titles

/// Guessing a subtitle file's language from its name and its words.
@MainActor
final class LanguageGuessTests: XCTestCase {

    private func code(_ name: String, lastWordOnly: Bool = false) -> String? {
        LanguageGuess.fromName(name, lastWordOnly: lastWordOnly)?.code
    }

    func testLanguageCodesAtTheEndOfTheName() {
        XCTAssertEqual(code("Film.en"), "en")
        XCTAssertEqual(code("Film_HR"), "hr")
        XCTAssertEqual(code("Film HR"), "hr")
        XCTAssertEqual(code("Film-de"), "de")
        XCTAssertEqual(code("Movie (DE)"), "de")
        XCTAssertEqual(code("Film.2024.1080p.en"), "en")
        XCTAssertEqual(code("Film.pt-BR"), "pt-BR")
        XCTAssertEqual(code("Film_sr-Latn"), "sr-Latn")
        XCTAssertEqual(code("Film.zh-Hans"), "zh-Hans")
    }

    func testThreeLetterCodesAndLanguageNames() {
        XCTAssertEqual(code("Film ENG"), "en")
        XCTAssertEqual(code("Film.hrv"), "hr")
        XCTAssertEqual(code("Film.srp"), "sr-Latn")
        XCTAssertEqual(code("Film croatian"), "hr")
        XCTAssertEqual(code("Film - Hrvatski"), "hr")
        XCTAssertEqual(code("Film - Français"), "fr")
        XCTAssertEqual(code("Deutsch"), "de")
    }

    func testOrdinaryWordsAreNotTakenForLanguages() {
        XCTAssertNil(code("What Is It"))
        XCTAssertNil(code("Leave It To Me"))
        XCTAssertNil(code("Film"))
        XCTAssertNil(code("Episode 12"))
        XCTAssertNil(code(""))
    }

    func testALanguageAtTheEndBeatsAWordInTheTitle() {
        XCTAssertEqual(code("The English Patient.hr"), "hr")
        XCTAssertEqual(code("The Italian Job_DE"), "de")
    }

    func testAWordInTheFilmTitleIsOnlyALastResort() {
        // Counted when nothing better is known…
        XCTAssertEqual(code("The English Patient"), "en")
        // …but not as the strong signal that skips reading the file.
        XCTAssertNil(code("The English Patient", lastWordOnly: true))
        XCTAssertNil(code("The Italian Job", lastWordOnly: true))
        XCTAssertNil(code("The Rum Diary", lastWordOnly: true))
        XCTAssertNil(code("Dan in Real Life", lastWordOnly: true))
        XCTAssertEqual(code("Film croatian", lastWordOnly: true), "hr")
        XCTAssertEqual(code("Film.en", lastWordOnly: true), "en")
    }

    // MARK: From the file itself

    private let english = """
    1
    00:00:01,000 --> 00:00:03,000
    I never thought I would see you again.

    2
    00:00:04,000 --> 00:00:06,000
    We have to leave before it gets dark outside.

    3
    00:00:07,000 --> 00:00:09,000
    Tell the captain that the engines are ready.

    4
    00:00:10,000 --> 00:00:12,000
    She said she would be here by now. Something is wrong.

    """

    private let croatian = """
    1
    00:00:01,000 --> 00:00:03,000
    Nisam znao da ćeš doći, ali drago mi je što si ovdje.

    2
    00:00:04,000 --> 00:00:06,000
    Moramo krenuti prije nego što padne mrak.

    3
    00:00:07,000 --> 00:00:09,000
    Recite kapetanu da su strojevi spremni.

    4
    00:00:10,000 --> 00:00:12,000
    Rekla je da će već biti ovdje. Nešto nije u redu.

    """

    func testTheWordsDecideWhenTheNameSaysNothing() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = try writeFile("Film.srt", english, in: folder)
        XCTAssertEqual(LanguageGuess.language(of: plain)?.code, "en")
        let hr = try writeFile("Episode 12.srt", croatian, in: folder)
        XCTAssertEqual(LanguageGuess.language(of: hr)?.code, "hr")
    }

    func testAFilmTitleDoesNotOverrideTheWords() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try writeFile("The Italian Job.srt", english, in: folder)
        XCTAssertEqual(LanguageGuess.language(of: url)?.code, "en")
        let rum = try writeFile("The Rum Diary.srt", croatian, in: folder)
        XCTAssertEqual(LanguageGuess.language(of: rum)?.code, "hr")
    }

    func testTheNameWinsWhenItEndsWithALanguage() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try writeFile("Film.hr.srt", english, in: folder)
        XCTAssertEqual(LanguageGuess.language(of: url)?.code, "hr")
    }

    func testWindowsLineEndingsAndOldEncodingsAreRead() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let windows = croatian.replacingOccurrences(of: "\n", with: "\r\n")
        let utf8 = try writeFile("One.srt", windows, in: folder)
        XCTAssertEqual(LanguageGuess.language(of: utf8)?.code, "hr")
        let old = try writeFile("Two.srt", windows, in: folder, encoding: .windowsCP1250)
        XCTAssertEqual(LanguageGuess.language(of: old)?.code, "hr")
    }

    func testAFileWithNoWordsGivesNoGuess() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let empty = try writeFile("Film.srt", "1\n00:00:01,000 --> 00:00:02,000\n\n", in: folder)
        XCTAssertNil(LanguageGuess.language(of: empty))
        XCTAssertNil(LanguageGuess.language(of: folder.appendingPathComponent("Missing.srt")))
    }

    func testLanguageNames() {
        XCTAssertEqual(Language.named("HR").name, "Croatian")
        XCTAssertEqual(Language.named("sr-latn").code, "sr-Latn")
        XCTAssertEqual(Language.named("xx").name, "xx")
        XCTAssertEqual(Set(Language.common.map(\.code)).count, Language.common.count)
    }
}
