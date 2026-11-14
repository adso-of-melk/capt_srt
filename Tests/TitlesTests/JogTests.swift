import XCTest
import AppKit
@testable import Titles

/// Fine-tuning an edge with Control or Option held. The mouse, the wheel and the [ ] keys
/// all move the same edge through one session, so they can be mixed under one hold.
@MainActor
final class JogTests: XCTestCase {
    private func end(_ f: Fixture, _ id: UUID) throws -> Double {
        try XCTUnwrap(f.en.doc.subtitle(id)).end
    }

    func testMouseAndWheelCarryOnFromWhereTheOtherStopped() throws {
        let a = sub(1, 3, "A")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        let frame = f.model.frameDuration

        // Wheel for rough ...
        f.model.jogMove(.end, by: 10 * frame)
        XCTAssertEqual(try end(f, a.id), 3.4, accuracy: 0.0001)
        XCTAssertEqual(f.engine.currentTime, 3.4, accuracy: 0.0001)       // the picture is on the edge

        // ... mouse for fine: it starts from the wheel's position, not from where it last was.
        f.model.jogMove(.end, by: -frame)
        XCTAssertEqual(try end(f, a.id), 3.36, accuracy: 0.0001)
        f.model.jogMove(.end, by: -frame)
        XCTAssertEqual(try end(f, a.id), 3.32, accuracy: 0.0001)

        // And back to the wheel, then the mouse once more: no jumps either way.
        f.model.jogMove(.end, by: 5 * frame)
        XCTAssertEqual(try end(f, a.id), 3.52, accuracy: 0.0001)
        f.model.jogMove(.end, by: frame)
        XCTAssertEqual(try end(f, a.id), 3.56, accuracy: 0.0001)
        XCTAssertEqual(f.engine.currentTime, 3.56, accuracy: 0.0001)
    }

    func testAnEdgeThatIsNotOnAFrameKeepsItsOffset() throws {
        let a = sub(1.013, 3.007, "A")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        f.model.jogMove(.start, by: 0.04)
        f.model.jogMove(.start, by: 0.04)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).start, 1.093, accuracy: 0.0001)
    }

    func testAWholeHoldIsOneUndoStepAndPlaysOnceWhenTheKeyIsLetGo() throws {
        let a = sub(1, 3, "A")
        let f = makeFixture([("en", [a])])
        f.model.replayAfterJog = true
        f.model.select(a.id)
        f.model.jogMove(.end, by: 0.2)
        f.model.jogMove(.end, by: -0.04)
        f.model.jogMove(.end, by: 0.08)

        // A pause in the middle of a hold (long enough for any timer to have fired)
        // neither ends the jog nor replays the picture.
        _ = waitUntil(timeout: 0.9) { false }
        XCTAssertTrue(f.model.isJogging)
        XCTAssertTrue(f.en.doc.isLive)
        XCTAssertTrue(f.engine.ranges.isEmpty)
        f.model.jogMove(.end, by: 0.04)
        XCTAssertEqual(try end(f, a.id), 3.28, accuracy: 0.0001)

        // Letting go: one replay of the whole title, one undo step.
        f.model.endJog(commit: true)
        XCTAssertFalse(f.model.isJogging)
        XCTAssertEqual(f.engine.ranges.count, 1)
        XCTAssertEqual(f.engine.ranges.first?.to ?? 0, 3.53, accuracy: 0.0001)
        _ = waitUntil(timeout: 0.9) { false }
        XCTAssertEqual(f.engine.ranges.count, 1)                       // nothing plays a second time
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitles, [a])
        XCTAssertFalse(f.en.doc.canUndo)
    }

    func testEscapeDropsTheHoldAndPutsThePictureBack() throws {
        let a = sub(1, 3, "A")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        f.model.jogMove(.start, by: 0.3)
        XCTAssertEqual(f.engine.currentTime, 1.3, accuracy: 0.0001)
        f.model.endJog(commit: false)
        XCTAssertEqual(f.en.doc.subtitles, [a])
        XCTAssertFalse(f.en.doc.canUndo)
        XCTAssertEqual(f.engine.currentTime, 1, accuracy: 0.0001)
        XCTAssertTrue(f.engine.ranges.isEmpty)
    }

    func testPushingAgainstANeighbourAndBackReturnsAtOnce() throws {
        let a = sub(1, 2, "A"), b = sub(2.5, 3.5, "B")
        let f = makeFixture([("en", [a, b])])
        f.model.select(a.id)
        f.model.jogMove(.end, by: 1)                                    // far too much
        XCTAssertEqual(try end(f, a.id), 2.42, accuracy: 0.0001)        // stops 2 frames before B
        f.model.jogMove(.end, by: -0.04)                                // one frame back moves at once
        XCTAssertEqual(try end(f, a.id), 2.38, accuracy: 0.0001)
        f.model.endJog(commit: true)
    }

    func testSwitchingEdgeEndsTheHoldOnTheFirstEdge() throws {
        let a = sub(1, 3, "A")
        let f = makeFixture([("en", [a])])
        f.model.replayAfterJog = true
        f.model.select(a.id)
        f.model.jogMove(.start, by: 0.2)
        f.model.jogMove(.end, by: 0.2)                                  // Option instead of Control
        XCTAssertEqual(f.engine.ranges.count, 1)                        // the start's hold finished
        XCTAssertEqual(f.model.jogEdge, .end)
        f.model.endJog(commit: true)
        XCTAssertEqual(f.engine.ranges.count, 2)
        let moved = try XCTUnwrap(f.en.doc.subtitle(a.id))
        XCTAssertEqual(moved.start, 1.2, accuracy: 0.0001)
        XCTAssertEqual(moved.end, 3.2, accuracy: 0.0001)
        f.model.undo()
        f.model.undo()
        XCTAssertEqual(f.en.doc.subtitles, [a])
    }

    func testALockedLanguageNeverStartsAHold() throws {
        let a = sub(1, 2, "A")
        let f = makeFixture([("en", [a])])
        f.model.addLanguage(Language.named("hr"), locked: true, copyText: false)
        let before = f.hr.doc.subtitles
        f.model.select(before[0].id)
        f.model.statusMessage = nil
        f.model.jogMove(.end, by: 0.2)
        f.model.jogMove(.end, by: 0.2)
        XCTAssertFalse(f.model.isJogging)
        XCTAssertEqual(f.hr.doc.subtitles, before)
        XCTAssertNotNil(f.model.statusMessage)
        XCTAssertTrue(f.engine.ranges.isEmpty)
    }

    func testClosingTheProjectMidHoldLeavesNothingBehind() {
        let a = sub(1, 3, "A")
        let f = makeFixture([("en", [a])])
        f.model.select(a.id)
        f.model.jogMove(.end, by: 0.2)
        XCTAssertTrue(f.model.isJogging)
        f.model.closeProject(save: false)
        XCTAssertFalse(f.model.isJogging)
    }

    // MARK: Mouse jog outside the window

    /// Mouse movement as macOS reports it with the pointer over the desktop: no window.
    private func movement(dx: Int64, flags: CGEventFlags, at stamp: UInt64) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                       mouseCursorPosition: CGPoint(x: 5, y: 5), mouseButton: .left))
        cg.setIntegerValueField(.mouseEventDeltaX, value: dx)
        cg.flags = flags
        cg.timestamp = stamp
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    func testAJogStartsAndCarriesOnWithThePointerOutsideTheWindow() throws {
        let a = sub(1, 5, "A")
        let f = makeFixture([("en", [a])])
        f.model.mouseJogOn = true
        f.model.mouseJogStep = .frame
        f.model.mouseJogSensitivity = 0.35
        f.model.select(a.id)
        let input = InputController(model: f.model)
        var held = 0, released = 0
        input.pointer = InputController.PointerCapture(hold: { held += 1 }, release: { released += 1 })
        func start() throws -> Double { try XCTUnwrap(f.en.doc.subtitle(a.id)).start }

        // Control held, pointer over the desktop: the first movement takes hold of the
        // pointer, and enough travel moves the start, wherever the pointer is.
        var last: NSEvent?
        for k in 1...60 {
            let e = try movement(dx: 8, flags: .maskControl, at: UInt64(k) * 10_000_000)
            XCTAssertNil(e.window)
            XCTAssertTrue(input.mouseMovedOutside(e, appActive: true, editorIsKey: true))
            last = e
        }
        XCTAssertEqual(held, 1)
        XCTAssertTrue(f.model.isJogging)
        XCTAssertEqual(f.model.jogEdge, .start)
        let moved = try start()
        XCTAssertGreaterThan(moved, 1.2)

        // The same movement reported a second time counts once.
        for _ in 1...60 { input.mouseMovedOutside(try XCTUnwrap(last), appActive: true, editorIsKey: true) }
        XCTAssertEqual(try start(), moved, accuracy: 0.0001)

        // The key let go: the pointer is free again, and movement is just movement.
        let free = try movement(dx: 8, flags: [], at: 900_000_000)
        XCTAssertFalse(input.mouseMovedOutside(free, appActive: true, editorIsKey: true))
        XCTAssertEqual(released, 1)
        XCTAssertEqual(try start(), moved, accuracy: 0.0001)
        f.model.endJog(commit: true)
    }

    func testMovementOutsideIsLeftAloneWhenKPTNSUBIsntInFrontOrASheetIsUp() throws {
        let a = sub(1, 5, "A")
        let f = makeFixture([("en", [a])])
        f.model.mouseJogOn = true
        f.model.select(a.id)
        let input = InputController(model: f.model)
        var held = 0
        input.pointer = InputController.PointerCapture(hold: { held += 1 }, release: {})
        for k in 1...60 {
            let e = try movement(dx: 8, flags: .maskControl, at: UInt64(k) * 10_000_000)
            XCTAssertFalse(input.mouseMovedOutside(e, appActive: false, editorIsKey: true))   // another app in front
            XCTAssertFalse(input.mouseMovedOutside(e, appActive: true, editorIsKey: false))   // a sheet or Settings
        }
        XCTAssertEqual(held, 0)
        XCTAssertFalse(f.model.isJogging)
        XCTAssertEqual(try XCTUnwrap(f.en.doc.subtitle(a.id)).start, 1, accuracy: 0.0001)
    }

    func testMouseJogPicksTheEdgeFromTheKeyHeld() {
        func edge(_ flags: NSEvent.ModifierFlags, on: Bool = true, media: Bool = true, selection: Bool = true) -> Edge? {
            InputController.mouseJogEdge(flags: flags, mouseJogOn: on, hasMedia: media, hasSelection: selection)
        }
        XCTAssertEqual(edge([.control]), .start)
        XCTAssertEqual(edge([.option]), .end)
        XCTAssertEqual(edge([.control, .shift]), .start)        // Shift: coarse steps
        XCTAssertNil(edge([.control, .option]))
        XCTAssertNil(edge([]))
        XCTAssertNil(edge([.control], on: false))              // mouse jog off in Settings
        XCTAssertNil(edge([.control], media: false))
        XCTAssertNil(edge([.control], selection: false))
    }

    func testMovementOutsideTheWindowJogsOnlyWhileKPTNSUBHasTheKeyboard() {
        XCTAssertTrue(InputController.acceptsOutsideMovement(appActive: true, editorIsKey: true, editing: true))
        XCTAssertFalse(InputController.acceptsOutsideMovement(appActive: false, editorIsKey: true, editing: true))
        XCTAssertFalse(InputController.acceptsOutsideMovement(appActive: true, editorIsKey: false, editing: true))
        XCTAssertFalse(InputController.acceptsOutsideMovement(appActive: true, editorIsKey: true, editing: false))
    }
}
