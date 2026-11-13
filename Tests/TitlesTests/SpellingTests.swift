import XCTest
import AppKit
@testable import Titles

/// Spell check with a tiny made-up dictionary ("xx"), so the results never depend on the
/// dictionaries installed on the Mac running the tests. Nothing is written to the Mac.
@MainActor
final class SpellingTests: XCTestCase {
    /// Puts the test dictionaries in place (and nothing else), for one test.
    private func useTestDictionaries() throws {
        let folder = try tempFolder()
        _ = try writeFile("xx.aff", "SET UTF-8\nTRY aeioućčkhlwrdtsn\n", in: folder)
        _ = try writeFile("xx.dic", "6\nhello\nworld\nkuća\nthe\nsat\ncat\n", in: folder)
        // An older dictionary in a one-byte character set, as some still are.
        _ = try writeFile("yy.aff", "SET ISO8859-2\nTRY aeioućčkh\n", in: folder, encoding: latin2)
        _ = try writeFile("yy.dic", "2\nkuća\nčaša\n", in: folder, encoding: latin2)
        let spell = SpellService.shared
        spell.persists = false
        spell.extraFolders = [folder]
        spell.projectWords = [:]
        spell.reloadDictionaries()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    }

    private let latin2 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.isoLatin2.rawValue)))

    private func words(_ text: String, _ code: String = "xx") -> [String] {
        SpellService.shared.misspelled(in: text, language: code).map { (text as NSString).substring(with: $0) }
    }

    func testMisspelledWordsAreFound() throws {
        try useTestDictionaries()
        XCTAssertEqual(words("Hello wrld"), ["wrld"])
        XCTAssertEqual(words("hello world"), [])
        XCTAssertEqual(words("HELLO kuća, kuca!"), ["kuca"])
    }

    func testTagsAndNumbersAreNotChecked() throws {
        try useTestDictionaries()
        XCTAssertEqual(words("{\\an8}Hello <font color=\"red\">wrld</font>"), ["wrld"])
        XCTAssertEqual(words("<i>hello</i> R2D2 1984"), [])
    }

    func testSuggestions() throws {
        try useTestDictionaries()
        XCTAssertTrue(SpellService.shared.suggestions(for: "kuca", language: "xx").contains("kuća"))
        XCTAssertTrue(SpellService.shared.suggestions(for: "wrld", language: "xx").contains("world"))
    }

    func testADictionaryInAnOlderCharacterSetWorks() throws {
        try useTestDictionaries()
        XCTAssertEqual(HunspellDictionary.encoding(named: "ISO8859-2"), latin2)
        XCTAssertEqual(HunspellDictionary.encoding(named: "UTF-8"), .utf8)
        XCTAssertEqual(words("kuća čaša", "yy"), [])
        XCTAssertEqual(words("kuca", "yy"), ["kuca"])
        // A word the dictionary's character set can't write is simply wrong, not a crash.
        XCTAssertEqual(words("кућа", "yy"), ["кућа"])
    }

    func testALanguageWithNoDictionaryIsNotChecked() throws {
        try useTestDictionaries()
        XCTAssertFalse(SpellService.shared.hasDictionary(for: "qq"))
        XCTAssertEqual(words("anything goes", "qq"), [])
    }

    func testDictionaryNames() throws {
        try useTestDictionaries()
        XCTAssertEqual(SpellService.dictionaryNames(for: "hr"), ["hr"])
        XCTAssertEqual(SpellService.dictionaryNames(for: "pt-BR"), ["pt-BR", "pt_BR", "pt"])
        // Latin-script Serbian must never fall back to the Cyrillic "sr" dictionary.
        XCTAssertEqual(SpellService.dictionaryNames(for: "sr-Latn"), ["sr-Latn", "sr_Latn"])
        XCTAssertEqual(SpellService.dictionaryNames(for: "sr-Cyrl"), ["sr-Cyrl", "sr_Cyrl", "sr"])
    }

    func testWordsAreSplitTheWayTheLanguageSplitsThem() throws {
        try useTestDictionaries()
        let text = "Hello, world!"
        let found = SpellService.words(in: text, language: "en").map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(found, ["Hello", "world"])
        // Thai has no spaces between words.
        XCTAssertGreaterThanOrEqual(SpellService.words(in: "สวัสดีครับ", language: "th").count, 2)
    }

    func testLearnedWordsAreRightAndNeverWrittenFromTests() throws {
        try useTestDictionaries()
        XCTAssertEqual(words("wrld"), ["wrld"])
        SpellService.shared.learn("wrld", language: "xx")
        XCTAssertEqual(words("wrld"), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SpellService.wordsFolder.appendingPathComponent("xx.txt").path))
    }

    func testProjectWordsAreSavedInTheProject() throws {
        try useTestDictionaries()
        let f = makeFixture([("xx", [sub(1, 2, "hello Zagreb"), sub(3, 4, "the cat sat")])])
        XCTAssertEqual(words("Zagreb"), ["Zagreb"])
        f.model.addProjectWord("Zagreb", language: "xx")
        XCTAssertEqual(words("Zagreb"), [])
        XCTAssertEqual(f.model.project?.settings.spellingWords["xx"], ["Zagreb"])
        // Saved with the project's settings, and read back.
        let data = try JSONEncoder().encode(f.model.project!.settings)
        let back = try JSONDecoder().decode(ProjectSettings.self, from: data)
        XCTAssertEqual(back.spellingWords["xx"], ["Zagreb"])
        // A project saved before there were project words still opens.
        let old = try JSONDecoder().decode(ProjectSettings.self, from: Data("{\"crlf\": false}".utf8))
        XCTAssertEqual(old.spellingWords, [:])
        XCTAssertFalse(old.crlf)
    }

    func testNextMisspellingGoesToTheNextTitleWithOne() throws {
        try useTestDictionaries()
        let a = sub(1, 2, "hello world"), b = sub(3, 4, "the cat sat"), c = sub(5, 6, "hello wrld")
        let f = makeFixture([("xx", [a, b, c])])
        XCTAssertEqual(f.model.nextMisspelling(), c.id)
        XCTAssertEqual(f.model.doc.selectedID, c.id)
        XCTAssertTrue(f.model.statusMessage?.contains("wrld") ?? false)
        f.en.doc.setText(a.id, "helo world")
        // Round to the start again.
        XCTAssertEqual(f.model.nextMisspelling(), a.id)
    }

    func testNextMisspellingWithoutADictionarySaysWhatToDo() throws {
        try useTestDictionaries()
        let f = makeFixture([("qq", [sub(1, 2, "anything")])])
        XCTAssertNil(f.model.nextMisspelling())
        XCTAssertTrue(f.model.statusMessage?.contains("dictionary") ?? false)
        XCTAssertEqual(f.model.spellingStatus(for: Language.named("qq")), "Spelling: no dictionary yet")
        XCTAssertEqual(f.model.spellingStatus(for: Language.named("xx")), "Spelling: downloaded dictionary")
    }
}
