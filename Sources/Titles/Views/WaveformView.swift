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
    private let edgeGrab: CGFloat = 6
    private var boxRects: [(id: UUID, rect: CGRect)] = []
    /// Number pills, for double-click-to-play.
    private var numberPills: [(id: UUID, rect: CGRect)] = []
    /// Boxes of the other open languages, in their slim lanes under the waveform.
    private var laneBoxes: [(track: UUID, id: UUID, rect: CGRect)] = []
    private var laneRects: [(track: UUID, rect: CGRect)] = []

    // Interaction
    private enum Drag {
        case none
        case ruler
        case creating(t0: Double, t1: Double)
        case moving(id: UUID, grab: Double, length: Double)
        case resizing(id: UUID, edge: Edge)
    }
    private var drag: Drag = .none

    // Resistance: while dragging, a title stops at the minimum gap from its neighbours.
    // Drag about 12 px further and it gives, letting the titles overlap.
    private var barrierLower: Double?
    private var barrierUpper: Double?
    private var holdingLower = false, holdingUpper = false
    private var brokeLower = false, brokeUpper = false
    private var downPoint: CGPoint = .zero
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
    /// The other open languages, each drawn as a slim read-only lane at the bottom.
    private var laneTracks: [Track] {
        guard let model else { return [] }
        return model.openTracks.filter { $0.id != model.video?.focusedTrackID }
    }

    private var lanesHeight: CGFloat {
        let n = CGFloat(laneTracks.count)
        guard n > 0 else { return 0 }
        return min(n * 20, max(0, bounds.height - rulerHeight) * 0.45)
    }

    private var waveRect: CGRect {
        CGRect(x: 0, y: rulerHeight, width: bounds.width, height: max(0, bounds.height - rulerHeight - lanesHeight))
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
        drawWaveform(ctx, in: wave, model: model)
        drawBoxes(ctx, in: wave, model: model)
        drawLanes(model: model, top: wave.maxY)
        if model.focusedIsLocked {
            drawText("LOCKED TO MASTER: TEXT ONLY", at: CGPoint(x: bounds.width - 190, y: wave.minY + 6),
                     font: labelFont(9), color: Palette.lilac)
        }

        if case let .creating(t0, t1) = drag {
            let r = CGRect(x: x(min(t0, t1)), y: wave.minY + 6,
                           width: max(1, x(max(t0, t1)) - x(min(t0, t1))), height: wave.height - 12)
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

    private func drawBoxes(_ ctx: CGContext, in rect: CGRect, model: AppModel) {
        let doc = model.doc
        let subs = doc.subtitles
        let lanes = laneOffsets(subs)
        let overlaps = doc.overlappingIDs
        let selected = doc.selectedID
        let langTag = (model.focusedTrack?.language.code ?? "").split(separator: "-").first.map { $0.uppercased() } ?? ""
        let tagFont = labelFont(9)
        let tagSize = (langTag as NSString).size(withAttributes: [.font: tagFont])
        let viewEnd = viewStart + visibleDuration
        let baseHeight = rect.height * 0.74
        let laneShift = rect.height * 0.11

        boxRects.removeAll(keepingCapacity: true)
        numberPills.removeAll(keepingCapacity: true)
        var selectedRect: CGRect?

        for (index, s) in subs.enumerated() where (model.liveSpotEnd(for: s.id) ?? s.end) >= viewStart && s.start <= viewEnd {
            let lane = lanes[s.id] ?? 0
            let height = lane == 0 ? baseHeight : baseHeight - laneShift
            let y = rect.midY - height / 2 + CGFloat(lane) * laneShift
            let end = model.liveSpotEnd(for: s.id) ?? s.end
            let r = CGRect(x: x(s.start), y: y, width: max(2, x(end) - x(s.start)), height: height)
            boxRects.append((s.id, r))

            let isSel = s.id == selected
            let base: NSColor = overlaps.contains(s.id) ? Palette.lilac : Palette.status(model.preset.status(s))
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            base.withAlphaComponent(isSel ? 0.24 : 0.13).setFill()
            path.fill()
            (isSel ? Palette.amber : base.withAlphaComponent(0.75)).setStroke()
            path.lineWidth = isSel ? 2 : 1
            path.stroke()

            // Number pill, then the full title text (all lines), wrapped inside the box.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).addClip()
            let numberText = model.rowNumber(of: s.id).map(String.init) ?? "\(index + 1)"
            let font = labelFont(11)
            let numWidth = (numberText as NSString).size(withAttributes: [.font: font]).width + 10
            let pill = CGRect(x: r.minX + 4, y: r.minY + 4, width: numWidth, height: 15)
            numberPills.append((s.id, pill.intersection(r)))
            (isSel ? Palette.amber : base).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 7.5, yRadius: 7.5).fill()
            drawText(numberText, at: CGPoint(x: pill.minX + 5, y: pill.minY + 1), font: font, color: Palette.background)
            let fullText = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Beside the number pill when there's room; otherwise underneath it.
            let besidePill = r.maxX - pill.maxX - 9 >= 40
            let textRect = besidePill
                ? CGRect(x: pill.maxX + 5, y: r.minY + 3, width: r.maxX - pill.maxX - 9, height: r.height - 6)
                : CGRect(x: r.minX + 4, y: pill.maxY + 2, width: r.width - 8, height: r.maxY - pill.maxY - 4)
            // Spotting: a running timer in the top right corner.
            if s.id == model.spottingID, let timer = model.spotTimer() {
                let tf = monoFont(10)
                let tw = (timer.text as NSString).size(withAttributes: [.font: tf]).width + 12
                let tr = CGRect(x: r.maxX - tw - 4, y: r.minY + 4, width: tw, height: 15)
                if tr.minX > pill.maxX + 2 {
                    timer.status.nsColor.setFill()
                    NSBezierPath(roundedRect: tr, xRadius: 7.5, yRadius: 7.5).fill()
                    drawText(timer.text, at: CGPoint(x: tr.minX + 6, y: tr.minY + 1), font: tf, color: Palette.background)
                }
            }
            if !fullText.isEmpty, textRect.width > 6, textRect.height > 8 {
                let para = NSMutableParagraphStyle()
                para.lineBreakMode = .byWordWrapping
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: Palette.text.withAlphaComponent(0.9),
                    .paragraphStyle: para
                ]
                (fullText as NSString).draw(with: textRect,
                                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                            attributes: attrs)
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

    /// Slim lanes for the other open languages: boxes and numbers, no text. The row selected
    /// in the card pane is outlined in every lane, so drift between languages is easy to see.
    private func drawLanes(model: AppModel, top: CGFloat) {
        laneBoxes.removeAll(keepingCapacity: true)
        laneRects.removeAll(keepingCapacity: true)
        let tracks = laneTracks
        guard !tracks.isEmpty else { return }
        let laneH = lanesHeight / CGFloat(tracks.count)
        let viewEnd = viewStart + visibleDuration
        let selectedRow = model.selectedRowKey
        let masterID = model.video?.masterTrackID
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
                let inRow = selectedRow != nil && RowBuilder.key(of: s, inMaster: track.id == masterID) == selectedRow
                (inRow ? Palette.amber : color.withAlphaComponent(0.6)).setStroke()
                path.lineWidth = inRow ? 1.5 : 1
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
            let tagRect = CGRect(x: 4, y: lane.minY + (laneH - 13) / 2, width: tw, height: 13)
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
        var candidates = Array(boxRects.reversed())
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
        if event.clickCount == 2, let pill = numberPills.last(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }) {
            if case .moving = drag { model.doc.cancelLive() }
            drag = .none
            model.playTitle(pill.id)
            needsDisplay = true
            return
        }

        // A locked language keeps the master's timing: clicks only select and seek.
        if model.focusedIsLocked {
            drag = .none
            switch hit(p) {
            case let .edge(id, _), let .body(id):
                model.select(id, seekToStart: event.clickCount == 2)
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
            model.select(id)
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
            let t0 = t(p.x)
            drag = .creating(t0: t0, t1: t0)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - downPoint.x, p.y - downPoint.y) > 3 { didDrag = true }
        guard didDrag else { return }
        autoscroll(for: p)

        switch drag {
        case .none:
            break
        case .ruler:
            model.placePlayhead(t(p.x))
        case let .creating(t0, _):
            drag = .creating(t0: t0, t1: t(p.x))
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
        case .none, .ruler:
            break
        case let .creating(t0, t1):
            if didDrag, abs(t1 - t0) >= 0.15 {
                model.createTitle(start: min(t0, t1), end: max(t0, t1))
            } else {
                model.placePlayhead(t0)
            }
        case let .moving(id, _, _):
            model.doc.commitLive()
            if didDrag, let s = model.doc.subtitle(id) {
                model.playRange(from: max(0, s.start - 0.5), to: s.end)
            }
        case let .resizing(id, edge):
            model.doc.commitLive()
            if didDrag { model.preview(edge, of: id, after: .resize) }
        }
    }

    /// Notes where the neighbours are (minus the minimum gap) when a drag starts.
    private func setBarriers(around id: UUID, model: AppModel) {
        holdingLower = false; holdingUpper = false
        brokeLower = false; brokeUpper = false
        barrierLower = nil; barrierUpper = nil
        guard let s = model.doc.subtitle(id) else { return }
        let gap = model.minGap
        if let prev = model.doc.previous(of: id), prev.end <= s.start + 0.0005 {
            barrierLower = min(s.start, prev.end + gap)
        }
        if let next = model.doc.next(of: id), next.start >= s.end - 0.0005 {
            barrierUpper = max(s.end, next.start - gap)
        }
    }

    /// Holds a dragged time at the barrier until it's pulled about 12 px past it.
    private func stick(_ value: Double, lower: Bool) -> Double {
        let breakDistance = 12.0 / Double(pps)
        if lower {
            guard let b = barrierLower, !brokeLower else { return value }
            if value >= b { holdingLower = false; return value }
            if b - value > breakDistance { brokeLower = true; tick(); return value }
            if !holdingLower { holdingLower = true; tick() }
            return b
        } else {
            guard let b = barrierUpper, !brokeUpper else { return value }
            if value <= b { holdingUpper = false; return value }
            if value - b > breakDistance { brokeUpper = true; tick(); return value }
            if !holdingUpper { holdingUpper = true; tick() }
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

        // Optional (off by default): a trackpad two-finger horizontal swipe over the
        // left/right half of a box adjusts start/end. Mice, wheels and trackballs never
        // do this (they have no gesture phase), so scrolling can't change a title.
        let isTrackpadGesture = event.hasPreciseScrollingDeltas && !event.phase.isEmpty
        if model.swipeOverTitleAdjusts, isTrackpadGesture, horizontal, event.momentumPhase.isEmpty {
            let p = convert(event.locationInWindow, from: nil)
            if let box = boxRects.first(where: { $0.rect.contains(p) }) {
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
