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

/// A film opened before, shown on the home screen. URLs are stored as strings so links work too.
struct RecentFilm: Codable, Identifiable, Equatable {
    var video: String
    var subtitles: String?
    var opened: Date

    var id: String { video }
    var videoURL: URL? { URL(string: video) }
    var subtitleURL: URL? { subtitles.flatMap(URL.init(string:)) }
    var name: String { videoURL?.deletingPathExtension().lastPathComponent ?? video }
}

enum ExportFormat: String, CaseIterable {
    case srt, vtt
    var title: String { self == .srt ? "SubRip (.srt)" : "WebVTT (.vtt)" }
    var type: UTType { UTType(filenameExtension: rawValue) ?? .plainText }
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
    @Published var spotMode: SpotMode = .hold {
        didSet { UserDefaults.standard.set(spotMode.rawValue, forKey: "spotMode") }
    }
    /// Control/Option + mouse jog sensitivity (1 = default). Set in Settings.
    @Published var jogSpeed: Double = 1 {
        didSet { UserDefaults.standard.set(jogSpeed, forKey: "jogSpeed") }
    }
    @Published var preset: TimingPreset = .general
    /// Live spotting: subtracted from the key press (title start). 0 = exactly where you press.
    @Published var spotStartOffset: Double = 0 {
        didSet { UserDefaults.standard.set(spotStartOffset, forKey: "spotStartOffset") }
    }
    /// Live spotting: subtracted from the key release (title end), allowing for reaction time.
    @Published var spotEndOffset: Double = 0.25 {
        didSet { UserDefaults.standard.set(spotEndOffset, forKey: "spotEndOffset") }
    }
    @Published var pixelsPerSecond: Double = 120
    @Published var waveGain: Double = 1
    @Published var dbScale = false
    @Published var followPlayhead = true
    /// Trackpad: a plain two-finger swipe over a title's left/right half adjusts that edge.
    /// Off by default because it competes with scrolling the waveform.
    @Published var swipeOverTitleAdjusts = false
    @Published var playbackRate: Float = 1 {
        didSet { engine.setRate(playbackRate) }
    }
    /// The card whose text field should have keyboard focus (nil = none).
    @Published var focusRequest: UUID?
    @Published var statusMessage: String?
    @Published var showURLSheet = false
    /// The start screen for choosing a film. Shown at launch and after Back to Home.
    @Published var showHome = true
    @Published private(set) var recents: [RecentFilm] = []
    private var pendingSubtitles: URL?

    private(set) var spottingID: UUID?
    private var nudgeCommit: Task<Void, Never>?
    private var nudgeEdge: Edge?
    private var statusClear: Task<Void, Never>?

    init(engine: PlaybackEngine? = nil) {
        let engine = engine ?? AVFoundationEngine()
        self.engine = engine
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: "spotMode").flatMap(SpotMode.init(rawValue:)) { spotMode = mode }
        if defaults.object(forKey: "jogSpeed") != nil { jogSpeed = defaults.double(forKey: "jogSpeed") }
        if defaults.object(forKey: "spotStartOffset") != nil { spotStartOffset = defaults.double(forKey: "spotStartOffset") }
        if defaults.object(forKey: "spotEndOffset") != nil { spotEndOffset = defaults.double(forKey: "spotEndOffset") }
        if let data = defaults.data(forKey: "recentFilms"),
           let list = try? JSONDecoder().decode([RecentFilm].self, from: data) { recents = list }
        engine.onTimeChange = { [weak self] t in self?.tick(t) }
        engine.onPlayStateChange = { [weak self] playing in
            guard let self else { return }
            self.clock.isPlaying = playing
            if !playing {
                self.finishSpotting()
                if let until = self.previewUntil {
                    // The preview's own pause before it seeks doesn't end it; reaching its end does.
                    if self.engine.currentTime >= until - 0.05 { self.previewUntil = nil }
                } else {
                    self.selectTitleAtPlayhead()
                }
            }
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
        ensureLocal(url) { [weak self] local in self?.loadVideo(local) }
    }

    private func loadVideo(_ url: URL) {
        loadingName = url.lastPathComponent
        Task {
            defer { loadingName = nil }
            do {
                try await engine.load(url: url)
                videoURL = url
                clock.time = 0
                audio.load(url: url)
                showHome = false
                if let subs = pendingSubtitles {
                    pendingSubtitles = nil
                    openSubtitles(subs)
                }
                rememberFilm()
                if !url.isFileURL { flash("Streaming: the waveform appears once the audio has been read.") }
            } catch {
                pendingSubtitles = nil
                showError("Couldn't open \(url.lastPathComponent)", error.localizedDescription)
            }
        }
    }

    // MARK: Home screen and recent films

    /// Asks to save unsaved changes, then closes the film and shows the home screen.
    func goHome() {
        guard !showHome, confirmDiscardChanges() else { return }
        closeFilm()
        showHome = true
    }

    func openRecent(_ film: RecentFilm) {
        guard let url = film.videoURL else { return }
        if url.isFileURL && !FileManager.default.fileExists(atPath: url.path) {
            removeRecent(film)
            showError("Can't find \(url.lastPathComponent)",
                      "It may have been moved, renamed or deleted, so it has been taken off the list. Open it again with ⌘O.")
            return
        }
        if let subs = film.subtitleURL, !subs.isFileURL || FileManager.default.fileExists(atPath: subs.path) {
            pendingSubtitles = subs
        }
        openVideo(url)
    }

    func removeRecent(_ film: RecentFilm) {
        recents.removeAll { $0.id == film.id }
        storeRecents()
    }

    /// Records the open video, and its subtitle file once there is one.
    private func rememberFilm() {
        guard let video = videoURL else { return }
        let key = video.absoluteString
        var entry = recents.first { $0.video == key } ?? RecentFilm(video: key, subtitles: nil, opened: Date())
        if let subs = subtitleURL { entry.subtitles = subs.absoluteString }
        entry.opened = Date()
        recents.removeAll { $0.video == key }
        recents.insert(entry, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        storeRecents()
    }

    private func storeRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: "recentFilms")
        }
    }

    /// true when it's fine to throw the current titles away.
    private func confirmDiscardChanges() -> Bool {
        guard doc.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(suggestedName(ext: "srt"))?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save()
            return !doc.isDirty   // false if the save panel was cancelled
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func closeFilm() {
        finishSpotting()
        previewUntil = nil
        focusRequest = nil
        mainWindow?.makeFirstResponder(nil)
        engine.unload()
        clock.isPlaying = false
        clock.time = 0
        audio.clear()
        doc.replaceAll([])
        doc.selectedID = nil
        videoURL = nil
        subtitleURL = nil
        pendingSubtitles = nil
    }

    // MARK: iCloud and errors

    /// Name of the file waiting on iCloud or opening (shown in the title bar and on the home screen).
    @Published private(set) var loadingName: String?
    @Published private(set) var isDownloadingFromICloud = false
    private var iCloudWaits: [URL: Task<Void, Never>] = [:]

    private enum LocalState: Sendable { case local, inCloud }

    /// Makes sure a file is on this Mac before it's opened, downloading it from iCloud Drive
    /// if it's only in the cloud. Every iCloud query and download request runs off the main
    /// thread with a timeout: iCloud can stall on a cloud-only file, and the app must stay usable.
    private func ensureLocal(_ url: URL, then completion: @escaping (URL) -> Void) {
        guard url.isFileURL else { completion(url); return }
        iCloudWaits[url]?.cancel()
        iCloudWaits[url] = Task { [weak self] in
            let started = Date()
            var requestedDownload = false
            var probe: Task<LocalState, Never>?
            while !Task.isCancelled {
                // Reuse a query that hasn't answered yet rather than piling up new ones.
                let running = probe ?? Self.offMain { Self.localState(of: url) }
                probe = running
                let state = await Self.value(of: running, timeout: 1.5)
                guard let self, !Task.isCancelled else { return }
                if state != nil { probe = nil }
                if state == .local {
                    self.finishICloudWait(url)
                    completion(URL(fileURLWithPath: url.path))
                    return
                }
                // Cloud-only, or iCloud is slow to answer: ask for the download and show that we're waiting.
                if !requestedDownload {
                    requestedDownload = true
                    _ = Self.offMain { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
                }
                self.loadingName = url.lastPathComponent
                self.isDownloadingFromICloud = true
                if Date().timeIntervalSince(started) > 90 {
                    self.finishICloudWait(url)
                    self.pendingSubtitles = nil
                    self.showError("iCloud hasn't delivered \(url.lastPathComponent)",
                                   "It's stored only in iCloud Drive and hasn't downloaded yet. In Finder, right-click it and choose Download Now, then open it again once it has downloaded.")
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Stops waiting for iCloud (the Cancel button next to "Waiting for iCloud").
    func cancelICloudWait() {
        iCloudWaits.values.forEach { $0.cancel() }
        iCloudWaits.removeAll()
        pendingSubtitles = nil
        isDownloadingFromICloud = false
        loadingName = nil
    }

    private func finishICloudWait(_ url: URL) {
        iCloudWaits[url] = nil
        if iCloudWaits.isEmpty {
            isDownloadingFromICloud = false
            loadingName = nil
        }
    }

    /// Blocking: may wait on iCloud. Only call off the main thread.
    private nonisolated static func localState(of url: URL) -> LocalState {
        let fresh = URL(fileURLWithPath: url.path)   // avoids cached resource values
        guard let values = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return .local }
        return values.ubiquitousItemDownloadingStatus == .notDownloaded ? .inCloud : .local
    }

    /// Runs blocking work on a background queue (not the Swift concurrency pool, which it could starve).
    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) -> Task<T, Never> {
        Task.detached {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
            }
        }
    }

    /// The task's result, or nil if it takes longer than `timeout` (the task keeps running).
    private static func value<T: Sendable>(of task: Task<T, Never>, timeout: Double) async -> T? {
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task {
                let v = await task.value
                if once.claim() { continuation.resume(returning: v) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Problems opening or saving are shown as an alert, so nothing fails silently.
    func showError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func openURLString(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else {
            showError("That doesn't look like a video link",
                      "Use a direct link to a video file (https://…/film.mp4) or an HLS stream (.m3u8).")
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
        ensureLocal(url) { [weak self] local in self?.readSubtitles(local) }
    }

    /// The file is read off the main thread, so a slow disk or iCloud can't freeze the app.
    private func readSubtitles(_ url: URL) {
        loadingName = url.lastPathComponent
        let reading = Self.offMain { () -> Result<[Subtitle], SubtitleReadError> in
            do { return .success(try SubtitleFormats.read(url: url)) }
            catch { return .failure(SubtitleReadError(message: error.localizedDescription)) }
        }
        Task {
            let result = await reading.value
            if loadingName == url.lastPathComponent { loadingName = nil }
            switch result {
            case .success(let subs):
                doc.replaceAll(subs)
                subtitleURL = url.pathExtension.lowercased() == "srt" ? url : nil
                rememberFilm()
                flash("Loaded \(subs.count) titles from \(url.lastPathComponent)")
            case .failure(let error):
                showError("Couldn't read \(url.lastPathComponent)", error.message)
            }
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
            if write(SubtitleFormats.srt(doc.subtitles), to: url) {
                subtitleURL = url
                rememberFilm()
            }
        }
    }

    /// File ▸ Export…: a save panel with a Format menu. Exporting doesn't change the file ⌘S saves to.
    func export() {
        let defaults = UserDefaults.standard
        let initial = defaults.string(forKey: "exportFormat").flatMap(ExportFormat.init(rawValue:)) ?? .srt
        let panel = NSSavePanel()
        panel.title = "Export Subtitles"
        panel.prompt = "Export"
        panel.allowedContentTypes = [initial.type]
        panel.nameFieldStringValue = suggestedName(ext: initial.rawValue)

        let switcher = ExportFormatSwitcher(panel: panel)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        ExportFormat.allCases.forEach { popup.addItem(withTitle: $0.title) }
        popup.selectItem(at: ExportFormat.allCases.firstIndex(of: initial) ?? 0)
        popup.target = switcher
        popup.action = #selector(ExportFormatSwitcher.formatChanged(_:))
        let stack = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        stack.setFrameSize(stack.fittingSize)
        panel.accessoryView = stack

        let response = withExtendedLifetime(switcher) { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        let format = ExportFormat.allCases[max(0, popup.indexOfSelectedItem)]
        defaults.set(format.rawValue, forKey: "exportFormat")
        let text = format == .srt ? SubtitleFormats.srt(doc.subtitles) : SubtitleFormats.vtt(doc.subtitles)
        write(text, to: url, markSaved: false)
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
            showError("Couldn't save \(url.lastPathComponent)", error.localizedDescription)
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
        previewUntil = nil
        if engine.isPlaying {
            engine.pause()
        } else {
            // Starting playback leaves text editing so the cards can follow the playhead.
            // When it stops, the title under the playhead is selected; Return or typing edits it.
            if focusRequest != nil {
                focusRequest = nil
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            engine.play()
        }
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
        followSelection(at: t)
        if let id = spottingID, let s = doc.subtitle(id) {
            let end = max(s.start + 0.1, t - spotEndOffset)
            if end > s.end { doc.liveUpdate(id) { $0.end = end } }
        }
    }

    // MARK: Selection

    func select(_ id: UUID?, seekToStart: Bool = false) {
        doc.selectedID = id
        if seekToStart, let s = doc.subtitle(id) { seek(s.start) }
    }

    /// As the playhead moves (playing, stepping or seeking), the last title it reached
    /// becomes selected, and the card list keeps it centred. The selection only changes
    /// when the playhead reaches a *different* title, so clicking another title's box
    /// isn't undone on the next tick. Paused while previewing, spotting, dragging or typing.
    private var lastFollowedID: UUID?

    private func followSelection(at t: Double) {
        guard !isPreviewing, spottingID == nil, !doc.isLive, focusRequest == nil else { return }
        let last = doc.subtitles.last(where: { $0.start <= t + 0.001 })
        guard last?.id != lastFollowedID else { return }
        lastFollowedID = last?.id
        guard let last else { return }
        if clock.isPlaying {
            if last.id != doc.selectedID { doc.selectedID = last.id }
        } else {
            // Paused (stepping, seeking): scroll the cards but keep the selection, so a
            // jog or nudge never lands on a different title than the one you picked.
            cardScrollTarget = last.id
        }
    }

    /// Card the list should scroll to centre, without selecting it.
    @Published var cardScrollTarget: UUID?

    /// The editor window; keyboard and mouse handling ignores every other window
    /// (Settings, sheets), so typing there can't change titles.
    weak var mainWindow: NSWindow?

    /// Clicking to place the playhead (ruler or empty waveform). While paused: landing
    /// inside a title selects it; landing in a gap clears the selection and scrolls the
    /// cards to that point in the list.
    func placePlayhead(_ t: Double) {
        guard hasMedia else { return }
        seek(t)
        guard !clock.isPlaying else { return }
        if let s = doc.active(at: t) {
            doc.selectedID = s.id
            cardScrollTarget = s.id
        } else {
            doc.selectedID = nil
            cardScrollTarget = doc.subtitles.last(where: { $0.start <= t })?.id ?? doc.subtitles.first?.id
        }
    }

    /// When playback stops, the title under the playhead becomes the selected one.
    private func selectTitleAtPlayhead() {
        guard !doc.isLive, let s = doc.active(at: engine.currentTime), s.id != doc.selectedID else { return }
        if focusRequest != nil { focusRequest = nil }
        doc.selectedID = s.id
    }

    /// Typing while a title is selected (and nothing is being edited) starts editing it.
    func typeIntoSelected(_ characters: String) {
        guard let id = doc.selectedID, let s = doc.subtitle(id) else { return }
        doc.setText(id, s.text + characters)
        focusRequest = id
    }

    /// Moves to the next/previous title and puts the playhead at its start.
    func selectAdjacent(_ delta: Int, keepEditing: Bool = false) {
        guard !doc.subtitles.isEmpty else { return }
        let i: Int
        if let sel = doc.index(of: doc.selectedID) {
            i = sel
        } else {
            // Nothing selected (playhead in a gap): step from the playhead's position in the list.
            let t = clock.time
            let k = doc.subtitles.lastIndex(where: { $0.start <= t }) ?? -1
            i = delta > 0 ? k : k + 1
        }
        let j = min(max(0, i + delta), doc.subtitles.count - 1)
        let id = doc.subtitles[j].id
        if engine.isPlaying { engine.pause() }
        select(id, seekToStart: true)
        if keepEditing { focusRequest = id }
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
        // Either edge: play the whole title, from 1 s before it starts to just after it ends.
        guard hasMedia, let s = doc.subtitle(id) else { return }
        playRange(from: max(0, s.start - 1), to: s.end + 0.25)
    }

    /// Short, automatic playbacks (previews). Selection doesn't follow the playhead
    /// during these, so the title being worked on stays selected.
    private var previewUntil: Double?
    var isPreviewing: Bool { previewUntil != nil }

    func playRange(from: Double, to: Double) {
        guard hasMedia else { return }
        previewUntil = to
        engine.play(from: from, to: to)
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

    /// The playhead time when a key event actually happened. Events can reach us a little
    /// after the key moved (while the main thread is drawing), so that delay is taken back off.
    private func spotTime(eventTimestamp: TimeInterval?, offset: Double) -> Double {
        var t = engine.currentTime
        if let ts = eventTimestamp {
            let lag = min(0.2, max(0, ProcessInfo.processInfo.systemUptime - ts))
            t -= lag * Double(playbackRate)
        }
        return max(0, t - offset)
    }

    /// Hold mode: key down. Tap mode: "end this, start next".
    func spotDown(eventTimestamp: TimeInterval? = nil) {
        guard hasMedia, engine.isPlaying else { return }
        let t = spotTime(eventTimestamp: eventTimestamp, offset: spotStartOffset)
        if spotMode == .tap, spottingID != nil {
            finishSpotting(at: spotTime(eventTimestamp: eventTimestamp, offset: spotEndOffset))
        }
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
    func spotUp(eventTimestamp: TimeInterval? = nil) {
        finishSpotting(at: spotTime(eventTimestamp: eventTimestamp, offset: spotEndOffset))
    }

    // MARK: Splitting

    /// Splits a title at `t`, leaving the minimum gap (half each side of the split point).
    /// The text is divided at the line break or word nearest the split.
    func splitTitle(_ id: UUID, at t: Double) {
        guard let s = doc.subtitle(id) else { return }
        let half = minGap / 2
        let firstEnd = t - half
        let secondStart = t + half
        guard firstEnd - s.start >= 0.1, s.end - secondStart >= 0.1 else {
            flash("Too close to the edge of the title to split there.")
            return
        }
        let parts = Self.splitText(s.text, at: (t - s.start) / max(0.001, s.duration))
        let second = Subtitle(start: secondStart, end: s.end, text: parts.1)
        doc.perform { subs in
            guard let i = subs.firstIndex(where: { $0.id == id }) else { return }
            subs[i].end = firstEnd
            subs[i].text = parts.0
            subs.append(second)
        }
        doc.selectedID = second.id
        if !engine.isPlaying { seek(secondStart) }
    }

    /// Title ▸ Split at Playhead: splits the title under the playhead.
    func splitAtPlayhead() {
        let t = engine.currentTime
        guard hasMedia, let s = doc.active(at: t) else {
            flash("Put the playhead over a title to split it.")
            return
        }
        splitTitle(s.id, at: t)
    }

    /// Divides text at the line break, or else the word gap, nearest `fraction` of the way through.
    static func splitText(_ text: String, at fraction: Double) -> (String, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }
        let chars = Array(trimmed)
        let target = Double(chars.count) * min(1, max(0, fraction))
        let lineBreaks = chars.indices.filter { chars[$0] == "\n" }
        let spaces = chars.indices.filter { chars[$0] == " " }
        let candidates = lineBreaks.isEmpty ? spaces : lineBreaks
        guard let cut = candidates.min(by: { abs(Double($0) - target) < abs(Double($1) - target) }) else {
            // A single word: keep it on the side with more of the time.
            return fraction < 0.5 ? ("", trimmed) : (trimmed, "")
        }
        let a = String(chars[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let b = String(chars[(cut + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (a, b)
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

/// Keeps the export panel's file type and extension in step with its Format menu.
@MainActor
final class ExportFormatSwitcher: NSObject {
    private weak var panel: NSSavePanel?
    init(panel: NSSavePanel) { self.panel = panel }

    @objc func formatChanged(_ sender: NSPopUpButton) {
        guard let panel, ExportFormat.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        let format = ExportFormat.allCases[sender.indexOfSelectedItem]
        panel.allowedContentTypes = [format.type]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(format.rawValue)"
    }
}

struct SubtitleReadError: Error, Sendable { let message: String }

/// Lets exactly one of several racing callers resume a continuation.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
