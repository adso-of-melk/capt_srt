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

    /// Stands in for the real pointer: where it "is", and what a jog asked of it (in place
    /// of hiding, moving and freezing the real one).
    private final class Pointer {
        var at = CGPoint(x: 400, y: 300)
        var held = 0, released = 0
        var movedTo: CGPoint?
        var putBack: CGPoint?

        @MainActor
        var capture: InputController.PointerCapture {
            InputController.PointerCapture(
                location: { self.at },
                hold: { self.held += 1; self.movedTo = $0 },
                release: { self.released += 1; self.putBack = $0 })
        }
    }

    /// A controller that never touches the real pointer, with its editor window "here".
    private func controller(_ f: Fixture, pointer: Pointer,
                            window: CGRect? = CGRect(x: 100, y: 100, width: 1000, height: 600)) -> InputController {
        let input = InputController(model: f.model)
        input.pointer = pointer.capture
        input.editorFrame = { window }
        return input
    }

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
        let pointer = Pointer()
        pointer.at = CGPoint(x: 1400, y: 40)          // over the desktop, right of the window
        let input = controller(f, pointer: pointer)
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
        XCTAssertEqual(pointer.held, 1)
        // The hidden pointer was brought inside the editor window for the hold.
        let home = try XCTUnwrap(pointer.movedTo)
        XCTAssertTrue(CGRect(x: 100, y: 100, width: 1000, height: 600).contains(home))
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
        XCTAssertEqual(pointer.released, 1)
        XCTAssertEqual(pointer.putBack, CGPoint(x: 1400, y: 40))     // back where it was taken from
        XCTAssertEqual(try start(), moved, accuracy: 0.0001)
        f.model.endJog(commit: true)
    }

    func testAJogStartedInsideTheWindowLeavesThePointerWhereItIs() throws {
        let a = sub(1, 5, "A")
        let f = makeFixture([("en", [a])])
        f.model.mouseJogOn = true
        f.model.select(a.id)
        let pointer = Pointer()                       // inside the window
        let input = controller(f, pointer: pointer)
        // (Reported with no window all the same: the hold is what's looked at here.)
        XCTAssertTrue(input.mouseMovedOutside(try movement(dx: 8, flags: .maskAlternate, at: 10_000_000),
                                              appActive: true, editorIsKey: true))
        XCTAssertEqual(pointer.held, 1)
        XCTAssertNil(pointer.movedTo)
        input.mouseMovedOutside(try movement(dx: 8, flags: [], at: 20_000_000), appActive: true, editorIsKey: true)
        XCTAssertEqual(pointer.released, 1)
        XCTAssertNil(pointer.putBack)
        f.model.endJog(commit: true)
    }

    func testAWobbleOfTheHandOutsideTheWindowIsNotAJog() throws {
        let a = sub(1, 5, "A")
        let f = makeFixture([("en", [a])])
        f.model.mouseJogOn = true
        f.model.select(a.id)
        let pointer = Pointer()
        pointer.at = CGPoint(x: 1400, y: 40)
        let input = controller(f, pointer: pointer)
        // Control-click on something out there: a point or two of travel isn't a jog.
        XCTAssertFalse(input.mouseMovedOutside(try movement(dx: 1, flags: .maskControl, at: 10_000_000),
                                               appActive: true, editorIsKey: true))
        XCTAssertFalse(input.mouseMovedOutside(try movement(dx: -1, flags: .maskControl, at: 20_000_000),
                                               appActive: true, editorIsKey: true))
        XCTAssertEqual(pointer.held, 0)
        // Going on moving is one.
        XCTAssertTrue(input.mouseMovedOutside(try movement(dx: 2, flags: .maskControl, at: 30_000_000),
                                              appActive: true, editorIsKey: true))
        XCTAssertEqual(pointer.held, 1)
        input.mouseMovedOutside(try movement(dx: 2, flags: [], at: 40_000_000), appActive: true, editorIsKey: true)
        XCTAssertEqual(pointer.released, 1)
        f.model.endJog(commit: true)
    }

    /// The pointer's position is watched while the key is held, so the jog starts out there
    /// even when macOS reports no movement to KPTN.SUB at all.
    func testWatchingThePointerStartsAJogOutsideTheWindowWithNoMovementReported() throws {
        let a = sub(1, 5, "A")
        let f = makeFixture([("en", [a])])
        f.model.mouseJogOn = true
        f.model.mouseJogStep = .frame
        f.model.mouseJogSensitivity = 0.35
        f.model.select(a.id)

        // Inside the window: movement comes as events there, and the watch leaves it alone.
        let inside = Pointer()
        let first = controller(f, pointer: inside)
        first.pointerWatchTick(.start, held: [.control], appActive: true, editorIsKey: true)
        inside.at.x += 40
        first.pointerWatchTick(.start, held: [.control], appActive: true, editorIsKey: true)
        XCTAssertEqual(inside.held, 0)

        let pointer = Pointer()
        pointer.at = CGPoint(x: 1400, y: 40)          // over the desktop
        let input = controller(f, pointer: pointer)
        func tick(_ held: NSEvent.ModifierFlags = [.control], active: Bool = true, key: Bool = true) {
            input.pointerWatchTick(.start, held: held, appActive: active, editorIsKey: key)
        }

        // Control goes down: travel is measured from here. Still, or a wobble: nothing.
        tick()
        tick()
        pointer.at.x += 2
        tick()
        XCTAssertEqual(pointer.held, 0)

        // Real travel, but another app is in front, or a sheet is up: nothing.
        pointer.at.x += 20
        tick(active: false)
        tick(key: false)
        XCTAssertEqual(pointer.held, 0)

        // The key let go (or the other one pressed): the watch is over.
        tick([])
        tick([.option])
        XCTAssertEqual(pointer.held, 0)

        // Control again, and real travel: the jog takes the pointer and brings it inside.
        tick()
        pointer.at.x += 6
        tick()
        XCTAssertEqual(pointer.held, 1)
        XCTAssertNotNil(pointer.movedTo)
        // Taken once: later ticks ask nothing more of it.
        tick()
        XCTAssertEqual(pointer.held, 1)

        // From there the reported movement jogs, and letting go puts the pointer back.
        for k in 1...40 {
            input.mouseMovedOutside(try movement(dx: 8, flags: .maskControl, at: UInt64(k) * 10_000_000),
                                    appActive: true, editorIsKey: true)
        }
        XCTAssertTrue(f.model.isJogging)
        XCTAssertGreaterThan(try XCTUnwrap(f.en.doc.subtitle(a.id)).start, 1.2)
        input.mouseMovedOutside(try movement(dx: 8, flags: [], at: 900_000_000), appActive: true, editorIsKey: true)
        XCTAssertEqual(pointer.released, 1)
        XCTAssertEqual(pointer.putBack, CGPoint(x: 1428, y: 40))
        f.model.endJog(commit: true)
    }

    func testTheWatchLeavesThePointerAloneWithNoTitleSelectedOrMouseJogOff() {
        let a = sub(1, 5, "A")
        let f = makeFixture([("en", [a])])
        let pointer = Pointer()
        pointer.at = CGPoint(x: 1400, y: 40)
        let input = controller(f, pointer: pointer)
        func travel() {
            pointer.at.x += 30
            input.pointerWatchTick(.end, held: [.option], appActive: true, editorIsKey: true)
        }
        f.model.mouseJogOn = true
        f.model.select(nil)
        input.pointerWatchTick(.end, held: [.option], appActive: true, editorIsKey: true)   // Option goes down
        travel()
        f.model.select(a.id)
        f.model.mouseJogOn = false
        travel()
        XCTAssertEqual(pointer.held, 0)
        f.model.mouseJogOn = true
        travel()
        XCTAssertEqual(pointer.held, 1)
    }

    func testWhereTheHiddenPointerGoesForAJogFromOutside() throws {
        let window = CGRect(x: 100, y: 100, width: 1000, height: 600)
        // Inside already (or no window to go to): it stays put.
        XCTAssertNil(InputController.jogHome(pointer: CGPoint(x: 400, y: 300), window: window))
        XCTAssertNil(InputController.jogHome(pointer: CGPoint(x: 1400, y: 40), window: nil))
        XCTAssertNil(InputController.jogHome(pointer: CGPoint(x: 1400, y: 40), window: .zero))
        // Outside: over the waveform's part of the window (right of the cards, near the bottom).
        let home = try XCTUnwrap(InputController.jogHome(pointer: CGPoint(x: 1400, y: 40), window: window))
        XCTAssertEqual(home.x, 700, accuracy: 0.001)
        XCTAssertEqual(home.y, 220, accuracy: 0.001)
        // The Mac moves the pointer in coordinates that run down from the top of the main display.
        XCTAssertEqual(InputController.PointerCapture.quartz(CGPoint(x: 700, y: 220), mainDisplayHeight: 1440),
                       CGPoint(x: 700, y: 1220))
    }

    func testMovementOutsideIsLeftAloneWhenKPTNSUBIsntInFrontOrASheetIsUp() throws {
        let a = sub(1, 5, "A")
        let f = makeFixture([("en", [a])])
        f.model.mouseJogOn = true
        f.model.select(a.id)
        let pointer = Pointer()
        pointer.at = CGPoint(x: 1400, y: 40)
        let input = controller(f, pointer: pointer)
        for k in 1...60 {
            let e = try movement(dx: 8, flags: .maskControl, at: UInt64(k) * 10_000_000)
            XCTAssertFalse(input.mouseMovedOutside(e, appActive: false, editorIsKey: true))   // another app in front
            XCTAssertFalse(input.mouseMovedOutside(e, appActive: true, editorIsKey: false))   // a sheet or Settings
        }
        XCTAssertEqual(pointer.held, 0)
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
