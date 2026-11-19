import XCTest
@testable import Titles
@testable import TitlesCore

/// Checks of a title's text itself: broken formatting tags (repaired on export), blank lines,
/// and words only partly in italics. Each is a QC issue with its own fix.
@MainActor
final class TextChecksTests: XCTestCase {

    // MARK: Formatting tags

    func testTagsLeftOpenAreClosedAndStrayOnesDropped() {
        XCTAssertEqual(TextChecks.repairedTags("<i>Hello"), "<i>Hello</i>")
        XCTAssertEqual(TextChecks.repairedTags("<i>One\nTwo"), "<i>One\nTwo</i>")
        XCTAssertEqual(TextChecks.repairedTags("Hello</i> there"), "Hello there")
        XCTAssertEqual(TextChecks.repairedTags("<i>One</i></i>"), "<i>One</i>")
        XCTAssertEqual(TextChecks.repairedTags("<i>One <i>two</i>"), "<i>One two</i>", "opened twice")
    }

    func testCrossedTagsAreUntangledAndEmptyPairsTakenOut() {
        XCTAssertEqual(TextChecks.repairedTags("<i><b>Hi</i></b>"), "<i><b>Hi</b></i>")
        XCTAssertEqual(TextChecks.repairedTags("<i></i>Hello"), "Hello")
        XCTAssertEqual(TextChecks.repairedTags("Hello<i> </i>there"), "Hello there")
    }

    func testMistypedTagsAreWrittenProperly() {
        XCTAssertEqual(TextChecks.repairedTags("< i >Hello</ i >"), "<i>Hello</i>")
        XCTAssertEqual(TextChecks.repairedTags("<i Hello</i>"), "<i>Hello</i>")
        XCTAssertEqual(TextChecks.repairedTags("<i>Hello</i there"), "<i>Hello</i> there")
        XCTAssertEqual(TextChecks.repairedTags("i>Hello</i>"), "<i>Hello</i>")
    }

    func testTextThatIsRightIsLeftAsItWas() {
        for text in ["<i>Hello</i> there", "<I>Hello</I>", "{\\an8}<i>Hello</i>",
                     "<font color=\"red\">Hello</font>", "1 < 2 and 3 > 2", "Line one<br>two",
                     "<i>One\nTwo</i>", "Plain text"] {
            XCTAssertEqual(TextChecks.repairedTags(text), text)
            XCTAssertFalse(TextChecks.hasBrokenTags(text), text)
        }
        XCTAssertTrue(TextChecks.hasBrokenTags("<i>Hello"))
        XCTAssertEqual(TextChecks.brokenTagCount([sub(1, 2, "<i>Hi"), sub(3, 4, "Fine"), sub(5, 6, "</b>No")]), 2)
    }

    // MARK: Blank lines

    func testBlankLinesAreFound() {
        XCTAssertTrue(TextChecks.hasBlankLine("One\n\nTwo"))
        XCTAssertTrue(TextChecks.hasBlankLine("One\n   "))
        XCTAssertTrue(TextChecks.hasBlankLine("\nOne"))
        XCTAssertTrue(TextChecks.hasBlankLine("One\n<i></i>"), "only tags: nothing to read")
        XCTAssertFalse(TextChecks.hasBlankLine("One\nTwo"))
        XCTAssertFalse(TextChecks.hasBlankLine(""))
        XCTAssertFalse(TextChecks.hasBlankLine("  \n "), "no text at all: that's an empty title")
    }

    func testBlankLinesAreTakenOutWithTheirTagsKept() {
        XCTAssertEqual(TextChecks.withoutBlankLines("One\n\nTwo"), "One\nTwo")
        XCTAssertEqual(TextChecks.withoutBlankLines("One\n   "), "One")
        XCTAssertEqual(TextChecks.withoutBlankLines("One\nTwo"), "One\nTwo")
        // The italics still start and stop where they did.
        XCTAssertEqual(TextChecks.withoutBlankLines("<i>\nOne</i>\nTwo"), "<i>One</i>\nTwo")
        XCTAssertEqual(TextChecks.withoutBlankLines("<i>One\n</i>"), "<i>One</i>")
    }

    // MARK: Words partly in italics

    func testWordsPartlyInItalicsAreFoundButWholeWordsAreNot() {
        XCTAssertTrue(TextChecks.hasPartItalicWord("Hel<i>lo</i> there"))
        XCTAssertTrue(TextChecks.hasPartItalicWord("<i>don'</i>t"), "an apostrophe doesn't end a word")
        XCTAssertFalse(TextChecks.hasPartItalicWord("<i>Hello</i> there"))
        XCTAssertFalse(TextChecks.hasPartItalicWord("<i>Hello,</i> there"), "punctuation isn't a letter")
        XCTAssertFalse(TextChecks.hasPartItalicWord("\"<i>Hello</i>\""))
        XCTAssertFalse(TextChecks.hasPartItalicWord("<i>Well</i>-known"), "a hyphen splits words")
        XCTAssertFalse(TextChecks.hasPartItalicWord("He<b>ll</b>o"), "bold isn't italics")
        XCTAssertFalse(TextChecks.hasPartItalicWord("<i>One\nTwo</i>"))
        XCTAssertFalse(TextChecks.hasPartItalicWord("Plain"))
    }

    func testAWordPartlyInItalicsBecomesWhollyOneOrTheOther() {
        XCTAssertEqual(TextChecks.wholeWordItalics("Hel<i>lo</i> there", italic: true), "<i>Hello</i> there")
        XCTAssertEqual(TextChecks.wholeWordItalics("Hel<i>lo</i> there", italic: false), "Hello there")
        XCTAssertEqual(TextChecks.wholeWordItalics("<i>One Tw</i>o", italic: true), "<i>One Two</i>")
        XCTAssertEqual(TextChecks.wholeWordItalics("<i>One Tw</i>o", italic: false), "<i>One</i> Two")
        XCTAssertEqual(TextChecks.wholeWordItalics("{\\an8}Hel<i>lo</i>", italic: true), "{\\an8}<i>Hello</i>",
                       "other tags stay where they were")
        XCTAssertEqual(TextChecks.wholeWordItalics("<i>Hello</i>", italic: false), "<i>Hello</i>",
                       "nothing partly in italics: left alone")
    }

    // MARK: In QC and on export

    func testQCFindsEachOfThem() {
        let a = sub(1, 3, "Hello\n "),
            b = sub(4, 6, "Hel<i>lo</i> there."),
            c = sub(7, 9, "<i>Hello there."),
            d = sub(10, 12, "<i>Hello</i> there."),
            e = sub(13, 15, "")
        let f = makeFixture([("en", [a, b, c, d, e])])
        f.en.spellCheck = false
        let report = Dictionary(uniqueKeysWithValues: f.model.qcReport(for: f.en).map { ($0.id, $0.issues) })
        XCTAssertEqual(report[a.id], [.blankLine])
        XCTAssertEqual(report[b.id], [.partItalic])
        XCTAssertEqual(report[c.id], [.tags])
        XCTAssertNil(report[d.id])
        XCTAssertEqual(report[e.id], [.empty], "an empty title isn't also a blank line")
        XCTAssertEqual(QCRules.describe([.tags, .blankLine], of: c, rules: .general),
                       "a blank line · broken formatting tags")
    }

    func testEachGetsItsFixAndTheFixesLeaveTimingAlone() {
        XCTAssertEqual(QCFix.fixes(for: [.blankLine]), [.removeBlankLines])
        XCTAssertEqual(QCFix.fixes(for: [.partItalic]), [.italicizeWords, .unitalicizeWords])
        XCTAssertEqual(QCFix.fixes(for: [.tags, .lineLength]), [.rebreak, .repairTags])
        // A language locked to the master's timing can still have its text fixed.
        XCTAssertTrue(QCFix.extend.changesTiming)
        XCTAssertTrue(QCFix.widenGaps.changesTiming)
        for fix in [QCFix.rebreak, .removeBlankLines, .italicizeWords, .unitalicizeWords, .repairTags] {
            XCTAssertFalse(fix.changesTiming, fix.rawValue)
        }
    }

    func testTheFixesWorkOnTheirTitleInOneUndoStep() throws {
        let a = sub(1, 3, "Hello\n\nthere."),
            b = sub(4, 6, "Hel<i>lo</i> there."),
            c = sub(7, 9, "<i>Hello there.")
        let f = makeFixture([("en", [a, b, c])])
        f.en.spellCheck = false
        f.model.focusTrack(f.en.id, edit: false)
        f.model.applyQCFix(.removeBlankLines, to: a.id)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).text, "Hello\nthere.")
        f.model.applyQCFix(.italicizeWords, to: b.id)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).text, "<i>Hello</i> there.")
        f.model.undo()
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).text, b.text)
        f.model.applyQCFix(.unitalicizeWords, to: b.id)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(b.id)).text, "Hello there.")
        f.model.applyQCFix(.repairTags, to: c.id)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(c.id)).text, "<i>Hello there.</i>")
        XCTAssertTrue(f.model.qcReport(for: f.en).isEmpty, "nothing left to fix")
        f.model.undo()
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(c.id)).text, c.text)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).text, "Hello\nthere.", "one step at a time")
    }

    func testEveryTitleCanBeRepairedAtOnceInOneUndoStep() throws {
        let a = sub(1, 2, "<i>Hello"), b = sub(3, 4, "Fine."), c = sub(5, 6, "</b>There\n ")
        let f = makeFixture([("en", [a, b, c])])
        f.model.focusTrack(f.en.id, edit: false)
        XCTAssertEqual(f.model.fixTextInAll(.repairTags), 2)
        XCTAssertEqual(f.en.doc.subtitles.map(\.text), ["<i>Hello</i>", "Fine.", "There\n "])
        XCTAssertEqual(f.model.fixTextInAll(.removeBlankLines), 1)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(c.id)).text, "There")
        XCTAssertEqual(f.model.fixTextInAll(.repairTags), 0, "nothing left to repair")
        f.model.undo()
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitles.map(\.text), [a.text, b.text, c.text])
    }

    func testExportRepairsTagsAndClosesUpBlankLines() {
        let out = SubtitleFormats.exportable([sub(1, 2, "<i>Hello\n\nthere"), sub(3, 4, "Fine</i> then."),
                                              sub(5, 6, "<i>\n</i>")]).map(\.1)
        XCTAssertEqual(out, ["<i>Hello\nthere</i>", "Fine then."])
        XCTAssertTrue(SubtitleFormats.srt([sub(1, 2, "<i>Hello")]).contains("<i>Hello</i>\n"))
        // The export says how many titles it repaired.
        let f = makeFixture([("en", [sub(1, 2, "<i>Hello"), sub(3, 4, "Fine.")])])
        let items = f.model.exportItems(allLanguages: false, allVideos: false, format: .srt)
        XCTAssertEqual(items.map(\.repaired), [1])
    }

    // MARK: Remembered

    func testATitlesIssuesAreRememberedUntilItOrItsNeighbourChanges() {
        let a = sub(1, 2, "Hello there."), b = sub(2.04, 4, "Next.")
        let f = makeFixture([("en", [a, b])])
        f.en.spellCheck = false
        f.model.qcIssueMemo.removeAll()
        XCTAssertEqual(f.model.qcIssues(of: a, in: f.en, next: b, overlapping: []), [.gap])
        XCTAssertEqual(f.model.qcIssueMemo.count, 1)
        XCTAssertEqual(f.model.qcIssues(of: a, in: f.en, next: b, overlapping: []), [.gap])
        XCTAssertEqual(f.model.qcIssueMemo.count, 1, "asked again: remembered, not worked out again")
        // The next title starts later: no gap issue.
        var later = b
        later.start = 3
        XCTAssertEqual(f.model.qcIssues(of: a, in: f.en, next: later, overlapping: []), [])
        // Its own text changes.
        var edited = a
        edited.text = "Hello\n "
        XCTAssertEqual(f.model.qcIssues(of: edited, in: f.en, next: later, overlapping: []), [.blankLine])
        XCTAssertEqual(f.model.qcIssues(of: edited, in: f.en, next: later, overlapping: [a.id]), [.blankLine, .overlap])
        // The rules change.
        f.model.setOverrides(f.en, maxCPS: .some(5))
        XCTAssertEqual(f.model.qcIssues(of: a, in: f.en, next: later, overlapping: []), [.readingSpeed])
    }
}
