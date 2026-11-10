import XCTest
import AppKit
@testable import Titles

/// Formatting tags: hidden from the viewer's count, shown as real italics in the editor,
/// and written back exactly.
@MainActor
final class MarkupTests: XCTestCase {

    func testPlainRemovesFormattingTags() {
        XCTAssertEqual(Markup.plain("<i>Hello</i>"), "Hello")
        XCTAssertEqual(Markup.plain("<b>Bold</b> and <u>under</u>"), "Bold and under")
        XCTAssertEqual(Markup.plain("<I>Shout</I>"), "Shout")
        XCTAssertEqual(Markup.plain("<font color=\"#ff0000\">Red</font>"), "Red")
        XCTAssertEqual(Markup.plain("{\\an8}Top of the picture"), "Top of the picture")
        XCTAssertEqual(Markup.plain("<v Roger>Hello</v>"), "Hello")
        XCTAssertEqual(Markup.plain("<c.yellow>Hi</c>"), "Hi")
        XCTAssertEqual(Markup.plain("<i>Two\nlines</i>"), "Two\nlines")
    }

    func testPlainKeepsTextThatOnlyLooksLikeATag() {
        for text in ["a < b and c > d", "a <b and c> d", "I <3 you", "<sigh> Fine.", "x <in> y", "3 < 5 > 2",
                     "No tags at all", ""] {
            XCTAssertEqual(Markup.plain(text), text)
        }
    }

    func testCharacterCountIgnoresTagsAndLineBreaks() {
        XCTAssertEqual(sub(0, 2, "<i>Hello</i>\nworld").characterCount, 10)
        XCTAssertEqual(sub(0, 2, "{\\an8}Hi").characterCount, 2)
        XCTAssertEqual(sub(0, 2, "").characterCount, 0)
        XCTAssertEqual(sub(0, 2, "a < b").characterCount, 5)
    }

    func testAttributedHidesTagsAndAppliesItalics() {
        let shown = Markup.attributed("<i>Hi</i> there")
        XCTAssertEqual(String(shown.characters), "Hi there")
        let runs = Array(shown.runs)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.first?.inlinePresentationIntent, InlinePresentationIntent.emphasized)
        XCTAssertNil(runs.last?.inlinePresentationIntent)

        XCTAssertEqual(String(Markup.attributed("<font color=\"red\">Red</font> {\\an8}top").characters), "Red top")
        XCTAssertEqual(String(Markup.attributed("a < b").characters), "a < b")
    }

    // MARK: The card editor

    func testEditorShowsStyleTagsAsFormatting() {
        let shown = RichMarkup.attributed("<i>Hi</i> <b>there</b>", size: 15)
        XCTAssertEqual(shown.string, "Hi there")
        XCTAssertNotNil(shown.attribute(RichMarkup.italic, at: 0, effectiveRange: nil))
        XCTAssertNil(shown.attribute(RichMarkup.bold, at: 0, effectiveRange: nil))
        XCTAssertNotNil(shown.attribute(RichMarkup.bold, at: 3, effectiveRange: nil))
        XCTAssertNil(shown.attribute(RichMarkup.italic, at: 3, effectiveRange: nil))
    }

    func testEditorKeepsOtherTagsVisibleSoNothingIsLost() {
        XCTAssertEqual(RichMarkup.attributed("{\\an8}Top", size: 15).string, "{\\an8}Top")
        XCTAssertEqual(RichMarkup.attributed("<font color=\"red\">Red</font>", size: 15).string,
                       "<font color=\"red\">Red</font>")
    }

    func testEditorWritesTheSameTagsBack() {
        let samples = [
            "Plain text",
            "<i>Italic</i>",
            "<b>Bold</b> and <i>italic</i>",
            "<u>Underlined</u>",
            "<i>Line one\nline two</i>",
            "<i><b>Both</b></i>",
            "<i>a <b>b</b> c</i>",
            "<b>a <i>b</i></b>",
            "{\\an8}Top",
            "<font color=\"#ffffff\">White</font>",
            "a < b and c > d",
            "",
        ]
        for markup in samples {
            let back = RichMarkup.markup(from: RichMarkup.attributed(markup, size: 15))
            XCTAssertEqual(back, markup)
        }
    }

    func testEditorTidiesTagOrder() {
        // Bold opened first, italic inside: written back italic first, still the same look.
        let back = RichMarkup.markup(from: RichMarkup.attributed("<b><i>Both</i></b>", size: 15))
        XCTAssertEqual(back, "<i><b>Both</b></i>")
        // An unclosed tag is closed.
        XCTAssertEqual(RichMarkup.markup(from: RichMarkup.attributed("<i>Open", size: 15)), "<i>Open</i>")
    }

    func testEditorTextSizeDoesNotChangeTheTags() {
        let big = RichMarkup.markup(from: RichMarkup.attributed("<i>Same</i> text", size: 15))
        let small = RichMarkup.markup(from: RichMarkup.attributed("<i>Same</i> text", size: 7.5))
        XCTAssertEqual(big, small)
    }
}
