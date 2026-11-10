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

    /// Pasted text takes the title's own look, not the source's fonts and colours.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    /// ⌘I: italic on or off for the selection (or for what you type next).
    func toggle(_ key: NSAttributedString.Key) {
        let r = selectedRange()
        if r.length == 0 {
            var t = typingAttributes
            t[key] = t[key] == nil ? true : nil
            t[.font] = RichMarkup.refont(t, size: baseSize)
            typingAttributes = t
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
            .font: RichMarkup.font(size: baseSize, italic: false, bold: false),
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TitleTextView {
        let tv = TitleTextView(usingTextLayoutManager: false)
        let c = context.coordinator
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
        tv.onFocusChange = { [weak c] focused in c?.focusChanged(focused) }
        tv.onWindow = { [weak c, weak tv] in
            guard let c, let tv, c.parent.focusNow else { return }
            DispatchQueue.main.async { c.takeFocus(tv) }
        }
        c.load(text, into: tv, size: fontSize)
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
        if focusNow { DispatchQueue.main.async { c.takeFocus(tv) } }
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
            tv.textStorage?.setAttributedString(RichMarkup.attributed(markup, size: size))
            tv.typingAttributes = RichMarkup.baseAttributes(size: size)
        }

        func takeFocus(_ tv: NSTextView) {
            guard parent.focusNow, let window = tv.window else { return }
            if window.firstResponder !== tv {
                window.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
            parent.onFocusTaken()
        }

        func focusChanged(_ focused: Bool) {
            if focused {
                wrapped = false
                manualBreak = false
            } else {
                parent.onEndEditing(wrapped && !manualBreak)
                wrapped = false
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            if let r = replacementString, r.contains("\n") { manualBreak = true }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
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
            tv.setSelectedRange(NSRange(location: i, length: 0))
        }

        private static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 || c == 0xA0 }
    }
}
