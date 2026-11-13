import SwiftUI
import AppKit

/// Bottom right: the waveform with numbered title boxes.
struct WaveformPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var doc: SubtitleDocument
    @ObservedObject var clock: PlayheadClock
    @ObservedObject var audio: AudioStore

    var body: some View {
        WaveformRepresentable(model: model, revision: Revision(
            subtitles: doc.subtitles, selected: doc.selectedID, time: clock.time,
            revision: model.revision, focused: model.video?.focusedTrackID,
            pps: model.pixelsPerSecond, gain: model.waveGain, db: model.dbScale,
            hasWave: audio.waveform != nil, loading: audio.isLoading))
            .background(Theme.background)
    }

    /// Everything the view draws from; a change triggers a redraw.
    struct Revision: Equatable {
        var subtitles: [Subtitle]
        var selected: UUID?
        var time: Double
        var revision: Int
        var focused: UUID?
        var pps: Double
        var gain: Double
        var db: Bool
        var hasWave: Bool
        var loading: Bool
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
    private let rulerHeight: CGFloat = 20
    /// The scroll bar along the bottom: the whole film, with the visible part as a handle.
    private let scrollbarHeight: CGFloat = 12
    private let edgeGrab: CGFloat = 6
    /// Every drawn box, per language band.
    private var boxRectsByTrack: [UUID: [(id: UUID, rect: CGRect)]] = [:]
    /// The focused language's boxes.
    private var boxRects: [(id: UUID, rect: CGRect)] {
        guard let id = model?.video?.focusedTrackID else { return [] }
        return boxRectsByTrack[id] ?? []
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

    // Interaction
    private enum Drag {
        case none
        case ruler
        case creating(t0: Double, t1: Double)
        case moving(id: UUID, grab: Double, length: Double)
        case movingGroup(grab: Double, originals: [UUID: Double])
        case marquee(from: CGPoint, to: CGPoint)
        case resizing(id: UUID, edge: Edge)
        case scrolling(grab: CGFloat)
        case bandResize(upper: UUID, lower: UUID, startY: CGFloat, hu: CGFloat, hl: CGFloat, wu: CGFloat, wl: CGFloat)
    }
    private var drag: Drag = .none

    // Resistance: while dragging, a title stops at the minimum gap from its neighbours.
    // Drag about 12 px further and it gives, letting the titles overlap.
    private var barrierLower: Double?
    private var barrierUpper: Double?
    private var holdingLower = false, holdingUpper = false
    private var brokeLower = false, brokeUpper = false
    /// Where the pointer was when the title stopped at a barrier.
    private var heldLowerAt: Double?, heldUpperAt: Double?
    private var downPoint: CGPoint = .zero
    /// Where a click on empty waveform landed (a plain click places the playhead there).
    private var createClickTime: Double = 0
    private var didDrag = false
    private var swipeAccumulator: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.lane.cgColor
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
    private var visibleDuration: Double { Double(bounds.width) / pps }
    /// Open languages drawn as full bands: the focused one, plus any opened as a band.
    private var bandTracks: [Track] {
        guard let model else { return [] }
        let focused = model.video?.focusedTrackID
        return model.openTracks.filter { $0.id == focused || model.waveBands.contains($0.id) }
    }

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
        let total = max(0.001, weights.reduce(0, +))
        var y = area.minY
        var result: [Band] = []
        for (i, track) in tracks.enumerated() {
            let h = i == tracks.count - 1 ? area.maxY - y : (area.height * weights[i] / total).rounded()
            let r = CGRect(x: 0, y: y, width: area.width, height: max(0, h))
            let code = track.language.code.uppercased() + (track.locked ? " 🔒" : "")
            let tw = (code as NSString).size(withAttributes: [.font: labelFont(9)]).width + 10
            let label = tracks.count > 1 ? CGRect(x: 10, y: r.minY + 3, width: tw, height: 13) : .zero
            result.append(Band(track: track, rect: r, focused: track.id == focused, label: label))
            y += h
        }
        bands = result
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

    private var lanesHeight: CGFloat {
        let n = CGFloat(laneTracks.count)
        guard n > 0 else { return 0 }
        return min(n * 20, max(0, bounds.height - rulerHeight - scrollbarHeight) * 0.45)
    }

    private var waveRect: CGRect {
        CGRect(x: 0, y: rulerHeight, width: bounds.width,
               height: max(0, bounds.height - rulerHeight - lanesHeight - scrollbarHeight))
    }

    // MARK: Scroll bar

    private var scrollbarRect: CGRect {
        CGRect(x: 0, y: bounds.height - scrollbarHeight, width: bounds.width, height: scrollbarHeight)
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
        let track = scrollbarRect
        Palette.panel.setFill()
        track.fill()
        Palette.rule.setFill()
        CGRect(x: 0, y: track.minY, width: track.width, height: 1).fill()
        let total = max(totalDuration, visibleDuration)
        // Where the titles are, as faint marks, so you can find your way along the film.
        Palette.textFaint.withAlphaComponent(0.35).setFill()
        let scale = track.width / CGFloat(total)
        for sub in model.doc.subtitles {
            CGRect(x: CGFloat(sub.start) * scale, y: track.midY - 1, width: max(1, CGFloat(sub.duration) * scale), height: 2).fill()
        }
        let thumb = thumbRect
        let dragging: Bool = { if case .scrolling = drag { return true } else { return false } }()
        (dragging ? Palette.amber : Palette.periwinkle).withAlphaComponent(dragging ? 0.75 : 0.45).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: thumb.height / 2, yRadius: thumb.height / 2).fill()
        // The playhead's place in the film.
        Palette.amber.setFill()
        CGRect(x: CGFloat(model.clock.time) * scale - 0.5, y: track.minY + 1, width: 1.5, height: track.height - 1).fill()
    }

    /// Keeps the playhead in view and keeps zoom anchored on it.
    func refresh() {
        guard let model else { return }
        let time = model.clock.time
        if lastPPS != 0 && lastPPS != pps {
            let anchorX = x(time) >= 0 && x(time) <= bounds.width ? x(time) : bounds.width / 2
            let anchorT = time >= viewStart && time <= viewStart + Double(bounds.width) / lastPPS
                ? time : viewStart + Double(bounds.width / 2) / lastPPS
            viewStart = max(0, anchorT - Double(anchorX) / pps)
        }
        lastPPS = pps

        if case .none = drag, time != lastTime {
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

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width
        let wave = waveRect

        Palette.lane.setFill()
        bounds.fill()

        drawRuler(ctx, width: w)
        layoutBands()
        boxRectsByTrack.removeAll(keepingCapacity: true)
        numberPills.removeAll(keepingCapacity: true)
        for band in bands {
            if bands.count > 1 && !band.focused {
                Palette.background.withAlphaComponent(0.35).setFill()
                band.rect.fill()
            }
            drawWaveform(ctx, in: band.rect, model: model)
            drawBoxes(ctx, in: band.rect, track: band.track, focused: band.focused, model: model)
            if bands.count > 1 {
                Palette.rule.setFill()
                CGRect(x: 0, y: band.rect.minY, width: w, height: 1).fill()
                let tag = band.track.language.code.uppercased() + (band.track.locked ? " 🔒" : "")
                (band.focused ? Palette.amber : Palette.panelRaised).setFill()
                NSBezierPath(roundedRect: band.label, xRadius: 6, yRadius: 6).fill()
                drawText(tag, at: CGPoint(x: band.label.minX + 5, y: band.label.minY + 1), font: labelFont(9),
                         color: band.focused ? Palette.background : Palette.periwinkle)
            }
        }
        drawLanes(model: model, top: wave.maxY)
        drawScrollbar(model: model)
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
        if model.focusedIsLocked {
            drawText("LOCKED TO MASTER: TEXT ONLY", at: CGPoint(x: bounds.width - 190, y: focusRect.minY + 6),
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

        // Playhead
        let px = x(model.clock.time)
        if px >= -2 && px <= w + 2 {
            Palette.amber.setFill()
            CGRect(x: px - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
            let tri = NSBezierPath()
            tri.move(to: CGPoint(x: px - 6, y: 0))
            tri.line(to: CGPoint(x: px + 6, y: 0))
            tri.line(to: CGPoint(x: px, y: 8))
            tri.close()
            tri.fill()
        }

        if model.audio.waveform == nil {
            let msg = model.audio.isLoading ? "READING AUDIO…" : (model.hasMedia ? "NO AUDIO" : "NO VIDEO LOADED")
            drawText(msg, at: CGPoint(x: 12, y: wave.minY + 8), font: labelFont(10), color: Palette.textFaint)
        }
    }

    private func drawRuler(_ ctx: CGContext, width: CGFloat) {
        Palette.panel.setFill()
        CGRect(x: 0, y: 0, width: width, height: rulerHeight).fill()
        Palette.rule.setFill()
        CGRect(x: 0, y: rulerHeight - 1, width: width, height: 1).fill()

        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let step = steps.first(where: { $0 * pps >= 80 }) ?? 600
        let minor = step / 5
        var tick = (viewStart / minor).rounded(.down) * minor
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

    private func drawWaveform(_ ctx: CGContext, in rect: CGRect, model: AppModel) {
        // Centre line
        Palette.rule.setFill()
        CGRect(x: 0, y: rect.midY, width: rect.width, height: 1).fill()
        guard let wf = model.audio.waveform, rect.width > 1 else { return }

        let pixels = Int(rect.width)
        let env = wf.envelope(from: viewStart, secondsPerPixel: 1 / pps, pixels: pixels)
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
        ctx.setStrokeColor(Palette.teal.withAlphaComponent(0.35).cgColor)
        ctx.strokePath()
        ctx.addPath(rmsPath)
        ctx.setStrokeColor(Palette.teal.withAlphaComponent(0.85).cgColor)
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
        // Languages that aren't focused are drawn quieter.
        let dim: CGFloat = focused ? 1 : 0.6
        let langTag = track.language.code.split(separator: "-").first.map { $0.uppercased() } ?? ""
        let tagFont = labelFont(9)
        let tagSize = (langTag as NSString).size(withAttributes: [.font: tagFont])
        let viewEnd = viewStart + visibleDuration
        let baseHeight = rect.height * 0.74
        let laneShift = rect.height * 0.11

        var rects: [(id: UUID, rect: CGRect)] = []
        defer { boxRectsByTrack[track.id] = rects }
        var selectedRect: CGRect?

        for (index, s) in subs.enumerated() {
            let end = (focused ? model.liveSpotEnd(for: s.id) : nil) ?? s.end
            guard end >= viewStart && s.start <= viewEnd else { continue }
            let lane = lanes[s.id] ?? 0
            let height = lane == 0 ? baseHeight : baseHeight - laneShift
            let y = rect.midY - height / 2 + CGFloat(lane) * laneShift
            let r = CGRect(x: x(s.start), y: y, width: max(2, x(end) - x(s.start)), height: height)
            rects.append((s.id, r))

            let isSel = s.id == selected || (focused && model.multiSelection.contains(s.id))
            let base: NSColor = (overlaps.contains(s.id) ? Palette.lilac : Palette.status(preset.status(s)))
                .withAlphaComponent(dim)
            let path = NSBezierPath(roundedRect: r, xRadius: Self.boxCornerRadius, yRadius: Self.boxCornerRadius)
            base.withAlphaComponent(isSel ? 0.24 : 0.13 * dim).setFill()
            path.fill()
            if isSel {
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
            // Find: a teal bar along the bottom of every title that has a match.
            if model.find.isShown, !model.find.highlights(in: s.id).ranges.isEmpty {
                Palette.teal.withAlphaComponent(dim).setFill()
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
            (isSel ? Palette.amber : base).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 7.5, yRadius: 7.5).fill()
            drawText(numberText, at: CGPoint(x: pill.minX + 5, y: pill.minY + 1), font: font, color: Palette.background)
            let fullText = Self.boxText(s.text, color: Palette.text.withAlphaComponent(0.9 * dim))
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
                base.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
                drawText(langTag, at: CGPoint(x: tag.minX + 4, y: tag.minY + 1), font: tagFont,
                         color: base.withAlphaComponent(0.6))
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

    /// A box's text as the waveform shows it: italic and bold as in the card, every tag
    /// hidden ({\an8}, <font …>), blank space at either end left out.
    static func boxText(_ markup: String, color: NSColor, size: CGFloat = 11) -> NSAttributedString {
        let a = NSMutableAttributedString(attributedString: RichMarkup.attributed(markup, size: size))
        // RichMarkup keeps position and colour codes as typed; the waveform hides them.
        for m in Markup.tagPattern.matches(in: a.string, range: NSRange(location: 0, length: a.length)).reversed() {
            a.deleteCharacters(in: m.range)
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

    /// Slim lanes for the other open languages: boxes and numbers, no text, never highlighted.
    private func drawLanes(model: AppModel, top: CGFloat) {
        laneBoxes.removeAll(keepingCapacity: true)
        laneRects.removeAll(keepingCapacity: true)
        laneTags.removeAll(keepingCapacity: true)
        let tracks = laneTracks
        guard !tracks.isEmpty else { return }
        let laneH = lanesHeight / CGFloat(tracks.count)
        let viewEnd = viewStart + visibleDuration
        for (i, track) in tracks.enumerated() {
            let lane = CGRect(x: 0, y: top + CGFloat(i) * laneH, width: bounds.width, height: laneH)
            laneRects.append((track.id, lane))
            Palette.background.withAlphaComponent(0.6).setFill()
            lane.fill()
            Palette.rule.setFill()
            CGRect(x: 0, y: lane.minY, width: bounds.width, height: 1).fill()
            let preset = model.preset(for: track)
            for s in track.doc.subtitles where s.end >= viewStart && s.start <= viewEnd {
                let r = CGRect(x: x(s.start), y: lane.minY + 2, width: max(2, x(s.end) - x(s.start)), height: max(4, laneH - 4))
                laneBoxes.append((track.id, s.id, r))
                let color = Palette.status(preset.status(s))
                let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
                color.withAlphaComponent(0.16).setFill()
                path.fill()
                // Never highlighted: only the language in focus shows a selection.
                color.withAlphaComponent(0.6).setStroke()
                path.lineWidth = 1
                path.stroke()
                if r.width > 22, laneH >= 12, let n = model.rowNumber(of: s.id) {
                    drawText("\(n)", at: CGPoint(x: r.minX + 4, y: r.minY + (r.height - 11) / 2),
                             font: labelFont(9), color: Palette.text.withAlphaComponent(0.7))
                }
            }
            // Language code tag at the left edge.
            let tag = track.language.code.uppercased() + (track.locked ? " 🔒" : "")
            let font = labelFont(9)
            let tw = (tag as NSString).size(withAttributes: [.font: font]).width + 10
            let tagRect = CGRect(x: 10, y: lane.minY + (laneH - 13) / 2, width: tw, height: 13)
            laneTags.append((track.id, tagRect.insetBy(dx: -3, dy: -3)))
            Palette.panelRaised.setFill()
            NSBezierPath(roundedRect: tagRect, xRadius: 6, yRadius: 6).fill()
            drawText(tag, at: CGPoint(x: tagRect.minX + 5, y: tagRect.minY + 1), font: font, color: Palette.periwinkle)
        }
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

    private enum Hit { case edge(UUID, Edge), body(UUID), empty }

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
        if bands.contains(where: { $0.label.contains(p) }) { NSCursor.pointingHand.set(); return }
        if p.y < rulerHeight || laneRects.contains(where: { $0.rect.contains(p) }) { NSCursor.pointingHand.set(); return }
        if model?.focusedIsLocked == true { NSCursor.arrow.set(); return }
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

        // A band's language tag: click to focus it; double-click to fold it back to a slim lane.
        if let b = bands.first(where: { $0.label.contains(p) }) {
            drag = .none
            if event.clickCount == 2 {
                model.setWaveBand(b.track.id, shown: false)
                if b.focused, let other = bands.first(where: { !$0.focused }) {
                    model.focusTrack(other.track.id, edit: false)
                }
            } else if !b.focused {
                model.focusTrack(b.track.id, edit: false)
            }
            needsDisplay = true
            return
        }

        // A slim lane's language tag, double-clicked: open that language as a full band.
        if event.clickCount == 2, let tag = laneTags.first(where: { $0.rect.contains(p) }) {
            drag = .none
            model.setWaveBand(tag.track, shown: true)
            needsDisplay = true
            return
        }

        // Clicking in another language's band works on that language: it becomes the focused one.
        if let b = band(at: p), !b.focused {
            model.focusTrack(b.track.id, edit: false)
        }

        // Another language's lane: focus that language (and the title clicked).
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

        if case let .edge(id, _) = hit(p) { setBarriers(around: id, model: model) }
        if case let .body(id) = hit(p) { setBarriers(around: id, model: model) }
        switch hit(p) {
        case let .edge(id, edge):
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
                model.doc.beginLive()
                drag = .moving(id: id, grab: t(p.x) - s.start, length: s.duration)
            }
            NSCursor.closedHand.set()
        case .empty:
            // Drawing a new title: it stops at the minimum gap from its neighbours, just
            // like stretching one (starting inside a gap moves the start out to it).
            createClickTime = t(p.x)
            let b = Self.createBarriers(at: createClickTime, in: model.doc.subtitles, gap: model.minGap)
            resetResistance()
            barrierLower = b.lower
            barrierUpper = b.upper
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
            let minH: CGFloat = 36
            let newU = min(max(minH, hu + (p.y - startY)), hu + hl - minH)
            let k = hu / max(0.001, wu)   // points per unit of weight
            bandWeights[upper] = newU / k
            bandWeights[lower] = (hu + hl - newU) / k
            needsDisplay = true
            return
        }
        guard didDrag else { return }
        autoscroll(for: p)

        switch drag {
        case .none:
            break
        case .scrolling, .bandResize:
            break
        case let .marquee(from, _):
            drag = .marquee(from: from, to: p)
        case let .movingGroup(grab, originals):
            var delta = t(p.x) - grab
            if let earliest = originals.values.min() { delta = max(delta, -earliest) }
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
            let raw = t(p.x)
            drag = .creating(t0: t0, t1: raw >= t0 ? stick(raw, lower: false) : stick(raw, lower: true))
        case let .moving(id, grab, length):
            var start = stick(max(0, t(p.x) - grab), lower: true)
            start = stick(start + length, lower: false) - length
            model.doc.liveUpdate(id) { $0.start = start; $0.end = start + length }
            model.engine.seek(to: start, exact: true)
        case let .resizing(id, edge):
            let target = stick(t(p.x), lower: edge == .start)
            if let value = model.moveEdge(edge, of: id, to: target, clamp: false) {
                model.scrubTo(value)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        defer {
            drag = .none
            needsDisplay = true
            updateCursor(event)
        }
        switch drag {
        case .none, .ruler, .scrolling, .bandResize:
            break
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
            if didDrag, let s = model.doc.subtitle(id) {
                model.playRange(from: max(0, s.start - 0.5), to: s.end)
            }
        case let .resizing(id, edge):
            model.doc.commitLive()
            if didDrag {
                model.preview(edge, of: id, after: .resize)
            } else if let s = model.doc.subtitle(id) {
                model.seek(s.start)
            }
        }
    }

    private func resetResistance() {
        holdingLower = false; holdingUpper = false
        brokeLower = false; brokeUpper = false
        heldLowerAt = nil; heldUpperAt = nil
        barrierLower = nil; barrierUpper = nil
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

    /// Notes where the neighbours are (minus the minimum gap) when a drag starts.
    private func setBarriers(around id: UUID, model: AppModel) {
        resetResistance()
        guard let s = model.doc.subtitle(id) else { return }
        let gap = model.minGap
        if let prev = model.doc.previous(of: id), prev.end <= s.start + 0.0005 {
            barrierLower = min(s.start, prev.end + gap)
        }
        if let next = model.doc.next(of: id), next.start >= s.end - 0.0005 {
            barrierUpper = max(s.end, next.start - gap)
        }
    }

    /// Holds a dragged title at the minimum gap from its neighbour, however fast it was
    /// dragged there. Pull on about 16 px further (into the neighbour) and it lets go, so
    /// titles can still overlap on purpose. Move back out past the gap and it holds again.
    private func stick(_ value: Double, lower: Bool) -> Double {
        let breakDistance = 16.0 / Double(pps)
        if lower {
            guard let b = barrierLower else { return value }
            // Back out past the gap: the resistance is there again next time.
            if value >= b { holdingLower = false; heldLowerAt = nil; brokeLower = false; return value }
            if brokeLower { return value }
            guard let from = heldLowerAt else {
                heldLowerAt = value; holdingLower = true; tick()
                return b
            }
            if from - value > breakDistance { brokeLower = true; tick(); return value }
            heldLowerAt = max(from, value)
            return b
        } else {
            guard let b = barrierUpper else { return value }
            if value <= b { holdingUpper = false; heldUpperAt = nil; brokeUpper = false; return value }
            if brokeUpper { return value }
            guard let from = heldUpperAt else {
                heldUpperAt = value; holdingUpper = true; tick()
                return b
            }
            if value - from > breakDistance { brokeUpper = true; tick(); return value }
            heldUpperAt = min(from, value)
            return b
        }
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
        let p = convert(event.locationInWindow, from: nil)
        if let b = band(at: p), !b.focused { model.focusTrack(b.track.id, edit: false) }
        let id: UUID
        switch hit(p) {
        case let .edge(i, _), let .body(i): id = i
        case .empty: return nil
        }
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
        menu.items = [play, edit, .separator(), delete]
        return menu
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
        guard let id = sender.representedObject as? UUID, let model, !model.refuseIfLocked() else { return }
        model.doc.delete(id)
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
                let edge: Edge = p.x < box.rect.midX ? .start : .end
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
