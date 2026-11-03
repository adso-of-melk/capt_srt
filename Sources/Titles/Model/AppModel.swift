import Foundation
import AppKit
import UniformTypeIdentifiers

/// Fast-changing playback state, kept separate so that only the views that
/// need it (video overlay, title bar, waveform) redraw 60 times a second.
@MainActor
final class PlayheadClock: ObservableObject {
    @Published var time: Double = 0
    @Published var isPlaying = false
}

enum SpotMode: String, CaseIterable, Identifiable {
    case hold = "Hold"
    case tap = "Tap"
    var id: String { rawValue }
}

/// Central controller: owns the document, the engine and the audio, and
/// implements every editing action so the keyboard, mouse, wheel and
/// trackpad all go through the same code.
@MainActor
final class AppModel: ObservableObject {
    let doc = SubtitleDocument()
    let clock = PlayheadClock()
    let audio = AudioStore()
    let engine: PlaybackEngine
    private let scrub = ScrubAudioPlayer()

    @Published private(set) var videoURL: URL?
    @Published private(set) var subtitleURL: URL?
    @Published var spotMode: SpotMode = .hold
    @Published var preset: TimingPreset = .general
    /// Subtracted from spotting key presses to allow for reaction time.
    @Published var reactionOffset: Double = 0.25
    @Published var pixelsPerSecond: Double = 120
    @Published var waveGain: Double = 1
    @Published var dbScale = false
    @Published var followPlayhead = true
    @Published var playbackRate: Float = 1 {
        didSet { engine.setRate(playbackRate) }
    }
    /// The card whose text field should have keyboard focus (nil = none).
    @Published var focusRequest: UUID?
    @Published var statusMessage: String?
    @Published var showURLSheet = false

    private(set) var spottingID: UUID?
    private var nudgeCommit: Task<Void, Never>?
    private var nudgeEdge: Edge?
    private var statusClear: Task<Void, Never>?

    init(engine: PlaybackEngine? = nil) {
        let engine = engine ?? AVFoundationEngine()
        self.engine = engine
        engine.onTimeChange = { [weak self] t in self?.tick(t) }
        engine.onPlayStateChange = { [weak self] playing in
            self?.clock.isPlaying = playing
            if !playing { self?.finishSpotting() }
        }
    }

    // MARK: Derived

    var frameDuration: Double { 1 / max(1, engine.frameRate) }
    var minGap: Double { Double(preset.minGapFrames) * frameDuration }
    var hasMedia: Bool { videoURL != nil }

    var windowTitle: String {
        let name = subtitleURL?.lastPathComponent ?? videoURL.map { $0.deletingPathExtension().lastPathComponent + ".srt" } ?? "Untitled"
        return doc.isDirty ? "\(name) — Edited" : name
    }

    // MARK: Files

    func openVideoPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { openVideo(url) }
    }

    func openVideo(_ url: URL) {
        Task {
            do {
                try await engine.load(url: url)
                videoURL = url
                clock.time = 0
                audio.load(url: url)
                if !url.isFileURL { flash("Streaming: the waveform appears once the audio has been read.") }
            } catch {
                flash("Couldn't open \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    func openURLString(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else {
            flash("That doesn't look like a video link.")
            return
        }
        openVideo(url)
    }

    func openSubtitlesPanel() {
        let panel = NSOpenPanel()
        let types: [UTType?] = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt"), UTType.plainText]
        panel.allowedContentTypes = types.compactMap { $0 }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { openSubtitles(url) }
    }

    func openSubtitles(_ url: URL) {
        do {
            let subs = try SubtitleFormats.read(url: url)
            doc.replaceAll(subs)
            subtitleURL = url.pathExtension.lowercased() == "srt" ? url : nil
            flash("Loaded \(subs.count) titles from \(url.lastPathComponent)")
        } catch {
            flash("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func handleDrop(_ urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ["srt", "vtt"].contains(ext) { openSubtitles(url) } else { openVideo(url) }
        }
    }

    func save() {
        if let url = subtitleURL { write(SubtitleFormats.srt(doc.subtitles), to: url) } else { saveAs() }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = suggestedName(ext: "srt")
        if panel.runModal() == .OK, let url = panel.url {
            if write(SubtitleFormats.srt(doc.subtitles), to: url) { subtitleURL = url }
        }
    }

    func exportVTT() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vtt") ?? .plainText]
        panel.nameFieldStringValue = suggestedName(ext: "vtt")
        if panel.runModal() == .OK, let url = panel.url {
            _ = write(SubtitleFormats.vtt(doc.subtitles), to: url, markSaved: false)
        }
    }

    private func suggestedName(ext: String) -> String {
        let base = subtitleURL?.deletingPathExtension().lastPathComponent
            ?? videoURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return "\(base).\(ext)"
    }

    @discardableResult
    private func write(_ text: String, to url: URL, markSaved: Bool = true) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            if markSaved { doc.markSaved() }
            flash("Saved \(url.lastPathComponent)")
            return true
        } catch {
            flash("Couldn't save: \(error.localizedDescription)")
            return false
        }
    }

    func flash(_ message: String) {
        statusMessage = message
        statusClear?.cancel()
        statusClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    // MARK: Transport

    func togglePlay() {
        guard hasMedia else { return }
        engine.isPlaying ? engine.pause() : engine.play()
    }

    func seek(_ t: Double, exact: Bool = true) {
        guard hasMedia else { return }
        engine.seek(to: t, exact: exact)
    }

    func stepFrames(_ n: Int) {
        guard hasMedia else { return }
        engine.pause()
        let t = engine.currentTime + Double(n) * frameDuration
        engine.seek(to: max(0, t), exact: true)
        grain(at: max(0, t))
    }

    func grain(at t: Double) {
        if let wf = audio.waveform { scrub.grain(at: t, from: wf) }
    }

    private func tick(_ t: Double) {
        clock.time = t
        if let id = spottingID, let s = doc.subtitle(id) {
            let end = max(s.start + 0.1, t - reactionOffset)
            if end > s.end { doc.liveUpdate(id) { $0.end = end } }
        }
    }

    // MARK: Selection

    func select(_ id: UUID?, seekToStart: Bool = false) {
        doc.selectedID = id
        if seekToStart, let s = doc.subtitle(id) { seek(s.start) }
    }

    func selectAdjacent(_ delta: Int) {
        guard !doc.subtitles.isEmpty else { return }
        let i = doc.index(of: doc.selectedID) ?? (delta > 0 ? -1 : doc.subtitles.count)
        let j = min(max(0, i + delta), doc.subtitles.count - 1)
        select(doc.subtitles[j].id, seekToStart: true)
    }

    func deleteSelected() {
        guard let id = doc.selectedID else { return }
        doc.delete(id)
    }

    /// Creates a title (used by click-drag) and opens its card for typing.
    func createTitle(start: Double, end: Double) {
        let id = doc.add(start: start, end: end)
        focusRequest = id
    }

    // MARK: Fine-tuning (shared by jog, wheel, trackpad and nudge keys)

    /// Moves one edge. With `clamp`, the edge stops at the neighbouring title minus the minimum gap.
    /// Must be called between `doc.beginLive()` and `doc.commitLive()`.
    @discardableResult
    func moveEdge(_ edge: Edge, of id: UUID, to t: Double, clamp: Bool) -> Double? {
        guard let s = doc.subtitle(id) else { return nil }
        let minLength = 0.1
        var value = t
        switch edge {
        case .start:
            var lower = 0.0
            if clamp, let prev = doc.previous(of: id), prev.end <= s.start + 0.0005 {
                lower = prev.end + minGap
            }
            value = min(max(value, lower), s.end - minLength)
            doc.liveUpdate(id) { $0.start = value }
        case .end:
            var upper = engine.duration > 0 ? engine.duration : Double.greatestFiniteMagnitude
            if clamp, let next = doc.next(of: id), next.start >= s.end - 0.0005 {
                upper = min(upper, next.start - minGap)
            }
            value = max(min(value, upper), s.start + minLength)
            doc.liveUpdate(id) { $0.end = value }
        }
        return value
    }

    /// Shows the frame at the edge and plays a short audio grain there.
    func scrubTo(_ t: Double) {
        engine.pause()
        engine.seek(to: t, exact: true)
        grain(at: t)
    }

    /// After an adjustment: start edges play from 1 s before to 1 s after;
    /// end edges play from 1 s before to 0.5 s after.
    func preview(_ edge: Edge, of id: UUID) {
        guard hasMedia, let s = doc.subtitle(id) else { return }
        switch edge {
        case .start: engine.play(from: max(0, s.start - 1), to: s.start + 1)
        case .end: engine.play(from: max(0, s.end - 1), to: s.end + 0.5)
        }
    }

    /// Keyboard, wheel and trackpad nudges: frame steps, coalesced into one undo
    /// step, previewed once the input pauses.
    func nudge(_ edge: Edge, frames: Int) {
        guard let id = doc.selectedID, let s = doc.subtitle(id) else { return }
        doc.beginLive()
        let current = edge == .start ? s.start : s.end
        if let t = moveEdge(edge, of: id, to: current + Double(frames) * frameDuration, clamp: true) {
            scrubTo(t)
        }
        nudgeEdge = edge
        nudgeCommit?.cancel()
        nudgeCommit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.doc.commitLive()
            if let e = self.nudgeEdge { self.preview(e, of: id) }
        }
    }

    /// Same as `nudge` but for a specific title under the pointer (trackpad over a box half).
    func nudge(_ edge: Edge, of id: UUID, frames: Int) {
        doc.selectedID = id
        nudge(edge, frames: frames)
    }

    // MARK: Live spotting

    /// Hold mode: key down. Tap mode: "end this, start next".
    func spotDown() {
        guard hasMedia, engine.isPlaying else { return }
        let t = max(0, engine.currentTime - reactionOffset)
        if spotMode == .tap, spottingID != nil { finishSpotting(at: t) }
        guard spottingID == nil else { return }
        let start: Double
        if let last = doc.subtitles.last(where: { $0.start <= t }), last.end > t - minGap, last.end <= t + 0.5 {
            start = max(t, last.end + minGap)
        } else {
            start = t
        }
        let s = Subtitle(start: start, end: start + 0.1)
        doc.live { $0.append(s) }
        doc.selectedID = s.id
        spottingID = s.id
    }

    /// Hold mode: key up. Tap mode: "end, leave a gap".
    func spotUp() {
        finishSpotting(at: max(0, engine.currentTime - reactionOffset))
    }

    private func finishSpotting(at t: Double? = nil) {
        guard let id = spottingID else { return }
        spottingID = nil
        if let t, let s = doc.subtitle(id) {
            doc.liveUpdate(id) { $0.end = max(s.start + 0.3, t) }
        }
        doc.commitLive()
    }

    var isSpotting: Bool { spottingID != nil }
}
