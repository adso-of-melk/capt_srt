import SwiftUI
import AppKit
import QuartzCore
@testable import TitlesCore

/// Bottom right: the waveform with numbered title boxes.
struct WaveformPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var doc: SubtitleDocument
    @ObservedObject var clock: PlayheadClock
    @ObservedObject var audio: AudioStore

    var body: some View {
        WaveformRepresentable(model: model, revision: Revision(
            subtitles: doc.subtitles, selected: doc.selectedID, time: clock.time, playing: clock.isPlaying,
            revision: model.revision, focused: model.video?.focusedTrackID,
            pps: model.pixelsPerSecond, gain: model.waveGain, db: model.dbScale,
            hasWave: audio.waveform != nil, loading: audio.isLoading,
            qcMode: model.qcMode, qcKinds: model.qcKinds))
            .background(Theme.background)
    }

    /// Everything the view draws from; a change triggers a redraw.
    struct Revision: Equatable {
        var subtitles: [Subtitle]
        var selected: UUID?
        var time: Double
        /// Starts and stops the waveform's own frame-by-frame movement (see frameTick).
        var playing: Bool
        var revision: Int
        var focused: UUID?
        var pps: Double
        var gain: Double
        var db: Bool
        var hasWave: Bool
        var loading: Bool
        var qcMode: Bool
        var qcKinds: Set<QCIssue>
    }
}

struct WaveformRepresentable: NSViewRepresentable {
    let model: AppModel
    let revision: WaveformPane.Revision

    func makeNSView(context: Context) -> WaveformNSView {
        let v = WaveformNSView()
        v.model = model
        return v
    }

    func updateNSView(_ nsView: WaveformNSView, context: Context) {
        nsView.refresh()
    }
}

/// AppKit view for full control of mouse, wheel and trackpad input.
@MainActor
final class WaveformNSView: NSView {
    weak var model: AppModel?

    // View window
    private var viewStart: Double = 0
    private var lastTime: Double = -1
    private var lastPPS: Double = 0

    // Layout
    private let rulerHeight: CGFloat = WaveLayout.ruler
    /// The scroll bar along the bottom: the whole film, with the visible part as a handle.
    private let scrollbarHeight: CGFloat = WaveLayout.scrollBar
    private let edgeGrab: CGFloat = 6
    /// Every drawn box, per language band.
    private var boxRectsByTrack: [UUID: [(id: UUID, rect: CGRect)]] = [:]
    /// The focused language's boxes.
    private var boxRects: [(id: UUID, rect: CGRect)] {
        guard let id = model?.video?.focusedTrackID else { return [] }
        return boxRectsByTrack[id] ?? []
    }
    /// Another language's colours on the waveform: the title pane's StepBack, worked out once.
    private enum Muted {
        static let periwinkle = Palette.steppedBack(Palette.periwinkle)
        static let lilac = Palette.steppedBack(Palette.lilac, saturation: StepBack.rimSaturation)
        static let gold = Palette.steppedBack(Palette.gold.withAlphaComponent(0.8), saturation: StepBack.rimSaturation)
        static let red = Palette.steppedBack(Palette.red, saturation: StepBack.rimSaturation)
        static let teal = Palette.steppedBack(Palette.teal)
    }

    /// Languages drawn as full bands, top to bottom in column order.
    private struct Band { let track: Track; let rect: CGRect; let focused: Bool; let label: CGRect }
    private var bands: [Band] = []
    /// Relative heights of the bands (drag the line between two bands).
    private var bandWeights: [UUID: CGFloat] = [:]
    /// Language tags on the slim lanes (double-click to open the language as a band).
    private var laneTags: [(track: UUID, rect: CGRect)] = []
    /// Number pills, for double-click-to-play.
    private var numberPills: [(track: UUID, id: UUID, rect: CGRect)] = []
    /// Boxes of the other open languages, in their slim lanes under the waveform.
    private var laneBoxes: [(track: UUID, id: UUID, rect: CGRect)] = []
    private var laneRects: [(track: UUID, rect: CGRect)] = []
    /// The slim lanes' codes, as drawn.
    private var laneCodes: [(track: Track, rect: CGRect, focused: Bool)] = []

    // Interaction
    private enum Drag {
        case none
        case ruler
        case creating(t0: Double, t1: Double)
        case moving(id: UUID, grab: Double, length: Double)
        case movingGroup(grab: Double, originals: [UUID: Double])
        case marquee(from: CGPoint, to: CGPoint)
        case resizing(id: UUID, edge: TitlesCore.Edge)
        case scrolling(grab: CGFloat)
        case bandResize(upper: UUID, lower: UUID, startY: CGFloat, hu: CGFloat, hl: CGFloat, wu: CGFloat, wl: CGFloat)
        /// A language dragged by its code, up or down (see `languageDrop`).
        case language(id: UUID)
    }
    private var drag: Drag = .none
    /// Where a language dragged by its code would land: among the open languages or the slim
    /// lanes, in which gap (0: above the first), the line drawn there, and the pointer.
    private struct LanguageDrop { let open: Bool; let slot: Int; let y: CGFloat; let point: CGPoint }
    private var languageDrop: LanguageDrop?

    // Resistance: while dragging, a title stops at the minimum gap from the next title in
    // its way. With overlapping titles on (Title menu), pulling on `breakPixels` further lets
    // it through, and it holds again as soon as the two stop overlapping. See DragResistance.
    private var resistance: DragResistance?
    /// How far past the stopping point the pointer has to pull before a title gives.
    static let breakPixels = 40.0
    /// The "overlapping titles are off" note has been shown during this drag.
    private var refusalShown = false
    private var downPoint: CGPoint = .zero
    /// Where a click on empty waveform landed (a plain click places the playhead there).
    private var createClickTime: Double = 0
    private var didDrag = false
    private var swipeAccumulator: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        stripView = WaveStripView(frame: NSRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.lane.cgColor
        // Boxes scrolled past the edge are cut off there, not drawn over the title pane.
        // (Views don't clip on macOS 14 and later unless asked; the split view used to.)
        clipsToBounds = true
        layer?.masksToBounds = true
        // While playing, the strip covers this view (see WaveStripView).
        stripView.autoresizingMask = [.width, .height]
        stripView.isHidden = true
        addSubview(stripView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    // MARK: Geometry

    private var pps: Double { model?.pixelsPerSecond ?? 120 }
    private func x(_ t: Double) -> CGFloat { CGFloat((t - viewStart) * pps) }
    private func t(_ x: CGFloat) -> Double { max(0, viewStart + Double(x) / pps) }
    private var visibleDuration: Double { Double(area.width) / pps }
    /// The size being drawn: the view's own, or a tile's while one is drawn for the strip.
    private var canvas: CGSize?
    private var area: CGSize { canvas ?? bounds.size }
    /// Languages open as full bands (double-click a code to open or close one). The language
    /// you work in isn't always one of them: closed, it's the slim lane with the amber code.
    private var bandTracks: [Track] { model?.waveBandTracks ?? [] }

    /// Codes are shown (to click, double-click and drag) once there's more than one language.
    private var showsCodes: Bool { (model?.openTracks.count ?? 0) > 1 }

    private func codeText(_ track: Track) -> String { track.language.code.uppercased() + (track.locked ? " 🔒" : "") }

    /// The other open languages, each drawn as a slim lane at the bottom.
    private var laneTracks: [Track] {
        guard let model else { return [] }
        let shown = Set(bandTracks.map(\.id))
        return model.openTracks.filter { !shown.contains($0.id) }
    }

    /// Splits the waveform area between the bands by their weights.
    private func layoutBands() {
        let area = waveRect
        let tracks = bandTracks
        let focused = model?.video?.focusedTrackID
        let weights = tracks.map { bandWeights[$0.id] ?? 1 }
        // Shared by their weights, none under two lines' height while there's room.
        let heights = WaveLayout.bandHeights(weights: weights, area: area.height, minimum: Self.minBandHeight)
        var y = area.minY
        var result: [Band] = []
        for (i, track) in tracks.enumerated() {
            let h = heights[i]
            let r = CGRect(x: 0, y: y, width: area.width, height: max(0, h))
            let tw = (codeText(track) as NSString).size(withAttributes: [.font: labelFont(9)]).width + 10
            let label = showsCodes ? CGRect(x: 10, y: r.minY + 3, width: tw, height: 13) : .zero
            result.append(Band(track: track, rect: r, focused: track.id == focused, label: label))
            y += h
        }
        bands = result
        model?.waveRoom = roomForBands
    }

    /// The least height of an open language: room for two lines of text in its boxes.
    static var minBandHeight: CGFloat { WaveLayout.minBand }

    /// How many languages fit open at once, each at least `minBandHeight` tall (the slim
    /// lanes of the rest take their share). Opening one more closes the lowest open one.
    private var roomForBands: Int {
        let n = model?.openTracks.count ?? 1
        let h = max(0, area.height - rulerHeight - scrollbarHeight)
        var k = max(1, n)
        while k > 1, (h - lanesHeight(count: n - k)) / CGFloat(k) < Self.minBandHeight { k -= 1 }
        return k
    }

    /// The language whose code is at `p`, on an open band or a slim lane.
    private func languageCode(at p: CGPoint) -> UUID? {
        if let b = bands.first(where: { $0.label != .zero && $0.label.insetBy(dx: -3, dy: -2).contains(p) }) { return b.track.id }
        return laneTags.first(where: { $0.rect.contains(p) })?.track
    }

    /// Where a language dragged by its code lands: above the slim lanes, among the open
    /// languages (it opens); among the slim lanes, there (it closes).
    private func languageDropTarget(for id: UUID, at p: CGPoint) -> LanguageDrop {
        let open = bands.filter { $0.track.id != id }
        let lanes = laneRects.filter { $0.track != id }
        let movingIsLane = laneRects.contains { $0.track == id }
        if p.y < waveRect.maxY || (lanes.isEmpty && !movingIsLane) {
            let slot = open.filter { $0.rect.midY < p.y }.count
            let y = slot < open.count ? open[slot].rect.minY : (open.last?.rect.maxY ?? waveRect.maxY)
            return LanguageDrop(open: true, slot: slot, y: y, point: p)
        }
        let slot = lanes.filter { $0.rect.midY < p.y }.count
        let y = slot < lanes.count ? lanes[slot].rect.minY
            : (lanes.last?.rect.maxY ?? laneRects.first?.rect.minY ?? waveRect.maxY)
        return LanguageDrop(open: false, slot: slot, y: y, point: p)
    }

    private func band(at p: CGPoint) -> Band? { bands.first { $0.rect.contains(p) } }

    private var focusedBandRect: CGRect { bands.first(where: \.focused)?.rect ?? waveRect }

    /// The line between two bands, for dragging their shared height.
    private func bandDivider(at p: CGPoint) -> (upper: Band, lower: Band)? {
        guard bands.count > 1 else { return nil }
        for i in 1..<bands.count where abs(p.y - bands[i].rect.minY) <= 3 {
            return (bands[i - 1], bands[i])
        }
        return nil
    }

    private var lanesHeight: CGFloat { lanesHeight(count: laneTracks.count) }

    private func lanesHeight(count n: Int) -> CGFloat {
        guard n > 0 else { return 0 }
        return min(CGFloat(n) * WaveLayout.lane, max(0, area.height - rulerHeight - scrollbarHeight) * 0.45)
    }

    private var waveRect: CGRect {
        CGRect(x: 0, y: rulerHeight, width: area.width,
               height: max(0, area.height - rulerHeight - lanesHeight - scrollbarHeight))
    }

    // MARK: Scroll bar

    private var scrollbarRect: CGRect {
        CGRect(x: 0, y: area.height - scrollbarHeight, width: area.width, height: scrollbarHeight)
    }

    /// The length the scroll bar stands for: the video, or the titles if there's no video yet.
    private var totalDuration: Double {
        guard let model else { return 60 }
        if model.engine.duration > 0 { return model.engine.duration }
        return max(60, (model.doc.subtitles.last?.end ?? 0) + 10)
    }

    private var thumbRect: CGRect {
        let track = scrollbarRect
        let total = max(totalDuration, visibleDuration)
        let w = max(28, track.width * CGFloat(visibleDuration / total))
        let x = (track.width - w) * CGFloat(viewStart / max(0.001, total - visibleDuration))
        return CGRect(x: min(max(0, x), track.width - w), y: track.minY + 2, width: w, height: track.height - 4)
    }

    private func scroll(thumbX: CGFloat) {
        let track = scrollbarRect
        let w = thumbRect.width
        let span = max(1, track.width - w)
        let fraction = Double(min(max(0, thumbX), span) / span)
        viewStart = max(0, fraction * max(0, totalDuration - visibleDuration))
        needsDisplay = true
    }

    private func drawScrollbar(model: AppModel) {
        drawScrollTrack(model: model, in: scrollbarRect)
        let thumb = thumbRect
        let dragging: Bool = { if case .scrolling = drag { return true } else { return false } }()
        (dragging ? Palette.amber : Palette.periwinkle).withAlphaComponent(dragging ? 0.75 : 0.45).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: thumb.height / 2, yRadius: thumb.height / 2).fill()
        // The playhead's place in the film.
        Palette.amber.setFill()
        scrollHeadRect.fill()
    }

    /// The scroll bar's track, with the titles on it as faint marks, so you can find your
    /// way along the film.
    private func drawScrollTrack(model: AppModel, in track: CGRect) {
        Palette.panel.setFill()
        track.fill()
        Palette.rule.setFill()
        CGRect(x: track.minX, y: track.minY, width: track.width, height: 1).fill()
        let total = max(totalDuration, visibleDuration)
        Palette.textFaint.withAlphaComponent(0.35).setFill()
        let scale = track.width / CGFloat(total)
        for sub in model.doc.subtitles {
            CGRect(x: track.minX + CGFloat(sub.start) * scale, y: track.midY - 1,
                   width: max(1, CGFloat(sub.duration) * scale), height: 2).fill()
        }
    }

    /// The playhead's mark on the scroll bar.
    private var scrollHeadRect: CGRect {
        let track = scrollbarRect
        let scale = track.width / CGFloat(max(totalDuration, visibleDuration))
        return CGRect(x: CGFloat(playheadTime) * scale - 0.5, y: track.minY + 1, width: 1.5, height: track.height - 1)
    }

    /// Keeps the playhead in view and keeps zoom anchored on it.
    func refresh() {
        guard let model else { return }
        updateFrameLink()
        // Playing on the strip: only what's drawn on it can need redrawing.
        if stripOn {
            if wantsStrip(model), stripUpdate(model) { return }
            leaveStrip()
        }
        let time = playheadTime
        if lastPPS != 0 && lastPPS != pps {
            let anchorX = x(time) >= 0 && x(time) <= bounds.width ? x(time) : bounds.width / 2
            let anchorT = time >= viewStart && time <= viewStart + Double(bounds.width) / lastPPS
                ? time : viewStart + Double(bounds.width / 2) / lastPPS
            viewStart = max(0, anchorT - Double(anchorX) / pps)
        }
        lastPPS = pps

        // While playing, the frame link moves the waveform (see frameTick).
        if case .none = drag, time != lastTime, frameLink == nil {
            let px = x(time)
            if model.clock.isPlaying && model.followPlayhead {
                // Playhead parked at 40% of the width; the waveform scrolls under it.
                viewStart = max(0, time - visibleDuration * 0.4)
            } else if px < 0 || px > bounds.width {
                viewStart = max(0, time - visibleDuration * 0.4)
            }
        }
        lastTime = time
        needsDisplay = true
    }

    // MARK: Moving with the film

    /// While playing, the waveform moves on every frame the screen shows, at the player's
    /// own time. (The playhead clock ticks 60 times a second too, but its ticks don't line up
    /// with the screen's frames, so the boxes moved in uneven steps.)
    private var frameLink: CADisplayLink?
    /// The player's time at the frame being drawn, while playing.
    private var frameTime: Double?

    /// The time the playhead is drawn at: the frame's while playing, the clock's otherwise.
    private var playheadTime: Double { frameTime ?? model?.clock.time ?? 0 }

    private func updateFrameLink() {
        let playing = window != nil && (model?.clock.isPlaying ?? false)
        if playing, frameLink == nil {
            let link = displayLink(target: self, selector: #selector(frameTick(_:)))
            link.add(to: .main, forMode: .common)
            frameLink = link
            frameTime = model?.engine.currentTime
        } else if !playing, let link = frameLink {
            link.invalidate()
            frameLink = nil
            frameTime = nil
        }
    }

    /// The film's time when the frame being made reaches the screen: the player's time now,
    /// plus the little while until then.
    static func displayTime(now t: Double, rate: Double, ahead: Double) -> Double {
        t + max(0, min(0.05, ahead)) * rate
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        guard let model, model.clock.isPlaying, window != nil else { updateFrameLink(); return }
        let t = Self.displayTime(now: model.engine.currentTime, rate: Double(model.playbackRate),
                                 ahead: link.targetTimestamp - CACurrentMediaTime())
        // Never backwards by a hair (the player's time can wobble as frames are decoded).
        if let last = frameTime, t < last, last - t < 0.05 { return }
        frameTime = t
        // The strip moves itself, by the film's clock; this only keeps it drawn ahead.
        if stripOn, !wantsStrip(model) { leaveStrip() }
        if !stripOn, wantsStrip(model) { enterStrip(model, at: t) }
        if stripOn {
            stripTick(model, at: t)
            lastTime = t
            return
        }
        if case .none = drag {
            if model.followPlayhead {
                // Playhead parked at 40% of the width; the waveform glides under it.
                viewStart = max(0, t - visibleDuration * 0.4)
            } else {
                let px = x(t)
                if px < 0 || px > bounds.width { viewStart = max(0, t - visibleDuration * 0.4) }
            }
        }
        lastTime = t
        needsDisplay = true
    }

    // MARK: The strip (see WaveStripView)

    private let stripView: WaveStripView
    /// Playing, with the strip shown over this view (whose own drawing waits underneath).
    private var stripOn = false
    /// Until then the view draws itself, frame by frame: a click, the wheel or a pinch has
    /// just had the waveform in hand.
    private var stripHold: CFTimeInterval = 0
    private var stripMotion = StripMotion(follow: true, lead: 0, page: 0, pps: 120)
    /// The strip's zero, a tile near the playhead (so its positions stay small numbers).
    private var stripOrigin = 0
    /// The time the strip's current run was set going around.
    private var stripRunTime = 0.0
    /// The film's clock isn't reaching the strip: it's moved by hand on each frame instead.
    private var stripManual = false
    private var stripMisses = 0
    private var stripScale: CGFloat = 2
    private var stripSpace: CGColorSpace?
    private var tileDirty: Set<Int> = []

    /// What the strip's size and movement were set up for: any change starts it afresh.
    private struct StripGeometry: Equatable {
        var pps: Double
        var size: CGSize
        var scale: CGFloat
        var follow: Bool
        var qc: Bool
    }
    private var stripGeometry: StripGeometry?

    /// Everything else the tiles are drawn from, but the titles, the selection and the title
    /// being typed in (those redraw only the tiles they're on): a change redraws every tile.
    private struct StripContent: Equatable {
        var focused: UUID?
        var bands: [UUID]
        var weights: [CGFloat]
        var lanes: [UUID]
        var qcKinds: Set<QCIssue>
        var gain: Double
        var db: Bool
        var wave: ObjectIdentifier?
        var multi: Set<UUID>
        var find: String
    }
    private var stripContent: StripContent?
    private var stripRevision = 0
    private var stripTitles: [UUID: [Subtitle]] = [:]
    private var stripSelected: UUID?
    private var stripTyping: UUID?

    /// What the strip's top layer (codes, notices) and scroll bar track show: redrawn when
    /// it changes. (The handle and the playhead's mark on it just move: see stripTick.)
    private struct OverlayKey: Equatable {
        var revision: Int
        var content: StripContent?
        var notice: String?
        var locked: Bool
        var size: CGSize
        var span: Double
    }
    private var overlayKey: OverlayKey?

    private var tileDuration: Double { StripTiles.duration(pps: pps) }
    /// How far either side of the playhead one run of the strip reaches (see StripMotion.stripRun).
    private var stripReach: Double { max(20, 100_000 / pps) }

    private func wantsStrip(_ model: AppModel) -> Bool {
        guard frameLink != nil, window != nil, model.clock.isPlaying, model.spottingID == nil,
              model.engine.syncItem != nil, bounds.width >= 40, bounds.height >= 40,
              CACurrentMediaTime() >= stripHold else { return false }
        if case .none = drag { return true }
        return false
    }

    private func currentStripGeometry(_ model: AppModel) -> StripGeometry? {
        guard let scale = window?.backingScaleFactor else { return nil }
        return StripGeometry(pps: pps, size: bounds.size, scale: scale, follow: model.followPlayhead, qc: model.qcMode)
    }

    private func enterStrip(_ model: AppModel, at t: Double) {
        guard let item = model.engine.syncItem, let window, let geometry = currentStripGeometry(model) else { return }
        stripGeometry = geometry
        stripScale = geometry.scale
        stripSpace = window.colorSpace?.cgColorSpace
        let vis = visibleDuration
        var page = viewStart
        if !model.followPlayhead, x(t) < 0 || x(t) > bounds.width { page = max(0, t - vis * 0.4) }
        stripMotion = StripMotion(follow: model.followPlayhead, lead: vis * 0.4, page: page, pps: pps)
        viewStart = stripMotion.viewStart(at: t)
        stripOrigin = Int((viewStart / tileDuration).rounded(.down))
        let height = bounds.height
        let head = StripImage.render(size: CGSize(width: WaveStripView.playheadHalf * 2, height: height),
                                     scale: stripScale, space: stripSpace) {
            Self.drawPlayheadMark(at: WaveStripView.playheadHalf, height: height)
        }
        stripView.prepare(item: item, size: bounds.size, scale: stripScale,
                          background: (model.qcMode ? Palette.alertLane : Palette.lane).cgColor, playhead: head,
                          thumb: Palette.periwinkle.withAlphaComponent(0.45).cgColor, head: Palette.amber.cgColor)
        stripView.rebase(origin: stripOrigin)
        stripOn = true
        stripManual = false
        noteStripContent(model)
        tileDirty.removeAll()
        renderTiles(model, budget: 0)   // everything in view, now
        renderOverlay(model)
        runStrip(at: t)
        stripView.isHidden = false
    }

    /// Back to the view's own drawing, just where the strip was.
    private func leaveStrip(now: Bool = true) {
        guard stripOn else { return }
        stripOn = false
        if let model { viewStart = stripMotion.viewStart(at: frameTime ?? model.engine.currentTime) }
        if now { display() } else { needsDisplay = true }
        stripView.isHidden = true
        stripView.clear()
        tileDirty.removeAll()
        overlayKey = nil
        stripContent = nil
        stripGeometry = nil
    }

    /// A click, the wheel or a pinch: the waveform draws itself for a moment, so what's
    /// under the pointer is exactly what's drawn.
    private func takeBack(for seconds: Double = 0.6) {
        stripHold = max(stripHold, CACurrentMediaTime() + seconds)
        leaveStrip()
    }

    private func runStrip(at t: Double) {
        stripRunTime = t
        stripMisses = 0
        if stripManual { placeStrip(at: t); return }
        let origin = Double(stripOrigin) * tileDuration
        stripView.run(strip: stripMotion.stripRun(origin: origin, around: t, reach: stripReach),
                      stripAt: stripMotion.stripX(origin: origin, at: t),
                      playhead: stripMotion.playheadRun(span: visibleDuration * 3),
                      playheadAt: stripMotion.playheadX(at: t))
    }

    private func placeStrip(at t: Double) {
        let origin = Double(stripOrigin) * tileDuration
        stripView.place(stripAt: stripMotion.stripX(origin: origin, at: t), playheadAt: stripMotion.playheadX(at: t))
    }

    private func stripTick(_ model: AppModel, at t: Double) {
        guard stripView.item === model.engine.syncItem else { leaveStrip(); return }
        var rerun = false
        if !stripMotion.follow {
            // Not following: a new page once the playhead runs off this one.
            let px = stripMotion.playheadX(at: t)
            if px < 0 || px > bounds.width { stripMotion.page = max(0, t - visibleDuration * 0.4); rerun = true }
        }
        let start = stripMotion.viewStart(at: t)
        viewStart = start
        // A new zero near the playhead now and then (and after a jump), so the numbers the
        // graphics system works with stay small.
        if abs(t - stripRunTime) > stripReach / 2 || abs(start - Double(stripOrigin) * tileDuration) * pps > 50_000 {
            stripOrigin = Int((start / tileDuration).rounded(.down))
            stripView.rebase(origin: stripOrigin)
            rerun = true
        }
        if rerun { runStrip(at: t) }
        if stripManual { placeStrip(at: t) } else { checkStripClock(model) }
        renderTiles(model, budget: 0.004)
        if makeOverlayKey(model) != overlayKey { renderOverlay(model) }
        stripView.placeScrollBar(thumb: thumbRect, head: scrollHeadRect)
    }

    /// The strip should be moving by the film's clock. If the graphics system shows it
    /// somewhere else for a while (the clock isn't reaching it), it's moved by hand instead.
    private func checkStripClock(_ model: AppModel) {
        guard let shown = stripView.shown else { return }
        let now = model.engine.currentTime
        let origin = Double(stripOrigin) * tileDuration
        let off = stripMotion.follow && now > stripMotion.lead
            ? abs(shown.strip - stripMotion.stripX(origin: origin, at: now))
            : abs(shown.playhead - stripMotion.playheadX(at: now))
        stripMisses = off > max(40, CGFloat(0.25 * pps)) ? stripMisses + 1 : 0
        guard stripMisses > 30 else { return }
        stripManual = true
        NSLog("KPTN.SUB: the waveform strip is moved frame by frame (the film's clock isn't reaching it)")
        placeStrip(at: frameTime ?? now)
    }

    private func makeStripContent(_ model: AppModel) -> StripContent {
        let bandIDs = bandTracks.map(\.id)
        let find = model.find
        return StripContent(
            focused: model.video?.focusedTrackID, bands: bandIDs, weights: bandIDs.map { bandWeights[$0] ?? 1 },
            lanes: laneTracks.map(\.id), qcKinds: model.qcKinds, gain: model.waveGain, db: model.dbScale,
            wave: model.audio.waveform.map { ObjectIdentifier($0) }, multi: model.multiSelection,
            find: find.isShown ? "\(find.query)|\(find.matchCase)|\(find.wholeWord)|\(find.scope.rawValue)" : "")
    }

    private func titlesSnapshot(_ model: AppModel) -> [UUID: [Subtitle]] {
        Dictionary(model.openTracks.map { ($0.id, $0.doc.subtitles) }, uniquingKeysWith: { a, _ in a })
    }

    /// What the tiles now on the strip were drawn from.
    private func noteStripContent(_ model: AppModel) {
        stripContent = makeStripContent(model)
        stripRevision = model.revision
        stripTitles = titlesSnapshot(model)
        stripSelected = model.doc.selectedID
        stripTyping = model.typingIn
    }

    /// Marks the tiles a change is on for redrawing (they keep their picture until then).
    /// False when the strip has to start afresh (a new size, zoom or way of following).
    private func stripUpdate(_ model: AppModel) -> Bool {
        guard currentStripGeometry(model) == stripGeometry else {
            stripHold = max(stripHold, CACurrentMediaTime() + 0.3)
            return false
        }
        let content = makeStripContent(model)
        if content != stripContent {
            noteStripContent(model)
            tileDirty = stripView.tileNumbers
            return true
        }
        let focusedID = model.video?.focusedTrackID
        if model.revision != stripRevision || focusedID.map({ stripTitles[$0] != model.doc.subtitles }) == true {
            let titles = titlesSnapshot(model)
            if let spans = StripTiles.changedSpans(old: stripTitles, new: titles) {
                for span in spans { redraw(span) }
            } else {
                tileDirty = stripView.tileNumbers
            }
            stripTitles = titles
            stripRevision = model.revision
        }
        let selected = model.doc.selectedID
        if selected != stripSelected {
            redraw(title: stripSelected)
            redraw(title: selected)
            stripSelected = selected
        }
        if model.typingIn != stripTyping {
            redraw(title: stripTyping)
            redraw(title: model.typingIn)
            stripTyping = model.typingIn
        }
        return true
    }

    private func redraw(_ span: ClosedRange<Double>) {
        let touched = StripTiles.touched(from: span.lowerBound, to: span.upperBound, pps: pps)
        tileDirty.formUnion(stripView.tileNumbers.filter { touched.contains($0) })
    }

    private func redraw(title id: UUID?) {
        guard let id else { return }
        for subs in stripTitles.values {
            if let s = subs.first(where: { $0.id == id }) { redraw(s.start...max(s.start, s.end)) }
        }
    }

    /// Draws the tiles the strip needs: those in view at once, the rest (ahead of the
    /// playhead, and any marked for redrawing) a few at a time, `budget` seconds a frame.
    private func renderTiles(_ model: AppModel, budget: CFTimeInterval) {
        let d = tileDuration
        let start = viewStart, end = viewStart + visibleDuration
        let visible = StripTiles.range(from: start, to: end, pps: pps)
        let wanted = StripTiles.range(from: start - d, to: end + 2 * d, pps: pps)
        let keep = (wanted.lowerBound - 1)...(wanted.upperBound + 1)
        stripView.removeTiles { !keep.contains($0) }
        let have = stripView.tileNumbers
        tileDirty.formIntersection(have)
        let blank = Set(wanted).subtracting(have)
        let todo = Array(blank.union(tileDirty.filter { wanted.contains($0) }))
        guard !todo.isEmpty else { return }
        let playhead = Int((max(0, frameTime ?? start) / d).rounded(.down))
        let began = CACurrentMediaTime()
        for k in StripTiles.order(todo, visible: visible, blank: blank, playhead: playhead) {
            let mustNow = visible.contains(k) && blank.contains(k)
            if !mustNow, CACurrentMediaTime() - began > budget { break }
            if let image = renderTile(k, model: model) { stripView.setTile(k, image: image) }
            tileDirty.remove(k)
        }
    }

    /// Tile `k`: drawn just as the view draws that stretch of film (see drawContent).
    private func renderTile(_ k: Int, model: AppModel) -> CGImage? {
        let saved = (viewStart, bands, boxRectsByTrack, numberPills, laneBoxes, laneRects, laneTags, laneCodes)
        defer {
            (viewStart, bands, boxRectsByTrack, numberPills, laneBoxes, laneRects, laneTags, laneCodes) = saved
            canvas = nil
        }
        let size = CGSize(width: StripTiles.width, height: bounds.height)
        canvas = size
        viewStart = Double(k) * tileDuration
        return StripImage.render(size: size, scale: stripScale, space: stripSpace) { drawContent(model: model) }
    }

    private func makeOverlayKey(_ model: AppModel) -> OverlayKey {
        OverlayKey(revision: model.revision, content: stripContent, notice: audioNotice(model),
                   locked: model.focusedIsLocked, size: bounds.size, span: max(totalDuration, visibleDuration))
    }

    /// The strip's top layer: codes and notices (see drawOverlay), and the scroll bar's track.
    private func renderOverlay(_ model: AppModel) {
        overlayKey = makeOverlayKey(model)
        layoutBands()
        layoutLanes(top: waveRect.maxY)
        stripView.setOverlay(StripImage.render(size: bounds.size, scale: stripScale, space: stripSpace) {
            drawOverlay(model: model, strip: true)
        })
        let track = scrollbarRect
        stripView.setScrollTrack(StripImage.render(size: track.size, scale: stripScale, space: stripSpace) {
            drawScrollTrack(model: model, in: CGRect(origin: .zero, size: track.size))
        }, in: track)
        stripView.placeScrollBar(thumb: thumbRect, head: scrollHeadRect)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if stripOn {
            stripHold = max(stripHold, CACurrentMediaTime() + 0.3)
            leaveStrip(now: false)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // While the strip is shown, it covers this view (see WaveStripView).
        guard let model, !stripOn else { return }
        drawContent(model: model)
        drawOverlay(model: model, strip: false)
    }

    /// What moves with the film: the ruler, each language's waveform and boxes, the slim
    /// lanes. (Drawn into the strip's tiles too, a tile at a time: see `canvas`.)
    private func drawContent(model: AppModel) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = area
        let wave = waveRect

        (model.qcMode ? Palette.alertLane : Palette.lane).setFill()
        CGRect(origin: .zero, size: size).fill()

        drawRuler(ctx, width: size.width)
        layoutBands()
        boxRectsByTrack.removeAll(keepingCapacity: true)
        numberPills.removeAll(keepingCapacity: true)
        for band in bands {
            if showsCodes && !band.focused {
                Palette.background.withAlphaComponent(0.35).setFill()
                band.rect.fill()
            }
            drawWaveform(ctx, in: band.rect, model: model, muted: showsCodes && !band.focused)
            drawBoxes(ctx, in: band.rect, track: band.track, focused: band.focused, model: model)
            if showsCodes {
                Palette.rule.setFill()
                CGRect(x: 0, y: band.rect.minY, width: size.width, height: 1).fill()
            }
        }
        drawLanes(model: model, top: wave.maxY)
    }

    /// What stays put on top: the languages' codes, the scroll bar and notices; while
    /// dragging, the drop line, marquee and new box; and the playhead. (`strip`: for the
    /// strip's top layer, which has its own scroll bar and playhead.)
    private func drawOverlay(model: AppModel, strip: Bool) {
        let w = area.width
        let wave = waveRect
        if showsCodes {
            for band in bands { drawCode(band.track, in: band.label, focused: band.focused) }
        }
        for code in laneCodes { drawCode(code.track, in: code.rect, focused: code.focused) }
        // A language dragged by its code: an amber line where it would land, and its code
        // at the pointer.
        if case let .language(id) = drag, didDrag, let drop = languageDrop, let track = model.video?.track(id) {
            Palette.amber.setFill()
            CGRect(x: 0, y: drop.y - 1, width: w, height: 2).fill()
            let tw = (codeText(track) as NSString).size(withAttributes: [.font: labelFont(9)]).width + 10
            drawCode(track, in: CGRect(x: drop.point.x - tw / 2, y: drop.point.y - 7, width: tw, height: 13), focused: true)
        }
        if !strip { drawScrollbar(model: model) }
        if case let .marquee(a, b) = drag {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            Palette.amber.withAlphaComponent(0.08).setFill()
            r.fill()
            let path = NSBezierPath(rect: r)
            path.setLineDash([4, 3], count: 2, phase: 0)
            Palette.amber.withAlphaComponent(0.8).setStroke()
            path.stroke()
        }
        let focusRect = focusedBandRect
        if model.focusedIsLocked, bands.contains(where: \.focused) {
            drawText("LOCKED TO MASTER: TEXT ONLY", at: CGPoint(x: w - 190, y: focusRect.minY + 6),
                     font: labelFont(9), color: Palette.lilac)
        }

        if case let .creating(t0, t1) = drag {
            let r = CGRect(x: x(min(t0, t1)), y: focusRect.minY + 6,
                           width: max(1, x(max(t0, t1)) - x(min(t0, t1))), height: max(4, focusRect.height - 12))
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            Palette.amber.withAlphaComponent(0.18).setFill()
            path.fill()
            Palette.amber.setStroke()
            path.lineWidth = 1.5
            let dash: [CGFloat] = [5, 3]
            path.setLineDash(dash, count: 2, phase: 0)
            path.stroke()
        }

        if !strip {
            let px = x(playheadTime)
            if px >= -2 && px <= w + 2 { Self.drawPlayheadMark(at: px, height: area.height) }
        }

        if let notice = audioNotice(model) {
            drawText(notice, at: CGPoint(x: 12, y: wave.minY + 8), font: labelFont(10), color: Palette.textFaint)
        }
    }

    /// The playhead: an amber line down the pane, with a small triangle at the top.
    private static func drawPlayheadMark(at px: CGFloat, height: CGFloat) {
        Palette.amber.setFill()
        CGRect(x: px - 0.75, y: 0, width: 1.5, height: height).fill()
        let tri = NSBezierPath()
        tri.move(to: CGPoint(x: px - 6, y: 0))
        tri.line(to: CGPoint(x: px + 6, y: 0))
        tri.line(to: CGPoint(x: px, y: 8))
        tri.close()
        tri.fill()
    }

    /// Why there's no waveform, when there isn't one.
    private func audioNotice(_ model: AppModel) -> String? {
        guard model.audio.waveform == nil else { return nil }
        return model.audio.isLoading ? "READING AUDIO…" : (model.hasMedia ? "NO AUDIO" : "NO VIDEO LOADED")
    }

    private func drawRuler(_ ctx: CGContext, width: CGFloat) {
        Palette.panel.setFill()
        CGRect(x: 0, y: 0, width: width, height: rulerHeight).fill()
        Palette.rule.setFill()
        CGRect(x: 0, y: rulerHeight - 1, width: width, height: 1).fill()

        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let step = steps.first(where: { $0 * pps >= 80 }) ?? 600
        let minor = step / 5
        // From a step before the left edge: a label that starts just off it still shows its
        // end (the strip's tiles meet there).
        var tick = max(0, ((viewStart - step) / minor).rounded(.down) * minor)
        let end = viewStart + visibleDuration
        while tick <= end {
            let px = x(tick)
            let isMajor = abs((tick / step).rounded() * step - tick) < minor * 0.01
            (isMajor ? Palette.textDim : Palette.textFaint).setFill()
            CGRect(x: px, y: isMajor ? rulerHeight - 9 : rulerHeight - 5, width: 1, height: isMajor ? 8 : 4).fill()
            if isMajor {
                drawText(Timecode.ruler(tick, showTenths: step < 1), at: CGPoint(x: px + 3, y: 3),
                         font: monoFont(9), color: Palette.textDim)
            }
            tick += minor
        }
    }

    /// The audio's outline for the width in view: the same for every band, so worked out
    /// once a frame.
    private var envelopeKey: (start: Double, pps: Double, pixels: Int, id: ObjectIdentifier)?
    private var envelopeCache: [(peak: Float, rms: Float)] = []

    private func envelope(_ wf: Waveform, pixels: Int) -> [(peak: Float, rms: Float)] {
        let id = ObjectIdentifier(wf)
        if let k = envelopeKey, k.start == viewStart, k.pps == pps, k.pixels == pixels, k.id == id { return envelopeCache }
        envelopeCache = wf.envelope(from: viewStart, secondsPerPixel: 1 / pps, pixels: pixels)
        envelopeKey = (viewStart, pps, pixels, id)
        return envelopeCache
    }

    private func drawWaveform(_ ctx: CGContext, in rect: CGRect, model: AppModel, muted: Bool = false) {
        // Centre line
        Palette.rule.setFill()
        CGRect(x: 0, y: rect.midY, width: rect.width, height: 1).fill()
        guard let wf = model.audio.waveform, rect.width > 1 else { return }

        let pixels = Int(rect.width)
        let env = envelope(wf, pixels: pixels)
        let half = rect.height / 2 - 4
        let gain = model.waveGain
        let useDB = model.dbScale

        func scale(_ a: Float) -> CGFloat {
            let v: Double
            if useDB {
                let db = 20 * log10(max(Double(a), 1e-5)) + 20 * log10(gain)
                v = (db + 60) / 60
            } else {
                v = Double(a) * gain
            }
            return CGFloat(min(1, max(0, v))) * half
        }

        let peakPath = CGMutablePath()
        let rmsPath = CGMutablePath()
        for (i, e) in env.enumerated() {
            let xx = CGFloat(i) + 0.5
            let p = scale(e.peak), r = scale(e.rms)
            if p > 0.3 {
                peakPath.move(to: CGPoint(x: xx, y: rect.midY - p))
                peakPath.addLine(to: CGPoint(x: xx, y: rect.midY + p))
            }
            if r > 0.3 {
                rmsPath.move(to: CGPoint(x: xx, y: rect.midY - r))
                rmsPath.addLine(to: CGPoint(x: xx, y: rect.midY + r))
            }
        }
        ctx.setLineWidth(1)
        ctx.addPath(peakPath)
        // Another language's band: its waveform steps back with it.
        let teal = muted ? Muted.teal : Palette.teal
        ctx.setStrokeColor(teal.withAlphaComponent(teal.alphaComponent * 0.35).cgColor)
        ctx.strokePath()
        ctx.addPath(rmsPath)
        ctx.setStrokeColor(teal.withAlphaComponent(teal.alphaComponent * 0.85).cgColor)
        ctx.strokePath()
    }

    private func drawBoxes(_ ctx: CGContext, in rect: CGRect, track: Track, focused: Bool, model: AppModel) {
        let doc = track.doc
        let subs = doc.subtitles
        let lanes = laneOffsets(subs)
        let overlaps = doc.overlappingIDs
        // Only the focused language shows a selection.
        let selected = focused ? doc.selectedID : nil
        let preset = model.preset(for: track)
        // Another language steps back, as its column in the title pane does: its boxes in the
        // quiet blue of its cards, a rim in the warning colour when a title is near or over a
        // limit (red the stronger), less colour and fainter all round (see `Muted`).
        let muted = showsCodes && !focused
        let bandDim: CGFloat = muted ? CGFloat(StepBack.opacity) : 1
        let langTag = track.language.code.split(separator: "-").first.map { $0.uppercased() } ?? ""
        let tagFont = labelFont(9)
        let tagSize = (langTag as NSString).size(withAttributes: [.font: tagFont])
        let viewEnd = viewStart + visibleDuration
        // Titles with an issue get a bar along the top, in QC mode or not (not the title being
        // typed in or spotted): yellow-alert in the focused language, the quiet blue of an
        // unfocused card in the others. QC mode: the focused language's other titles step back.
        let qc = focused && model.qcMode
        let baseHeight = rect.height * WaveLayout.boxShare
        let laneShift = rect.height * (WaveLayout.boxShare - WaveLayout.shiftedBoxShare)

        var rects: [(id: UUID, rect: CGRect)] = []
        defer { boxRectsByTrack[track.id] = rects }
        var selectedRect: CGRect?

        for (index, s) in subs.enumerated() {
            let end = (focused ? model.liveSpotEnd(for: s.id).map { max($0, playheadTime) } : nil) ?? s.end
            guard end >= viewStart && s.start <= viewEnd else { continue }
            let lane = lanes[s.id] ?? 0
            let height = lane == 0 ? baseHeight : baseHeight - laneShift
            let y = rect.midY - height / 2 + CGFloat(lane) * laneShift
            let r = CGRect(x: x(s.start), y: y, width: max(2, x(end) - x(s.start)), height: height)
            rects.append((s.id, r))

            let isSel = s.id == selected || (focused && model.multiSelection.contains(s.id))
            let marked = s.id != model.typingIn && s.id != model.spottingID
                && !model.qcIssues(of: s, in: track, next: index + 1 < subs.count ? subs[index + 1] : nil,
                                   overlapping: overlaps).isDisjoint(with: model.qcKinds)
            let dim: CGFloat = qc && !marked && !isSel ? 0.45 : bandDim
            let status = preset.status(s)
            let overlapping = overlaps.contains(s.id)
            let base: NSColor = muted ? Muted.periwinkle
                : (overlapping ? Palette.lilac : Palette.status(status)).withAlphaComponent(dim)
            let path = NSBezierPath(roundedRect: r, xRadius: Self.boxCornerRadius, yRadius: Self.boxCornerRadius)
            if muted {
                // Like a CPS chip in another language's column (Chip.muted).
                let rim: NSColor? = overlapping ? Muted.lilac : (status == .bad ? Muted.red : status == .warn ? Muted.gold : nil)
                (status == .bad && !overlapping ? Muted.red.faded(0.22) : Muted.periwinkle.faded(0.13)).setFill()
                path.fill()
                (rim ?? Muted.periwinkle.faded(0.75)).setStroke()
                path.lineWidth = status == .bad && !overlapping ? 1.5 : 1
                path.stroke()
            } else {
                base.withAlphaComponent(isSel ? 0.24 : 0.13 * dim).setFill()
                path.fill()
            }
            if muted {
                // Drawn above.
            } else if isSel {
                // Selected: the frame keeps the title's own timing colour, and amber LCARS
                // brackets ( ) hold its left and right ends, so selection never looks like
                // a timing warning. Frame and brackets run along one line, so the brackets
                // cover the frame completely, and their outer edge is the box's own edge.
                drawSelection(r, frame: base)
            } else {
                base.withAlphaComponent(0.75 * dim).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            if marked {
                (focused ? Palette.alert : Muted.periwinkle.faded(0.75)).setFill()
                NSBezierPath(roundedRect: CGRect(x: r.minX + 4, y: r.minY - 5, width: max(2, r.width - 8), height: 3),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }
            // Find: a teal bar along the bottom of every title that has a match.
            if model.find.isShown, !model.find.highlights(in: s.id).ranges.isEmpty {
                (muted ? Muted.teal : Palette.teal.withAlphaComponent(dim)).setFill()
                NSBezierPath(roundedRect: CGRect(x: r.minX + 4, y: r.maxY - 6, width: max(2, r.width - 8), height: 3),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }

            // Number pill, then the full title text (all lines), wrapped inside the box.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).addClip()
            let numberText = model.rowNumber(of: s.id).map(String.init) ?? "\(index + 1)"
            let font = labelFont(11)
            let numWidth = (numberText as NSString).size(withAttributes: [.font: font]).width + 10
            let pill = CGRect(x: r.minX + 4, y: r.minY + 4, width: numWidth, height: 15)
            numberPills.append((track.id, s.id, pill.intersection(r)))
            (isSel ? Palette.amber : (muted ? Muted.periwinkle.faded(0.75) : base)).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 7.5, yRadius: 7.5).fill()
            drawText(numberText, at: CGPoint(x: pill.minX + 5, y: pill.minY + 1), font: font, color: Palette.background)
            let fullText = cachedBoxText(s.text, focused: focused, dim: dim)
            // Beside the number pill when there's room; otherwise underneath it.
            let besidePill = r.maxX - pill.maxX - 9 >= 40
            let textRect = besidePill
                ? CGRect(x: pill.maxX + 5, y: r.minY + 3, width: r.maxX - pill.maxX - 9, height: r.height - 6)
                : CGRect(x: r.minX + 4, y: pill.maxY + 2, width: r.width - 8, height: r.maxY - pill.maxY - 4)
            // Spotting: a running timer in the top right corner.
            if focused, s.id == model.spottingID, let timer = model.spotTimer() {
                let tf = monoFont(10)
                let tw = (timer.text as NSString).size(withAttributes: [.font: tf]).width + 12
                let tr = CGRect(x: r.maxX - tw - 4, y: r.minY + 4, width: tw, height: 15)
                if tr.minX > pill.maxX + 2 {
                    timer.status.nsColor.setFill()
                    NSBezierPath(roundedRect: tr, xRadius: 7.5, yRadius: 7.5).fill()
                    drawText(timer.text, at: CGPoint(x: tr.minX + 6, y: tr.minY + 1), font: tf, color: Palette.background)
                }
            }
            if fullText.length > 0, textRect.width > 6, textRect.height > 8 {
                fullText.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
            // Which language this is: a quiet tag in the lower right corner.
            if !langTag.isEmpty, r.width >= pill.width + tagSize.width + 24, r.height >= 40 {
                let tag = CGRect(x: r.maxX - tagSize.width - 12, y: r.maxY - 17,
                                 width: tagSize.width + 8, height: 13)
                (muted ? base.faded(0.16) : base.withAlphaComponent(0.16)).setFill()
                NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
                drawText(langTag, at: CGPoint(x: tag.minX + 4, y: tag.minY + 1), font: tagFont,
                         color: muted ? base.faded(0.6) : base.withAlphaComponent(0.6))
            }
            NSGraphicsContext.restoreGraphicsState()

            if isSel { selectedRect = r }
        }

        // Grips on the selected title's edges.
        if let r = selectedRect {
            Palette.amber.setFill()
            for gx in [r.minX, r.maxX] {
                NSBezierPath(roundedRect: CGRect(x: gx - 2, y: r.midY - 9, width: 4, height: 18), xRadius: 2, yRadius: 2).fill()
            }
        }
    }

    /// Box texts already formatted. The waveform redraws many times a second while playing,
    /// and working out a title's italics afresh for every box on every frame would cost
    /// smoothness; a title's text only changes when it's edited.
    private var boxTextCache: [String: NSAttributedString] = [:]

    private func cachedBoxText(_ markup: String, focused: Bool, dim: CGFloat) -> NSAttributedString {
        // The focused language, the others, and (in QC mode) titles with nothing to fix are
        // drawn at different strengths.
        let key = (dim >= 0.99 ? "1" : dim >= 0.5 ? "0" : "q") + markup
        if let hit = boxTextCache[key] { return hit }
        if boxTextCache.count > 1500 { boxTextCache.removeAll(keepingCapacity: true) }
        let built = Self.boxText(markup, color: Palette.text.withAlphaComponent(0.9 * dim))
        boxTextCache[key] = built
        return built
    }

    /// A box's text as the waveform shows it: italic and bold as in the card, every tag
    /// hidden ({\an8}, <font …>), blank space at either end left out.
    static func boxText(_ markup: String, color: NSColor, size: CGFloat = 11) -> NSAttributedString {
        let a: NSMutableAttributedString
        if markup.contains("<") || markup.contains("{") {
            a = NSMutableAttributedString(attributedString: RichMarkup.attributed(markup, size: size))
            // RichMarkup keeps position and colour codes as typed; the waveform hides them.
            for m in Markup.tagPattern.matches(in: a.string, range: NSRange(location: 0, length: a.length)).reversed() {
                a.deleteCharacters(in: m.range)
            }
        } else {
            // No tags at all (most titles): nothing to work out.
            a = NSMutableAttributedString(string: markup, attributes: [
                .font: RichMarkup.font(size: size, italic: false, bold: false)
            ])
        }
        let s = a.string as NSString
        let visible = CharacterSet.whitespacesAndNewlines.inverted
        let first = s.rangeOfCharacter(from: visible)
        guard first.location != NSNotFound else { return NSAttributedString() }
        let last = s.rangeOfCharacter(from: visible, options: .backwards)
        let out = NSMutableAttributedString(attributedString: a.attributedSubstring(
            from: NSRange(location: first.location, length: NSMaxRange(last) - first.location)))
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let all = NSRange(location: 0, length: out.length)
        out.addAttribute(.foregroundColor, value: color, range: all)
        out.addAttribute(.paragraphStyle, value: para, range: all)
        return out
    }

    /// How far each selection bracket reaches along the top and bottom: a fifth of the box,
    /// never so far that the two meet.
    static func selectionBracketArm(width: CGFloat) -> CGFloat {
        min(max(width / 5, 6), width * 0.4)
    }

    /// Corner radius of a title's box on the waveform.
    static let boxCornerRadius: CGFloat = 8
    /// Thickness of the selection brackets.
    static let bracketWidth: CGFloat = 3

    /// The line a selected box's frame and brackets both run along: half a bracket's width
    /// inside the box, so the bracket's outer edge is exactly the box's edge (where it's
    /// grabbed), and the fine frame sits in the middle of the bracket, hidden under it.
    static func selectionLine(for r: CGRect) -> (rect: CGRect, radius: CGFloat, arm: CGFloat) {
        let c = r.insetBy(dx: bracketWidth / 2, dy: bracketWidth / 2)
        let arm = selectionBracketArm(width: c.width)
        let radius = max(0.5, min(boxCornerRadius - bracketWidth / 2, c.height / 2, arm))
        return (c, radius, arm)
    }

    /// Where each prong of a selection bracket ends, measured in from the box's side: the
    /// line's tip, and the small capsule after it (shaped like the pane-header icon), or nil
    /// where there's no room for one. The bracket reaches as far either way: `arm` plus 8.5.
    static func bracketEnd(arm: CGFloat, radius: CGFloat, width: CGFloat)
        -> (lineTip: CGFloat, capsule: ClosedRange<CGFloat>?) {
        let reach = arm + 8.5
        let capsule: CGFloat = 10, gap: CGFloat = 2.5, cap = bracketWidth / 2
        let tip = reach - capsule - gap - cap
        guard tip >= radius + 2, 2 * reach < width else { return (arm, nil) }
        return (tip, (reach - capsule)...reach)
    }

    /// A selected box: its fine frame in the timing colour, and two rounded amber brackets
    /// over its ends, each prong ending in a small capsule.
    private func drawSelection(_ r: CGRect, frame color: NSColor) {
        let lw = Self.bracketWidth
        guard r.width > lw * 2 + 2, r.height > lw * 2 + 2 else {
            // Too small for brackets: just an amber outline.
            Palette.amber.setStroke()
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 2, yRadius: 2)
            p.lineWidth = 1.5
            p.stroke()
            return
        }
        let (b, radius, arm) = Self.selectionLine(for: r)
        let frame = NSBezierPath(roundedRect: b, xRadius: radius, yRadius: radius)
        color.setStroke()
        frame.lineWidth = 1.5
        frame.stroke()

        let end = Self.bracketEnd(arm: arm, radius: radius, width: b.width)
        let pillHeight: CGFloat = 4.5
        Palette.amber.setStroke()
        Palette.amber.setFill()
        for side in [CGFloat(-1), 1] {
            let edge = side < 0 ? b.minX : b.maxX
            let inward = -side
            let tip = edge + inward * end.lineTip
            let p = NSBezierPath()
            p.move(to: CGPoint(x: tip, y: b.minY))
            p.line(to: CGPoint(x: edge + inward * radius, y: b.minY))
            p.appendArc(from: CGPoint(x: edge, y: b.minY), to: CGPoint(x: edge, y: b.minY + radius), radius: radius)
            p.line(to: CGPoint(x: edge, y: b.maxY - radius))
            p.appendArc(from: CGPoint(x: edge, y: b.maxY), to: CGPoint(x: edge + inward * radius, y: b.maxY), radius: radius)
            p.line(to: CGPoint(x: tip, y: b.maxY))
            p.lineWidth = lw
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
            guard let pill = end.capsule else { continue }
            let x0 = edge + inward * pill.lowerBound, x1 = edge + inward * pill.upperBound
            for y in [b.minY, b.maxY] {
                let rect = CGRect(x: min(x0, x1), y: y - pillHeight / 2, width: abs(x1 - x0), height: pillHeight)
                NSBezierPath(roundedRect: rect, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()
            }
        }
    }

    /// Where the slim lanes of the other open languages are, and their codes.
    private func layoutLanes(top: CGFloat) {
        laneRects.removeAll(keepingCapacity: true)
        laneTags.removeAll(keepingCapacity: true)
        laneCodes.removeAll(keepingCapacity: true)
        let tracks = laneTracks
        guard !tracks.isEmpty else { return }
        let laneH = lanesHeight / CGFloat(tracks.count)
        let focusedID = model?.video?.focusedTrackID
        for (i, track) in tracks.enumerated() {
            let lane = CGRect(x: 0, y: top + CGFloat(i) * laneH, width: area.width, height: laneH)
            laneRects.append((track.id, lane))
            // Language code tag at the left edge.
            let tw = (codeText(track) as NSString).size(withAttributes: [.font: labelFont(9)]).width + 10
            let tagRect = CGRect(x: 10, y: lane.minY + (laneH - 13) / 2, width: tw, height: 13)
            laneTags.append((track.id, tagRect.insetBy(dx: -3, dy: -3)))
            laneCodes.append((track, tagRect, track.id == focusedID))
        }
    }

    /// Slim lanes for the other open languages: boxes and numbers, no text, never highlighted.
    /// (Their codes are drawn on top, with the bands' codes: see drawOverlay.)
    private func drawLanes(model: AppModel, top: CGFloat) {
        laneBoxes.removeAll(keepingCapacity: true)
        layoutLanes(top: top)
        let tracks = laneTracks
        guard !tracks.isEmpty, tracks.count == laneRects.count else { return }
        let viewEnd = viewStart + visibleDuration
        let focusedID = model.video?.focusedTrackID
        for (i, track) in tracks.enumerated() {
            // The language you work in, closed: its code is amber and its selected title shows.
            let focused = track.id == focusedID
            let lane = laneRects[i].rect
            let laneH = lane.height
            Palette.background.withAlphaComponent(0.6).setFill()
            lane.fill()
            Palette.rule.setFill()
            CGRect(x: 0, y: lane.minY, width: lane.width, height: 1).fill()
            let preset = model.preset(for: track)
            for s in track.doc.subtitles where s.end >= viewStart && s.start <= viewEnd {
                let r = CGRect(x: x(s.start), y: lane.minY + 2, width: max(2, x(s.end) - x(s.start)), height: max(4, laneH - 4))
                laneBoxes.append((track.id, s.id, r))
                // Another language steps back here too (see `Muted`).
                let status = preset.status(s)
                let color = focused ? Palette.status(status)
                    : (status == .bad ? Muted.red : status == .warn ? Muted.gold : Muted.periwinkle)
                let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
                color.faded(0.16).setFill()
                path.fill()
                // Only the language you work in shows a selection.
                let selected = focused && s.id == track.doc.selectedID
                (selected ? Palette.amber : color.faded(0.6)).setStroke()
                path.lineWidth = selected ? 2 : 1
                path.stroke()
                if r.width > 22, laneH >= 12, let n = model.rowNumber(of: s.id) {
                    drawText("\(n)", at: CGPoint(x: r.minX + 4, y: r.minY + (r.height - 11) / 2),
                             font: labelFont(9), color: Palette.text.withAlphaComponent(0.7))
                }
            }
        }
    }

    /// A language's code: amber for the language you work in, quiet blue for the others.
    private func drawCode(_ track: Track, in r: CGRect, focused: Bool) {
        (focused ? Palette.amber : Palette.panelRaised).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        drawText(codeText(track), at: CGPoint(x: r.minX + 5, y: r.minY + 1), font: labelFont(9),
                 color: focused ? Palette.background : Palette.periwinkle)
    }

    /// Overlapping titles alternate one lane up and one lane down; others sit in the middle.
    private func laneOffsets(_ subs: [Subtitle]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var clusterEnd = -Double.infinity
        var cluster: [UUID] = []
        func flush() {
            if cluster.count > 1 {
                for (i, id) in cluster.enumerated() { result[id] = i % 2 == 0 ? -1 : 1 }
            }
            cluster.removeAll()
        }
        for s in subs {
            if s.start < clusterEnd - 0.0005 {
                cluster.append(s.id)
            } else {
                flush()
                cluster = [s.id]
            }
            clusterEnd = max(clusterEnd, s.end)
        }
        flush()
        return result
    }

    // MARK: Hit testing

    private enum Hit { case edge(UUID, TitlesCore.Edge), body(UUID), empty }

    private func hit(_ p: CGPoint) -> Hit {
        // Selected box first, then later boxes (drawn on top).
        let selected = model?.doc.selectedID
        let rects = band(at: p).flatMap { boxRectsByTrack[$0.track.id] } ?? []
        var candidates = Array(rects.reversed())
        if let i = candidates.firstIndex(where: { $0.id == selected }) {
            let sel = candidates.remove(at: i)
            candidates.insert(sel, at: 0)
        }
        for (id, r) in candidates where r.insetBy(dx: -edgeGrab, dy: 0).contains(p) {
            if abs(p.x - r.minX) <= edgeGrab && r.width > edgeGrab * 2 { return .edge(id, .start) }
            if abs(p.x - r.maxX) <= edgeGrab { return .edge(id, .end) }
            if r.contains(p) { return .body(id) }
        }
        return .empty
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }

    /// Command held over a box: the split cursor.
    private var flagsMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        if window == nil { leaveStrip(now: false) }
        updateFrameLink()
        guard window != nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, e.window === window else { return }
                let p = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if self.bounds.contains(p) { self.updateCursor(at: p, flags: e.modifierFlags) }
            }
            return e
        }
    }

    private func updateCursor(_ event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil), flags: event.modifierFlags)
    }

    private static func isSplitClick(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .shift, .control, .option]) == [.command]
    }

    private func updateCursor(at p: CGPoint, flags: NSEvent.ModifierFlags) {
        if scrollbarRect.contains(p) { NSCursor.arrow.set(); return }
        if bandDivider(at: p) != nil { NSCursor.resizeUpDown.set(); return }
        if case .language = drag, didDrag { NSCursor.closedHand.set(); return }
        if languageCode(at: p) != nil { NSCursor.openHand.set(); return }
        if p.y < rulerHeight || laneRects.contains(where: { $0.rect.contains(p) }) { NSCursor.pointingHand.set(); return }
        if model?.focusedIsLocked == true { NSCursor.arrow.set(); return }
        // Playing on the strip: the boxes are where the strip shows them, not where they
        // were last drawn here (a click finds them again: see mouseDown).
        if stripOn { NSCursor.crosshair.set(); return }
        let split = Self.isSplitClick(flags)
        switch hit(p) {
        case .edge: (split ? NSCursor.split : NSCursor.resizeLeftRight).set()
        case .body: (split ? NSCursor.split : NSCursor.openHand).set()
        case .empty: NSCursor.crosshair.set()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        // Clicked while playing: the view draws itself again, so what's under the pointer
        // is exactly what's drawn (the strip comes back once the hand is off).
        takeBack()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        didDrag = false

        if p.y < rulerHeight {
            drag = .ruler
            model.placePlayhead(t(p.x))
            return
        }

        // The scroll bar: drag the handle, or click anywhere along it to jump there.
        if scrollbarRect.contains(p) {
            let thumb = thumbRect
            if thumb.insetBy(dx: 0, dy: -3).contains(p) {
                drag = .scrolling(grab: p.x - thumb.minX)
            } else {
                drag = .scrolling(grab: thumb.width / 2)
                scroll(thumbX: p.x - thumb.width / 2)
            }
            needsDisplay = true
            return
        }

        // The line between two bands: drag to share the height between them.
        if let pair = bandDivider(at: p) {
            drag = .bandResize(upper: pair.upper.track.id, lower: pair.lower.track.id, startY: p.y,
                               hu: pair.upper.rect.height, hl: pair.lower.rect.height,
                               wu: bandWeights[pair.upper.track.id] ?? 1, wl: bandWeights[pair.lower.track.id] ?? 1)
            return
        }

        // A language's code, on an open band or a slim lane: a click moves you to that
        // language (nothing opens or closes), a double-click opens or closes it, and a drag
        // moves it up or down, into the open languages or the slim lanes.
        if let id = languageCode(at: p) {
            languageDrop = nil
            if event.clickCount == 2 {
                drag = .none
                model.toggleWaveBand(id)
            } else {
                if id != model.video?.focusedTrackID { model.focusTrack(id, edit: false) }
                drag = .language(id: id)
            }
            needsDisplay = true
            return
        }

        // Clicking in another language's band works on that language: it becomes the focused one.
        if let b = band(at: p), !b.focused {
            model.focusTrack(b.track.id, edit: false)
        }

        // A slim lane: move to that language (and the title clicked).
        if let lane = laneRects.first(where: { $0.rect.contains(p) }) {
            drag = .none
            model.focusTrack(lane.track, edit: false)
            if let box = laneBoxes.first(where: { $0.track == lane.track && $0.rect.insetBy(dx: -2, dy: 0).contains(p) }) {
                model.select(box.id, seekToStart: true)
            } else {
                model.placePlayhead(t(p.x))
            }
            needsDisplay = true
            return
        }

        // Double-click a box's number: play that title.
        if event.clickCount == 2, let pill = numberPills.last(where: {
            $0.track == model.video?.focusedTrackID && $0.rect.insetBy(dx: -2, dy: -2).contains(p)
        }) {
            if case .moving = drag { model.doc.cancelLive() }
            drag = .none
            model.playTitle(pill.id)
            needsDisplay = true
            return
        }

        // Shift-click a box: add it to (or take it out of) a group of titles.
        // Shift-drag on empty waveform: draw a box to select every title it touches.
        if event.modifierFlags.contains(.shift), !Self.isSplitClick(event.modifierFlags) {
            switch hit(p) {
            case let .edge(id, _), let .body(id):
                model.toggleMulti(id)
                drag = .none
            case .empty:
                drag = .marquee(from: p, to: p)
            }
            needsDisplay = true
            return
        }

        // Dragging any title of a group moves the whole group.
        if model.multiSelection.count > 1, !model.focusedIsLocked, !Self.isSplitClick(event.modifierFlags),
           case let .body(id) = hit(p), model.multiSelection.contains(id) {
            var originals: [UUID: Double] = [:]
            for s in model.doc.subtitles where model.multiSelection.contains(s.id) { originals[s.id] = s.start }
            startResistance(.move, ids: model.multiSelection, model: model)
            model.doc.beginLive()
            drag = .movingGroup(grab: t(p.x), originals: originals)
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }
        model.clearMulti()

        // A locked language keeps the master's timing: clicks only select and seek.
        if model.focusedIsLocked {
            drag = .none
            switch hit(p) {
            case let .edge(id, _), let .body(id):
                model.select(id, seekToStart: true)
                if event.clickCount == 2 { model.focusRequest = id }
            case .empty:
                model.placePlayhead(t(p.x))
            }
            needsDisplay = true
            return
        }

        // ⌘-click on a box: split it there.
        if Self.isSplitClick(event.modifierFlags) {
            switch hit(p) {
            case let .edge(id, _), let .body(id):
                model.splitTitle(id, at: t(p.x))
                drag = .none
                needsDisplay = true
                return
            case .empty:
                break
            }
        }

        switch hit(p) {
        case let .edge(id, edge):
            startResistance(.edge(edge), ids: [id], model: model)
            model.select(id)
            model.doc.beginLive()
            drag = .resizing(id: id, edge: edge)
        case let .body(id):
            // Clicking a title takes the playhead to its start, so play starts there.
            model.select(id, seekToStart: true)
            if event.clickCount == 2, let s = model.doc.subtitle(id) {
                model.seek(s.start)
                model.focusRequest = id
                drag = .none
                return
            }
            if let s = model.doc.subtitle(id) {
                startResistance(.move, ids: [id], model: model)
                model.doc.beginLive()
                drag = .moving(id: id, grab: t(p.x) - s.start, length: s.duration)
            }
            NSCursor.closedHand.set()
        case .empty:
            // Drawing a new title: it stops at the minimum gap from its neighbours, just
            // like stretching one (starting inside a gap moves the start out to it).
            createClickTime = t(p.x)
            let b = Self.createBarriers(at: createClickTime, in: model.doc.subtitles, gap: model.minGap)
            refusalShown = false
            // Inside another title's time (its box sits a lane up or down): with overlapping
            // titles off, nothing can be drawn there.
            let inside = model.doc.subtitles.contains { $0.start < b.start - 0.0005 && $0.end > b.start + 0.0005 }
            resistance = inside && !model.allowOverlaps ? nil : DragResistance(
                mode: .draw(from: b.start), original: [.init(start: b.start, end: b.start)],
                others: model.doc.subtitles, gap: model.minGap, allowOverlap: model.allowOverlaps,
                keepGap: model.keepMinGap, breakDistance: Self.breakPixels / pps)
            drag = .creating(t0: b.start, t1: b.start)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - downPoint.x, p.y - downPoint.y) > 3 { didDrag = true }
        if case let .scrolling(grab) = drag {
            scroll(thumbX: p.x - grab)
            return
        }
        if case let .bandResize(upper, lower, startY, hu, hl, wu, _) = drag {
            // Neither band under two lines' height (when the two have room for that).
            let minH = min(Self.minBandHeight, (hu + hl) / 2)
            let newU = min(max(minH, hu + (p.y - startY)), hu + hl - minH)
            let k = hu / max(0.001, wu)   // points per unit of weight
            bandWeights[upper] = newU / k
            bandWeights[lower] = (hu + hl - newU) / k
            needsDisplay = true
            return
        }
        if case let .language(id) = drag {
            if didDrag {
                languageDrop = languageDropTarget(for: id, at: p)
                NSCursor.closedHand.set()
            }
            needsDisplay = true
            return
        }
        guard didDrag else { return }
        autoscroll(for: p)

        switch drag {
        case .none:
            break
        case .scrolling, .bandResize, .language:
            break
        case let .marquee(from, _):
            drag = .marquee(from: from, to: p)
        case let .movingGroup(grab, originals):
            var delta = t(p.x) - grab
            if let earliest = originals.values.min() { delta = max(delta, -earliest) }
            delta = resist(delta)
            for (id, start) in originals {
                model.doc.liveUpdate(id) { s in
                    let length = s.duration
                    s.start = start + delta
                    s.end = s.start + length
                }
            }
            if let first = originals.min(by: { $0.value < $1.value }) {
                model.engine.seek(to: first.value + delta, exact: true)
            }
        case .ruler:
            model.placePlayhead(t(p.x))
        case let .creating(t0, _):
            guard resistance != nil else {
                showRefusal(atGap: false)
                break
            }
            drag = .creating(t0: t0, t1: resist(max(0, t(p.x))))
        case let .moving(id, grab, length):
            let from = resistance?.original.first?.start ?? 0
            let start = from + resist(max(0, t(p.x) - grab) - from)
            model.doc.liveUpdate(id) { $0.start = start; $0.end = start + length }
            model.engine.seek(to: start, exact: true)
        case let .resizing(id, edge):
            let target = resist(t(p.x))
            if let value = model.moveEdge(edge, of: id, to: target, clamp: false) {
                resistance?.settle(at: value)
                model.scrubTo(value)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        stripHold = max(stripHold, CACurrentMediaTime() + 0.3)
        defer {
            drag = .none
            resistance = nil
            needsDisplay = true
            updateCursor(event)
        }
        switch drag {
        case .none, .ruler, .scrolling, .bandResize:
            break
        case let .language(id):
            if didDrag, let drop = languageDrop {
                let group = drop.open ? bands.map { $0.track.id } : laneRects.map { $0.track }
                let column = AppModel.waveDropColumn(order: model.video?.openTrackIDs ?? [], moving: id,
                                                     group: group, slot: drop.slot)
                model.dropOnWaveform(id, column: column, open: drop.open)
            }
            languageDrop = nil
        case let .marquee(a, b):
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            let hits = boxRects.filter { $0.rect.intersects(r) }.map(\.id)
            model.addToMulti(hits)
        case .movingGroup:
            model.doc.commitLive()
        case let .creating(t0, t1):
            if didDrag, abs(t1 - t0) >= 0.15 {
                model.createTitle(start: min(t0, t1), end: max(t0, t1))
            } else {
                model.placePlayhead(createClickTime)
            }
        case let .moving(id, _, _):
            model.doc.commitLive()
            if didDrag { model.replayMoved(id) }
        case let .resizing(id, edge):
            model.doc.commitLive()
            if didDrag {
                model.preview(edge, of: id, after: .resize)
            } else if let s = model.doc.subtitle(id) {
                model.seek(s.start)
            }
        }
    }

    /// A drag of these titles (or one edge of one) begins: note what's in their way.
    private func startResistance(_ mode: DragResistance.Mode, ids: Set<UUID>, model: AppModel) {
        refusalShown = false
        let dragged = model.doc.subtitles.filter { ids.contains($0.id) }
        resistance = DragResistance(
            mode: mode, original: dragged.map { .init(start: $0.start, end: $0.end) },
            others: model.doc.subtitles.filter { !ids.contains($0.id) }, gap: model.minGap,
            allowOverlap: model.allowOverlaps, keepGap: model.keepMinGap, breakDistance: Self.breakPixels / pps)
    }

    /// Where the drag goes for what the pointer asks: held at the next title in the way.
    private func resist(_ wanted: Double) -> Double {
        guard var r = resistance else { return wanted }
        r.breakDistance = Self.breakPixels / pps
        let v = r.drag(to: wanted)
        resistance = r
        if r.bumped { tick() }
        if r.refused { showRefusal(atGap: r.refusedAtGap) }
        return v
    }

    /// Pulled hard against a title that can't come closer: say which setting holds it (once a drag).
    private func showRefusal(atGap: Bool) {
        guard !refusalShown else { return }
        refusalShown = true
        model?.flash(atGap
            ? "Titles keep the minimum gap between them. To let them closer: Title ▸ Keep Minimum Gap."
            : "Titles can't overlap. To allow it: Title ▸ Enable Overlapping Titles.")
    }

    /// Where a title drawn from `t0` stops: the minimum gap after the title before it and
    /// before the title after it. A start inside one of those gaps moves out to it. Starting
    /// inside a title, or where the gap leaves no room, nothing holds.
    static func createBarriers(at t0: Double, in subs: [Subtitle], gap: Double)
        -> (start: Double, lower: Double?, upper: Double?) {
        let eps = 0.0005
        if subs.contains(where: { $0.start < t0 - eps && $0.end > t0 + eps }) { return (t0, nil, nil) }
        let lower = subs.filter { $0.end <= t0 + eps }.map(\.end).max().map { $0 + gap }
        let upper = subs.filter { $0.start >= t0 - eps }.map(\.start).min().map { $0 - gap }
        if let l = lower, let u = upper, l > u { return (t0, nil, nil) }
        var start = t0
        if let l = lower, start < l { start = l }
        if let u = upper, start > u { start = u }
        return (start, lower.map { min($0, start) }, upper.map { max($0, start) })
    }

    /// A light trackpad tap (Force Touch trackpads only; nothing elsewhere).
    private func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Scrolls the view when dragging past either side.
    private func autoscroll(for p: CGPoint) {
        let margin: CGFloat = 24
        if p.x < margin { viewStart = max(0, viewStart - Double(margin - p.x) / pps * 0.5) }
        if p.x > bounds.width - margin { viewStart += Double(p.x - (bounds.width - margin)) / pps * 0.5 }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        takeBack(for: 1)
        let p = convert(event.locationInWindow, from: nil)
        if let b = band(at: p), !b.focused { model.focusTrack(b.track.id, edit: false) }
        let id: UUID
        switch hit(p) {
        case let .edge(i, _), let .body(i): id = i
        case .empty: return nil
        }
        // Right-clicking one of a picked group keeps the group (to join it).
        if !model.multiSelection.contains(id) { model.clearMulti() }
        model.select(id)
        let menu = NSMenu()
        let play = NSMenuItem(title: "Play Title", action: #selector(menuPlay(_:)), keyEquivalent: "")
        play.representedObject = id
        play.target = self
        let edit = NSMenuItem(title: "Edit Text", action: #selector(menuEdit(_:)), keyEquivalent: "")
        edit.representedObject = id
        edit.target = self
        let delete = NSMenuItem(title: "Delete Title", action: #selector(menuDelete(_:)), keyEquivalent: "")
        delete.representedObject = id
        delete.target = self
        let join = NSMenuItem(title: "Join \(model.multiSelection.count) Titles", action: #selector(menuJoin(_:)), keyEquivalent: "")
        join.target = self
        menu.items = model.canJoin ? [play, edit, .separator(), join, .separator(), delete]
                                   : [play, edit, .separator(), delete]
        return menu
    }

    @objc private func menuJoin(_ sender: NSMenuItem) {
        model?.joinSelected()
    }

    @objc private func menuPlay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let s = model?.doc.subtitle(id) else { return }
        model?.playRange(from: s.start, to: s.end)
    }

    @objc private func menuEdit(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model?.focusRequest = id
    }

    @objc private func menuDelete(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let model else { return }
        model.deleteTitle(id)
    }

    /// Edit ▸ Select All (⌘A) while the waveform has focus: every title in this language.
    override func selectAll(_ sender: Any?) {
        model?.selectAllTitles()
        needsDisplay = true
    }

    // MARK: Wheel and trackpad
    // (Control/Option + wheel or swipe is handled app-wide by InputController.)

    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        takeBack()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌘ + scroll: zoom around the pointer.
        if flags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            zoom(by: exp(Double(delta) * 0.01), around: convert(event.locationInWindow, from: nil).x)
            return
        }

        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let horizontal = abs(dx) > abs(dy)

        // A trackpad two-finger horizontal swipe over the left/right half of the selected
        // title's box adjusts its start/end. Mice, wheels and trackballs never
        // do this (they have no gesture phase), so scrolling can't change a title.
        let isTrackpadGesture = event.hasPreciseScrollingDeltas && !event.phase.isEmpty
        if model.swipeOverTitleAdjusts, isTrackpadGesture, horizontal, event.momentumPhase.isEmpty {
            let p = convert(event.locationInWindow, from: nil)
            // Only the selected title: swiping over any other box scrolls as usual, so a
            // scroll can't move a title by accident.
            if let box = boxRects.first(where: { $0.rect.contains(p) && $0.id == model.doc.selectedID }),
               !model.focusedIsLocked {
                if event.phase == .began { swipeAccumulator = 0 }
                let edge: TitlesCore.Edge = p.x < box.rect.midX ? .start : .end
                // Fingers moving right = later in time, whatever the scroll-direction setting.
                let finger = event.isDirectionInvertedFromDevice ? dx : -dx
                swipeAccumulator += finger
                let pointsPerFrame: CGFloat = 6
                while abs(swipeAccumulator) >= pointsPerFrame {
                    let step = swipeAccumulator > 0 ? 1 : -1
                    swipeAccumulator -= CGFloat(step) * pointsPerFrame
                    model.nudge(edge, of: box.id, frames: step)
                }
                return
            }
        }
        // Otherwise: pan.
        let amount: CGFloat
        if event.hasPreciseScrollingDeltas {
            amount = horizontal ? dx : dy
        } else {
            amount = (horizontal ? dx : dy) * 12
        }
        viewStart = max(0, viewStart - Double(amount) / pps)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        takeBack()
        zoom(by: 1 + Double(event.magnification), around: convert(event.locationInWindow, from: nil).x)
    }

    private func zoom(by factor: Double, around px: CGFloat) {
        guard let model else { return }
        let anchor = t(px)
        let newPPS = min(1600, max(8, model.pixelsPerSecond * factor))
        lastPPS = newPPS   // we anchor here, not in refresh()
        viewStart = max(0, anchor - Double(px) / newPPS)
        model.pixelsPerSecond = newPPS
    }

    // MARK: Text helpers

    private func labelFont(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    private func monoFont(_ size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
    }

    private func drawText(_ s: String, at p: CGPoint, font: NSFont, color: NSColor) {
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }
}

extension NSCursor {
    /// Scissors with a split line, shown while ⌘ is held over a title box.
    static let split: NSCursor = {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 12, y: 1))
            line.line(to: NSPoint(x: 12, y: 23))
            line.lineWidth = 3
            NSColor.black.withAlphaComponent(0.7).setStroke()
            line.stroke()
            line.lineWidth = 1
            NSColor.white.setStroke()
            line.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                .applying(.init(paletteColors: [.white]))
            if let scissors = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Split")?
                .withSymbolConfiguration(config) {
                let s = scissors.size
                let r = NSRect(x: 13, y: 12 - s.height / 2, width: s.width, height: s.height)
                NSGraphicsContext.current?.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = .black
                shadow.shadowBlurRadius = 2
                shadow.set()
                scissors.draw(in: r)
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
}
