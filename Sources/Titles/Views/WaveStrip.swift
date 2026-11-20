import AppKit
import AVFoundation
import QuartzCore
@testable import TitlesCore

// While the film plays, the waveform isn't redrawn on every frame. It's drawn ahead of time
// in tiles (a few screens' worth around the playhead), and the graphics system slides them
// along in step with the picture: the tiles sit in an AVSynchronizedLayer, which follows
// the player's own clock, so the boxes glide on every frame the screen shows, whatever else
// the app is busy with at that moment. Only a change to what's drawn (a title selected,
// typed in or moved) redraws a tile, in the background, a little at a time. A click, the
// wheel or a pinch hands the waveform back to its own drawing (WaveformNSView.draw) until
// the hand is off it again.

/// The strip's tiles: tile `k` covers the film from `k` tile lengths in.
enum StripTiles {
    /// A tile's width, in points.
    static let width: CGFloat = 512

    /// The length of film a tile covers at `pps` points a second.
    static func duration(pps: Double) -> Double { Double(width) / max(0.001, pps) }

    /// The tiles covering the film from `start` to `end` (none before the film starts).
    static func range(from start: Double, to end: Double, pps: Double) -> ClosedRange<Int> {
        let d = duration(pps: pps)
        let a = max(0, Int((start / d).rounded(.down)))
        let b = max(a, Int((max(start, end) / d).rounded(.down)))
        return a...b
    }

    /// The tiles a title from `start` to `end` is drawn on (its frame, grips and marks reach
    /// a few points past its times).
    static func touched(from start: Double, to end: Double, pps: Double) -> ClosedRange<Int> {
        let reach = 6 / max(0.001, pps)
        return range(from: start - reach, to: end + reach, pps: pps)
    }

    /// The order to draw tiles in: those in view and still blank first, then the rest in
    /// view, then those just ahead of the playhead and behind it, nearest first.
    static func order(_ tiles: [Int], visible: ClosedRange<Int>, blank: Set<Int>, playhead: Int) -> [Int] {
        tiles.sorted { a, b in
            func rank(_ k: Int) -> (Int, Int, Int) {
                let inView = visible.contains(k)
                // Ahead of the playhead comes before behind it, at the same distance.
                let distance = k >= playhead ? 2 * (k - playhead) : 2 * (playhead - k) + 1
                return (inView && blank.contains(k) ? 0 : 1, inView ? 0 : 1, distance)
            }
            return rank(a) < rank(b)
        }
    }

    /// What a change to the titles redraws: for every language whose titles changed, the
    /// stretch from the title before each changed one to the title after it (an issue mark
    /// can depend on the gap to the next title, and overlapping titles on their neighbours).
    /// Nil when titles came or went, or changed places: then everything is redrawn (the
    /// numbers on the boxes after it change too).
    static func changedSpans(old: [UUID: [Subtitle]], new: [UUID: [Subtitle]]) -> [ClosedRange<Double>]? {
        guard Set(old.keys) == Set(new.keys) else { return nil }
        var spans: [ClosedRange<Double>] = []
        for (track, before) in old {
            guard let after = new[track] else { return nil }
            if before == after { continue }
            guard before.count == after.count,
                  zip(before, after).allSatisfy({ $0.id == $1.id }) else { return nil }
            for i in before.indices where before[i] != after[i] {
                let lo = max(0, i - 1), hi = min(before.count - 1, i + 1)
                let from = min(before[lo].start, after[lo].start, before[i].start, after[i].start)
                let to = max(before[hi].end, after[hi].end, before[i].end, after[i].end)
                spans.append(from...max(from, to))
            }
        }
        return spans
    }
}

/// How the waveform moves while the film plays, as its time goes on.
struct StripMotion: Equatable {
    /// Following the playhead: it's parked `lead` seconds into the view, and the waveform
    /// moves under it (until then, at the very start of the film, the playhead moves).
    var follow: Bool
    var lead: Double
    /// Not following: the stretch of film in view starts here, and the playhead crosses it.
    var page: Double
    var pps: Double

    /// The time at the view's left edge.
    func viewStart(at t: Double) -> Double { follow ? max(0, t - lead) : page }

    /// The playhead's place, in points from the view's left edge.
    func playheadX(at t: Double) -> CGFloat { CGFloat((t - viewStart(at: t)) * pps) }

    /// The strip's place, for a strip whose own zero is `origin` seconds into the film.
    func stripX(origin: Double, at t: Double) -> CGFloat { CGFloat((origin - viewStart(at: t)) * pps) }

    /// A straight run in the film's time: from `from` at `begin`, to `to` `duration` later.
    struct Run: Equatable {
        var begin: Double
        var duration: Double
        var from: CGFloat
        var to: CGFloat

        func value(at t: Double) -> CGFloat {
            guard duration > 0 else { return from }
            let f = min(1, max(0, (t - begin) / duration))
            return from + (to - from) * CGFloat(f)
        }
    }

    /// The strip's movement for `reach` seconds either side of `t`, or nil when it stands
    /// still (not following). Kept to a stretch so the numbers stay small: the strip gets a
    /// new origin, and a new run, long before the run ends.
    func stripRun(origin: Double, around t: Double, reach: Double) -> Run? {
        guard follow else { return nil }
        let begin = max(lead, t - reach)
        let end = max(begin + 1, t + reach)
        return Run(begin: begin, duration: end - begin,
                   from: stripX(origin: origin, at: begin), to: stripX(origin: origin, at: end))
    }

    /// The playhead's movement: following, from the film's start until it's parked;
    /// otherwise across the page (and on, `span` seconds in all, past its right edge).
    func playheadRun(span: Double) -> Run {
        if follow { return Run(begin: 0, duration: lead, from: 0, to: CGFloat(lead * pps)) }
        return Run(begin: page, duration: span, from: 0, to: CGFloat(span * pps))
    }
}

/// Pictures for the strip, drawn with the same code (and in the same colours) as the view.
enum StripImage {
    /// Draws into a new picture `size` points big, top down like the view (y grows downwards).
    @MainActor
    static func render(size: CGSize, scale: CGFloat, space: CGColorSpace?, _ draw: () -> Void) -> CGImage? {
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard w > 0, h > 0,
              let cs = space ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        // As the view draws (a layer-backed view's text isn't smoothed).
        ctx.setShouldSmoothFonts(false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

/// The strip itself: tiles on a layer the film's clock slides along, the codes and scroll
/// bar on top, and the playhead over everything. Takes no clicks (the waveform under it does).
@MainActor
final class WaveStripView: NSView {
    private let sync = AVSynchronizedLayer()
    private let strip = CALayer()
    private let overlay = CALayer()
    /// The scroll bar: its track (with the titles' marks) as a picture; the handle and the
    /// playhead's mark as plain layers, moved as the film goes on.
    private let scrollTrack = CALayer()
    private let scrollThumb = CALayer()
    private let scrollHead = CALayer()
    private let playhead = CALayer()
    /// The title being spotted: a box on the strip whose width grows by the film's clock,
    /// with its number at the left and the running time at its right edge.
    private let spot = CALayer()
    private let spotLabel = CALayer()
    private let spotTimer = CALayer()
    /// Where the spotted title starts (film seconds), at `spotPPS` points a second.
    private var spotStart: Double?
    private var spotPPS: Double = 120
    private var spotTimerWidth: CGFloat = 0
    /// Sized by hand, frame by frame (the film's clock isn't reaching the strip).
    private var spotManual = false
    /// How long a spotted title can grow on its own (far longer than any title).
    private static let spotReach: Double = 600
    private var tiles: [Int: CALayer] = [:]
    /// The strip's own zero, as a tile number (tiles sit a whole number of widths from it).
    private var origin = 0
    private var size: CGSize = .zero
    private var scale: CGFloat = 2
    /// The layers' y runs down the view (as the view's own drawing does), not up.
    private var topDown = false
    /// Half the playhead picture's width: its line is in the middle.
    static let playheadHalf: CGFloat = 6.5

    private static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull(),
        "hidden": NSNull(), "sublayers": NSNull(), "backgroundColor": NSNull(), "contentsScale": NSNull(),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.masksToBounds = true
        root.actions = Self.noActions
        layer = root
        wantsLayer = true
        for l in [sync, strip, overlay, scrollTrack, scrollThumb, scrollHead, playhead] as [CALayer] {
            l.actions = Self.noActions
            l.anchorPoint = .zero
        }
        root.addSublayer(sync)
        for l in [strip, overlay, scrollTrack, scrollThumb, scrollHead, playhead] { sync.addSublayer(l) }
        for l in [spot, spotLabel, spotTimer] {
            l.actions = Self.noActions
            l.anchorPoint = .zero
        }
        spot.masksToBounds = true
        spot.zPosition = 1          // over the tiles
        spot.isHidden = true
        spot.addSublayer(spotLabel)
        spot.addSublayer(spotTimer)
        strip.addSublayer(spot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The player item whose clock moves the strip.
    var item: AVPlayerItem? { sync.playerItem }

    private func still(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    /// Ready for a new run of play: the size, the clock, the colour behind any tile not yet
    /// drawn, and the playhead's picture. Every tile goes.
    func prepare(item: AVPlayerItem, size: CGSize, scale: CGFloat, background: CGColor, playhead image: CGImage?,
                 thumb: CGColor, head: CGColor) {
        self.size = size
        self.scale = scale
        // A picture always shows the right way up, but where a layer sits depends on which
        // way its container's y runs (see CALayer.contentsAreFlipped).
        topDown = sync.contentsAreFlipped()
        still {
            scrollTrack.contentsScale = scale
            scrollThumb.backgroundColor = thumb
            scrollHead.backgroundColor = head
            if sync.playerItem !== item { sync.playerItem = item }
            sync.frame = CGRect(origin: .zero, size: size)
            sync.backgroundColor = background
            strip.removeAllAnimations()
            strip.frame = CGRect(origin: .zero, size: size)
            overlay.frame = CGRect(origin: .zero, size: size)
            overlay.contentsScale = scale
            playhead.removeAllAnimations()
            playhead.frame = CGRect(x: 0, y: 0, width: Self.playheadHalf * 2, height: size.height)
            playhead.contentsScale = scale
            playhead.contents = image
            for t in tiles.values { t.removeFromSuperlayer() }
            tiles.removeAll()
        }
    }

    /// Lets go of everything (the waveform draws itself again).
    func clear() {
        hideSpot()
        still {
            strip.removeAllAnimations()
            playhead.removeAllAnimations()
            for t in tiles.values { t.removeFromSuperlayer() }
            tiles.removeAll()
            overlay.contents = nil
            scrollTrack.contents = nil
            sync.playerItem = nil
        }
    }

    var tileNumbers: Set<Int> { Set(tiles.keys) }

    func setTile(_ k: Int, image: CGImage) {
        still {
            let tile: CALayer
            if let t = tiles[k] {
                tile = t
            } else {
                tile = CALayer()
                tile.actions = Self.noActions
                tile.anchorPoint = .zero
                tile.contentsScale = scale
                tiles[k] = tile
                strip.addSublayer(tile)
            }
            tile.frame = frame(ofTile: k)
            tile.contents = image
        }
    }

    func removeTiles(where drop: (Int) -> Bool) {
        let gone = tiles.keys.filter(drop)
        guard !gone.isEmpty else { return }
        still {
            for k in gone { tiles[k]?.removeFromSuperlayer(); tiles[k] = nil }
        }
    }

    private func frame(ofTile k: Int) -> CGRect {
        CGRect(x: CGFloat(k - origin) * StripTiles.width, y: 0, width: StripTiles.width, height: size.height)
    }

    /// A new zero for the strip, near the playhead (the tiles move with it).
    func rebase(origin newOrigin: Int) {
        guard newOrigin != origin else { return }
        origin = newOrigin
        still {
            for (k, t) in tiles { t.frame = frame(ofTile: k) }
            if let start = spotStart { spot.position.x = spotX(start) }
        }
    }

    // MARK: The title being spotted

    /// Where film time `t` is on the strip (tile `origin` starts at 0).
    private func spotX(_ t: Double) -> CGFloat {
        CGFloat(t * spotPPS) - CGFloat(origin) * StripTiles.width
    }

    /// Starts the growing box of a title being spotted from `start`. `box` gives its top and
    /// height (the view's points, y down); `label` is its number, drawn at its top left.
    func showSpot(start: Double, pps: Double, box: CGRect, fill: CGColor, border: CGColor, radius: CGFloat,
                  label: CGImage?, labelSize: CGSize) {
        spotStart = start
        spotPPS = pps
        spotManual = false
        let y = layerRect(box).minY
        still {
            spot.removeAllAnimations()
            spotTimer.removeAllAnimations()
            spot.frame = CGRect(x: spotX(start), y: y, width: 0, height: box.height)
            spot.backgroundColor = fill
            spot.borderColor = border
            spot.borderWidth = 1.5
            spot.cornerRadius = radius
            spotLabel.contentsScale = scale
            spotLabel.contents = label
            spotLabel.frame = inBox(CGRect(origin: CGPoint(x: 4, y: 4), size: labelSize), height: box.height)
            spotTimer.contents = nil
            spotTimer.isHidden = true
            spot.isHidden = false
            // In a synchronized layer, times are the film's: the box is as wide as the time
            // since its start, on every frame, however busy the app is.
            spot.add(Self.growth(since: start, keyPath: "bounds.size.width", from: 0,
                                 to: CGFloat(Self.spotReach * pps)), forKey: "grow")
        }
    }

    /// Moves the box's top and height (the bands were resized).
    func moveSpot(box: CGRect) {
        guard spotStart != nil else { return }
        let y = layerRect(box).minY
        guard abs(spot.frame.minY - y) > 0.1 || abs(spot.bounds.height - box.height) > 0.1 else { return }
        still {
            spot.position.y = y
            spot.bounds.size.height = box.height
            spotLabel.frame = inBox(CGRect(origin: CGPoint(x: 4, y: 4), size: spotLabel.bounds.size), height: box.height)
            spotTimer.position.y = inBox(CGRect(x: 0, y: 4, width: 1, height: spotTimer.bounds.height),
                                         height: box.height).minY
        }
    }

    /// The running time, a picture `size` big at the box's right edge (hidden while the box is
    /// too narrow for it beside the number).
    func setSpotTimer(_ image: CGImage?, size: CGSize, visible: Bool) {
        guard let start = spotStart else { return }
        let height = spot.bounds.height
        still {
            spotTimer.contentsScale = scale
            spotTimer.contents = image
            spotTimer.isHidden = !visible
            if abs(size.width - spotTimerWidth) > 0.1 || (!spotManual && spotTimer.animation(forKey: "slide") == nil) {
                spotTimerWidth = size.width
                spotTimer.removeAllAnimations()
                spotTimer.frame = inBox(CGRect(x: -size.width - 4, y: 4, width: size.width, height: size.height),
                                        height: height)
                if !spotManual {
                    spotTimer.add(Self.growth(since: start, keyPath: "position.x", from: -size.width - 4,
                                              to: CGFloat(Self.spotReach * spotPPS) - size.width - 4), forKey: "slide")
                }
            }
        }
    }

    /// Without the film's clock: the box sized by hand for time `t`.
    func placeSpot(at t: Double) {
        guard let start = spotStart else { return }
        spotManual = true
        let width = max(0, CGFloat((t - start) * spotPPS))
        still {
            if spot.animationKeys()?.isEmpty == false { spot.removeAllAnimations() }
            if spotTimer.animationKeys()?.isEmpty == false { spotTimer.removeAllAnimations() }
            spot.bounds.size.width = width
            spotTimer.position.x = width - spotTimerWidth - 4
        }
    }

    func hideSpot() {
        guard spotStart != nil else { return }
        spotStart = nil
        spotTimerWidth = 0
        still {
            spot.removeAllAnimations()
            spotTimer.removeAllAnimations()
            spot.isHidden = true
            spotLabel.contents = nil
            spotTimer.contents = nil
        }
    }

    /// A rectangle inside the spotted box (y down from its top) where its layers put it.
    private func inBox(_ r: CGRect, height: CGFloat) -> CGRect {
        topDown ? r : CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    /// A value growing by `pps` points a second of film from `start` on.
    private static func growth(since start: Double, keyPath: String, from: CGFloat, to: CGFloat) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.beginTime = start <= 0 ? AVCoreAnimationBeginTimeAtZero : start
        a.duration = spotReach
        a.fillMode = .both
        a.isRemovedOnCompletion = false
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        return a
    }

    func setOverlay(_ image: CGImage?) {
        still { overlay.contents = image }
    }

    /// The scroll bar's track, a picture of `rect` (in the view's points, y down).
    func setScrollTrack(_ image: CGImage?, in rect: CGRect) {
        still {
            scrollTrack.frame = layerRect(rect)
            scrollTrack.contents = image
        }
    }

    /// The scroll bar's handle and the playhead's mark on it (in the view's points, y down).
    func placeScrollBar(thumb: CGRect, head: CGRect) {
        let t = layerRect(thumb), h = layerRect(head)
        func moved(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) > 0.1 || abs(a.width - b.width) > 0.1 || abs(a.minY - b.minY) > 0.1 || abs(a.height - b.height) > 0.1
        }
        guard moved(t, scrollThumb.frame) || moved(h, scrollHead.frame) else { return }
        still {
            scrollThumb.frame = t
            scrollThumb.cornerRadius = t.height / 2
            scrollHead.frame = h
        }
    }

    /// A rectangle in the view's points (y down) where the layers put it.
    private func layerRect(_ r: CGRect) -> CGRect {
        topDown ? r : CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
    }

    /// Sets the strip and playhead going, by the film's clock (`strip`: nil when the strip
    /// stands still), and puts them where they are at `t` meanwhile.
    func run(strip run: StripMotion.Run?, stripAt x: CGFloat, playhead head: StripMotion.Run, playheadAt px: CGFloat) {
        still {
            strip.removeAllAnimations()
            playhead.removeAllAnimations()
            strip.position = CGPoint(x: x, y: 0)
            playhead.position = CGPoint(x: px - Self.playheadHalf, y: 0)
            if let run { strip.add(Self.animation(run, offset: 0), forKey: "run") }
            playhead.add(Self.animation(head, offset: -Self.playheadHalf), forKey: "run")
        }
    }

    /// Without the film's clock: the strip and the playhead put in place by hand, frame by frame.
    func place(stripAt x: CGFloat, playheadAt px: CGFloat) {
        still {
            if strip.animationKeys()?.isEmpty == false { strip.removeAllAnimations() }
            if playhead.animationKeys()?.isEmpty == false { playhead.removeAllAnimations() }
            strip.position = CGPoint(x: x, y: 0)
            playhead.position = CGPoint(x: px - Self.playheadHalf, y: 0)
        }
    }

    /// Where the graphics system shows the strip and the playhead right now.
    var shown: (strip: CGFloat, playhead: CGFloat)? {
        guard let s = strip.presentation(), let p = playhead.presentation() else { return nil }
        return (s.position.x, p.position.x + Self.playheadHalf)
    }

    private static func animation(_ run: StripMotion.Run, offset: CGFloat) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = run.from + offset
        a.toValue = run.to + offset
        // In a synchronized layer, times are the film's; 0 would mean "now".
        a.beginTime = run.begin <= 0 ? AVCoreAnimationBeginTimeAtZero : run.begin
        a.duration = max(0.001, run.duration)
        a.fillMode = .both
        a.isRemovedOnCompletion = false
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        return a
    }
}
