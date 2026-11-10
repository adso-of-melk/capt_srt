import XCTest
@testable import Titles

/// Reading and writing subtitle files, and the timecodes in them.
@MainActor
final class FormatsTests: XCTestCase {

    // MARK: Reading

    func testReadsSRTWithWindowsLineEndings() {
        let text = "1\r\n00:00:01,000 --> 00:00:02,500\r\nHello\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nTwo\r\nlines\r\n\r\n"
        let subs = SubtitleFormats.parse(text)
        XCTAssertEqual(subs.count, 2)
        XCTAssertEqual(subs[0].start, 1, accuracy: 0.0001)
        XCTAssertEqual(subs[0].end, 2.5, accuracy: 0.0001)
        XCTAssertEqual(subs[0].text, "Hello")
        XCTAssertEqual(subs[1].text, "Two\nlines")
    }

    func testReadsAFileThatStartsWithAByteOrderMark() {
        let subs = SubtitleFormats.parse("\u{FEFF}1\n00:00:01,000 --> 00:00:02,000\nHello\n")
        XCTAssertEqual(subs.map(\.text), ["Hello"])
    }

    func testReadsWebVTT() {
        let text = """
        WEBVTT

        NOTE a comment

        00:01.000 --> 00:02.000 line:0 position:50%
        Hello

        cue-2
        00:00:03.000 --> 00:00:04.500
        <v Roger>World</v>
        """
        let subs = SubtitleFormats.parse(text)
        XCTAssertEqual(subs.count, 2)
        XCTAssertEqual(subs[0].start, 1, accuracy: 0.0001)
        XCTAssertEqual(subs[0].end, 2, accuracy: 0.0001)
        XCTAssertEqual(subs[0].text, "Hello")
        XCTAssertEqual(subs[1].end, 4.5, accuracy: 0.0001)
        XCTAssertEqual(subs[1].text, "<v Roger>World</v>")
    }

    func testSeparatorLinesHoldingOnlySpacesStillSeparateTitles() {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nA\n \n2\n00:00:03,000 --> 00:00:04,000\nB\n\t\n3\n00:00:05,000 --> 00:00:06,000\nC\n"
        XCTAssertEqual(SubtitleFormats.parse(text).map(\.text), ["A", "B", "C"])
    }

    func testExtraBlankLinesAndMissingNumbersAreFine() {
        let text = "00:00:01,000 --> 00:00:02,000\nA\n\n\n\n00:00:03,000 --> 00:00:04,000\nB"
        XCTAssertEqual(SubtitleFormats.parse(text).map(\.text), ["A", "B"])
    }

    func testTitlesComeOutInTimeOrder() {
        let text = "1\n00:00:05,000 --> 00:00:06,000\nLater\n\n2\n00:00:01,000 --> 00:00:02,000\nEarlier\n"
        XCTAssertEqual(SubtitleFormats.parse(text).map(\.text), ["Earlier", "Later"])
    }

    func testAnEndBeforeTheStartIsNotKept() {
        let subs = SubtitleFormats.parse("1\n00:00:05,000 --> 00:00:04,000\nBackwards\n")
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].start, 5, accuracy: 0.0001)
        XCTAssertEqual(subs[0].end, 5, accuracy: 0.0001)
    }

    func testTextThatIsNotASubtitleFileGivesNoTitles() {
        XCTAssertTrue(SubtitleFormats.parse("Just some words.\n\nAnd some more.").isEmpty)
        XCTAssertTrue(SubtitleFormats.parse("").isEmpty)
    }

    func testReadsTimes() throws {
        XCTAssertEqual(try XCTUnwrap(SubtitleFormats.parseTime("00:01:02,345")), 62.345, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(SubtitleFormats.parseTime("01:02:03.500")), 3723.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(SubtitleFormats.parseTime("01:02.500")), 62.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(SubtitleFormats.parseTime("  00:00:01.000 ")), 1, accuracy: 0.0001)
        XCTAssertNil(SubtitleFormats.parseTime("abc"))
        XCTAssertNil(SubtitleFormats.parseTime("1:2:3:4"))
        XCTAssertNil(SubtitleFormats.parseTime("5"))
    }

    // MARK: Writing

    func testWritesSRTLeavingOutEmptyTitles() {
        let subs = [sub(1, 2.5, "Hello"), sub(3, 4, ""), sub(5, 6, "Two\n\nlines"), sub(7, 8, "<i></i>"),
                    sub(9, 10, "  padded  ")]
        XCTAssertEqual(SubtitleFormats.srt(subs), """
        1
        00:00:01,000 --> 00:00:02,500
        Hello

        2
        00:00:05,000 --> 00:00:06,000
        Two
        lines

        3
        00:00:09,000 --> 00:00:10,000
        padded


        """)
    }

    func testWritesWebVTT() {
        XCTAssertEqual(SubtitleFormats.vtt([sub(1, 2.5, "Hello")]),
                       "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.500\nHello\n\n")
    }

    func testFileBytesFollowTheExportSettings() {
        let windows = SubtitleFormats.data([sub(1, 2, "A\nB")], format: .srt, bom: true, crlf: true)
        XCTAssertEqual(Array(windows.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(String(decoding: windows.dropFirst(3), as: UTF8.self),
                       "1\r\n00:00:01,000 --> 00:00:02,000\r\nA\r\nB\r\n\r\n")

        let plain = SubtitleFormats.data([sub(1, 2, "A\nB")], format: .srt, bom: false, crlf: false)
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), "1\n00:00:01,000 --> 00:00:02,000\nA\nB\n\n")
        XCTAssertFalse(plain.contains(13))

        let vtt = SubtitleFormats.data([sub(1, 2, "A")], format: .vtt, bom: false, crlf: false)
        XCTAssertTrue(String(decoding: vtt, as: UTF8.self).hasPrefix("WEBVTT\n\n"))
    }

    func testWhatIsWrittenReadsBackTheSame() throws {
        let subs = [sub(0.04, 1.96, "First"), sub(2.5, 4.123, "<i>Second</i>\nline"), sub(3600.5, 3602, "Čćđšž ČĆĐŠŽ"),
                    sub(7199.999, 7201.001, "- One.\n- Two.")]
        for format in ExportFormat.allCases {
            for crlf in [true, false] {
                for bom in [true, false] {
                    let data = SubtitleFormats.data(subs, format: format, bom: bom, crlf: crlf)
                    let back = SubtitleFormats.parse(try XCTUnwrap(SubtitleFormats.decodeText(data)))
                    XCTAssertEqual(back.map(\.text), subs.map(\.text))
                    for (a, b) in zip(back, subs) {
                        XCTAssertEqual(a.start, b.start, accuracy: 0.0006)
                        XCTAssertEqual(a.end, b.end, accuracy: 0.0006)
                    }
                }
            }
        }
    }

    // MARK: Text encodings

    private func file(_ lines: [String]) -> String {
        var out = ""
        for (i, line) in lines.enumerated() {
            let start = Timecode.srt(Double(i) * 3 + 1), end = Timecode.srt(Double(i) * 3 + 3)
            out += "\(i + 1)\r\n\(start) --> \(end)\r\n\(line)\r\n\r\n"
        }
        return out
    }

    private let croatian = [
        "Što se dogodilo jučer navečer?",
        "Ne znam, ali čuo sam da je bilo gužve u gradu.",
        "Đuro je rekao da će doći sutra ujutro.",
        "Želim ti reći nešto važno prije nego što odeš.",
        "Možemo li se naći kod škole u četiri sata?",
        "Sve će biti u redu, ne brini se.",
        "Nisam znao da ćeš doći, ali drago mi je što si ovdje.",
        "Kuća je na kraju ulice, odmah iza crkve.",
    ]

    func testReadsUTF8AndUTF16() throws {
        let text = file(croatian)
        XCTAssertEqual(SubtitleFormats.decodeText(Data(text.utf8)), text)
        let utf16 = try XCTUnwrap(text.data(using: .utf16))
        XCTAssertEqual(SubtitleFormats.decodeText(utf16), text)
    }

    func testReadsOldCentralEuropeanFiles() throws {
        // The same bytes read as Western would show è æ ð for č ć đ.
        let text = file(croatian)
        let data = try XCTUnwrap(text.data(using: .windowsCP1250))
        XCTAssertEqual(SubtitleFormats.decodeText(data), text)
    }

    func testReadsOldWesternFiles() throws {
        let text = file([
            "Je ne sais pas où il est allé hier soir.",
            "Tu es très gentille, mais ça ne change rien.",
            "Nous avons été à la plage près de l'hôtel.",
            "C'est déjà trop tard pour ça, elle est partie.",
            "Où est-ce que tu étais pendant tout ce temps ?",
            "Il faut que je te dise quelque chose d'important.",
            "Elle a répété la même chose à sa mère.",
        ])
        let data = try XCTUnwrap(text.data(using: .windowsCP1252))
        XCTAssertEqual(SubtitleFormats.decodeText(data), text)

        let german = file(["Ich weiß nicht, was gestern Abend passiert ist.", "Wir müssen gehen, bevor es zu spät wird.",
                           "Das Mädchen möchte später Ärztin werden."])
        XCTAssertEqual(SubtitleFormats.decodeText(try XCTUnwrap(german.data(using: .windowsCP1252))), german)
    }

    func testReadsOldCyrillicFiles() throws {
        let text = file([
            "Я не знаю, что случилось вчера вечером.",
            "Мы должны идти, пока не стало слишком поздно.",
            "Она сказала, что придёт завтра утром.",
            "Всё будет хорошо, не волнуйся.",
        ])
        let data = try XCTUnwrap(text.data(using: .windowsCP1251))
        XCTAssertEqual(SubtitleFormats.decodeText(data), text)
    }

    func testReadsOldGreekFiles() throws {
        let text = file([
            "Δεν ξέρω τι έγινε χθες το βράδυ.",
            "Πρέπει να φύγουμε πριν να είναι πολύ αργά.",
            "Είπε ότι θα έρθει αύριο το πρωί.",
        ])
        let data = try XCTUnwrap(text.data(using: .windowsCP1253))
        XCTAssertEqual(SubtitleFormats.decodeText(data), text)
    }

    func testReadsOldTurkishFiles() throws {
        let text = file([
            "Dün akşam ne olduğunu bilmiyorum.",
            "Çok geç olmadan gitmemiz gerekiyor.",
            "Sana önemli bir şey söylemem lazım.",
            "Bugün hava çok güzel, dışarı çıkalım mı?",
            "Işıkları kapatmayı unutma, lütfen.",
            "Yarın sabah erkenden yola çıkacağız.",
        ])
        let data = try XCTUnwrap(text.data(using: .windowsCP1254))
        XCTAssertEqual(SubtitleFormats.decodeText(data), text)
    }

    func testAStrayByteDoesNotSpoilAUTF8File() throws {
        var data = Data(file(croatian).utf8)
        data.append(0xA9)   // a "©" saved by another program in an old encoding
        let text = try XCTUnwrap(SubtitleFormats.decodeText(data))
        XCTAssertTrue(text.contains("čuo sam da je bilo gužve"))
        XCTAssertEqual(SubtitleFormats.parse(text).count, croatian.count)
    }

    func testReadsAFileFromDisk() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try writeFile("Film.srt", file(croatian), in: folder, encoding: .windowsCP1250)
        XCTAssertEqual(try SubtitleFormats.read(url: url).map(\.text), croatian)
    }

    func testTheWordsOfAFileLeaveOutNumbersTimecodesAndTags() {
        let words = SubtitleFormats.spokenText("1\r\n00:00:01,000 --> 00:00:02,000\r\n<i>Hello</i> there\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nGeneral Kenobi\r\n")
        XCTAssertEqual(words, "Hello there General Kenobi")
    }

    // MARK: Timecodes

    func testMillisecondTimecodes() {
        XCTAssertEqual(Timecode.srt(3723.456), "01:02:03,456")
        XCTAssertEqual(Timecode.vtt(3723.456), "01:02:03.456")
        XCTAssertEqual(Timecode.srt(0), "00:00:00,000")
        XCTAssertEqual(Timecode.srt(-1), "00:00:00,000")
        XCTAssertEqual(Timecode.srt(0.9996), "00:00:01,000")
        XCTAssertEqual(Timecode.srt(59.9999), "00:01:00,000")
    }

    func testFrameTimecodes() {
        XCTAssertEqual(Timecode.frames(0, fps: 25), "00:00:00:00")
        XCTAssertEqual(Timecode.frames(-3, fps: 25), "00:00:00:00")
        XCTAssertEqual(Timecode.frames(0.96, fps: 25), "00:00:00:24")
        XCTAssertEqual(Timecode.frames(1, fps: 25), "00:00:01:00")
        // 13.28 s is exactly frame 332, though 13.28 × 25 comes out a hair under in floating point.
        XCTAssertEqual(Timecode.frames(13.28, fps: 25), "00:00:13:07")
        XCTAssertEqual(Timecode.frames(3600, fps: 25), "01:00:00:00")
        // 23.976: counted in whole frames, 24 to the second, like a burnt-in timecode.
        let film = 24000.0 / 1001.0
        XCTAssertEqual(Timecode.frames(24 / film, fps: film), "00:00:01:00")
        XCTAssertEqual(Timecode.frames(86400 / film, fps: film), "01:00:00:00")
    }

    func testEveryFrameHasItsOwnTimecodeAndGoesBackToTheSameTime() throws {
        let rates = [24000.0 / 1001.0, 24, 25, 30000.0 / 1001.0, 30, 50, 60000.0 / 1001.0, 60]
        let frames = [0, 1, 2, 23, 24, 25, 29, 30, 59, 60, 999, 1000, 1001, 86399, 86400, 90000, 123457]
        for fps in rates {
            let nominal = Int(fps.rounded())
            for n in frames {
                let t = Double(n) / fps
                let shown = Timecode.frames(t, fps: fps)
                let parts = shown.split(separator: ":").compactMap { Int($0) }
                XCTAssertEqual(parts.count, 4, shown)
                guard parts.count == 4 else { continue }
                let counted = (parts[0] * 3600 + parts[1] * 60 + parts[2]) * nominal + parts[3]
                XCTAssertEqual(counted, n, "\(shown) at \(fps) fps")
                let back = Timecode.seconds(hours: Double(parts[0]), minutes: Double(parts[1]),
                                            seconds: Double(parts[2]), frames: Double(parts[3]), fps: fps)
                XCTAssertEqual(back, t, accuracy: 0.000001)
            }
        }
    }

    func testRulerLabels() {
        XCTAssertEqual(Timecode.ruler(62.5, showTenths: false), "1:02")
        XCTAssertEqual(Timecode.ruler(62.5, showTenths: true), "1:02.5")
        XCTAssertEqual(Timecode.ruler(3725, showTenths: false), "1:02:05")
        XCTAssertEqual(Timecode.ruler(0, showTenths: false), "0:00")
    }
}
