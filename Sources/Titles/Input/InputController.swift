import AppKit
import CoreGraphics
import os

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
    /// Mouse movement that macOS hands to another app (its window is under the pointer).
    /// Movement over the desktop comes to KPTN.SUB itself, with no window: see `handle`.
    private var outsideMonitor: Any?
    /// The time of the last movement taken from outside the window, so one movement reported
    /// both to KPTN.SUB and to the app under the pointer counts once.
    private var lastOutsideMove: TimeInterval = -1
    /// One line in the Mac's log per hold of Control/Option with the pointer outside the
    /// window, saying how the movement was seen and whether it was taken. If a jog out there
    /// ever fails again, the log says why (Console, or `log show`, subsystem KPTN.SUB).
    private let jogLog = Logger(subsystem: "KPTN.SUB", category: "jog")
    private var loggedOutsideHold = false

    /// Hiding and freezing the pointer for a jog. Tests swap in one that leaves the real
    /// mouse alone.
    @MainActor
    struct PointerCapture {
        /// Where the pointer is on the screen (AppKit's coordinates: y goes up).
        var location: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
        /// Hides the pointer and freezes it. With `moveTo`, it is put there first: a jog that
        /// starts outside the editor window brings the hidden pointer inside.
        var hold: @MainActor (_ moveTo: CGPoint?) -> Void = { target in
            NSCursor.hide()
            if let target {
                CGWarpMouseCursorPosition(PointerCapture.quartz(target))
                // After moving the pointer, macOS ignores the mouse for a quarter of a
                // second; joining the two again ends that at once.
                CGAssociateMouseAndMouseCursorPosition(1)
            }
            CGAssociateMouseAndMouseCursorPosition(0)
        }
        /// Lets the pointer go and shows it, back where it was taken from (`putBack`).
        var release: @MainActor (_ putBack: CGPoint?) -> Void = { back in
            CGAssociateMouseAndMouseCursorPosition(1)
            if let back {
                CGWarpMouseCursorPosition(PointerCapture.quartz(back))
                CGAssociateMouseAndMouseCursorPosition(1)
            }
            NSCursor.unhide()
        }

        /// AppKit's screen point (y up from the bottom of the main display) as Quartz wants
        /// it (y down from the top of the main display).
        static func quartz(_ p: CGPoint, mainDisplayHeight: CGFloat? = nil) -> CGPoint {
            let height = mainDisplayHeight ?? CGDisplayBounds(CGMainDisplayID()).height
            return CGPoint(x: p.x, y: height - p.y)
        }
    }
    var pointer = PointerCapture()
    /// The editor window's place on the screen. Tests give one; the app reads its window.
    var editorFrame: (@MainActor () -> CGRect?)?

    /// Where the pointer was when a jog took it from outside the editor window. It goes back
    /// there when the key is let go.
    private var takenFrom: CGPoint?
    /// The first movement reported after the pointer was brought inside includes that move.
    private var skipNextMovement = false
    /// How far the mouse has travelled outside the window during this hold of the key.
    private var outsideTravel: CGFloat = 0
    /// Outside the window a jog starts after this much travel (points), so a Control-click or
    /// Option-click out there, with a slight wobble of the hand, isn't taken for one.
    static let outsideStartDistance: CGFloat = 3
    /// While Control or Option is held, the pointer's position is also watched directly, so
    /// a jog starts out there whether or not macOS reports the movement to KPTN.SUB.
    private var watch: Timer?
    /// Where the pointer was when the key went down (or last was, inside the window).
    private var watchFrom: CGPoint?
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
    /// Space put the cursor into a card; its key repeats are swallowed until another key.
    private var spaceOpenedCard = false
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
        // Mouse events only (no keys), so this needs no Accessibility permission.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.mouseMovedOutside(event, viaOtherApp: true) }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopWatching()
                self?.endJog(commit: true)
            }
        }
    }

    // MARK: Dispatch

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard let model else { return e }
        // The pointer isn't over any KPTN.SUB window (the desktop, the menu bar, past the
        // window's edge): macOS still sends the active app its movement, with no window.
        // A jog starts and carries on out there exactly as it does over the waveform.
        if e.type == .mouseMoved, e.window == nil {
            return mouseMovedOutside(e) ? nil : e
        }
        if e.type == .flagsChanged {
            loggedOutsideHold = false
            outsideTravel = 0
        }
        let flags = e.modifierFlags.intersection([.shift, .control, .option, .command])
        // The mouse is only ever held for as long as the key that asked for it.
        if capturedEdge != nil, Self.edge(for: flags) != capturedEdge { releaseCursor() }
        // Only the editor window. Settings and sheets get their keys untouched.
        // (While jogging, an event can report no window; that still counts.)
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
            watchPointer(for: Self.mouseJogEdge(flags: flags, mouseJogOn: model.mouseJogOn, hasMedia: model.hasMedia,
                                                hasSelection: model.doc.selectedID != nil))
            // Control / Option let go: a nudge made while holding them plays now.
            if !e.modifierFlags.contains(.control) && !e.modifierFlags.contains(.option) {
                model.modifiersReleased()
            }
            return e

        case .mouseMoved:
            // A jog that began outside the window brought the pointer inside: the first
            // movement reported after that is the move itself, not the hand.
            if skipNextMovement, capturedEdge != nil {
                skipNextMovement = false
                return nil
            }
            // The key's own state travels with the event, so this never depends on having
            // seen the key go down.
            return jogWithMouse(e, flags: flags, model: model) ? nil : e

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
        NSApp.keyWindow?.firstResponder is TitleTextView
    }

    enum DeleteKeyAction { case delete, remind, nothing }

    /// Delete or Forward Delete outside a card: only with Control does it delete the title.
    static func deleteKeyAction(_ flags: NSEvent.ModifierFlags) -> DeleteKeyAction {
        let f = flags.intersection([.shift, .control, .option, .command])
        if f.subtracting(.shift) == [.control] { return .delete }
        return f.isEmpty ? .remind : .nothing
    }

    /// Another text field (Find, Replace) has the keyboard: it gets every key.
    private var isInOtherTextField: Bool {
        guard let fr = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return !(fr is TitleTextView)
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

    func keyDown(_ e: NSEvent, flags: NSEvent.ModifierFlags, model: AppModel) -> NSEvent? {
        if e.keyCode == Key.escape, model.isJogging {
            endJog(commit: false)
            return nil
        }

        // Typing in the Find or Replace field: every key is the field's.
        // Esc there closes Find.
        if isInOtherTextField {
            if e.keyCode == Key.escape, model.find.isShown, model.sheet == nil {
                model.find.close()
                return nil
            }
            return e
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
            let back = flags.contains(.shift)
            model.selectAdjacent(back ? -1 : 1, keepEditing: isEditingText, restart: back)
            return nil
        }

        // Control/Option + [ or ]: nudge one frame (Shift: 10). Works while typing too.
        if e.keyCode == Key.leftBracket || e.keyCode == Key.rightBracket, let edge = Self.edge(for: flags) {
            let dir = e.keyCode == Key.leftBracket ? -1 : 1
            model.jogMove(edge, by: Double(dir * (flags.contains(.shift) ? 10 : 1)) * model.frameDuration)
            return nil
        }

        if isEditingText {
            // Space opened this card: holding it down doesn't type spaces into it.
            if e.keyCode == Key.space, e.isARepeat, spaceOpenedCard { return nil }
            spaceOpenedCard = false
            // ⌘I: italic on or off (in a card it shows as italic; it's saved as <i>…</i>).
            if flags == [.command], e.charactersIgnoringModifiers?.lowercased() == "i",
               let editor = NSApp.keyWindow?.firstResponder as? TitleTextView {
                // An empty title's italics belong to the title (its card shows a badge), so
                // they hold until typing starts, however the card is reloaded.
                if editor.string.isEmpty, model.doc.selectedID != nil {
                    model.toggleItalicOnSelected()
                } else {
                    editor.toggle(RichMarkup.italic)
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

        // A selected title that isn't being typed in (say the waveform was clicked last):
        // ⌘V pastes into it and ⌘I switches italics, just as typing goes straight into it.
        if flags == [.command], model.hasTypingTarget, let key = e.charactersIgnoringModifiers?.lowercased() {
            if key == "v" { model.pasteIntoSelected(); return nil }
            if key == "i" { model.toggleItalicOnSelected(); return nil }
        }

        // Control-Delete deletes the selected title. Plain Delete doesn't, so a title can't
        // be lost by a stray key press.
        if e.keyCode == Key.delete || e.keyCode == Key.forwardDelete {
            switch Self.deleteKeyAction(flags) {
            case .delete: model.deleteSelected()
            case .remind: if model.doc.selectedID != nil { model.flash("To delete the title, press Control-Delete.") }
            case .nothing: break
            }
            return nil
        }

        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return e }

        switch e.keyCode {
        case Key.space:
            // Space outside a card puts the cursor at the end of the selected title's text (no
            // space is typed), like Return; Shift+Space plays and pauses.
            if !e.isARepeat, model.hasTypingTarget {
                model.editSelected()
                spaceOpenedCard = true
            }
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

    /// The edge a mouse movement jogs: Control or Option held, mouse jog on, a video, and a
    /// selected title. nil: the movement is just a movement.
    static func mouseJogEdge(flags: NSEvent.ModifierFlags, mouseJogOn: Bool, hasMedia: Bool,
                             hasSelection: Bool) -> Edge? {
        guard mouseJogOn, hasMedia, hasSelection else { return nil }
        return edge(for: flags)
    }

    /// Movement seen outside the app counts only while KPTN.SUB is the active app and its
    /// editor window has the keyboard (not a sheet, Settings, or another app).
    static func acceptsOutsideMovement(appActive: Bool, editorIsKey: Bool, editing: Bool) -> Bool {
        appActive && editorIsKey && editing
    }

    /// Mouse movement with Control / Option held: jog the selected title's edge.
    private func jogWithMouse(_ e: NSEvent, flags: NSEvent.ModifierFlags, model: AppModel,
                              seenBy route: String = "its own events") -> Bool {
        guard let edge = Self.mouseJogEdge(flags: flags, mouseJogOn: model.mouseJogOn, hasMedia: model.hasMedia,
                                           hasSelection: model.doc.selectedID != nil) else { return false }
        captureCursor(for: edge, seenBy: route)
        mouseJog(edge, dx: e.deltaX, coarse: flags.contains(.shift))
        return true
    }

    /// Whether the editor is showing (not Home, the project's videos, or a timecode being typed).
    private func isEditing(_ model: AppModel) -> Bool {
        !model.showHome && model.project != nil && !model.showProjectView && !model.editingTimecode
    }

    /// One line in the log per hold of the key with the pointer outside the window.
    private func logOutside(_ route: String, key: Bool, editing: Bool, model: AppModel) {
        guard !loggedOutsideHold else { return }
        loggedOutsideHold = true
        let selected = model.doc.selectedID != nil
        let jogOn = model.mouseJogOn, media = model.hasMedia
        jogLog.notice("jog key held, pointer outside the window: seen by \(route, privacy: .public) editorKey=\(key) editing=\(editing) selection=\(selected) mouseJog=\(jogOn) media=\(media)")
    }

    /// Mouse movement with the pointer outside every KPTN.SUB window (the desktop, or another
    /// app's window): the jog starts and goes on as if it were over the waveform. Returns
    /// whether the movement was used. `appActive` and `editorIsKey` are read from the app
    /// unless a test says otherwise.
    @discardableResult
    func mouseMovedOutside(_ e: NSEvent, viaOtherApp: Bool = false,
                           appActive: Bool? = nil, editorIsKey: Bool? = nil) -> Bool {
        // Cheap first: this also sees every mouse movement while another app is in front.
        guard appActive ?? NSApp.isActive, let model else { return false }
        let flags = e.modifierFlags.intersection([.shift, .control, .option, .command])
        if capturedEdge != nil, Self.edge(for: flags) != capturedEdge { releaseCursor() }
        let editing = isEditing(model)
        let key = editorIsKey ?? (model.mainWindow?.isKeyWindow ?? false)
        let route = viaOtherApp ? "another app's events" : "its own events"
        if Self.edge(for: flags) != nil { logOutside(route, key: key, editing: editing, model: model) }
        guard Self.acceptsOutsideMovement(appActive: true, editorIsKey: key, editing: editing) else {
            // A sheet or Settings took the keyboard mid-jog: lock what was done.
            if model.isJogging { endJog(commit: true) }
            return false
        }
        // The same movement can arrive twice (to KPTN.SUB and, as a copy, from the app
        // under the pointer): it counts once.
        guard e.timestamp != lastOutsideMove else { return capturedEdge != nil }
        lastOutsideMove = e.timestamp
        // Not held yet: a few points of travel first (see `outsideStartDistance`).
        if capturedEdge == nil {
            guard Self.edge(for: flags) != nil else { return false }
            outsideTravel += abs(e.deltaX)
            guard outsideTravel >= Self.outsideStartDistance else { return false }
        }
        return jogWithMouse(e, flags: flags, model: model, seenBy: route)
    }

    // MARK: Watching the pointer

    /// Starts (or with nil, stops) watching the pointer's position for a jog of this edge.
    private func watchPointer(for edge: Edge?) {
        stopWatching()
        guard let edge, capturedEdge == nil else { return }
        watchFrom = pointer.location()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerWatchTick(edge) }
        }
        // Not while a menu is open or a window is being dragged (those pause this mode).
        RunLoop.main.add(timer, forMode: .default)
        watch = timer
    }

    private func stopWatching() {
        watch?.invalidate()
        watch = nil
        watchFrom = nil
    }

    /// 60 times a second while Control or Option is held and the pointer isn't taken yet:
    /// has it moved, outside the editor window? Then the jog takes it, exactly as reported
    /// movement would. `held`, `appActive` and `editorIsKey` are read from the Mac unless a
    /// test says otherwise.
    func pointerWatchTick(_ edge: Edge, held: NSEvent.ModifierFlags? = nil,
                          appActive: Bool? = nil, editorIsKey: Bool? = nil) {
        guard let model, capturedEdge == nil else { stopWatching(); return }
        let flags = (held ?? NSEvent.modifierFlags).intersection([.shift, .control, .option, .command])
        // The key was let go (perhaps while another app had the keyboard).
        guard Self.edge(for: flags) == edge else { stopWatching(); return }
        let at = pointer.location()
        guard let from = watchFrom else { watchFrom = at; return }
        // Inside the window, movement arrives as events, the way a jog has always started.
        guard Self.jogHome(pointer: at, window: editorRect()) != nil else {
            watchFrom = at
            return
        }
        guard abs(at.x - from.x) >= Self.outsideStartDistance else { return }
        let editing = isEditing(model)
        let key = editorIsKey ?? (model.mainWindow?.isKeyWindow ?? false)
        logOutside("watching the pointer", key: key, editing: editing, model: model)
        guard Self.acceptsOutsideMovement(appActive: appActive ?? NSApp.isActive, editorIsKey: key, editing: editing),
              Self.mouseJogEdge(flags: flags, mouseJogOn: model.mouseJogOn, hasMedia: model.hasMedia,
                                hasSelection: model.doc.selectedID != nil) == edge else { return }
        captureCursor(for: edge, seenBy: "watching the pointer")
    }

    /// The part of the editor window that is on its screen.
    private func editorRect() -> CGRect? {
        if let given = editorFrame { return given() }
        guard let window = model?.mainWindow else { return nil }
        guard let screen = window.screen else { return window.frame }
        return window.frame.intersection(screen.frame)
    }

    /// Where the hidden pointer is put for a jog that starts outside the editor window: over
    /// the waveform's part of it (right of the cards, near the bottom). nil: the pointer is
    /// inside already, and stays where it is.
    static func jogHome(pointer: CGPoint, window frame: CGRect?) -> CGPoint? {
        guard let frame, !frame.isEmpty, !frame.contains(pointer) else { return nil }
        return CGPoint(x: frame.minX + frame.width * 0.6, y: frame.minY + frame.height * 0.2)
    }

    // MARK: Holding the pointer

    /// Hides the pointer and freezes it, so mouse movement is raw and never hits the screen
    /// edge. From outside the editor window, the hidden pointer is first brought inside:
    /// there its movement is reported the way it always has been, whatever macOS does with
    /// movement over the desktop or another app. It goes back when the key is let go.
    private func captureCursor(for edge: Edge, seenBy route: String = "its own events") {
        guard capturedEdge == nil else { return }
        capturedEdge = edge
        stopWatching()
        let at = pointer.location()
        let home = Self.jogHome(pointer: at, window: editorRect())
        if home != nil {
            takenFrom = at
            skipNextMovement = true
            jogLog.notice("jog started with the pointer outside the window, seen by \(route, privacy: .public)")
        }
        pointer.hold(home)
    }

    private func releaseCursor() {
        guard capturedEdge != nil else { return }
        capturedEdge = nil
        skipNextMovement = false
        outsideTravel = 0
        pointer.release(takenFrom)
        takenFrom = nil
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
