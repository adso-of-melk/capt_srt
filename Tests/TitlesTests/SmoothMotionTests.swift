import XCTest
import AppKit
@testable import Titles
@testable import TitlesCore

/// While playing, the waveform is a pre-drawn strip slid along by the film's clock, and the
/// title cards flow with the film on every frame.
@MainActor
final class SmoothMotionTests: XCTestCase {

    // MARK: The strip's tiles

    func testTilesCoverTheFilmInEqualStretches() {
        XCTAssertEqual(StripTiles.duration(pps: 128), 4)
        XCTAssertEqual(StripTiles.range(from: 0, to: 15.9, pps: 128), 0...3)
        XCTAssertEqual(StripTiles.range(from: 4, to: 8, pps: 128), 1...2)
        XCTAssertEqual(StripTiles.range(from: -10, to: 1, pps: 128), 0...0, "none before the film starts")
        // A title's frame and grips reach a few points past its times.
        XCTAssertEqual(StripTiles.touched(from: 4.01, to: 7.99, pps: 128), 0...2)
        XCTAssertEqual(StripTiles.touched(from: 5, to: 6, pps: 128), 1...1)
    }

    func testBlankTilesInViewAreDrawnFirstThenTheOnesAhead() {
        let order = StripTiles.order([2, 7, 3, 6, 4, 5], visible: 3...5, blank: [4, 7], playhead: 4)
        // In view and blank; the rest in view; then out of view, ahead before behind, nearest first.
        XCTAssertEqual(order, [4, 5, 3, 6, 2, 7])
    }

    func testAChangedTitleRedrawsOnlyFromTheTitleBeforeToTheTitleAfter() {
        let track = UUID()
        let a = sub(1, 2, "A"), b = sub(3, 4, "B"), c = sub(5, 6, "C"), d = sub(20, 21, "D")
        var moved = c
        moved.start = 5.5
        let spans = StripTiles.changedSpans(old: [track: [a, b, c, d]], new: [track: [a, b, moved, d]])
        XCTAssertEqual(spans, [3...21])
        XCTAssertEqual(StripTiles.changedSpans(old: [track: [a, b]], new: [track: [a, b]]), [])
        // Titles came or went, or changed places: everything.
        XCTAssertNil(StripTiles.changedSpans(old: [track: [a, b]], new: [track: [a]]))
        XCTAssertNil(StripTiles.changedSpans(old: [track: [a, b]], new: [track: [b, a]]))
        XCTAssertNil(StripTiles.changedSpans(old: [track: [a]], new: [UUID(): [a]]))
    }

    // MARK: How the strip moves

    func testFollowingTheWaveformMovesUnderAParkedPlayhead() {
        let m = StripMotion(follow: true, lead: 4, page: 0, pps: 100)
        // At the very start the playhead moves; once parked, the waveform does.
        XCTAssertEqual(m.viewStart(at: 2), 0)
        XCTAssertEqual(m.playheadX(at: 2), 200)
        XCTAssertEqual(m.viewStart(at: 10), 6)
        XCTAssertEqual(m.playheadX(at: 10), 400)
        XCTAssertEqual(m.playheadX(at: 60), 400)
        // The strip, whose zero is 8 s into the film, sits where that time is in the view.
        XCTAssertEqual(m.stripX(origin: 8, at: 10), 200)
        XCTAssertEqual(m.stripX(origin: 8, at: 12), 0)
    }

    func testTheStripsRunMatchesItsPlaceAtEveryMoment() throws {
        let m = StripMotion(follow: true, lead: 4, page: 0, pps: 120)
        let run = try XCTUnwrap(m.stripRun(origin: 100, around: 104, reach: 50))
        for t in stride(from: 60.0, through: 150, by: 7.3) {
            XCTAssertEqual(run.value(at: t), m.stripX(origin: 100, at: t), accuracy: 0.001)
        }
        // Near the film's start it holds still until the playhead is parked.
        let start = try XCTUnwrap(m.stripRun(origin: 0, around: 1, reach: 50))
        XCTAssertEqual(start.begin, 4)
        XCTAssertEqual(start.value(at: 2), 0)
        XCTAssertEqual(start.value(at: 30), m.stripX(origin: 0, at: 30), accuracy: 0.001)
        // The numbers stay small: within the reach either side.
        XCTAssertLessThanOrEqual(abs(run.from), 50 * 120 + 1)
        XCTAssertLessThanOrEqual(abs(run.to), 50 * 120 + 1)
    }

    func testThePlayheadsRunMatchesItsPlace() {
        let follow = StripMotion(follow: true, lead: 4, page: 0, pps: 100)
        let run = follow.playheadRun(span: 30)
        for t in [0.0, 1, 3.9, 4, 20] { XCTAssertEqual(run.value(at: t), follow.playheadX(at: t), accuracy: 0.001) }
        // Not following: the strip stands still and the playhead crosses the page.
        let paging = StripMotion(follow: false, lead: 4, page: 50, pps: 100)
        XCTAssertNil(paging.stripRun(origin: 48, around: 52, reach: 20))
        XCTAssertEqual(paging.stripX(origin: 48, at: 55), -200)
        let cross = paging.playheadRun(span: 30)
        for t in [50.0, 51.5, 59, 70] { XCTAssertEqual(cross.value(at: t), paging.playheadX(at: t), accuracy: 0.001) }
    }

    func testTheFrameShowsTheFilmsTimeWhenItReachesTheScreen() {
        XCTAssertEqual(WaveformNSView.displayTime(now: 10, rate: 1, ahead: 0.016), 10.016, accuracy: 1e-9)
        XCTAssertEqual(WaveformNSView.displayTime(now: 10, rate: 2, ahead: 0.01), 10.02, accuracy: 1e-9)
        XCTAssertEqual(WaveformNSView.displayTime(now: 10, rate: 1, ahead: -0.2), 10, "never back")
        XCTAssertEqual(WaveformNSView.displayTime(now: 10, rate: 1, ahead: 3), 10.05, accuracy: 1e-9, "a hitch isn't guessed across")
    }

    // MARK: Pictures for the strip

    func testStripPicturesAreDrawnTopDownLikeTheView() throws {
        let image = try XCTUnwrap(StripImage.render(size: CGSize(width: 4, height: 4), scale: 1,
                                                    space: CGColorSpace(name: CGColorSpace.sRGB)) {
            NSColor.white.setFill()
            CGRect(x: 0, y: 0, width: 4, height: 4).fill()
            NSColor.black.setFill()
            CGRect(x: 0, y: 0, width: 4, height: 1).fill()   // the top row, in the view's terms
        })
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 4)
        // Read it back: the picture's first row is its top.
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                          space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        let pixels = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertLessThan(pixels[0], 40, "top row dark")
        XCTAssertGreaterThan(pixels[3 * 16], 215, "bottom row light")
    }

    // MARK: The cards' flow

    private func rows(_ times: [Double]) -> [CardRow] {
        times.map { CardRow(key: UUID(), time: $0, cells: [:]) }
    }

    func testTheFlowCentresEachRowAsItsTitleStarts() throws {
        let p: [(time: Double, y: CGFloat)] = [(10, 100), (12, 180), (20, 260), (21, 340)]
        for point in p {
            XCTAssertEqual(try XCTUnwrap(CardFlow.centre(at: point.time, points: p)), point.y, accuracy: 0.001)
        }
        // Before the first and after the last, it holds.
        XCTAssertEqual(CardFlow.centre(at: 2, points: p), 100)
        XCTAssertEqual(CardFlow.centre(at: 99, points: p), 340)
        XCTAssertNil(CardFlow.centre(at: 5, points: []))
    }

    func testTheFlowNeverRunsBackOrOvershoots() throws {
        let p: [(time: Double, y: CGFloat)] = [(0, 0), (1, 90), (30, 170), (30.8, 260), (31.5, 340), (60, 420)]
        var last = -CGFloat.infinity
        for t in stride(from: -1.0, through: 61, by: 0.01) {
            let y = try XCTUnwrap(CardFlow.centre(at: t, points: p))
            XCTAssertGreaterThanOrEqual(y, last - 0.0001, "at \(t)")
            last = y
            // Between two rows, it stays between them.
            if let k = p.indices.dropLast().last(where: { p[$0].time <= t }), t <= p.last!.time {
                XCTAssertGreaterThanOrEqual(y, p[k].y - 0.001)
                XCTAssertLessThanOrEqual(y, p[k + 1].y + 0.001)
            }
        }
    }

    func testTheFlowMovesSmoothlyFromOneRowToTheNext() throws {
        let p: [(time: Double, y: CGFloat)] = [(0, 0), (2, 100), (3, 200), (8, 300)]
        // The speed doesn't jump as a row goes by.
        func speed(_ t: Double) throws -> Double {
            let a = try XCTUnwrap(CardFlow.centre(at: t - 0.0005, points: p))
            let b = try XCTUnwrap(CardFlow.centre(at: t + 0.0005, points: p))
            return Double(b - a) / 0.001
        }
        XCTAssertEqual(try speed(2 - 0.002), try speed(2 + 0.002), accuracy: 2)
        XCTAssertEqual(try speed(3 - 0.002), try speed(3 + 0.002), accuracy: 2)
    }

    func testTheFlowFindsTheRowsAroundThePlayhead() throws {
        let list = rows([1, 4, 4, 9, 15])
        XCTAssertEqual(CardFlow.row(atOrBefore: 0.5, in: list), -1)
        XCTAssertEqual(CardFlow.row(atOrBefore: 4, in: list), 2)
        XCTAssertEqual(CardFlow.row(atOrBefore: 100, in: list), 4)
        var frames: [UUID: CGRect] = [:]
        for (i, r) in list.enumerated() { frames[r.key] = CGRect(x: 0, y: CGFloat(i) * 80, width: 100, height: 72) }
        let points = try XCTUnwrap(CardFlow.points(at: 10, rows: list, frames: frames))
        // Row 3 (9 s), the one before (4 s), two after: one per start time.
        XCTAssertEqual(points.map { $0.time }, [4, 9, 15])
        // Not laid out where the playhead is (the list is far away): nothing to go by.
        frames[list[4].key] = nil
        XCTAssertNil(CardFlow.points(at: 10, rows: list, frames: frames))
        XCTAssertNil(CardFlow.points(at: 10, rows: [], frames: frames))
    }

    func testTheFlowEasesInFromWhereTheCardsWere() {
        XCTAssertEqual(CardFlow.blendLeft(elapsed: 0, duration: 0.45), 1)
        XCTAssertEqual(CardFlow.blendLeft(elapsed: 0.225, duration: 0.45), 0.5, accuracy: 0.001)
        XCTAssertEqual(CardFlow.blendLeft(elapsed: 1, duration: 0.45), 0)
        XCTAssertGreaterThan(CardFlow.blendLeft(elapsed: 0.05, duration: 0.45), 0.95, "starts gently")
    }

    func testTheCardsFlowByDefault() {
        let (model, _) = makeModel()
        if UserDefaults.standard.object(forKey: "cardsFlow") == nil { XCTAssertTrue(model.cardsFlow) }
    }
}
