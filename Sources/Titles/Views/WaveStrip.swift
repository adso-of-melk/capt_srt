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
        still { for (k, t) in tiles { t.frame = frame(ofTile: k) } }
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
