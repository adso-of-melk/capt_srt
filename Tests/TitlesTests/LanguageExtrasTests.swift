import XCTest
@testable import Titles
@testable import TitlesCore

/// Language Options extras: minimum duration, line-break style, export format and file
/// options per language, and Serbian in either alphabet.
@MainActor
final class LanguageExtrasTests: XCTestCase {

    // MARK: Line-break style

    func testBottomHeavyPutsTheShorterLineOnTopAndTopHeavyTheLonger() {
        let text = "aaaa bbbb cccc dddd eeee"
        XCTAssertEqual(LineBreaker.breakLines(text, maxChars: 14, maxLines: 2, language: "xx"),
                       "aaaa bbbb\ncccc dddd eeee")
        XCTAssertEqual(LineBreaker.breakLines(text, maxChars: 14, maxLines: 2, language: "xx", style: .topHeavy),
                       "aaaa bbbb cccc\ndddd eeee")
    }

    func testBalancedTakesTheEvenestLines() {
        // Shorter on top by 6, or longer on top by 4.
        let text = "aaaaa bbbb cccc ddddd eeeee"
        XCTAssertEqual(LineBreaker.breakLines(text, maxChars: 16, maxLines: 2, language: "xx"),
                       "aaaaa bbbb\ncccc ddddd eeeee")
        XCTAssertEqual(LineBreaker.breakLines(text, maxChars: 16, maxLines: 2, language: "xx", style: .balanced),
                       "aaaaa bbbb cccc\nddddd eeeee")
    }

    func testTheLanguagesStyleIsUsedWhenRebreaking() {
        let f = makeFixture([("en", [sub(1, 5, "aaaa bbbb cccc dddd eeee")]), ("xx", [sub(1, 5, "aaaa bbbb cccc dddd eeee")])])
        f.model.setOverrides(f.hr, maxChars: .some(14))
        f.hr.lineBreakStyle = .topHeavy
        f.model.focusTrack(f.hr.id, edit: false)
        f.model.rebreakAll()
        XCTAssertEqual(f.hr.doc.subtitles[0].text, "aaaa bbbb cccc\ndddd eeee")
    }

    // MARK: Options

    func testOptionsSetMinimumDurationStyleAndExportChoices() throws {
        let f = makeFixture([("en", [sub(1, 2)]), ("hr", [sub(1, 2)])])
        var o = LanguageOptions(f.hr, isMaster: false)
        XCTAssertNil(o.minDuration)
        XCTAssertEqual(o.lineBreakStyle, .bottomHeavy)
        o.minDuration = 1.5
        o.lineBreakStyle = .balanced
        o.exportFormat = .ttml
        o.utf8BOM = false
        o.crlf = true

        f.model.applyLanguageOptions(f.hr, o)

        XCTAssertEqual(f.model.preset(for: f.hr).minDuration, 1.5)
        XCTAssertEqual(f.model.preset(for: f.en).minDuration, TimingPreset.general.minDuration)
        XCTAssertEqual(f.hr.lineBreakStyle, .balanced)
        XCTAssertEqual(f.hr.exportFormat, .ttml)
        XCTAssertEqual(f.hr.utf8BOM, false)
        XCTAssertEqual(f.hr.crlf, true)

        // Saved with the project, and back.
        let data = try JSONEncoder().encode(f.hr.file)
        let back = Track(try JSONDecoder().decode(TrackFile.self, from: data))
        XCTAssertEqual(back.minDuration, 1.5)
        XCTAssertEqual(back.lineBreakStyle, .balanced)
        XCTAssertEqual(back.exportFormat, .ttml)
        XCTAssertEqual(back.utf8BOM, false)
        XCTAssertEqual(back.crlf, true)

        // A duplicate takes them along.
        let copy = try XCTUnwrap(f.model.duplicateLanguage(f.hr))
        XCTAssertEqual(copy.minDuration, 1.5)
        XCTAssertEqual(copy.exportFormat, .ttml)
        XCTAssertEqual(copy.lineBreakStyle, .balanced)
    }

    func testOlderProjectsReadWithTheProjectsSettings() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","language":{"code":"hr","name":"Croatian"},"locked":false,"subtitles":[]}"#
        let track = Track(try JSONDecoder().decode(TrackFile.self, from: Data(json.utf8)))
        XCTAssertNil(track.minDuration)
        XCTAssertEqual(track.lineBreakStyle, .bottomHeavy)
        XCTAssertNil(track.exportFormat)
        XCTAssertNil(track.utf8BOM)
        XCTAssertNil(track.crlf)
    }

    // MARK: Serbian alphabets

    func testCyrillicToLatin() {
        XCTAssertEqual(SerbianScript.convert("Љубав, ЉУБАВ и џеп. <i>Ђак</i> {\\an8}Њ", to: .latin),
                       "Ljubav, LJUBAV i džep. <i>Đak</i> {\\an8}Nj")
        XCTAssertEqual(SerbianScript.convert("Шта ћеш? Чекај!", to: .latin), "Šta ćeš? Čekaj!")
    }

    func testLatinToCyrillic() {
        XCTAssertEqual(SerbianScript.convert("Ljubav je nadživela injekciju i konja.", to: .cyrillic),
                       "Љубав је надживела инјекцију и коња.")
        XCTAssertEqual(SerbianScript.convert("LJUBAV, Džep, đak, Šta ćeš?", to: .cyrillic), "ЉУБАВ, Џеп, ђак, Шта ћеш?")
        // Formatting tags, foreign words, web addresses and Roman numerals stay as they are.
        XCTAssertEqual(SerbianScript.convert("<i>Imamo</i> Wi-Fi na www.rts.rs, Luj XIV i Henri II.", to: .cyrillic),
                       "<i>Имамо</i> Wi-Fi на www.rts.rs, Луј XIV и Хенри II.")
        // There and back again.
        let latin = "Njegova ćerka džara vatru."
        XCTAssertEqual(SerbianScript.convert(SerbianScript.convert(latin, to: .cyrillic), to: .latin), latin)
    }

    func testTheAlphabetAndCode() {
        XCTAssertEqual(SerbianScript.dominant(in: ["Здраво", "Hi"]), .cyrillic)
        XCTAssertEqual(SerbianScript.dominant(in: ["Zdravo"]), .latin)
        XCTAssertNil(SerbianScript.dominant(in: ["123 !"]))
        XCTAssertEqual(SerbianScript.code("sr-Cyrl", for: .latin), "sr-Latn")
        XCTAssertEqual(SerbianScript.code("sr", for: .latin), "sr-Latn")
        XCTAssertEqual(SerbianScript.code("sr-Latn-ME", for: .cyrillic), "sr-Cyrl-ME")
        XCTAssertTrue(SerbianScript.applies(to: "sr-Latn"))
        XCTAssertFalse(SerbianScript.applies(to: "hr"))
    }

    func testConvertingALanguageIsOneUndoAndChangesItsCode() {
        let f = makeFixture([("en", [sub(1, 2, "Hello"), sub(3, 4, "Bye")]),
                             ("sr-Cyrl", [sub(1, 2, "Здраво"), sub(3, 4, "<i>Збогом</i>")])])
        var o = LanguageOptions(f.hr, isMaster: false)
        o.convertTo = .latin
        o.language = Language.named("sr-Latn")

        f.model.applyLanguageOptions(f.hr, o)

        XCTAssertEqual(f.hr.doc.subtitles.map(\.text), ["Zdravo", "<i>Zbogom</i>"])
        XCTAssertEqual(f.hr.language.code, "sr-Latn")
        f.hr.doc.undo()
        XCTAssertEqual(f.hr.doc.subtitles.map(\.text), ["Здраво", "<i>Збогом</i>"])
    }
}
