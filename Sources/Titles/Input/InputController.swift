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
/// Mouse, wheel and keys can be mixed under one hold (wheel for rough, mouse for fine):
/// they all move the same edge through `AppModel.jogMove`, so each picks up exactly
/// where the other left off.
@MainActor
final class InputController {
    weak var model: AppModel?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// The mouse is hidden and frozen for jogging, on behalf of this edge.
    private var capturedEdge: Edge?
    /// Leftover fractions of a step from the mouse and from the wheel.
    private var jogAccumulator: CGFloat = 0
    private var wheelAccumulator: CGFloat = 0

    // Shift+Space while typing: only a deliberate press plays (Shift alone, held a moment,
    // nothing typed with it). Typing "I am" fast just types the space.
    private var shiftDownAt: TimeInterval = 0
    private var typedSinceShift = false
    private var shiftHeld = false

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
                self?.endJog(commit: true)
            }
        }
    }

    // MARK: Dispatch

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard let model else { return e }
        let flags = e.modifierFlags.intersection([.shift, .control, .option, .command])
        // The mouse is only ever held for as long as the key that asked for it.
        if capturedEdge != nil, Self.edge(for: flags) != capturedEdge { releaseCursor() }
        // Only the editor window. Settings and sheets get their keys untouched.
        // (While jogging, the frozen pointer can report no window; that still counts.)
        let inEditor = e.window === model.mainWindow || (model.isJogging && e.window == nil)
        guard inEditor, let window = model.mainWindow else {
            if model.isJogging { endJog(commit: true) }
            return e
        }
        // The home screen has no titles to edit.
        if model.showHome || model.project == nil || model.showProjectView {
            if model.isJogging { endJog(commit: true) }
            return e
        }
        // Typing a timecode to go to: its fields get every key (Tab, Return, Esc).
        if model.editingTimecode { return e }
        if !window.acceptsMouseMovedEvents { window.acceptsMouseMovedEvents = true }

        switch e.type {
        case .flagsChanged:
            let shiftNow = e.modifierFlags.contains(.shift)
            if shiftNow && !shiftHeld { shiftDownAt = e.timestamp; typedSinceShift = false }
            shiftHeld = shiftNow
            let edge = Self.edge(for: flags)
            if let held = model.jogEdge, edge != held { endJog(commit: true) }
            jogAccumulator = 0
            wheelAccumulator = 0
            // Control / Option let go: a nudge made while holding them plays now.
            if !e.modifierFlags.contains(.control) && !e.modifierFlags.contains(.option) {
                model.modifiersReleased()
            }
            return e

        case .mouseMoved:
            // The key's own state travels with the event, so this never depends on having
            // seen the key go down.
            guard let edge = Self.edge(for: flags), model.mouseJogOn, model.hasMedia,
                  model.doc.selectedID != nil else { return e }
            captureCursor(for: edge)
            mouseJog(edge, dx: e.deltaX, coarse: flags.contains(.shift))
            return nil

        case .leftMouseDown, .rightMouseDown:
            // Control+click is right-click on the Mac; ignore clicks while jogging.
            if capturedEdge != nil { return nil }
            // A click in the card being typed in goes to the field editor, so the card never
            // sees it. Still take the playhead back to that title's start.
            if e.type == .leftMouseDown, let editor = window.firstResponder as? NSTextView,
               editor.bounds.contains(editor.convert(e.locationInWindow, from: nil)),
               let s = model.doc.subtitle(model.doc.selectedID) {
                model.seek(s.start)
            }
            return e

        case .scrollWheel:
            guard let edge = Self.edge(for: flags), model.wheelJogOn, model.doc.selectedID != nil else { return e }
            wheelJog(e, edge: edge, coarse: flags.contains(.shift))
            return nil

        case .keyDown:
            return keyDown(e, flags: flags, model: model)

        case .keyUp:
            if e.keyCode == Key.down, model.spotMode == .hold, model.isSpotting {
                model.spotUp(eventTimestamp: e.timestamp)
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
        static let tab: UInt16 = 48
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
        if e.keyCode == Key.escape, model.isJogging {
            endJog(commit: false)
            return nil
        }

        let plain = flags.subtracting(.shift).isEmpty

        if e.keyCode != Key.space { typedSinceShift = true }

        // Shift+Space: play/pause from anywhere. While typing in a card, only when nothing
        // was typed while Shift was down; otherwise it's the space after a capital ("I am").
        if e.keyCode == Key.space, flags == [.shift], !isEditingText || !typedSinceShift {
            if !e.isARepeat { model.togglePlay() }
            return nil
        }

        // Tab / Shift+Tab: next / previous title, from anywhere. Keeps editing if you were.
        if e.keyCode == Key.tab, plain {
            model.selectAdjacent(flags.contains(.shift) ? -1 : 1, keepEditing: isEditingText)
            return nil
        }

        // Control/Option + [ or ]: nudge one frame (Shift: 10). Works while typing too.
        if e.keyCode == Key.leftBracket || e.keyCode == Key.rightBracket, let edge = Self.edge(for: flags) {
            let dir = e.keyCode == Key.leftBracket ? -1 : 1
            model.jogMove(edge, by: Double(dir * (flags.contains(.shift) ? 10 : 1)) * model.frameDuration)
            return nil
        }

        if isEditingText {
            // ⌘I: italic on or off (in a card it shows as italic; it's saved as <i>…</i>).
            if flags == [.command], e.charactersIgnoringModifiers?.lowercased() == "i",
               let editor = NSApp.keyWindow?.firstResponder as? TitleTextView {
                editor.toggle(RichMarkup.italic)
                return nil
            }
            if flags == [.command], e.charactersIgnoringModifiers?.lowercased() == "i",
               let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                let range = editor.selectedRange()
                let selected = (editor.string as NSString).substring(with: range)
                editor.insertText("<i>" + selected + "</i>", replacementRange: range)
                if range.length == 0 {
                    editor.setSelectedRange(NSRange(location: range.location + 3, length: 0))
                }
                return nil
            }
            // ⌘V: once the paste lands, break the title's lines by the rules.
            if flags == [.command], e.charactersIgnoringModifiers?.lowercased() == "v",
               let id = model.doc.selectedID {
                DispatchQueue.main.async { [weak model] in model?.autoBreakAfterPaste(id) }
                return e
            }
            // Return (or Shift+Return) is a line break inside the title, not "done".
            if e.keyCode == Key.returnKey || e.keyCode == Key.enter, flags.subtracting(.shift).isEmpty,
               let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                editor.insertNewlineIgnoringFieldEditor(nil)
                return nil
            }
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
            // Space alone does nothing outside a card; Shift+Space plays and pauses.
            return nil
        case Key.down:
            if model.clock.isPlaying {
                if !e.isARepeat { model.spotDown(eventTimestamp: e.timestamp) }
            } else {
                model.selectAdjacent(1)
            }
            return nil
        case Key.up:
            if model.clock.isPlaying {
                if model.spotMode == .tap && !e.isARepeat { model.spotUp(eventTimestamp: e.timestamp) }
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
            model.editSelected()
            return nil
        case Key.delete, Key.forwardDelete:
            model.deleteSelected()
            return nil
        default:
            // Typing while a title is selected starts editing it (the keystroke isn't lost).
            if let chars = e.characters, let scalar = chars.unicodeScalars.first,
               scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value),
               model.hasTypingTarget {
                model.typeIntoSelected(chars)
                return nil
            }
            return e
        }
    }

    // MARK: Jog

    /// Hides the pointer and freezes it, so mouse movement is raw and never hits the screen edge.
    private func captureCursor(for edge: Edge) {
        guard capturedEdge == nil else { return }
        capturedEdge = edge
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    private func releaseCursor() {
        guard capturedEdge != nil else { return }
        capturedEdge = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    private func endJog(commit: Bool) {
        releaseCursor()
        model?.endJog(commit: commit)
    }

    /// Mouse movement while Control / Option is held.
    private func mouseJog(_ edge: Edge, dx: CGFloat, coarse: Bool) {
        guard let model, dx != 0 else { return }
        wheelAccumulator = 0
        // Even and predictable: the same distance always moves the same number of steps,
        // however fast you move. A sudden jerk counts for at most 8 points, so it can't
        // throw the edge across the screen.
        let d = max(-8, min(8, dx))
        // Turning back starts afresh, so moving back the same distance lands where you began.
        if jogAccumulator != 0 && (jogAccumulator > 0) != (d > 0) { jogAccumulator = 0 }
        // Sensitivity: 40 points of travel per step (finest) down to 2 (fastest).
        let pointsPerStep = 40 * pow(2.0 / 40, model.mouseJogSensitivity)
        jogAccumulator += d / CGFloat(pointsPerStep)
        let whole = Int(jogAccumulator)
        guard whole != 0 else { return }
        jogAccumulator -= CGFloat(whole)
        let step = model.mouseJogStep.seconds(frame: model.frameDuration) * (coarse ? 10 : 1)
        model.jogMove(edge, by: Double(whole) * step)
    }

    /// Wheel or two-finger swipe while Control / Option is held.
    private func wheelJog(_ e: NSEvent, edge: Edge, coarse: Bool) {
        guard let model, e.momentumPhase.isEmpty else { return }
        let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        // Positive = later in time: wheel towards you, or fingers moving right.
        let later = e.isDirectionInvertedFromDevice ? d : -d
        guard later != 0 else { return }
        jogAccumulator = 0
        // Changing direction starts afresh, so one click back undoes one click forward exactly.
        if wheelAccumulator != 0 && (wheelAccumulator > 0) != (later > 0) { wheelAccumulator = 0 }
        // Sensitivity: a quarter of a step per click (finest) up to four steps per click.
        let stepsPerClick = CGFloat(pow(16, model.wheelJogSensitivity) / 4)
        if !e.phase.isEmpty {
            // Trackpad: about 6 points of finger travel counts as a click.
            if e.phase == .began { wheelAccumulator = 0 }
            wheelAccumulator += later / 6 * stepsPerClick
        } else if e.hasPreciseScrollingDeltas {
            // A smooth-scrolling mouse: about 10 points count as a click.
            wheelAccumulator += later / 10 * stepsPerClick
        } else {
            // A clicky wheel: every click counts the same, however fast you turn it.
            wheelAccumulator += (later > 0 ? 1 : -1) * stepsPerClick
        }
        let whole = Int(wheelAccumulator)
        guard whole != 0 else { return }
        wheelAccumulator -= CGFloat(whole)
        let step = model.wheelJogStep.seconds(frame: model.frameDuration) * (coarse ? 10 : 1)
        model.jogMove(edge, by: Double(whole) * step)
    }
}
