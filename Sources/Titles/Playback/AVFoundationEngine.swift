import AVFoundation
import AVKit
import AppKit

enum EngineError: LocalizedError {
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let ext):
            let kind = ext.isEmpty ? "This video" : "This \(ext) file"
            return "\(kind) can't be played yet. Build 1 plays MP4, MOV and M4V (H.264, HEVC, ProRes). MKV, WebM and AVI arrive with the next video engine."
        }
    }
}

/// AVFoundation-backed engine: MP4, MOV and M4V with H.264, HEVC or ProRes, plus HTTPS and HLS.
@MainActor
final class AVFoundationEngine: NSObject, PlaybackEngine {
    let player = AVPlayer()

    private(set) var duration: Double = 0
    private(set) var frameRate: Double = 25
    private(set) var hasVideo = false

    var onTimeChange: ((Double) -> Void)?
    var onPlayStateChange: ((Bool) -> Void)?

    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    private var stopAt: Double?
    private var playRate: Float = 1

    // "Chase" seeking: only one exact seek in flight; the latest target wins.
    private var isSeeking = false
    private var chaseTarget = CMTime.zero

    override init() {
        super.init()
        player.actionAtItemEnd = .pause
        let interval = CMTime(value: 1, timescale: 60)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time.seconds)
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let playing = player.rate != 0
            Task { @MainActor in self?.onPlayStateChange?(playing) }
        }
    }

    var currentTime: Double {
        if isSeeking { return chaseTarget.seconds }
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    var isPlaying: Bool { player.rate != 0 }

    func load(url: URL) async throws {
        pause()
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        guard playable else { throw EngineError.unsupported(url.pathExtension.uppercased()) }
        let dur = try await asset.load(.duration)
        duration = dur.seconds.isFinite ? dur.seconds : 0
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        hasVideo = !videoTracks.isEmpty
        if let track = videoTracks.first {
            let fps = try await track.load(.nominalFrameRate)
            frameRate = fps > 1 ? Double(fps) : 25
        }
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        onTimeChange?(0)
    }

    func play() {
        stopAt = nil
        player.rate = playRate
    }

    func pause() {
        player.pause()
    }

    func setRate(_ rate: Float) {
        playRate = rate
        if isPlaying { player.rate = rate }
    }

    func seek(to seconds: Double, exact: Bool) {
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        let t = CMTime(seconds: clamped, preferredTimescale: 600)
        onTimeChange?(clamped)
        if !exact {
            player.seek(to: t)
            return
        }
        chaseTarget = t
        if !isSeeking { performChase() }
    }

    func play(from: Double, to: Double) {
        let start = CMTime(seconds: max(0, from), preferredTimescale: 600)
        player.pause()
        isSeeking = true
        chaseTarget = start
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSeeking = false
                self.stopAt = to
                self.player.rate = self.playRate
            }
        }
    }

    func makeVideoView() -> NSView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        return view
    }

    // MARK: Private

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        if let stop = stopAt, t >= stop {
            stopAt = nil
            player.pause()
        }
        if !isSeeking { onTimeChange?(t) }
    }

    private func performChase() {
        isSeeking = true
        let target = chaseTarget
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if CMTimeCompare(target, self.chaseTarget) == 0 {
                    self.isSeeking = false
                } else {
                    self.performChase()
                }
            }
        }
    }
}
