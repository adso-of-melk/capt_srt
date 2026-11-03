import AppKit
import CoreGraphics

/// App-wide keyboard, modifier-jog and wheel handling.
///
/// Fine-tuning ("jog"):
///   Hold Control → move the mouse left/right to move the selected title's START.
///   Hold Option  → move the mouse left/right to move its END.
///   Add Shift for coarse steps. Release to lock and preview. Esc while holding cancels.
///   The cursor hides and raw mouse movement is used, so you never hit the screen edge.
/// The same modifiers with the scroll wheel or a two-finger swipe step frame by frame,
/// and with [ / ] they nudge by one frame (Shift: 10).
@MainActor
final class InputController {
    weak var model: AppModel?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    private var armedEdge: Edge?
    private var jogEdge: Edge?
    private var jogID: UUID?
    private var jogTarget: Double = 0
    private var jogAccumulator: CGFloat = 0
    private var wheelAccumulator: CGFloat = 0

    init(model: AppModel) {
        self.model = model
    }

    func install() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .mouseMoved,
                                           .leftMouseDown, .rightMouseDown, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handle(event)
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.armedEdge = nil
                self?.endJog(commit: true)
            }
        }
    }

    // MARK: Dispatch

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard let model else { return e }
        let flags = e.modifierFlags.intersection([.shift, .control, .option, .command])

        switch e.type {
        case .flagsChanged:
            e.window?.acceptsMouseMovedEvents = true
            let edge = Self.edge(for: flags)
            if jogEdge != nil && edge != jogEdge { endJog(commit: true) }
            armedEdge = edge
            jogAccumulator = 0
            return e

        case .mouseMoved:
            guard let edge = armedEdge, model.hasMedia, let id = model.doc.selectedID else { return e }
            if jogEdge == nil { beginJog(edge, id) }
            applyJog(dx: e.deltaX, coarse: flags.contains(.shift))
            return nil

        case .leftMouseDown, .rightMouseDown:
            // Control+click is right-click on the Mac; ignore clicks while jogging.
            return jogEdge != nil ? nil : e

        case .scrollWheel:
            guard let edge = Self.edge(for: flags), model.doc.selectedID != nil else { return e }
            wheelNudge(e, edge: edge, coarse: flags.contains(.shift))
            return nil

        case .keyDown:
            return keyDown(e, flags: flags, model: model)

        case .keyUp:
            if e.keyCode == Key.down, model.spotMode == .hold, model.isSpotting {
                model.spotUp()
                return nil
            }
            return e

        default:
            return e
        }
    }

    /// Control alone = start, Option alone = end (Shift may be added for coarse steps).
    private static func edge(for flags: NSEvent.ModifierFlags) -> Edge? {
        let core = flags.subtracting(.shift)
        if core == [.control] { return .start }
        if core == [.option] { return .end }
        return nil
    }

    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    // MARK: Keys

    private enum Key {
        static let space: UInt16 = 49
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let leftBracket: UInt16 = 33
        static let rightBracket: UInt16 = 30
    }

    private func keyDown(_ e: NSEvent, flags: NSEvent.ModifierFlags, model: AppModel) -> NSEvent? {
        if e.keyCode == Key.escape, jogEdge != nil {
            endJog(commit: false)
            return nil
        }

        // Control/Option + [ or ]: nudge one frame (Shift: 10). Works while typing too.
        if e.keyCode == Key.leftBracket || e.keyCode == Key.rightBracket, let edge = Self.edge(for: flags) {
            let dir = e.keyCode == Key.leftBracket ? -1 : 1
            model.nudge(edge, frames: dir * (flags.contains(.shift) ? 10 : 1))
            return nil
        }

        if isEditingText {
            if e.keyCode == Key.escape {
                model.focusRequest = nil
                e.window?.makeFirstResponder(nil)
                return nil
            }
            return e
        }

        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return e }

        switch e.keyCode {
        case Key.space:
            if !e.isARepeat { model.togglePlay() }
            return nil
        case Key.down:
            if model.clock.isPlaying {
                if !e.isARepeat { model.spotDown() }
            } else {
                model.selectAdjacent(1)
            }
            return nil
        case Key.up:
            if model.clock.isPlaying {
                if model.spotMode == .tap && !e.isARepeat { model.spotUp() }
            } else {
                model.selectAdjacent(-1)
            }
            return nil
        case Key.left:
            model.stepFrames(flags.contains(.shift) ? -Int(model.engine.frameRate.rounded()) : -1)
            return nil
        case Key.right:
            model.stepFrames(flags.contains(.shift) ? Int(model.engine.frameRate.rounded()) : 1)
            return nil
        case Key.returnKey, Key.enter:
            if let id = model.doc.selectedID { model.focusRequest = id }
            return nil
        case Key.delete, Key.forwardDelete:
            model.deleteSelected()
            return nil
        default:
            // Typing while a title is selected starts editing it (the keystroke isn't lost).
            if let chars = e.characters, let scalar = chars.unicodeScalars.first,
               scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value),
               model.doc.selectedID != nil {
                model.typeIntoSelected(chars)
                return nil
            }
            return e
        }
    }

    // MARK: Jog

    private func beginJog(_ edge: Edge, _ id: UUID) {
        guard let model, let s = model.doc.subtitle(id) else { return }
        model.engine.pause()
        model.doc.beginLive()
        jogEdge = edge
        jogID = id
        jogTarget = edge == .start ? s.start : s.end
        jogAccumulator = 0
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    private func applyJog(dx: CGFloat, coarse: Bool) {
        guard let model, let edge = jogEdge, let id = jogID else { return }
        // Speed-sensitive: slow movement = single frames, fast = bigger jumps.
        let speed = abs(dx)
        let framesPerPoint: CGFloat = speed < 2 ? 0.12 : speed < 6 ? 0.25 : speed < 15 ? 0.5 : 1.0
        jogAccumulator += dx * framesPerPoint * (coarse ? 5 : 1)
        let whole = Int(jogAccumulator)
        guard whole != 0 else { return }
        jogAccumulator -= CGFloat(whole)
        jogTarget += Double(whole) * model.frameDuration
        if let value = model.moveEdge(edge, of: id, to: jogTarget, clamp: true) {
            jogTarget = value
            model.scrubTo(value)
        }
    }

    private func endJog(commit: Bool) {
        guard let edge = jogEdge else { return }
        let id = jogID
        jogEdge = nil
        jogID = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        guard let model else { return }
        if commit {
            model.doc.commitLive()
            if let id { model.preview(edge, of: id) }
        } else {
            model.doc.cancelLive()
            if let id, let s = model.doc.subtitle(id) {
                model.engine.seek(to: edge == .start ? s.start : s.end, exact: true)
            }
        }
    }

    // MARK: Wheel / two-finger swipe with a modifier

    private func wheelNudge(_ e: NSEvent, edge: Edge, coarse: Bool) {
        guard let model, e.momentumPhase.isEmpty else { return }
        let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        // Positive = later in time: wheel towards you, or fingers moving right.
        let later = e.isDirectionInvertedFromDevice ? d : -d
        let stepFrames = coarse ? 10 : 1
        if e.hasPreciseScrollingDeltas {
            if e.phase == .began { wheelAccumulator = 0 }
            wheelAccumulator += later
            let pointsPerStep: CGFloat = 6
            while abs(wheelAccumulator) >= pointsPerStep {
                let dir = wheelAccumulator > 0 ? 1 : -1
                wheelAccumulator -= CGFloat(dir) * pointsPerStep
                model.nudge(edge, frames: dir * stepFrames)
            }
        } else if later != 0 {
            model.nudge(edge, frames: (later > 0 ? 1 : -1) * stepFrames)
        }
    }
}
