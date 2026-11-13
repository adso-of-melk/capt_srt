import SwiftUI
import AppKit
import Carbon

/// Formatted text for the card editor: <i>, <b> and <u> become real italic, bold and
/// underline, and the tags are written back when the text changes. Other tags
/// (<font …>, {\an8}) stay visible as typed, so nothing is lost.
enum RichMarkup {
    static let italic = NSAttributedString.Key("kptn.italic")
    static let bold = NSAttributedString.Key("kptn.bold")

    static func font(size: CGFloat, italic: Bool, bold: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .medium)
        guard italic else { return base }
        let d = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: d, size: size) ?? base
    }

    static func paragraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byWordWrapping
        return p
    }

    static func baseAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font(size: size, italic: false, bold: false),
         .foregroundColor: Palette.text,
         .paragraphStyle: paragraph()]
    }

    /// The right font for a run's style keys.
    static func refont(_ attrs: [NSAttributedString.Key: Any], size: CGFloat) -> NSFont {
        font(size: size, italic: attrs[italic] != nil, bold: attrs[bold] != nil)
    }

    static func attributed(_ markup: String, size: CGFloat) -> NSAttributedString {
        let ns = markup as NSString
        let out = NSMutableAttributedString()
        var i = 0, b = 0, u = 0
        func append(_ piece: String) {
            guard !piece.isEmpty else { return }
            var attrs = baseAttributes(size: size)
            if i > 0 { attrs[italic] = true }
            if b > 0 { attrs[bold] = true }
            if u > 0 { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            attrs[.font] = font(size: size, italic: i > 0, bold: b > 0)
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        var cursor = 0
        for m in Markup.tagPattern.matches(in: markup, range: NSRange(location: 0, length: ns.length)) {
            append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            cursor = m.range.location + m.range.length
            let tag = ns.substring(with: m.range)
            guard m.range(at: 2).location != NSNotFound else { append(tag); continue }
            let step = ns.substring(with: m.range(at: 1)) == "/" ? -1 : 1
            switch ns.substring(with: m.range(at: 2)).lowercased() {
            case "i": i = max(0, i + step)
            case "b": b = max(0, b + step)
            case "u": u = max(0, u + step)
            default: append(tag)   // kept as typed
            }
        }
        append(ns.substring(from: cursor))
        return out
    }

    /// Adds text at the end of a title in the style of its last character (italic stays
    /// italic). `italic` forces italics on or off for the new text.
    static func appending(_ plain: String, to text: String, italic forced: Bool? = nil) -> String {
        let a = NSMutableAttributedString(attributedString: attributed(text, size: 15))
        var attrs = a.length > 0 ? a.attributes(at: a.length - 1, effectiveRange: nil) : baseAttributes(size: 15)
        if let forced { attrs[italic] = forced ? true : nil }
        attrs[.font] = refont(attrs, size: 15)
        a.append(NSAttributedString(string: plain, attributes: attrs))
        return markup(from: a)
    }

    /// Every visible character of the title is italic.
    static func isAllItalic(_ text: String) -> Bool {
        let a = attributed(text, size: 15)
        let s = a.string as NSString
        var all = true, any = false
        a.enumerateAttribute(italic, in: NSRange(location: 0, length: a.length)) { v, r, _ in
            // Spaces and codes like {\an8} don't count: only what the viewer reads.
            guard !Markup.plain(s.substring(with: r)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            any = true
            if v == nil { all = false }
        }
        return any && all
    }

    /// The whole title in italics, or none of it.
    static func withItalic(_ on: Bool, _ text: String) -> String {
        let a = NSMutableAttributedString(attributedString: attributed(text, size: 15))
        let r = NSRange(location: 0, length: a.length)
        if on {
            a.addAttribute(italic, value: true, range: r)
            // Position and colour codes ({\an8}, <font …>) stay outside the italics.
            for m in Markup.tagPattern.matches(in: a.string, range: r) { a.removeAttribute(italic, range: m.range) }
        } else {
            a.removeAttribute(italic, range: r)
        }
        a.enumerateAttributes(in: r) { attrs, sub, _ in a.addAttribute(.font, value: refont(attrs, size: 15), range: sub) }
        return markup(from: a)
    }

    /// Back to text with tags, properly nested.
    static func markup(from a: NSAttributedString) -> String {
        var out = ""
        var open: [String] = []
        let ns = a.string as NSString
        a.enumerateAttributes(in: NSRange(location: 0, length: a.length)) { attrs, range, _ in
            var want: [String] = []
            if attrs[italic] != nil { want.append("i") }
            if attrs[bold] != nil { want.append("b") }
            if let u = attrs[.underlineStyle] as? Int, u != 0 { want.append("u") }
            while open.contains(where: { !want.contains($0) }), let top = open.popLast() {
                out += "</\(top)>"
            }
            for w in want where !open.contains(w) {
                out += "<\(w)>"
                open.append(w)
            }
            out += ns.substring(with: range)
        }
        for tag in open.reversed() { out += "</\(tag)>" }
        return out
    }
}

/// The text view used to edit a title.
final class TitleTextView: NSTextView {
    var baseSize: CGFloat = 15
    var onFocusChange: ((Bool) -> Void)?
    var onWindow: (() -> Void)?
    var placeholder = "Type the title…"
    /// A style switched with ⌘I at the cursor, waiting for the next character typed or pasted.
    /// It survives the text being reloaded (shrinking to fit, live line breaks) until the
    /// cursor moves or something is typed.
    var pendingTyping: [NSAttributedString.Key: Any]?
    var pendingLocation: Int?
    /// The language spell check uses here (nil: spell check is off).
    var spellLanguage: String?
    var onLearn: ((String) -> Void)?
    var onProjectWord: ((String) -> Void)?

    /// Right-click on an underlined word: the dictionary's suggestions, Learn Spelling, and
    /// Add to Project Words (names and places in this film).
    override func menu(for event: NSEvent) -> NSMenu? {
        let standard = super.menu(for: event)
        guard let lang = spellLanguage else { return standard }
        let i = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard let r = SpellService.shared.misspelled(in: string, language: lang)
            .first(where: { i >= $0.location && i <= $0.location + $0.length }) else { return standard }
        let word = (string as NSString).substring(with: r)
        let menu = NSMenu()
        let guesses = SpellService.shared.suggestions(for: word, language: lang).prefix(8)
        if guesses.isEmpty {
            let none = NSMenuItem(title: "No Suggestions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for g in guesses {
            let item = NSMenuItem(title: g, action: #selector(useGuess(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Guess(range: r, word: word, replacement: g)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let learn = NSMenuItem(title: "Learn Spelling", action: #selector(learnWord(_:)), keyEquivalent: "")
        learn.target = self
        learn.representedObject = word
        menu.addItem(learn)
        let project = NSMenuItem(title: "Add to Project Words", action: #selector(addProjectWord(_:)), keyEquivalent: "")
        project.target = self
        project.representedObject = word
        menu.addItem(project)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        return menu
    }

    private final class Guess: NSObject {
        let range: NSRange, word: String, replacement: String
        init(range: NSRange, word: String, replacement: String) {
            self.range = range; self.word = word; self.replacement = replacement
        }
    }

    @objc private func useGuess(_ item: NSMenuItem) {
        guard let g = item.representedObject as? Guess, let storage = textStorage,
              g.range.location + g.range.length <= storage.length,
              storage.attributedSubstring(from: g.range).string == g.word,
              shouldChangeText(in: g.range, replacementString: g.replacement) else { return }
        // The new word keeps the old one's style (italic stays italic).
        storage.replaceCharacters(in: g.range, with: g.replacement)
        didChangeText()
        setSelectedRange(NSRange(location: g.range.location + (g.replacement as NSString).length, length: 0))
    }

    @objc private func learnWord(_ item: NSMenuItem) {
        if let w = item.representedObject as? String { onLearn?(w) }
    }

    @objc private func addProjectWord(_ item: NSMenuItem) {
        if let w = item.representedObject as? String { onProjectWord?(w) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindow?() }
    }

    override func becomeFirstResponder() -> Bool {
        // Whatever keyboard (input source) you're using stays: a card never switches it.
        let keyboard = KeyboardSource.currentID()
        let ok = super.becomeFirstResponder()
        if ok {
            KeyboardSource.keep(keyboard, in: self)
            onFocusChange?(true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    /// Pasted text takes the title's own look, not the source's fonts and colours: it is
    /// typed in with the style at the cursor (italic after ⌘I, or after italic text).
    override func paste(_ sender: Any?) {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        insertText(text, replacementRange: selectedRange())
    }

    /// ⌘I: italic on or off for the selection (or for what you type next).
    func toggle(_ key: NSAttributedString.Key) {
        let r = selectedRange()
        if r.length == 0 {
            var t = typingAttributes
            t[key] = t[key] == nil ? true : nil
            t[.font] = RichMarkup.refont(t, size: baseSize)
            typingAttributes = t
            pendingTyping = t
            pendingLocation = r.location
            return
        }
        guard let storage = textStorage, shouldChangeText(in: r, replacementString: nil) else { return }
        var allOn = true
        storage.enumerateAttribute(key, in: r) { v, _, _ in if v == nil { allOn = false } }
        storage.beginEditing()
        if allOn { storage.removeAttribute(key, range: r) } else { storage.addAttribute(key, value: true, range: r) }
        storage.enumerateAttributes(in: r) { attrs, sub, _ in
            storage.addAttribute(.font, value: RichMarkup.refont(attrs, size: baseSize), range: sub)
        }
        storage.endEditing()
        didChangeText()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: RichMarkup.font(size: baseSize, italic: typingAttributes[RichMarkup.italic] != nil, bold: false),
            .foregroundColor: Palette.textFaint,
            .paragraphStyle: RichMarkup.paragraph()
        ]
        (placeholder as NSString).draw(in: bounds, withAttributes: attrs)
    }
}

/// The keyboard layout / input source, so editing never changes it.
@MainActor
enum KeyboardSource {
    nonisolated static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// macOS can give each text box its own remembered keyboard ("Automatically switch to a
    /// document's input source"). Put back the one that was active before the click.
    static func keep(_ id: String?, in view: NSTextView) {
        guard let id else { return }
        apply(id, to: view)
        Task { @MainActor [weak view] in
            if let view { apply(id, to: view) }
        }
    }

    private static func apply(_ id: String, to view: NSTextView) {
        guard let context = view.inputContext, context.selectedKeyboardInputSource != id,
              context.keyboardInputSources?.contains(id) ?? false else { return }
        context.selectedKeyboardInputSource = id
    }
}

/// The editable title in the selected card: formatted as it will look, edited in place.
struct TitleEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    /// Take the keyboard now (the card was asked to start editing).
    let focusNow: Bool
    let onFocusTaken: () -> Void
    /// Leaving the card. `rebalance`: lines were wrapped automatically while typing (none by hand).
    let onEndEditing: (_ rebalance: Bool) -> Void
    /// While typing: the title re-broken by the rules if a line ran over, else nil.
    let liveBreak: (String) -> String?
    /// ⌘I was pressed on this (empty) title before it was being typed in: start in italics.
    var startItalic: Bool = false
    /// The italics asked for with `startItalic` have been used (or the text is no longer empty).
    var onStartItalicUsed: () -> Void = {}
    /// The language to spell check in, or nil when spell check is off.
    var spellLanguage: String? = nil
    /// What Find is looking for, to highlight it here too.
    var findHighlight: FindHighlight? = nil
    var onLearn: (String) -> Void = { _ in }
    var onProjectWord: (String) -> Void = { _ in }
    /// All the text of an all-italic title was deleted: the empty title stays italic.
    var onEmptiedItalic: () -> Void = {}
    /// The text cursor came into this card (true) or left it, or the card closed (false).
    var onCursor: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TitleTextView {
        let tv = TitleTextView(usingTextLayoutManager: false)
        let c = context.coordinator
        c.view = tv
        tv.delegate = c
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = false          // ⌘Z is the app's own undo, title by title
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.drawsBackground = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.insertionPointColor = Palette.amber
        // The app checks spelling itself, in the title's own language (not the Mac's).
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.onLearn = { [weak c] w in c?.parent.onLearn(w) }
        tv.onProjectWord = { [weak c] w in c?.parent.onProjectWord(w) }
        tv.onFocusChange = { [weak c] focused in c?.focusChanged(focused) }
        tv.onWindow = { [weak c, weak tv] in
            guard let c, let tv, c.parent.focusNow else { return }
            DispatchQueue.main.async { c.takeFocus(tv) }
        }
        c.load(text, into: tv, size: fontSize)
        c.syncStartItalic(tv)
        tv.spellLanguage = spellLanguage
        c.decorate(tv)
        return tv
    }

    func updateNSView(_ tv: TitleTextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.currentMarkup != text || c.fontSize != fontSize {
            let caret = c.caretKey(in: tv)
            c.load(text, into: tv, size: fontSize)
            c.restoreCaret(caret, in: tv)
        }
        c.syncStartItalic(tv)
        tv.spellLanguage = spellLanguage
        c.decorate(tv)
        if focusNow { DispatchQueue.main.async { c.takeFocus(tv) } }
    }

    static func dismantleNSView(_ tv: TitleTextView, coordinator: Coordinator) {
        // A card closed while you were typing in it (Tab, a click elsewhere).
        let done = coordinator.parent.onCursor
        DispatchQueue.main.async { done(false) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TitleTextView, context: Context) -> CGSize? {
        let proposed = proposal.width ?? 240
        let width = proposed.isFinite ? max(20, proposed) : 240
        guard let lm = nsView.layoutManager, let tc = nsView.textContainer else { return nil }
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let line = lm.defaultLineHeight(for: RichMarkup.font(size: fontSize, italic: false, bold: false))
        return CGSize(width: width, height: ceil(max(used, line)))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TitleEditor
        var currentMarkup = ""
        var fontSize: CGFloat = 15
        /// Lines were wrapped for you while typing, and you haven't pressed Return.
        private var wrapped = false
        private var manualBreak = false

        init(_ parent: TitleEditor) { self.parent = parent }

        func load(_ markup: String, into tv: NSTextView, size: CGFloat) {
            currentMarkup = markup
            fontSize = size
            (tv as? TitleTextView)?.baseSize = size
            // Replacing the text can move the cursor; that isn't the user moving it.
            let was = restoring
            restoring = true
            tv.textStorage?.setAttributedString(RichMarkup.attributed(markup, size: size))
            restoring = was
            applyTypingStyle(tv)
        }

        /// The style for the next character: one switched with ⌘I and not used yet, or else
        /// the style of the character before the cursor (the first one at the start), so
        /// italics never switch off just because the text was reloaded.
        func applyTypingStyle(_ tv: NSTextView) {
            var attrs: [NSAttributedString.Key: Any]
            let loc = tv.selectedRange().location
            if let pending = (tv as? TitleTextView)?.pendingTyping {
                attrs = pending
            } else if let storage = tv.textStorage, storage.length > 0 {
                let i = min(max(loc - 1, 0), storage.length - 1)
                attrs = storage.attributes(at: i, effectiveRange: nil)
            } else {
                attrs = RichMarkup.baseAttributes(size: fontSize)
            }
            attrs[.font] = RichMarkup.refont(attrs, size: fontSize)
            tv.typingAttributes = attrs
            // The placeholder of an empty title shows the style that typing will have.
            if tv.string.isEmpty { tv.needsDisplay = true }
        }

        /// Everything was deleted. An all-italic title stays italic, empty (most italic titles
        /// are italic throughout: voice-over, songs); its card shows a badge and ⌘I turns it
        /// off. Selective italics don't carry over: the empty title starts plain.
        private func emptied(_ tv: NSTextView, keepItalic: Bool) {
            var a = RichMarkup.baseAttributes(size: fontSize)
            if keepItalic {
                a[RichMarkup.italic] = true
                a[.font] = RichMarkup.refont(a, size: fontSize)
                if let t = tv as? TitleTextView {
                    t.pendingTyping = a
                    t.pendingLocation = 0
                }
                tv.typingAttributes = a
                parent.onEmptiedItalic()
            } else {
                tv.typingAttributes = a
            }
            tv.needsDisplay = true
        }

        /// ⌘I pressed on the title while it wasn't being typed in: an empty title starts in italics.
        private var startItalicApplied = false
        func syncStartItalic(_ tv: TitleTextView) {
            if parent.startItalic, tv.string.isEmpty, !startItalicApplied {
                var t = RichMarkup.baseAttributes(size: fontSize)
                t[RichMarkup.italic] = true
                t[.font] = RichMarkup.refont(t, size: fontSize)
                tv.pendingTyping = t
                tv.pendingLocation = 0
                startItalicApplied = true
                applyTypingStyle(tv)
            } else if !parent.startItalic, startItalicApplied {
                // ⌘I pressed again before typing: italics off.
                startItalicApplied = false
                tv.pendingTyping = nil
                tv.pendingLocation = nil
                applyTypingStyle(tv)
            }
        }

        /// Where the cursor was left by the last thing typed (nil once it's moved by hand).
        var typingAt: Int?

        /// The misspelled words to underline: all of them, except a word you're typing at its
        /// end right now. Putting the cursor on or in a word never hides its underline; only
        /// fixing the spelling does.
        static func marked(_ misspelled: [NSRange], caret: NSRange, typingAt: Int?) -> [NSRange] {
            guard caret.length == 0, let at = typingAt, at == caret.location else { return misspelled }
            return misspelled.filter { $0.location + $0.length != at }
        }

        /// Red dotted underlines under misspelled words, and Find's matches in teal. Drawn over
        /// the text; nothing is added to it.
        func decorate(_ tv: NSTextView) {
            guard let lm = tv.layoutManager else { return }
            let s = tv.string
            let full = NSRange(location: 0, length: (s as NSString).length)
            lm.removeTemporaryAttribute(.spellingState, forCharacterRange: full)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            guard full.length > 0 else { return }
            if let lang = parent.spellLanguage {
                let typing = tv.window?.firstResponder === tv ? typingAt : nil
                for r in Self.marked(SpellService.shared.misspelled(in: s, language: lang),
                                     caret: tv.selectedRange(), typingAt: typing) {
                    // 1 = NSSpellingStateSpellingFlag: the red dotted underline.
                    lm.addTemporaryAttribute(.spellingState, value: 1, forCharacterRange: r)
                }
            }
            if let f = parent.findHighlight {
                let tags = Markup.tagPattern.matches(in: s, range: full).map(\.range)
                let ranges = FindController.ranges(of: f.query, in: s, matchCase: f.matchCase, wholeWord: f.wholeWord)
                    .filter { r in !tags.contains { NSIntersectionRange($0, r).length > 0 } }
                for (k, r) in ranges.enumerated() {
                    let alpha: CGFloat = k == f.current ? 0.6 : 0.25
                    lm.addTemporaryAttribute(.backgroundColor, value: Palette.teal.withAlphaComponent(alpha),
                                             forCharacterRange: r)
                }
            }
        }

        func takeFocus(_ tv: NSTextView) {
            guard parent.focusNow, let window = tv.window else { return }
            if window.firstResponder !== tv {
                window.makeFirstResponder(tv)
                restoring = true
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                restoring = false
                applyTypingStyle(tv)
            }
            parent.onFocusTaken()
        }

        weak var view: NSTextView?

        func focusChanged(_ focused: Bool) {
            if let view { DispatchQueue.main.async { [weak self] in self?.decorate(view) } }
            let cursor = parent.onCursor
            DispatchQueue.main.async { cursor(focused) }
            if focused {
                wrapped = false
                manualBreak = false
            } else {
                parent.onEndEditing(wrapped && !manualBreak)
                wrapped = false
            }
        }

        /// Set while the editor moves the cursor itself, so that isn't taken for the user moving it.
        var restoring = false

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !restoring, let tv = notification.object as? TitleTextView else { return }
            // The cursor moved by hand (not by typing): every misspelled word shows again.
            let r0 = tv.selectedRange()
            if let at = typingAt, r0.length != 0 || r0.location != at { typingAt = nil }
            if tv.spellLanguage != nil { decorate(tv) }
            guard let at = tv.pendingLocation else { return }
            let r = tv.selectedRange()
            if r.length != 0 || r.location != at {
                tv.pendingTyping = nil
                tv.pendingLocation = nil
            }
        }

        /// The last change typed something in (not a deletion).
        private var lastEditInserted = false

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            if let r = replacementString, r.contains("\n") { manualBreak = true }
            lastEditInserted = !(replacementString ?? "").isEmpty
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let wasAllItalic = RichMarkup.isAllItalic(currentMarkup)
            // What was typed carries the waiting style now; from here on the text decides.
            if let t = tv as? TitleTextView, t.pendingTyping != nil {
                t.pendingTyping = nil
                t.pendingLocation = nil
            }
            if parent.startItalic, !tv.string.isEmpty { parent.onStartItalicUsed() }
            var markup = RichMarkup.markup(from: tv.attributedString())
            if !tv.hasMarkedText(), let broken = parent.liveBreak(markup), broken != markup {
                let caret = caretKey(in: tv)
                load(broken, into: tv, size: fontSize)
                restoreCaret(caret, in: tv)
                markup = broken
                wrapped = true
                manualBreak = false
            }
            currentMarkup = markup
            parent.text = markup
            if tv.string.isEmpty { emptied(tv, keepItalic: wasAllItalic) }
            // A word is left unmarked only while you type it; deleting (to fix it) keeps the mark.
            typingAt = lastEditInserted ? tv.selectedRange().location : nil
            decorate(tv)
        }

        // The caret is remembered as "after the Nth visible character", so it lands in the
        // same place after the lines are re-broken. Whether it sat after a space counts too.
        struct Caret { var count: Int; var afterSpace: Bool }

        func caretKey(in tv: NSTextView) -> Caret {
            let s = tv.string as NSString
            let loc = min(tv.selectedRange().location, s.length)
            var n = 0
            for i in 0..<loc where !Self.isSpace(s.character(at: i)) { n += 1 }
            let afterSpace = loc > 0 && Self.isSpace(s.character(at: loc - 1))
            return Caret(count: n, afterSpace: afterSpace)
        }

        func restoreCaret(_ caret: Caret, in tv: NSTextView) {
            let s = tv.string as NSString
            var n = 0, i = 0
            while i < s.length && n < caret.count {
                if !Self.isSpace(s.character(at: i)) { n += 1 }
                i += 1
            }
            if caret.afterSpace {
                while i < s.length && Self.isSpace(s.character(at: i)) { i += 1 }
            }
            restoring = true
            tv.setSelectedRange(NSRange(location: i, length: 0))
            restoring = false
            // A style waiting from ⌘I stays with the cursor where it now is.
            if let t = tv as? TitleTextView, t.pendingTyping != nil { t.pendingLocation = i }
            applyTypingStyle(tv)
        }

        private static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 || c == 0xA0 }
    }
}
