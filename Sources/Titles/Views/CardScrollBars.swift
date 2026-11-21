import SwiftUI
import AppKit
import Combine
@testable import TitlesCore

/// Where the title pane is scrolled to, for its own scroll bars. (The system's are hidden:
/// the up-down one belonged to the cards, which scroll sideways as a whole, so with many
/// languages it sat off to the right, out of view.) Kept apart from the pane, so scrolling
/// redraws only the bars.
///
/// Up and down, the cards' scroll view is watched directly (`RowsScrollObserver`): on the Mac,
/// SwiftUI's geometry inside a scroll view isn't kept up to date while it scrolls. Sideways the
/// pane only ever moves a whole language at a time, by our own hand, so the column at the left
/// edge (`columnStop`) is simply remembered.
@MainActor
final class CardScrollTracker: ObservableObject {
    typealias Metrics = CardScrollMetrics

    /// A click or drag on a bar: the row (or column) to scroll to, and where it should end up.
    struct Request {
        var id: UUID
        var anchor: UnitPoint
    }

    /// The cards, up and down.
    @Published private(set) var rows = Metrics()
    /// The language at the pane's left edge (0: the first).
    @Published private(set) var columnStop = 0
    /// Lit up while scrolling (wheel, Tab, the cards following the playhead), for a moment after.
    @Published private(set) var lit = false
    /// Rows to scroll to, from the up-down bar, when the scroll view can't be moved directly.
    let rowRequests = PassthroughSubject<Request, Never>()
    /// The cards' scroll view, once found (see RowsScrollObserver).
    weak var rowsScrollView: NSScrollView?
    /// Where each row of cards is, in the list's own points (see CardRowFramesKey). Not
    /// published: only the flow reads it, frame by frame.
    var rowFrames: [UUID: CGRect] = [:]
    /// Moves the cards with the film while playing (see CardFlow).
    weak var flow: RowsScrollObserverView?

    /// Playing, a title was reached: true when the flow takes the cards there (and takes up
    /// again after a scroll by hand). False: glide there instead (the flow waits meanwhile).
    func flowTakesOver(glide: Double) -> Bool { flow?.takeOver(glide: glide) ?? false }

    /// The cards were moved by hand (the scroll bar): the flow waits for the next title.
    func handScrolled() { flow?.pauseForHand() }
    private var fade: Task<Void, Never>?
    private var fadeAt = Date.distantPast

    func setRows(offset: CGFloat? = nil, content: CGFloat? = nil, viewport: CGFloat? = nil) {
        var m = rows
        if let offset { m.offset = offset }
        if let content { m.content = content }
        if let viewport { m.viewport = viewport }
        guard m != rows else { return }
        let moved = abs(m.offset - rows.offset) > 0.5
        rows = m
        if moved { light() }
    }

    /// From SwiftUI's layout: used only until the scroll view itself is found.
    func setRowsFromLayout(offset: CGFloat? = nil, content: CGFloat? = nil, viewport: CGFloat? = nil) {
        guard rowsScrollView == nil else { return }
        setRows(offset: offset, content: content, viewport: viewport)
    }

    /// Moves the cards so the thumb's start is at this point of its travel (0 at the top, 1 at
    /// the bottom), exactly, as a Mac scroll bar does. False if the scroll view isn't known.
    func scrollRows(toFraction f: CGFloat) -> Bool {
        handScrolled()
        guard let sv = rowsScrollView, let doc = sv.documentView else { return false }
        let clip = sv.contentView
        let range = max(0, doc.frame.height - clip.bounds.height)
        let y = range * min(1, max(0, f))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: doc.isFlipped ? y : range - y))
        sv.reflectScrolledClipView(clip)
        return true
    }

    /// Steps the pane sideways by `move` languages, within 0...`last`. The new column at the
    /// left edge, or nil when it doesn't move.
    func stepColumns(move: Int, last: Int) -> Int? {
        let to = min(last, max(0, columnStop + move))
        guard to != columnStop else { return nil }
        setColumnStop(to)
        return to
    }

    func setColumnStop(_ stop: Int, light lights: Bool = true) {
        let stop = max(0, stop)
        guard stop != columnStop else { return }
        columnStop = stop
        if lights { light() }
    }

    /// Lights the bars, and fades them back a little over a second after the last call.
    /// (Called on every frame of a scroll: it only moves the fade's time on.)
    func light() {
        if !lit { lit = true }
        fadeAt = Date().addingTimeInterval(1.2)
        guard fade == nil else { return }
        fade = Task { [weak self] in
            while let wait = self?.fadeAt.timeIntervalSinceNow, wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 1_000_000)
            }
            self?.lit = false
            self?.fade = nil
        }
    }

    /// The row to scroll to for a point on the up-down bar (`fraction`: 0 at the top of the
    /// bar's travel, 1 at the bottom), given how much of the list is in view. Only used when
    /// the scroll view can't be moved directly.
    static func rowTarget(fraction: CGFloat, count: Int, share: CGFloat) -> (index: Int, anchor: UnitPoint)? {
        guard count > 0 else { return nil }
        if fraction >= 0.999 { return (count - 1, .bottom) }
        let room = max(0, CGFloat(count) * (1 - share))
        let index = Int((room * max(0, fraction)).rounded())
        return (min(count - 1, max(0, index)), .top)
    }
}

/// Where the title pane stops when it scrolls sideways: with a whole language column at its
/// left edge (column `k` there when scrolled `k` columns along).
enum ColumnStops {
    /// The last column that can be at the left edge (the rest fill the pane to its right).
    static func last(count: Int, width: CGFloat, gap: CGFloat, viewport: CGFloat, margins: CGFloat = 24) -> Int {
        let fit = fitting(width: width, gap: gap, viewport: viewport, margins: margins)
        return max(0, count - fit)
    }

    /// How many whole columns the pane shows.
    static func fitting(width: CGFloat, gap: CGFloat, viewport: CGFloat, margins: CGFloat = 24) -> Int {
        max(1, Int(((viewport - margins + gap) / (width + gap) + 0.01).rounded(.down)))
    }

    /// The stop that brings column `index` into view from stop `current` (moving as little
    /// as it can), with `fit` columns in view.
    static func revealing(_ index: Int, from current: Int, fit: Int, last: Int) -> Int {
        let to: Int
        if index < current { to = index } else if index > current + fit - 1 { to = index - fit + 1 } else { to = current }
        return min(last, max(0, to))
    }
}

/// The scroll target for sideways stop `k`: a marker `k` column-widths along the pane.
struct ColumnStopID: Hashable {
    let index: Int
}

/// How far one of the title pane's scroll views is scrolled, and how much there is.
struct CardScrollMetrics: Equatable, Sendable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var viewport: CGFloat = 0
    var overflows: Bool { content > viewport + 1 }
    /// 0 scrolled to the start, 1 to the end.
    var position: CGFloat { overflows ? min(1, max(0, offset / (content - viewport))) : 0 }
    /// How much of the whole is in view.
    var share: CGFloat { content > 0 ? min(1, max(0, viewport / content)) : 1 }
}

/// The scroll offsets reported from inside the cards' scroll view (until it's found).
struct CardRowsScrollKey: PreferenceKey {
    static let defaultValue = CardScrollMetrics()
    static func reduce(value: inout CardScrollMetrics, nextValue: () -> CardScrollMetrics) {
        value = nextValue()
    }
}

struct CardRowsViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Sits inside the cards' scroll view, finds it, and reports every move it makes (and every
/// change in how much there is to scroll) to the tracker.
struct RowsScrollObserver: NSViewRepresentable {
    let tracker: CardScrollTracker
    let model: AppModel

    func makeNSView(context: Context) -> RowsScrollObserverView {
        let v = RowsScrollObserverView()
        v.tracker = tracker
        v.model = model
        return v
    }

    func updateNSView(_ v: RowsScrollObserverView, context: Context) {
        v.tracker = tracker
        v.model = model
        v.attach()
    }
}

/// Sits behind the list of cards, the same size as the list (so its points are the list's
/// own), watches the scroll view the list is in, and moves it while the cards flow.
final class RowsScrollObserverView: NSView {
    weak var tracker: CardScrollTracker?
    weak var model: AppModel? {
        didSet { if model !== oldValue { watchPlaying() } }
    }
    private weak var watched: NSScrollView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
        updateFlowLink()
    }

    func attach() {
        tracker?.flow = self
        guard let sv = enclosingScrollView else { return }
        if sv !== watched {
            if let old = watched {
                NotificationCenter.default.removeObserver(self, name: nil, object: old.contentView)
                NotificationCenter.default.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification, object: old)
                if let doc = old.documentView { NotificationCenter.default.removeObserver(self, name: nil, object: doc) }
            }
            watched = sv
            // A scroll by hand (trackpad, wheel): the flow waits for the next title.
            NotificationCenter.default.addObserver(self, selector: #selector(liveScroll(_:)),
                                                   name: NSScrollView.willStartLiveScrollNotification, object: sv)
            sv.contentView.postsBoundsChangedNotifications = true
            sv.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: sv.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)),
                                                   name: NSView.frameDidChangeNotification, object: sv.contentView)
            if let doc = sv.documentView {
                doc.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)),
                                                       name: NSView.frameDidChangeNotification, object: doc)
            }
        }
        tracker?.rowsScrollView = sv
        report()
    }

    @objc private func changed(_ note: Notification) { report() }

    @objc private func liveScroll(_ note: Notification) { pauseForHand() }

    // MARK: Flowing with the film (see CardFlow)

    private var flowLink: CADisplayLink?
    private var playingWatch: AnyCancellable?
    /// Scrolled by hand while playing: the flow waits for the next title to be reached.
    private var handHeld = false
    /// A glide is taking the cards to a title the flow couldn't place: it waits till then.
    private var waitUntil: CFTimeInterval = 0
    /// The flow moved the cards on the last frame, and where it put them (to tell a scroll
    /// by anyone else apart).
    private var flowing = false
    private var lastPut: CGFloat?
    private var lastTime: Double?
    /// Easing in from where the cards were (starting, after a pause, after a jump).
    private var blend: (offset: CGFloat, start: CFTimeInterval)?
    private static let blendTime = 0.45

    private func watchPlaying() {
        playingWatch = model?.clock.$isPlaying.sink { [weak self] playing in
            MainActor.assumeIsolated { self?.updateFlowLink(playing: playing) }
        }
    }

    private func updateFlowLink(playing: Bool? = nil) {
        let on = window != nil && (playing ?? model?.clock.isPlaying ?? false)
        if on, flowLink == nil {
            let link = displayLink(target: self, selector: #selector(flowTick(_:)))
            link.add(to: .main, forMode: .common)
            flowLink = link
        } else if !on, let link = flowLink {
            link.invalidate()
            flowLink = nil
            flowing = false
            handHeld = false
            lastPut = nil
            lastTime = nil
        }
    }

    /// Nothing else has the cards: no typing, spotting, preview, dragging of the bar or text.
    private func mayFlow(_ model: AppModel) -> Bool {
        model.cardsFlow && model.clock.isPlaying && !model.isPreviewing && model.spottingID == nil
            && model.focusRequest == nil && model.typingIn == nil && !model.fastScrolling
            && !model.doc.isLive && model.textDrag == nil
    }

    func pauseForHand() {
        guard flowLink != nil else { return }
        handHeld = true
        flowing = false
    }

    func takeOver(glide: Double) -> Bool {
        guard let model, flowLink != nil, mayFlow(model) else { return false }
        handHeld = false
        if let frames = tracker?.rowFrames,
           CardFlow.points(at: model.engine.currentTime + 0.05, rows: model.rows, frames: frames) != nil {
            return true
        }
        // Not laid out yet (far away): glide there, and flow on from there.
        waitUntil = CACurrentMediaTime() + glide + 0.05
        flowing = false
        return false
    }

    @objc private func flowTick(_ link: CADisplayLink) {
        guard let model, let tracker, let sv = watched, let doc = sv.documentView, window != nil else {
            updateFlowLink(); return
        }
        guard mayFlow(model), !handHeld, CACurrentMediaTime() >= waitUntil else {
            flowing = false
            return
        }
        let t = WaveformNSView.displayTime(now: model.engine.currentTime, rate: Double(model.playbackRate),
                                           ahead: link.targetTimestamp - CACurrentMediaTime())
        guard let points = CardFlow.points(at: t, rows: model.rows, frames: tracker.rowFrames),
              let centre = CardFlow.centre(at: t, points: points) else {
            flowing = false
            return
        }
        let clip = sv.contentView
        let now = clip.bounds.origin.y
        // Moved by anyone else since the last frame: a scroll by hand (one the scroll view
        // didn't announce). The flow waits for the next title.
        if flowing, let put = lastPut, abs(now - put) > 3 { pauseForHand(); return }
        // A jump in the film's time: ease over to the new place.
        if flowing, let last = lastTime, abs(t - last) > 0.5 { flowing = false }
        let range = max(0, doc.frame.height - clip.bounds.height)
        let middle = convert(NSPoint(x: 0, y: centre), to: doc).y
        let target = min(range, max(0, middle - clip.bounds.height / 2))
        let stamp = CACurrentMediaTime()
        if !flowing { blend = (now - target, stamp) }
        var y = target
        if let b = blend {
            let left = CardFlow.blendLeft(elapsed: stamp - b.start, duration: Self.blendTime)
            if left <= 0 { blend = nil } else { y = target + b.offset * left }
        }
        flowing = true
        lastTime = t
        guard abs(y - now) > 0.05 else { lastPut = now; return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        sv.reflectScrolledClipView(clip)
        lastPut = clip.bounds.origin.y
    }

    private func report() {
        guard let sv = watched, let tracker else { return }
        let clip = sv.contentView
        let height = sv.documentView?.frame.height ?? 0
        let flipped = sv.documentView?.isFlipped ?? true
        let offset = flipped ? clip.bounds.minY : height - clip.bounds.maxY
        tracker.setRows(offset: offset, content: height, viewport: clip.bounds.height)
    }
}

/// Reports where a view is in its window (AppKit's window points), as it moves and resizes.
struct WindowFrameReporter: NSViewRepresentable {
    let report: (NSRect) -> Void

    func makeNSView(context: Context) -> FrameReporterView {
        let v = FrameReporterView()
        v.report = report
        return v
    }

    func updateNSView(_ v: FrameReporterView, context: Context) {
        v.report = report
        v.send()
    }
}

final class FrameReporterView: NSView {
    var report: ((NSRect) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); send() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); send() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); send() }
    override func layout() { super.layout(); send() }

    func send() {
        report?(window == nil ? .zero : convert(bounds, to: nil))
    }
}

/// How the bars look, like the Mac's own: a capsule ("thumb") as long as the share of the list
/// in view, on a faint track. Wider and brighter under the pointer or while dragged, lit while
/// the pane scrolls.
private enum BarLook {
    static func thickness(active: Bool) -> CGFloat { active ? 9 : 6 }
    static func track(active: Bool) -> Color { Theme.periwinkle.opacity(active ? 0.16 : 0.07) }
    static func thumb(active: Bool, lit: Bool) -> Color {
        Theme.periwinkle.opacity(active ? 0.95 : (lit ? 0.8 : 0.6))
    }
}

/// One of the title pane's scroll bars. Drag the thumb and it stays under the pointer where
/// it was grabbed; click the track and the thumb's middle jumps there, then drags from there.
struct PaneScrollBar: View {
    let vertical: Bool
    /// Where the thumb is: 0 at the start of its travel, 1 at the end.
    let position: CGFloat
    /// How much of the whole is in view: the thumb's share of the bar.
    let share: CGFloat
    let lit: Bool
    var minThumb: CGFloat = 30
    /// Told when a drag starts (true) and ends (false).
    var dragging: (Bool) -> Void = { _ in }
    /// Asked for while dragging: where the thumb's start is, 0 to 1 of its travel.
    let scroll: (CGFloat) -> Void
    @State private var hover = false
    /// While dragging: how far from the thumb's start it was grabbed, and where it is now.
    @State private var grab: CGFloat?
    @State private var dragged: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let length = vertical ? geo.size.height : geo.size.width
            let thumb = min(length, max(minThumb, length * share))
            let travel = max(1, length - thumb)
            let start = travel * min(1, max(0, dragged ?? position))
            let active = hover || grab != nil
            let t = BarLook.thickness(active: active)
            ZStack(alignment: vertical ? .topTrailing : .bottomLeading) {
                Capsule()
                    .fill(BarLook.track(active: active))
                    .frame(width: vertical ? t : length, height: vertical ? length : t)
                if share < 0.999 {
                    Capsule()
                        .fill(BarLook.thumb(active: active, lit: lit))
                        .frame(width: vertical ? t : thumb, height: vertical ? thumb : t)
                        .offset(x: vertical ? 0 : start, y: vertical ? start : 0)
                }
            }
            .padding(vertical ? .trailing : .bottom, 2)
            .frame(width: geo.size.width, height: geo.size.height,
                   alignment: vertical ? .topTrailing : .bottomLeading)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard share < 0.999 else { return }
                        let p = vertical ? v.location.y : v.location.x
                        if grab == nil {
                            let s = vertical ? v.startLocation.y : v.startLocation.x
                            grab = Self.grabPoint(at: s, thumbStart: start, thumb: thumb)
                            dragging(true)
                        }
                        let f = Self.fraction(pointer: p, grab: grab ?? 0, travel: travel)
                        dragged = f
                        scroll(f)
                    }
                    .onEnded { _ in
                        if grab != nil { dragging(false) }
                        grab = nil
                        withAnimation(.easeOut(duration: 0.2)) { dragged = nil }
                    }
            )
            .animation(.easeOut(duration: 0.15), value: active)
            .animation(.easeOut(duration: 0.4), value: lit)
        }
    }

    /// Where on the thumb it's held: where it was clicked, when that's on the thumb; its
    /// middle when the click was on the track (the thumb jumps there).
    static func grabPoint(at s: CGFloat, thumbStart: CGFloat, thumb: CGFloat) -> CGFloat {
        (s >= thumbStart && s <= thumbStart + thumb) ? s - thumbStart : thumb / 2
    }

    /// Where the thumb's start goes, 0 to 1 of its travel, with the pointer at `pointer`.
    static func fraction(pointer: CGFloat, grab: CGFloat, travel: CGFloat) -> CGFloat {
        min(1, max(0, (pointer - grab) / max(1, travel)))
    }
}

/// The title pane's up-down scroll bar, on the pane's right edge, always there: it shows
/// where you are in the film. Drag its thumb, or click the bar to go there.
struct CardScrollBarV: View {
    /// Its strip, which can be pointed at; the bar is drawn at its right.
    static let width: CGFloat = 13

    @ObservedObject var tracker: CardScrollTracker
    let rows: [CardRow]
    /// The thumb is held (true) or let go (false).
    var dragging: (Bool) -> Void = { _ in }
    @State private var lastRequest: UUID?

    var body: some View {
        let m = tracker.rows
        PaneScrollBar(vertical: true, position: m.position, share: m.overflows ? m.share : 1,
                      lit: tracker.lit, minThumb: 30, dragging: dragging) { f in
            if tracker.scrollRows(toFraction: f) { return }
            // The scroll view wasn't found: go by rows instead.
            guard let target = CardScrollTracker.rowTarget(fraction: f, count: rows.count, share: m.share) else { return }
            let id = rows[target.index].key
            guard id != lastRequest else { return }
            lastRequest = id
            tracker.handScrolled()
            tracker.rowRequests.send(.init(id: id, anchor: target.anchor))
        }
        .frame(width: Self.width)
        .help("Where you are in the titles. Drag the bar, or click to go there.")
    }
}

/// The title pane's sideways scroll bar, along its bottom edge, when the languages don't all
/// fit. Its thumb moves a whole language at a time, as the pane does.
struct CardScrollBarH: View {
    static let height: CGFloat = 13

    @ObservedObject var tracker: CardScrollTracker
    /// The last column that can be at the pane's left edge (see ColumnStops).
    let lastStop: Int
    /// How much of all the languages the pane shows.
    let share: CGFloat
    /// Puts this column at the pane's left edge.
    let scrollTo: (Int) -> Void

    var body: some View {
        let position = lastStop > 0 ? CGFloat(min(tracker.columnStop, lastStop)) / CGFloat(lastStop) : 0
        PaneScrollBar(vertical: false, position: position, share: share, lit: tracker.lit, minThumb: 40) { f in
            let stop = Self.stop(fraction: f, last: lastStop)
            if stop != tracker.columnStop { scrollTo(stop) }
        }
        .frame(height: Self.height)
        .help("More languages to the side. Drag the bar, or click to go there.")
    }

    /// The column to put at the left edge for a point on the bar (0 at the start of the
    /// thumb's travel, 1 at its end).
    static func stop(fraction: CGFloat, last: Int) -> Int {
        Int((CGFloat(last) * min(1, max(0, fraction))).rounded())
    }
}
