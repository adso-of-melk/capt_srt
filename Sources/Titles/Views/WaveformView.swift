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
            pps: model.pixelsPerSecond, gain: model.waveGain, db: model.dbScale,
            hasWave: audio.waveform != nil, loading: audio.isLoading))
            .background(Theme.background)
    }

    /// Everything the view draws from; a change triggers a redraw.
    struct Revision: Equatable {
        var subtitles: [Subtitle]
        var selected: UUID?
        var time: Double
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

    // Interaction
    private enum Drag {
        case none
        case ruler
        case creating(t0: Double, t1: Double)
        case moving(id: UUID, grab: Double, length: Double)
        case resizing(id: UUID, edge: Edge)
    }
    private var drag: Drag = .none
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
    private var waveRect: CGRect {
        CGRect(x: 0, y: rulerHeight, width: bounds.width, height: max(0, bounds.height - rulerHeight))
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
        let viewEnd = viewStart + visibleDuration
        let baseHeight = rect.height * 0.74
        let laneShift = rect.height * 0.11

        boxRects.removeAll(keepingCapacity: true)
        var selectedRect: CGRect?

        for (index, s) in subs.enumerated() where s.end >= viewStart && s.start <= viewEnd {
            let lane = lanes[s.id] ?? 0
            let height = lane == 0 ? baseHeight : baseHeight - laneShift
            let y = rect.midY - height / 2 + CGFloat(lane) * laneShift
            let r = CGRect(x: x(s.start), y: y, width: max(2, x(s.end) - x(s.start)), height: height)
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
            let numberText = "\(index + 1)"
            let font = labelFont(11)
            let numWidth = (numberText as NSString).size(withAttributes: [.font: font]).width + 10
            let pill = CGRect(x: r.minX + 4, y: r.minY + 4, width: numWidth, height: 15)
            (isSel ? Palette.amber : base).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 7.5, yRadius: 7.5).fill()
            drawText(numberText, at: CGPoint(x: pill.minX + 5, y: pill.minY + 1), font: font, color: Palette.background)
            let fullText = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Beside the number pill when there's room; otherwise underneath it.
            let besidePill = r.maxX - pill.maxX - 9 >= 40
            let textRect = besidePill
                ? CGRect(x: pill.maxX + 5, y: r.minY + 3, width: r.maxX - pill.maxX - 9, height: r.height - 6)
                : CGRect(x: r.minX + 4, y: pill.maxY + 2, width: r.width - 8, height: r.maxY - pill.maxY - 4)
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

    private func updateCursor(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y < rulerHeight { NSCursor.pointingHand.set(); return }
        switch hit(p) {
        case .edge: NSCursor.resizeLeftRight.set()
        case .body: NSCursor.openHand.set()
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
            let start = max(0, t(p.x) - grab)
            model.doc.liveUpdate(id) { $0.start = start; $0.end = start + length }
            model.engine.seek(to: start, exact: true)
        case let .resizing(id, edge):
            if let value = model.moveEdge(edge, of: id, to: t(p.x), clamp: false) {
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
            if didDrag { model.preview(edge, of: id) }
        }
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
        guard let id = sender.representedObject as? UUID else { return }
        model?.doc.delete(id)
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
