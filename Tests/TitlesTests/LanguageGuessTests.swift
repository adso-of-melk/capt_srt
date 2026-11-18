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
        // Not in the list: the system's name for it, not "kk (kk)".
        XCTAssertEqual(Language.named("kk").name, "Kazakh")
        XCTAssertEqual(Set(Language.common.map(\.code)).count, Language.common.count)
    }

    // MARK: Languages the recogniser mixes up

    /// The same few lines in each language (Jeremy's test set had Farsi read as Urdu and
    /// Arabic, Serbian Cyrillic as Bulgarian and Kazakh).
    static let lookAlikes: [(code: String, text: String)] = [
        ("sr-Cyrl", "Рекла је да ће већ бити овде. Нешто није у реду. Где си био синоћ? Морамо да разговарамо о томе шта се десило. Њен брат ће доћи сутра. Љубав није довољна."),
        ("mk", "Рече дека веќе ќе биде тука. Нешто не е во ред. Каде беше синоќа? Мораме да зборуваме за тоа што се случи. Нејзиниот брат ќе дојде утре. Љубовта не е доволна."),
        ("bg", "Каза, че вече ще бъде тук. Нещо не е наред. Къде беше снощи? Трябва да поговорим за това, което се случи. Брат ѝ ще дойде утре. Любовта не е достатъчна."),
        ("ru", "Она сказала, что уже будет здесь. Что-то не так. Где ты был вчера вечером? Нам нужно поговорить о том, что случилось. Её брат придёт завтра. Любви недостаточно, это ясно."),
        ("uk", "Вона сказала, що вже буде тут. Щось не так. Де ти був учора ввечері? Нам треба поговорити про те, що сталося. Її брат прийде завтра. Любові недостатньо, і це ясно."),
        ("kk", "Ол мұнда болатынын айтты. Бірдеңе дұрыс емес. Кеше кешке қайда болдың? Не болғаны туралы сөйлесуіміз керек. Оның ағасы ертең келеді. Махаббат жеткіліксіз."),
        ("fa", "گفت که دیگر اینجا خواهد بود. چیزی درست نیست. دیشب کجا بودی؟ باید درباره اتفاقی که افتاد صحبت کنیم. برادرش فردا می‌آید. عشق کافی نیست."),
        ("ar", "قالت إنها ستكون هنا بالفعل. هناك شيء غير صحيح. أين كنت الليلة الماضية؟ يجب أن نتحدث عما حدث. سيأتي أخوها غدا. الحب ليس كافيا في هذه الحالة."),
        ("ur", "اس نے کہا کہ وہ پہلے ہی یہاں ہوگی۔ کچھ ٹھیک نہیں ہے۔ تم کل رات کہاں تھے؟ ہمیں اس بارے میں بات کرنی چاہیے جو ہوا۔ اس کا بھائی کل آئے گا۔ محبت کافی نہیں ہے۔"),
    ]

    func testLanguagesTheRecogniserMixesUpAreToldApartByTheirOwnLetters() {
        for (code, text) in Self.lookAlikes {
            XCTAssertEqual(LanguageGuess.byLetters(text)?.code, code, text)
            XCTAssertEqual(SubtitleFormats.languageGuess(text).code, code, text)
        }
        // Persian typed with the Arabic forms of ye and kaf is still Persian.
        let persian = Self.lookAlikes.first { $0.code == "fa" }!.text
            .replacingOccurrences(of: "ی", with: "ي").replacingOccurrences(of: "ک", with: "ك")
        XCTAssertEqual(LanguageGuess.byLetters(persian)?.code, "fa")
        // Latin letters: the recogniser decides, as before.
        XCTAssertNil(LanguageGuess.byLetters("Rekla je da će već biti ovdje."))
    }

    func testAFileWithNoLanguageInItsNameIsReadForItsLetters() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (n, sample) in Self.lookAlikes.enumerated() {
            let lines = sample.text.components(separatedBy: ". ")
            let srt = lines.enumerated().map { i, line in
                "\(i + 1)\n00:00:\(String(format: "%02d", i * 3 + 1)),000 --> 00:00:\(String(format: "%02d", i * 3 + 3)),000\n\(line)\n"
            }.joined(separator: "\n")
            let url = try writeFile("jumbled \(n).srt", srt, in: folder)
            XCTAssertEqual(LanguageGuess.language(of: url)?.code, sample.code, sample.code)
        }
    }

    func testTheWordsAreTakenFromAllThroughTheFile() {
        // Credits in English at the start, then a long film in Croatian.
        let text = String(repeating: "Subtitles by the team www.example.com ", count: 50)
            + String(repeating: "Rekla je da će već biti ovdje. Nešto nije u redu. ", count: 2000)
            + "Kraj filma."
        let sample = SubtitleFormats.sample(text)
        XCTAssertLessThanOrEqual(sample.count, 24_000 + 12)
        XCTAssertTrue(sample.contains("Kraj filma."))
        XCTAssertFalse(sample.contains("www.example.com"))
        XCTAssertEqual(SubtitleFormats.languageGuess(text).code, "hr")
    }
}
