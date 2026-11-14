import XCTest
@testable import Titles

/// Line breaks by the style-guide rules (42 characters, two lines unless said otherwise).
@MainActor
final class LineBreakerTests: XCTestCase {

    private func broken(_ text: String, chars: Int = 42, lines: Int = 2, language: String = "en") -> String {
        LineBreaker.breakLines(text, maxChars: chars, maxLines: lines, language: language)
    }

    func testATitleThatFitsStaysOnOneLine() {
        XCTAssertEqual(broken("Hello there."), "Hello there.")
        XCTAssertEqual(broken("Hello\nthere."), "Hello there.")
        XCTAssertEqual(broken("  Too   many    spaces  "), "Too many spaces")
        XCTAssertEqual(broken(""), "")
    }

    func testFormattingTagsDoNotCountTowardsTheLength() {
        // 40 characters on screen, 47 with the tags.
        let text = "<i>This line is exactly forty characters ok</i>"
        XCTAssertEqual(Markup.plain(text).count, 40)
        XCTAssertEqual(broken(text), text)
    }

    func testBreaksAfterPunctuation() {
        XCTAssertEqual(broken("She said she would be here by now. I think something is wrong."),
                       "She said she would be here by now.\nI think something is wrong.")
        XCTAssertEqual(broken("Hello there, General Kenobi. You are a bold one, I must say."),
                       "Hello there, General Kenobi.\nYou are a bold one, I must say.")
        // The comma ends the phrase, even though "about" is a preposition.
        XCTAssertEqual(broken("I don't know what you're talking about, and I don't care."),
                       "I don't know what you're talking about,\nand I don't care.")
    }

    func testBreaksBeforeAConjunctionOrPreposition() {
        XCTAssertEqual(broken("We went down to the river and looked at the old bridge."),
                       "We went down to the river\nand looked at the old bridge.")
        XCTAssertEqual(broken("I think that we should leave before it gets dark outside."),
                       "I think that we should leave\nbefore it gets dark outside.")
    }

    func testNeverLeavesASmallWordHangingAtTheEndOfALine() {
        XCTAssertEqual(broken("He told me that his brother was living in the old house."),
                       "He told me that his brother\nwas living in the old house.")
        XCTAssertEqual(broken("I never thought I would see you again after all these years."),
                       "I never thought I would see\nyou again after all these years.")
        let hanging: Set<String> = ["a", "an", "the", "his", "her", "to", "in", "of", "and", "I", "was"]
        for text in ["To be honest I am not really sure what you want from me",
                     "Tell the captain that the engines are ready and the crew is waiting.",
                     "The last thing I remember is the sound of the rain on the roof."] {
            let top = shownLines(broken(text))[0]
            let last = top.split(separator: " ").last.map(String.init) ?? ""
            XCTAssertFalse(hanging.contains(last), "\"\(top)\" ends with \"\(last)\"")
        }
    }

    func testKeepsFirstAndLastNamesTogether() {
        XCTAssertEqual(broken("Yesterday I spoke with Jean-Luc Picard about the mission ahead."),
                       "Yesterday I spoke with Jean-Luc Picard\nabout the mission ahead.")
        XCTAssertEqual(broken("We should ask Mr. Smith about the keys to the old warehouse."),
                       "We should ask Mr. Smith\nabout the keys to the old warehouse.")
    }

    func testTagsStayWhereTheyWere() {
        XCTAssertEqual(broken("<i>I never thought I would see you again after all these years.</i>"),
                       "<i>I never thought I would see\nyou again after all these years.</i>")
        XCTAssertEqual(broken("<i>Hello there, General Kenobi.</i> You are a bold one, I must say."),
                       "<i>Hello there, General Kenobi.</i>\nYou are a bold one, I must say.")
    }

    func testCroatianRules() {
        XCTAssertEqual(broken("Otišli smo jučer navečer u grad na večeru s prijateljima.", language: "hr"),
                       "Otišli smo jučer navečer\nu grad na večeru s prijateljima.")
        XCTAssertEqual(broken("Nisam znao da ćeš doći, ali drago mi je što si ovdje.", language: "hr"),
                       "Nisam znao da ćeš doći,\nali drago mi je što si ovdje.")
        XCTAssertEqual(broken("Mislim da bismo trebali krenuti prije nego što padne mrak.", language: "hr"),
                       "Mislim da bismo trebali krenuti\nprije nego što padne mrak.")
        // Bosnian and Serbian (Latin) use the same word list.
        XCTAssertEqual(broken("Nisam znao da ćeš doći, ali drago mi je što si ovdje.", language: "sr-Latn"),
                       "Nisam znao da ćeš doći,\nali drago mi je što si ovdje.")
    }

    func testALanguageWithoutAWordListStillBreaksByPunctuationAndBalance() {
        XCTAssertEqual(broken("Ich habe dir schon gesagt, dass wir morgen früh abreisen müssen.", language: "de"),
                       "Ich habe dir schon gesagt,\ndass wir morgen früh abreisen müssen.")
    }

    func testEveryWordSurvivesAndLinesFit() {
        let samples = [
            ("I never thought I would see you again after all these years.", "en"),
            ("The last thing I remember is the sound of the rain on the roof.", "en"),
            ("Tell the captain that the engines are ready and the crew is waiting.", "en"),
            ("Kad sam bio mali, mislio sam da će ljeto trajati zauvijek.", "hr"),
            ("Wir sollten gehen, bevor es dunkel wird und der Regen wieder anfängt.", "de"),
            ("Je ne savais pas que tu viendrais, mais je suis content de te voir.", "fr"),
        ]
        for (text, language) in samples {
            let result = broken(text, language: language)
            let parts = shownLines(result)
            XCTAssertEqual(parts.count, 2, text)
            XCTAssertTrue(parts.allSatisfy { $0.count <= 42 }, result)
            XCTAssertEqual(result.replacingOccurrences(of: "\n", with: " "), text)
        }
    }

    func testOneLineStandardNeverBreaks() {
        let text = "I never thought I would see you again after all these years."
        XCTAssertEqual(broken(text, lines: 1), text)
    }

    func testThreeLines() {
        let text = "This is a rather long sentence that has to be spread over three lines because the limit here is small."
        let result = broken(text, chars: 37, lines: 3)
        XCTAssertEqual(shownLines(result).count, 3)
        XCTAssertEqual(result.replacingOccurrences(of: "\n", with: " "), text)
    }

    func testASingleLongWordIsLeftAlone() {
        let word = "Supercalifragilisticexpialidociousandthensomemore"
        XCTAssertEqual(broken(word), word)
    }

    // MARK: Two speakers

    func testTwoSpeakersGetALineEach() {
        XCTAssertEqual(broken("- Hi. - Hello."), "- Hi.\n- Hello.")
        XCTAssertEqual(broken("-Hi. -Hello."), "-Hi.\n-Hello.")
        XCTAssertEqual(broken("- Where are you going? - Home."), "- Where are you going?\n- Home.")
        XCTAssertEqual(broken("<i>- Hi. - Hello.</i>"), "<i>- Hi.\n- Hello.</i>")
    }

    func testTwoSpeakersAlreadyOnTheirOwnLinesStayThatWay() {
        XCTAssertEqual(broken("- Where are you going?\n- Home."), "- Where are you going?\n- Home.")
        XCTAssertEqual(broken("- I told you -\n- I know."), "- I told you -\n- I know.")
    }

    func testADashInsideASentenceIsNotASecondSpeaker() {
        XCTAssertEqual(broken("- Well - I mean, no."), "- Well - I mean, no.")
        XCTAssertEqual(broken("- It's -5 outside."), "- It's -5 outside.")
        XCTAssertEqual(broken("- Wait. It's -5 outside."), "- Wait. It's -5 outside.")
    }

    func testTwoSpeakersNeedTwoLines() {
        XCTAssertEqual(broken("- Hi. - Hello.", lines: 1), "- Hi. - Hello.")
    }
}
