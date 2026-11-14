import AppKit

/// Everything the editor needs from a video engine. Build 1 uses AVFoundation;
/// a libmpv engine (MKV, WebM, AVI…) can be dropped in behind this protocol later.
@MainActor
protocol PlaybackEngine: AnyObject {
    var duration: Double { get }
    var frameRate: Double { get }
    var currentTime: Double { get }
    var isPlaying: Bool { get }
    var hasVideo: Bool { get }

    /// Called on the main thread roughly 60 times a second, and after every seek.
    var onTimeChange: ((Double) -> Void)? { get set }
    var onPlayStateChange: ((Bool) -> Void)? { get set }

    func load(url: URL) async throws
    /// Closes the current video, leaving an empty engine.
    func unload()
    func play()
    func pause()
    func setRate(_ rate: Float)

    /// `exact: true` shows the exact frame (used by scrubbing and nudges).
    /// Rapid exact seeks are coalesced so the picture never lags behind.
    func seek(to seconds: Double, exact: Bool)

    /// Plays from `from` and pauses automatically at `to`.
    func play(from: Double, to: Double)

    /// The view that renders the picture.
    func makeVideoView() -> NSView
}
