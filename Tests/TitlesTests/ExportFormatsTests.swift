import XCTest
@testable import Titles
@testable import TitlesCore

/// The export formats beyond SRT and WebVTT: TTML, DFXP, iTunes Timed Text, EBU STL,
/// SubStation, YouTube, plain text, dialogue lists and Avid DS.
@MainActor
final class ExportFormatsTests: XCTestCase {

    private func text(_ subs: [Subtitle], _ format: ExportFormat, _ context: ExportContext = ExportContext()) -> String {
        SubtitleFormats.text(subs, format: format, context: context)
    }

    // MARK: Styled text

    func testStyledLinesFollowItalicsAcrossLinesAndDropOtherTags() {
        let lines = Markup.styledLines("{\\an8}Say <i>it\nagain</i>, <b>Sam</b>")
        XCTAssertEqual(lines, [
            [Markup.Run(text: "Say "), Markup.Run(text: "it", italic: true)],
            [Markup.Run(text: "again", italic: true), Markup.Run(text: ", "), Markup.Run(text: "Sam", bold: true)],
        ])
        XCTAssertTrue(Markup.isTop("{\\an8}Up here"))
        XCTAssertFalse(Markup.isTop("{\\an2}Down here"))
    }

    // MARK: XML

    func testTTMLIsIMSCWithSpansLineBreaksAndRegions() {
        let subs = [sub(1, 2.5, "Tom & <i>Jerry</i>\nline"), sub(3, 4, "{\\an8}Top")]
        let ttml = text(subs, .ttml, ExportContext(language: "hr", title: "Film"))
        XCTAssertTrue(ttml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(ttml.contains("ttp:contentProfiles=\"http://www.w3.org/ns/ttml/profile/imsc1.1/text\""))
        XCTAssertTrue(ttml.contains("xml:lang=\"hr\""))
        XCTAssertTrue(ttml.contains("<p begin=\"00:00:01.000\" end=\"00:00:02.500\" region=\"bottom\">Tom &amp; <span tts:fontStyle=\"italic\">Jerry</span><br/>line</p>"), ttml)
        XCTAssertTrue(ttml.contains("region=\"top\">Top</p>"), ttml)
        XCTAssertNotNil(try? XMLDocument(xmlString: ttml), "TTML must be well-formed XML")
    }

    func testDFXPCountsTicks() {
        let dfxp = text([sub(1, 2.5, "Hi")], .dfxp)
        XCTAssertTrue(dfxp.contains("ttp:tickRate=\"10000000\""))
        XCTAssertTrue(dfxp.contains("<p begin=\"10000000t\" end=\"25000000t\" region=\"bottom\">Hi</p>"), dfxp)
        XCTAssertNotNil(try? XMLDocument(xmlString: dfxp))
    }

    func testITTCountsFramesAtTheProjectsRate() {
        let itt = text([sub(1, 2.5, "<b>Hi</b>")], .itt, ExportContext(fps: 25))
        XCTAssertTrue(itt.contains("ttp:timeBase=\"smpte\" ttp:frameRate=\"25\" ttp:dropMode=\"nonDrop\""), itt)
        XCTAssertTrue(itt.contains("<p begin=\"00:00:01:00\" end=\"00:00:02:12\"><span tts:fontWeight=\"bold\">Hi</span></p>"), itt)
        XCTAssertNotNil(try? XMLDocument(xmlString: itt))
        let ntsc = text([sub(1, 2, "Hi")], .itt, ExportContext(fps: 23.976))
        XCTAssertTrue(ntsc.contains("ttp:frameRate=\"24\" ttp:frameRateMultiplier=\"1000 1001\""), ntsc)
    }

    func testXMLNeverGetsAByteOrderMarkOrACodePage() {
        let subs = [sub(1, 2, "Čaša")]
        for format in [ExportFormat.ttml, .dfxp, .itt] {
            let data = SubtitleFormats.data(subs, format: format, bom: true, crlf: false)
            XCTAssertEqual(Array(data.prefix(5)), Array("<?xml".utf8), "\(format)")
            let out = SubtitleFormats.encoded(subs, format: format, bom: true, crlf: false, encoding: "windows-1250")
            XCTAssertTrue(String(data: out.data, encoding: .utf8)?.contains("Čaša") ?? false, "\(format) stays UTF-8")
        }
    }

    // MARK: SubStation

    func testASSWritesOverrideCodesAndHundredths() {
        let ass = text([sub(62.34, 63.5, "<i>Hello</i>\nthere"), sub(70, 71, "{\\an8}<i>One\nTwo</i>")], .ass,
                       ExportContext(title: "Film"))
        XCTAssertTrue(ass.contains("ScriptType: v4.00+"))
        XCTAssertTrue(ass.contains("Title: Film"))
        XCTAssertTrue(ass.contains("Dialogue: 0,0:01:02.34,0:01:03.50,Default,,0,0,0,,{\\i1}Hello{\\i0}\\Nthere\n"), ass)
        XCTAssertTrue(ass.contains(",,{\\an8}{\\i1}One{\\i0}\\N{\\i1}Two{\\i0}\n"), ass)
    }

    func testSSAPutsTopTitlesWithItsOwnCode() {
        let ssa = text([sub(1, 2.5, "{\\an8}Up")], .ssa)
        XCTAssertTrue(ssa.contains("ScriptType: v4.00\n"))
        XCTAssertTrue(ssa.contains("Dialogue: Marked=0,0:00:01.00,0:00:02.50,Default,,0000,0000,0000,,{\\a6}Up\n"), ssa)
    }

    // MARK: Text formats

    func testYouTubeAndPlainTextHaveNoFormatting() {
        let subs = [sub(1, 2.5, "<i>Hi</i>\nthere"), sub(3, 4, "Second")]
        XCTAssertEqual(text(subs, .sbv), "0:00:01.000,0:00:02.500\nHi\nthere\n\n0:00:03.000,0:00:04.000\nSecond\n")
        XCTAssertEqual(text(subs, .txt), "Hi\nthere\n\nSecond\n")
    }

    func testDialogueListAndAvidCountFromTheStartTimecode() {
        let subs = [sub(1, 2.5, "<i>Hi</i>\nthere")]
        let context = ExportContext(fps: 25, startTimecode: 36000)
        XCTAssertEqual(text(subs, .list, context), "1\t10:00:01:00\t10:00:02:12\nHi\nthere\n")
        let avid = text(subs, .avid, context)
        XCTAssertTrue(avid.hasPrefix("@ This file written with the Avid Caption plugin, version 1\n\n<begin subtitles>\n"))
        XCTAssertTrue(avid.contains("10:00:01:00 10:00:02:12\nHi\nthere\n\n<end subtitles>\n"), avid)
    }

    func testFileExtensions() {
        XCTAssertEqual(ExportFormat.list.fileExtension, "txt")
        XCTAssertEqual(ExportFormat.avid.fileExtension, "txt")
        XCTAssertEqual(ExportFormat.stl.fileExtension, "stl")
        XCTAssertEqual(ExportFormat.ttml.fileExtension, "ttml")
    }

    // MARK: EBU STL

    private func string(_ data: Data, _ from: Int, _ count: Int) -> String {
        String(decoding: data[from..<(from + count)], as: UTF8.self)
    }

    func testEBUSTLHeaderAndOneTitle() {
        let subs = [sub(1, 2.5, "Čaša <i>vode</i>\nĐak")]
        let c = ExportContext(fps: 25, language: "hr", title: "Film", startTimecode: 36000)
        let (data, lost) = EBUSTL.file(subs, context: c)
        XCTAssertEqual(lost, 0)
        XCTAssertEqual(data.count, 1024 + 128)
        XCTAssertEqual(string(data, 0, 3), "850")
        XCTAssertEqual(string(data, 3, 8), "STL25.01")
        XCTAssertEqual(string(data, 11, 1), "1")
        XCTAssertEqual(string(data, 12, 2), "00")                 // Latin
        XCTAssertEqual(string(data, 14, 2), "04")                 // Croatian
        XCTAssertEqual(string(data, 80, 32), "Film" + String(repeating: " ", count: 28))
        XCTAssertEqual(string(data, 238, 5), "00001")             // blocks
        XCTAssertEqual(string(data, 243, 5), "00001")             // titles
        XCTAssertEqual(string(data, 251, 4), "4023")              // 40 characters, 23 rows
        XCTAssertEqual(string(data, 256, 8), "10000000")          // programme start
        XCTAssertEqual(string(data, 264, 8), "10000100")          // first title

        let tti = Array(data[1024..<1152])
        XCTAssertEqual(Array(tti[0..<5]), [0, 1, 0, 0xFF, 0])     // group, number 1, last block
        XCTAssertEqual(Array(tti[5..<9]), [10, 0, 1, 0])          // in 10:00:01:00
        XCTAssertEqual(Array(tti[9..<13]), [10, 0, 2, 12])        // out 10:00:02:12
        XCTAssertEqual(tti[13], 20)                               // two lines: the first on row 20
        XCTAssertEqual(tti[14], 2)                                // centred
        let expected: [UInt8] = [0x0D, 0x0B, 0x0B, 0xCF, 0x43, 0x61, 0xCF, 0x73, 0x61, 0x20,
                                 0x80, 0x76, 0x6F, 0x64, 0x65, 0x81, 0x0A, 0x0A, 0x8A, 0x8A,
                                 0x0D, 0x0B, 0x0B, 0xE2, 0x61, 0x6B, 0x0A, 0x0A]
        XCTAssertEqual(Array(tti[16..<(16 + expected.count)]), expected)
        XCTAssertTrue(tti[(16 + expected.count)...].allSatisfy { $0 == 0x8F })
    }

    func testEBUSTLTopTitleAndThirtyFrames() {
        let (data, _) = EBUSTL.file([sub(1, 2, "{\\an8}Up")], context: ExportContext(fps: 29.97))
        XCTAssertEqual(string(data, 3, 8), "STL30.01")
        XCTAssertEqual(data[1024 + 13], 1)
    }

    func testEBUSTLLongTextGoesOnInExtensionBlocks() {
        let line = String(repeating: "a", count: 40)
        let (data, _) = EBUSTL.file([sub(1, 2, "\(line)\n\(line)\n\(line)")], context: ExportContext())
        XCTAssertEqual(data.count, 1024 + 2 * 128)
        XCTAssertEqual(string(data, 238, 5), "00002")
        XCTAssertEqual(string(data, 243, 5), "00001")
        XCTAssertEqual(Array(data[(1024 + 1)...(1024 + 3)]), [1, 0, 0])      // number 1, block 0
        XCTAssertEqual(Array(data[(1152 + 1)...(1152 + 3)]), [1, 0, 0xFF])   // number 1, last block
    }

    func testEBUSTLCyrillicAndLostCharacters() {
        let (data, lost) = EBUSTL.file([sub(1, 2, "жена")], context: ExportContext(language: "sr-Cyrl"))
        XCTAssertEqual(lost, 0)
        XCTAssertEqual(string(data, 12, 2), "01")
        XCTAssertEqual(string(data, 14, 2), "24")
        XCTAssertEqual(Array(data[(1024 + 19)..<(1024 + 23)]), [0xD6, 0xD5, 0xDD, 0xD0])
        XCTAssertEqual(EBUSTL.encode("日本 $", table: .latin).lost, 2)
        XCTAssertEqual(EBUSTL.encode("$", table: .latin).bytes, [0xA4])
        XCTAssertEqual(EBUSTL.encode("…", table: .latin).bytes, Array("...".utf8))
    }

    // MARK: Export from the app

    func testEveryLanguageKeepsItsOwnFormatAndLineEndings() {
        let f = makeFixture([("en", [sub(1, 2, "Hello")]), ("hr", [sub(1, 2, "Bok")])])
        f.hr.exportFormat = .stl
        f.en.crlf = true
        let all = f.model.exportItems(allLanguages: true, allVideos: false, format: .srt)
        XCTAssertEqual(all.map(\.name), ["Film.en.srt", "Film.hr.stl"])
        XCTAssertEqual(all.map(\.format), [.srt, .stl])
        XCTAssertTrue(String(decoding: all[0].data, as: UTF8.self).contains("\r\n"))
        XCTAssertEqual(all[1].data.count, 1024 + 128)
        // One language at a time, the format picked is the one written.
        f.model.focusTrack(f.hr.id, edit: false)
        let one = f.model.exportItems(allLanguages: false, allVideos: false, format: .avid)
        XCTAssertEqual(one.map(\.name), ["Film.hr.txt"])
    }

    func testByteOrderMarkPerLanguage() {
        let f = makeFixture([("en", [sub(1, 2, "Hello")]), ("hr", [sub(1, 2, "Bok")])])
        f.model.project?.settings.utf8BOM = true
        f.hr.utf8BOM = false
        let items = f.model.exportItems(allLanguages: true, allVideos: false, format: .srt)
        XCTAssertEqual(Array(items[0].data.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(Array(items[1].data.prefix(1)), Array("1".utf8))
    }
}
