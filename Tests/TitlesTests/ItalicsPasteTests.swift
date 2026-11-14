import XCTest
import AppKit
import SwiftUI
@testable import Titles

/// Italics that stay on, ⌘I and ⌘V on a selected title that isn't being typed in,
/// Control-Delete, drawing a title near its neighbours, and the selection colour.
@MainActor
final class ItalicsPasteTests: XCTestCase {

    // MARK: Helpers

    private final class Box {
        var text = ""
        /// The text view only holds its delegate weakly: the box keeps it alive for the test.
        var coordinator: AnyObject?
    }

    /// A card editor without a window, as the card shows it.
    private func editor(_ text: String, startItalic: Bool = false, box: Box,
                        onEmptiedItalic: @escaping () -> Void = {})
        -> (TitleTextView, TitleEditor.Coordinator) {
        box.text = text
        var e = TitleEditor(text: Binding(get: { box.text }, set: { box.text = $0 }),
                            fontSize: 15, focusNow: false, onFocusTaken: {}, onEndEditing: { _ in },
                            liveBreak: { _ in nil }, startItalic: startItalic)
        e.onEmptiedItalic = onEmptiedItalic
        let c = e.makeCoordinator()
        box.coordinator = c
        let tv = TitleTextView(usingTextLayoutManager: false)
        tv.delegate = c
        tv.isRichText = true
        tv.allowsUndo = false
        c.load(text, into: tv, size: 15)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        c.applyTypingStyle(tv)
        c.syncStartItalic(tv)
        return (tv, c)
    }

    private func typingIsItalic(_ tv: NSTextView) -> Bool { tv.typingAttributes[RichMarkup.italic] != nil }

    // MARK: Italics in the card editor

    func testTypingAfterItalicTextStaysItalicAfterTheTextIsReloaded() {
        let box = Box()
        let (tv, c) = editor("<i>Hello</i>", box: box)
        XCTAssertTrue(typingIsItalic(tv))
        // The text shrinks to fit (a new font size) or is re-broken: the editor reloads it.
        let caret = c.caretKey(in: tv)
        c.load("<i>Hello</i>", into: tv, size: 12)
        c.restoreCaret(caret, in: tv)
        XCTAssertTrue(typingIsItalic(tv), "a reload must not switch italics off")
        tv.insertText(" there", replacementRange: tv.selectedRange())
        XCTAssertEqual(box.text, "<i>Hello there</i>")
    }

    func testCommandIAtTheCursorSurvivesAReload() {
        let box = Box()
        let (tv, c) = editor("Hello ", box: box)
        XCTAssertFalse(typingIsItalic(tv))
        tv.toggle(RichMarkup.italic)
        XCTAssertTrue(typingIsItalic(tv))
        let caret = c.caretKey(in: tv)
        c.load("Hello ", into: tv, size: 13)
        c.restoreCaret(caret, in: tv)
        XCTAssertTrue(typingIsItalic(tv), "⌘I waiting at the cursor must survive the text shrinking")
        tv.insertText("world", replacementRange: tv.selectedRange())
        XCTAssertEqual(box.text, "Hello <i>world</i>")
    }

    func testCommandIInAnEmptyCardWorksFirstTime() {
        let box = Box()
        let (tv, _) = editor("", box: box)
        tv.toggle(RichMarkup.italic)
        tv.insertText("Hi", replacementRange: tv.selectedRange())
        XCTAssertEqual(box.text, "<i>Hi</i>")
    }

    func testAnEmptyTitleAskedToStartInItalicsDoes() {
        let box = Box()
        let (tv, _) = editor("", startItalic: true, box: box)
        XCTAssertTrue(typingIsItalic(tv))
        tv.insertText("Hi", replacementRange: tv.selectedRange())
        XCTAssertEqual(box.text, "<i>Hi</i>")
    }

    func testMovingTheCursorDropsAWaitingStyle() {
        let box = Box()
        let (tv, _) = editor("Hello", box: box)
        tv.toggle(RichMarkup.italic)
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertNil(tv.pendingTyping)
    }

    func testClearingAnAllItalicTitleKeepsItItalic() {
        let box = Box()
        var emptied = 0
        let (tv, c) = editor("<i>Voice-over</i>", box: box, onEmptiedItalic: { emptied += 1 })
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        tv.deleteBackward(nil)
        XCTAssertEqual(box.text, "")
        XCTAssertEqual(emptied, 1, "the card is told, so it shows the italic badge")
        XCTAssertTrue(typingIsItalic(tv))
        // The empty card is reloaded (it grows back to full size): still italic.
        c.load("", into: tv, size: 13)
        XCTAssertTrue(typingIsItalic(tv))
        tv.insertText("Next line", replacementRange: tv.selectedRange())
        XCTAssertEqual(box.text, "<i>Next line</i>")
    }

    func testClearingSelectiveItalicsStartsPlain() {
        let box = Box()
        var emptied = 0
        let (tv, _) = editor("Hello <i>there</i>", box: box, onEmptiedItalic: { emptied += 1 })
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        tv.deleteBackward(nil)
        XCTAssertEqual(emptied, 0)
        XCTAssertFalse(typingIsItalic(tv))
        tv.insertText("Plain", replacementRange: tv.selectedRange())
        XCTAssertEqual(box.text, "Plain")
    }

    func testAnEmptiedItalicTitleIsRememberedAndCommandITurnsItOff() {
        let a = sub(1, 2, "")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        // What the card does when its all-italic text is deleted.
        f.model.italicNext = a.id
        // ⌘I in the empty card goes to the title: italics off.
        f.model.toggleItalicOnSelected()
        XCTAssertNil(f.model.italicNext)
        f.model.typeIntoSelected("Plain")
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "Plain")
    }

    func testANewTitleNeverInheritsItalics() {
        let a = sub(1, 2, "")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        f.model.italicNext = a.id
        f.model.createTitle(start: 4, end: 5)
        let new = f.en.doc.subtitles.first { $0.id != a.id }
        XCTAssertNotNil(new)
        XCTAssertNotEqual(f.model.italicNext, new?.id)
        f.model.typeIntoSelected("Hi")
        XCTAssertEqual(f.en.doc.subtitle(new?.id)?.text, "Hi")
    }

    // MARK: Spelling marks while typing

    func testAMisspelledWordKeepsItsMarkWhenTheCursorLandsOnIt() {
        let words = [NSRange(location: 0, length: 4), NSRange(location: 5, length: 4)]   // "wrld wrld"
        let cursorAt = { (i: Int) in NSRange(location: i, length: 0) }
        // Clicked or arrowed onto (not typing): every mark stays.
        XCTAssertEqual(TitleEditor.Coordinator.marked(words, caret: cursorAt(4), typingAt: nil), words)
        XCTAssertEqual(TitleEditor.Coordinator.marked(words, caret: cursorAt(2), typingAt: nil), words)
        // Typing a word: only that word waits until you move on.
        XCTAssertEqual(TitleEditor.Coordinator.marked(words, caret: cursorAt(9), typingAt: 9), [words[0]])
        // The cursor moved away from where the typing was.
        XCTAssertEqual(TitleEditor.Coordinator.marked(words, caret: cursorAt(4), typingAt: 9), words)
    }

    // MARK: Markup helpers

    func testAppendingCarriesOnInTheLastCharactersStyle() {
        XCTAssertEqual(RichMarkup.appending(" there", to: "<i>Hello</i>"), "<i>Hello there</i>")
        XCTAssertEqual(RichMarkup.appending(" there", to: "Hello"), "Hello there")
        XCTAssertEqual(RichMarkup.appending("x", to: "", italic: true), "<i>x</i>")
        XCTAssertEqual(RichMarkup.appending(" plain", to: "<i>Hello</i>", italic: false), "<i>Hello</i> plain")
    }

    func testWholeTitleItalic() {
        XCTAssertTrue(RichMarkup.isAllItalic("<i>Hello</i>"))
        XCTAssertTrue(RichMarkup.isAllItalic("<i>Hello</i>\n<i>there</i>"))
        XCTAssertFalse(RichMarkup.isAllItalic("<i>Hello</i> there"))
        XCTAssertFalse(RichMarkup.isAllItalic(""))
        XCTAssertEqual(RichMarkup.withItalic(true, "<i>Hello</i> there"), "<i>Hello there</i>")
        XCTAssertEqual(RichMarkup.withItalic(false, "<i>Hello</i> there"), "Hello there")
        XCTAssertEqual(RichMarkup.withItalic(true, "{\\an8}Hello"), "{\\an8}<i>Hello</i>")
        XCTAssertTrue(RichMarkup.isAllItalic("{\\an8}<i>Hello</i>"))
        XCTAssertEqual(RichMarkup.withItalic(false, "{\\an8}<i>Hello</i>"), "{\\an8}Hello")
    }

    // MARK: ⌘I and ⌘V on a selected title (waveform clicked last)

    func testCommandIOnASelectedTitleTogglesTheWholeTitle() {
        let a = sub(1, 2, "<i>Hello</i> there")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        f.model.toggleItalicOnSelected()
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "<i>Hello there</i>")
        f.model.toggleItalicOnSelected()
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "Hello there")
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "<i>Hello there</i>")
    }

    func testTypingIntoASelectedItalicTitleStaysItalic() {
        let a = sub(1, 2, "<i>Hello</i>")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        f.model.typeIntoSelected(" there")
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "<i>Hello there</i>")
        XCTAssertEqual(f.model.focusRequest, a.id)
    }

    func testPasteGoesIntoTheSelectedTitleAndBreaksTheLines() {
        let a = sub(1, 4, "")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        f.model.pasteIntoSelected("I never thought I'd see the day when you would come back here again.")
        let lines = shownLines(f.en.doc.subtitle(a.id)?.text ?? "")
        XCTAssertEqual(lines.count, 2, "pasted text is broken by the rules")
        XCTAssertEqual(lines.joined(separator: " "), "I never thought I'd see the day when you would come back here again.")
        XCTAssertEqual(f.model.focusRequest, a.id, "the card opens for typing")
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "", "one ⌘Z takes the paste back out")
    }

    func testPasteAddsToTheEndOfATitle() {
        let a = sub(1, 4, "Hello")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        f.model.pasteIntoSelected(" world\r\n")
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "Hello world")
    }

    func testCommandIThenCommandVPastesInItalics() {
        let a = sub(1, 4, "")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        f.model.toggleItalicOnSelected()
        XCTAssertEqual(f.model.italicNext, a.id)
        f.model.pasteIntoSelected("Hello")
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "<i>Hello</i>")
        XCTAssertNil(f.model.italicNext)
    }

    func testCommandITwiceOnAnEmptyTitleIsPlainAgain() {
        let a = sub(1, 4, "")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        f.model.toggleItalicOnSelected()
        f.model.toggleItalicOnSelected()
        f.model.pasteIntoSelected("Hello")
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "Hello")
    }

    func testCommandIThenCommandVOnAnEmptySlotCreatesAnItalicTitle() {
        let a = sub(1, 2, "Hello")
        let f = makeFixture([("en", [a]), ("hr", [])])
        f.model.focusTrack(f.hr.id, edit: false)
        let key = f.model.rows[0].key
        f.model.doc.selectedID = nil
        f.model.emptySlotRow = key
        f.model.toggleItalicOnSelected()
        f.model.pasteIntoSelected("Bok")
        XCTAssertEqual(f.hr.doc.subtitles.count, 1)
        XCTAssertEqual(f.hr.doc.subtitles.first?.text, "<i>Bok</i>")
        XCTAssertEqual(f.hr.doc.subtitles.first?.start ?? 0, 1, accuracy: 0.001)
    }

    func testPastingNothingSaysSo() {
        let a = sub(1, 4, "Hello")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        f.model.pasteIntoSelected("  \n ")
        XCTAssertEqual(f.en.doc.subtitle(a.id)?.text, "Hello")
        XCTAssertTrue(f.model.statusMessage?.contains("Nothing to paste") ?? false)
    }

    // MARK: Control-Delete

    func testOnlyControlDeleteDeletesATitle() {
        XCTAssertEqual(InputController.deleteKeyAction([.control]), .delete)
        XCTAssertEqual(InputController.deleteKeyAction([.control, .shift]), .delete)
        XCTAssertEqual(InputController.deleteKeyAction([]), .remind)
        XCTAssertEqual(InputController.deleteKeyAction([.shift]), .nothing)
        XCTAssertEqual(InputController.deleteKeyAction([.command]), .nothing)
        XCTAssertEqual(InputController.deleteKeyAction([.option]), .nothing)
    }

    // MARK: Drawing a title near its neighbours

    func testDrawingATitleMeetsResistanceAtTheMinimumGap() {
        let subs = [sub(1, 2), sub(5, 6)]
        let gap = 0.08
        let mid = WaveformNSView.createBarriers(at: 3, in: subs, gap: gap)
        XCTAssertEqual(mid.start, 3, accuracy: 0.0001)
        XCTAssertEqual(mid.lower ?? -1, 2.08, accuracy: 0.0001)
        XCTAssertEqual(mid.upper ?? -1, 4.92, accuracy: 0.0001)

        // Starting inside the gap after a title: the new title starts at the gap's edge.
        let near = WaveformNSView.createBarriers(at: 2.03, in: subs, gap: gap)
        XCTAssertEqual(near.start, 2.08, accuracy: 0.0001)
        let before = WaveformNSView.createBarriers(at: 4.97, in: subs, gap: gap)
        XCTAssertEqual(before.start, 4.92, accuracy: 0.0001)

        // Nothing either side: no resistance.
        let open = WaveformNSView.createBarriers(at: 10, in: subs, gap: gap)
        XCTAssertEqual(open.start, 10, accuracy: 0.0001)
        XCTAssertEqual(open.lower ?? -1, 6.08, accuracy: 0.0001)
        XCTAssertNil(open.upper)

        // Inside a title, or in a gap too small for one: left alone.
        XCTAssertNil(WaveformNSView.createBarriers(at: 1.5, in: subs, gap: gap).lower)
        let tight = WaveformNSView.createBarriers(at: 2.05, in: [sub(1, 2), sub(2.1, 3)], gap: gap)
        XCTAssertNil(tight.lower)
        XCTAssertNil(tight.upper)
        XCTAssertEqual(tight.start, 2.05, accuracy: 0.0001)
    }

    // MARK: Colours

    func testSelectionBracketsHoldAFifthOfTheBoxAndNeverMeet() {
        XCTAssertEqual(WaveformNSView.selectionBracketArm(width: 200), 40, accuracy: 0.001)
        XCTAssertEqual(WaveformNSView.selectionBracketArm(width: 20), 6, accuracy: 0.001)
        for w in stride(from: CGFloat(2), through: 400, by: 1) {
            XCTAssertLessThanOrEqual(2 * WaveformNSView.selectionBracketArm(width: w), w * 0.8 + 0.001)
        }
    }

    func testEachProngEndsInACapsuleWithoutReachingFurther() {
        // A wide box: the line stops short and a 10 pt capsule ends the prong, reaching
        // exactly as far as the old round dot did (arm + 8.5).
        let wide = WaveformNSView.bracketEnd(arm: 40, radius: 6.5, width: 200)
        XCTAssertEqual(wide.capsule?.upperBound ?? 0, 48.5, accuracy: 0.001)
        XCTAssertEqual(wide.capsule.map { $0.upperBound - $0.lowerBound } ?? 0, 10, accuracy: 0.001)
        XCTAssertLessThan(wide.lineTip, wide.capsule?.lowerBound ?? 0)
        // A narrow box: no capsule, the line reaches as before.
        let narrow = WaveformNSView.bracketEnd(arm: 6, radius: 6, width: 30)
        XCTAssertNil(narrow.capsule)
        XCTAssertEqual(narrow.lineTip, 6, accuracy: 0.001)
    }

    func testTheBracketsOuterEdgeIsTheBoxsEdgeAndTheFrameRunsUnderIt() {
        let box = CGRect(x: 100, y: 20, width: 200, height: 60)
        let line = WaveformNSView.selectionLine(for: box)
        let half = WaveformNSView.bracketWidth / 2
        // The bracket is stroked on this line, so its outer edge is the box's own edge.
        XCTAssertEqual(line.rect.insetBy(dx: -half, dy: -half), box)
        // And its outer corners are exactly as round as the box's.
        XCTAssertEqual(line.radius + half, WaveformNSView.boxCornerRadius, accuracy: 0.001)
        // The fine frame (1.5 pt) on the same line is narrower than the bracket: none of it shows.
        XCTAssertLessThan(1.5, WaveformNSView.bracketWidth)
        // A small box: corners never rounder than the brackets can follow.
        let small = WaveformNSView.selectionLine(for: CGRect(x: 0, y: 0, width: 14, height: 12))
        XCTAssertLessThanOrEqual(small.radius, small.arm)
        XCTAssertLessThanOrEqual(small.radius, small.rect.height / 2)
    }

    func testTheEscHintFollowsTheCursorFromCardToCard() {
        let (model, _) = makeModel()
        let a = UUID(), b = UUID()
        model.textCursor(true, in: a)
        XCTAssertEqual(model.cursorIn, a)
        // Tab: the next card can take the cursor before the last one lets it go.
        model.textCursor(true, in: b)
        model.textCursor(false, in: a)
        XCTAssertEqual(model.cursorIn, b)
        // Esc: the cursor leaves, and so does the hint.
        model.textCursor(false, in: b)
        XCTAssertNil(model.cursorIn)
    }

    func testAnEditorTellsItsCardWhenTheCursorComesAndGoes() {
        let box = Box()
        var seen: [Bool] = []
        var e = TitleEditor(text: Binding(get: { box.text }, set: { box.text = $0 }),
                            fontSize: 15, focusNow: false, onFocusTaken: {}, onEndEditing: { _ in },
                            liveBreak: { _ in nil })
        e.onCursor = { seen.append($0) }
        let c = e.makeCoordinator()
        c.focusChanged(true)
        c.focusChanged(false)
        let done = expectation(description: "reported")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(seen, [true, false])
    }

    func testWaveformBoxesShowItalicsAndHideEveryTag() {
        func italic(_ a: NSAttributedString, _ i: Int) -> Bool {
            (a.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?
                .fontDescriptor.symbolicTraits.contains(.italic) ?? false
        }
        let a = WaveformNSView.boxText("{\\an8} Hello <i>there</i>\n", color: .white)
        XCTAssertEqual(a.string, "Hello there")
        XCTAssertFalse(italic(a, 0))                       // "Hello" plain
        XCTAssertTrue(italic(a, 6))                        // "there" italic
        let all = WaveformNSView.boxText("<i><font color=\"#ff0\">Two\nlines</font></i>", color: .white)
        XCTAssertEqual(all.string, "Two\nlines")
        XCTAssertTrue((0..<all.length).allSatisfy { italic(all, $0) })
        XCTAssertEqual(WaveformNSView.boxText("<i> </i>", color: .white).length, 0)
        // No tags at all: the text as it is, upright.
        let plain = WaveformNSView.boxText("  Plain & simple \n", color: .white)
        XCTAssertEqual(plain.string, "Plain & simple")
        XCTAssertFalse(italic(plain, 0))
    }

    func testSelectionAndWarningNeverShareAColour() {
        let statuses: [TimingStatus] = [.ok, .warn, .bad]
        for s in statuses {
            XCTAssertNotEqual(Palette.status(s), Palette.amber, "amber is the selection only")
        }
        XCTAssertEqual(Palette.status(.warn), Palette.gold)
        XCTAssertNotEqual(Palette.gold, Palette.amber)
    }
}
