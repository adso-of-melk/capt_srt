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

enum ExportFormat: String, CaseIterable, Codable, Sendable {
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
    /// The focused language's titles: everything that edits titles acts on this.
    @Published var doc = SubtitleDocument()
    let clock = PlayheadClock()
    let audio = AudioStore()
    let engine: PlaybackEngine
    private let scrub = ScrubAudioPlayer()

    @Published var videoURL: URL?
    @Published var spotMode: SpotMode = .hold {
        didSet { UserDefaults.standard.set(spotMode.rawValue, forKey: "spotMode") }
    }
    /// Control/Option + mouse jog sensitivity (1 = default). Set in Settings.
    @Published var jogSpeed: Double = 1 {
        didSet { UserDefaults.standard.set(jogSpeed, forKey: "jogSpeed") }
    }
    /// Live spotting: subtracted from the key press (title start). 0 = exactly where you press.
    @Published var spotStartOffset: Double = 0 {
        didSet { UserDefaults.standard.set(spotStartOffset, forKey: "spotStartOffset") }
    }
    /// Live spotting: subtracted from the key release (title end), allowing for reaction time.
    @Published var spotEndOffset: Double = 0 {
        didSet { UserDefaults.standard.set(spotEndOffset, forKey: "spotEndOffset") }
    }
    @Published var pixelsPerSecond: Double = 120
    @Published var waveGain: Double = 1
    @Published var dbScale = false
    @Published var followPlayhead = true
    /// Trackpad: a plain two-finger swipe over a title's left/right half adjusts that edge.
    /// Off by default because it competes with scrolling the waveform.
    @Published var swipeOverTitleAdjusts = true
    @Published var playbackRate: Float = 1 {
        didSet { engine.setRate(playbackRate) }
    }
    /// The card whose text field should have keyboard focus (nil = none).
    @Published var focusRequest: UUID?
    /// The timecode readout is being typed into (go to a time).
    @Published var editingTimecode = false
    /// A nudge made while Control/Option is still held plays once they're let go.
    var pendingPreview: (edge: Edge, id: UUID)?
    @Published var statusMessage: String?
    /// The start screen for choosing a project. Shown at launch and after Back to Home.
    @Published var showHome = true
    /// The project's video overview (the only place new videos are added).
    @Published var showProjectView = false

    // MARK: Project state (see AppModel+Project.swift)

    @Published var project: Project?
    @Published var video: VideoItem?
    /// Side-by-side rows for the open languages, rebuilt whenever any language changes.
    @Published var rows: [CardRow] = []
    /// Row index of every visible title, by title id.
    var rowOfSub: [UUID: Int] = [:]
    /// Titles picked together on the waveform (Shift-click, Shift-drag, ⌘A), in the focused language.
    @Published var multiSelection: Set<UUID> = []
    /// Per-language title numbers (1-based, time order).
    var numberOfSub: [UUID: Int] = [:]
    /// The focused language has no title in this row, and that empty slot is selected.
    @Published var emptySlotRow: UUID?
    /// Bumped on every change to any language, so views that draw several languages redraw.
    @Published var revision = 0
    /// A non-blocking notice under the top strip (e.g. working from the local copy).
    @Published var banner: String?
    @Published var sheet: SheetKind?
    @Published var recentProjects: [RecentProject] = []
    /// Video chosen before a project exists (dropped on the home screen).
    @Published var newProjectVideo: URL?
    /// A subtitle file waiting for its language to be chosen.
    @Published var pendingImport: URL?
    @Published var textOnly = false {
        didSet { UserDefaults.standard.set(textOnly, forKey: "textOnly") }
    }
    /// Break long titles into lines automatically (style-guide rules) when you leave a card.
    @Published var autoLineBreaks = true {
        didSet { UserDefaults.standard.set(autoLineBreaks, forKey: "autoLineBreaks") }
    }
    @Published var replayAfterJog = true {
        didSet { UserDefaults.standard.set(replayAfterJog, forKey: "replayAfterJog") }
    }
    @Published var replayAfterResize = true {
        didSet { UserDefaults.standard.set(replayAfterResize, forKey: "replayAfterResize") }
    }

    // Fine-tuning with Control/Option held (Settings ▸ Jogging).
    /// Moving the mouse moves the edge.
    @Published var mouseJogOn = true { didSet { UserDefaults.standard.set(mouseJogOn, forKey: "mouseJogOn") } }
    @Published var mouseJogStep = JogStep.frame { didSet { UserDefaults.standard.set(mouseJogStep.rawValue, forKey: "mouseJogStep") } }
    /// 0 = finest (a long mouse movement per step), 1 = fastest.
    @Published var mouseJogSensitivity = 0.35 { didSet { UserDefaults.standard.set(mouseJogSensitivity, forKey: "mouseJogSensitivity") } }
    /// The scroll wheel (or a two-finger swipe) moves the edge.
    @Published var wheelJogOn = true { didSet { UserDefaults.standard.set(wheelJogOn, forKey: "wheelJogOn") } }
    @Published var wheelJogStep = JogStep.frame { didSet { UserDefaults.standard.set(wheelJogStep.rawValue, forKey: "wheelJogStep") } }
    /// 0 = four wheel clicks per step, 0.5 = one click per step, 1 = four steps per click.
    @Published var wheelJogSensitivity = 0.5 { didSet { UserDefaults.standard.set(wheelJogSensitivity, forKey: "wheelJogSensitivity") } }

    /// See `updateCardColumnWidth()`.
    @Published var cardColumnMinWidth: CGFloat = 240
    /// Languages shown as full bands on the waveform, besides the focused one.
    @Published var waveBands: Set<UUID> = [] {
        didSet { UserDefaults.standard.set(waveBands.map(\.uuidString), forKey: "waveBands") }
    }
    var undoOrder: [UUID] = []
    var redoOrder: [UUID] = []
    var isSyncingLocks = false
    var refreshScheduled = false
    var autosaveTask: Task<Void, Never>?
    var lastBackup = Date.distantPast
    var originalWriteInFlight = false
    /// The newest save that arrived while an earlier one was still being written.
    var pendingOriginalWrite: (data: Data, url: URL)?
    var selectionWatchers: [Any] = []

    @Published private(set) var spottingID: UUID?
    private var nudgeCommit: Task<Void, Never>?
    private var nudgeEdge: Edge?
    private var statusClear: Task<Void, Never>?

    init(engine: PlaybackEngine? = nil) {
        let engine = engine ?? AVFoundationEngine()
        self.engine = engine
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: "spotMode").flatMap(SpotMode.init(rawValue:)) { spotMode = mode }
        if defaults.object(forKey: "jogSpeed") != nil { jogSpeed = defaults.double(forKey: "jogSpeed") }
        if defaults.object(forKey: "mouseJogOn") != nil { mouseJogOn = defaults.bool(forKey: "mouseJogOn") }
        if let v = defaults.string(forKey: "mouseJogStep").flatMap(JogStep.init(rawValue:)) { mouseJogStep = v }
        if defaults.object(forKey: "mouseJogSensitivity") != nil { mouseJogSensitivity = defaults.double(forKey: "mouseJogSensitivity") }
        if defaults.object(forKey: "wheelJogOn") != nil { wheelJogOn = defaults.bool(forKey: "wheelJogOn") }
        if let v = defaults.string(forKey: "wheelJogStep").flatMap(JogStep.init(rawValue:)) { wheelJogStep = v }
        if defaults.object(forKey: "wheelJogSensitivity") != nil { wheelJogSensitivity = defaults.double(forKey: "wheelJogSensitivity") }
        if let ids = defaults.array(forKey: "waveBands") as? [String] { waveBands = Set(ids.compactMap(UUID.init(uuidString:))) }
        if defaults.object(forKey: "spotStartOffset") != nil { spotStartOffset = defaults.double(forKey: "spotStartOffset") }
        if defaults.object(forKey: "spotEndOffset") != nil { spotEndOffset = defaults.double(forKey: "spotEndOffset") }
        if defaults.object(forKey: "textOnly") != nil { textOnly = defaults.bool(forKey: "textOnly") }
        if defaults.object(forKey: "replayAfterJog") != nil { replayAfterJog = defaults.bool(forKey: "replayAfterJog") }
        if defaults.object(forKey: "replayAfterResize") != nil { replayAfterResize = defaults.bool(forKey: "replayAfterResize") }
        if defaults.object(forKey: "autoLineBreaks") != nil { autoLineBreaks = defaults.bool(forKey: "autoLineBreaks") }
        loadRecentProjects()
        doc.playheadTime = { [weak self] in self?.clock.time ?? 0 }
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

    /// Frames per second: the project's setting, or the video's own.
    var fps: Double { project?.settings.frameRate ?? engine.frameRate }
    var frameDuration: Double { 1 / max(1, fps) }
    var minGap: Double { Double(preset.minGapFrames) * frameDuration }
    var hasMedia: Bool { videoURL != nil }

    /// The project's standard, with the focused language's own overrides.
    var preset: TimingPreset {
        let base = project?.settings.standard ?? .general
        return focusedTrack?.standard(from: base) ?? base
    }

    func preset(for track: Track) -> TimingPreset {
        track.standard(from: project?.settings.standard ?? .general)
    }

    /// A time as shown in the app: frames or milliseconds, plus the project's start timecode.
    func tc(_ t: Double) -> String {
        let shown = t + (project?.settings.startTimecode ?? 0)
        return project?.settings.timecodeDisplay == .milliseconds ? Timecode.srt(shown) : Timecode.frames(shown, fps: fps)
    }

    var windowTitle: String {
        guard let project else { return "KPTN.SUB" }
        if let video, project.videos.count > 1 { return "\(project.name) — \(video.name)" }
        return project.name
    }

    // MARK: Files

    /// Loads a video into the player (the project decides which).
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
                if !url.isFileURL { flash("Streaming: the waveform appears once the audio has been read.") }
            } catch {
                showError("Couldn't open \(url.lastPathComponent)", error.localizedDescription)
            }
        }
    }

    // MARK: iCloud and errors

    /// Name of the file waiting on iCloud or opening (shown in the title bar and on the home screen).
    @Published var loadingName: String?
    @Published private(set) var isDownloadingFromICloud = false
    private var iCloudWaits: [URL: Task<Void, Never>] = [:]

    private enum LocalState: Sendable { case local, inCloud }

    /// Makes sure a file is on this Mac before it's opened, downloading it from iCloud Drive
    /// if it's only in the cloud. Every iCloud query and download request runs off the main
    /// thread with a timeout: iCloud can stall on a cloud-only file, and the app must stay usable.
    func ensureLocal(_ url: URL, then completion: @escaping (URL) -> Void) {
        guard url.isFileURL else { completion(url); return }
        // Fast path: a file whose contents are on this Mac opens straight away, without asking iCloud.
        if !ProjectStore.isDataless(url) { completion(url); return }
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
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) -> Task<T, Never> {
        Task.detached {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
            }
        }
    }

    /// The task's result, or nil if it takes longer than `timeout` (the task keeps running).
    static func value<T: Sendable>(of task: Task<T, Never>, timeout: Double) async -> T? {
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
        addVideo(url)
    }

    /// Reads a subtitle file off the main thread, so a slow disk or iCloud can't freeze the app.
    func readSubtitleFile(_ url: URL, then completion: @escaping ([Subtitle]) -> Void) {
        ensureLocal(url) { [weak self] local in
            guard let self else { return }
            self.loadingName = local.lastPathComponent
            let reading = Self.offMain { () -> Result<[Subtitle], SubtitleReadError> in
                do { return .success(try SubtitleFormats.read(url: local)) }
                catch { return .failure(SubtitleReadError(message: error.localizedDescription)) }
            }
            Task {
                let result = await reading.value
                if self.loadingName == local.lastPathComponent { self.loadingName = nil }
                switch result {
                case .success(let subs): completion(subs)
                case .failure(let error): self.showError("Couldn't read \(local.lastPathComponent)", error.message)
                }
            }
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
        // While spotting, the waveform draws the growing box straight from the playhead
        // (see liveSpotEnd), so the document isn't rewritten 60 times a second.
    }

    /// While a title is being spotted: where its box currently ends, exactly at the playhead.
    func liveSpotEnd(for id: UUID) -> Double? {
        guard id == spottingID, let s = doc.subtitle(id) else { return nil }
        return max(s.end, clock.time)
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

    /// False in the automated tests, so they never write a project, a backup or the list of
    /// recent projects on the Mac they run on.
    var persists = true

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

    /// Something to type into: a selected title, or a selected empty slot.
    var hasTypingTarget: Bool { doc.selectedID != nil || emptySlotRow != nil }

    /// Typing while a title is selected (and nothing is being edited) starts editing it.
    /// On an empty slot, it creates the title there first.
    func typeIntoSelected(_ characters: String) {
        if doc.selectedID == nil, let key = emptySlotRow {
            createInRow(key, text: characters)
            return
        }
        guard let id = doc.selectedID, let s = doc.subtitle(id) else { return }
        doc.setText(id, s.text + characters)
        focusRequest = id
    }

    /// Return: edit the selected title, or create one in the selected empty slot.
    func editSelected() {
        if doc.selectedID == nil, let key = emptySlotRow { createInRow(key); return }
        if let id = doc.selectedID { focusRequest = id }
    }

    /// Tab / Shift-Tab, ↑ / ↓: the next or previous title in the focused language, with the
    /// playhead at its start. Rows where only another language has a title are skipped
    /// (click an empty slot to add one there). With a group selected, the group is let go
    /// and the title after its last one (or before its first) is selected.
    func selectAdjacent(_ delta: Int, keepEditing: Bool = false) {
        guard !rows.isEmpty, let track = focusedTrack else { return }
        if !multiSelection.isEmpty {
            let group = doc.subtitles.filter { multiSelection.contains($0.id) }
            multiSelection = []
            if let edge = delta > 0 ? group.last : group.first { doc.selectedID = edge.id }
            bump()
        }
        let i: Int
        if let cur = currentRowIndex {
            i = cur
        } else {
            // Nothing selected (playhead in a gap): step from the playhead's position.
            let t = clock.time
            let k = rows.lastIndex(where: { $0.time <= t }) ?? -1
            i = delta > 0 ? k : k + 1
        }
        let step = delta > 0 ? 1 : -1
        var j = i + step
        while j >= 0 && j < rows.count && rows[j].cells[track.id] == nil { j += step }
        guard j >= 0 && j < rows.count, let s = rows[j].cells[track.id] else { return }
        if engine.isPlaying { engine.pause() }
        emptySlotRow = nil
        select(s.id, seekToStart: true)
        if keepEditing { focusRequest = s.id }
    }

    var focusedIsLocked: Bool { focusedTrack?.locked ?? false }

    /// Locked languages keep the master's timing: only their text can change.
    func refuseIfLocked() -> Bool {
        guard focusedIsLocked else { return false }
        flash("\(focusedTrack?.language.name ?? "This language") is locked to the master: only its text can change.")
        return true
    }

    func deleteSelected() {
        guard let id = doc.selectedID, !refuseIfLocked() else { return }
        doc.delete(id)
    }

    /// Creates a title (used by click-drag) and opens its card for typing.
    /// In a translation, it's linked to the master title it overlaps.
    func createTitle(start: Double, end: Double) {
        guard !refuseIfLocked() else { return }
        let id = doc.add(start: start, end: end, link: autoLink(start: start, end: end))
        focusRequest = id
    }

    /// Plays one title from its start to its end.
    func playTitle(_ id: UUID) {
        guard let s = doc.subtitle(id) else { return }
        playRange(from: s.start, to: s.end)
    }

    // MARK: Fine-tuning (shared by jog, wheel, trackpad and nudge keys)

    /// Moves one edge. With `clamp`, the edge stops at the neighbouring title minus the minimum gap.
    /// Must be called between `doc.beginLive()` and `doc.commitLive()`.
    @discardableResult
    func moveEdge(_ edge: Edge, of id: UUID, to t: Double, clamp: Bool) -> Double? {
        guard !focusedIsLocked, let s = doc.subtitle(id) else { return nil }
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
    enum ReplayAfter { case jog, resize }

    func preview(_ edge: Edge, of id: UUID, after kind: ReplayAfter = .jog) {
        // Either edge: play the whole title, from 1 s before it starts to just after it ends.
        // Each kind of adjustment can be switched off in the Title menu.
        guard kind == .jog ? replayAfterJog : replayAfterResize else { return }
        guard hasMedia, let s = doc.subtitle(id) else { return }
        playRange(from: max(0, s.start - 1), to: s.end + 0.25)
    }

    /// Short, automatic playbacks (previews). Selection doesn't follow the playhead
    /// during these, so the title being worked on stays selected.
    private var previewUntil: Double?
    var isPreviewing: Bool { previewUntil != nil }
    func previewUntilReset() { previewUntil = nil }

    func playRange(from: Double, to: Double) {
        guard hasMedia else { return }
        previewUntil = to
        engine.play(from: from, to: to)
    }

    /// Keyboard, wheel and trackpad nudges: frame steps, coalesced into one undo
    /// step, previewed once the input pauses.
    func nudge(_ edge: Edge, frames: Int) {
        nudge(edge, by: Double(frames) * frameDuration)
    }

    /// Moves an edge by a number of jog steps (a frame, or a few milliseconds).
    func nudge(_ edge: Edge, steps: Int, of step: JogStep) {
        nudge(edge, by: Double(steps) * step.seconds(frame: frameDuration))
    }

    func nudge(_ edge: Edge, by seconds: Double) {
        guard let id = doc.selectedID, let s = doc.subtitle(id), !refuseIfLocked() else { return }
        doc.beginLive()
        let current = edge == .start ? s.start : s.end
        if let t = moveEdge(edge, of: id, to: current + seconds, clamp: true) {
            scrubTo(t)
        }
        nudgeEdge = edge
        pendingPreview = nil
        nudgeCommit?.cancel()
        nudgeCommit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.doc.commitLive()
            guard let e = self.nudgeEdge else { return }
            // Still holding Control or Option: you're not done yet. Play when they're let go.
            if !NSEvent.modifierFlags.intersection([.control, .option]).isEmpty {
                self.pendingPreview = (e, id)
            } else {
                self.preview(e, of: id)
            }
        }
    }

    /// Called when Control and Option are both up.
    func modifiersReleased() {
        guard let p = pendingPreview else { return }
        pendingPreview = nil
        preview(p.edge, of: p.id)
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
        guard hasMedia, engine.isPlaying, !refuseIfLocked() else { return }
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
        // Bring the new card into view once its row exists (rows rebuild just after).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            self?.cardScrollTarget = s.id
        }
    }

    /// The running length of the title being spotted, and its colour by the standard's
    /// duration limits: under the minimum, fine, nearing the maximum, over it.
    func spotTimer() -> (text: String, status: SpotTimerStatus)? {
        guard let id = spottingID, let s = doc.subtitle(id), let end = liveSpotEnd(for: id) else { return nil }
        let d = max(0, end - s.start)
        let ms = Int((d * 1000).rounded())
        let text = String(format: "%02d:%03d", ms / 1000, ms % 1000)
        let p = preset
        let status: SpotTimerStatus
        if d < p.minDuration { status = .short }
        else if d > p.maxDuration { status = .over }
        else if d > p.maxDuration * 0.85 { status = .near }
        else { status = .ok }
        return (text, status)
    }

    /// Hold mode: key up. Tap mode: "end, leave a gap".
    func spotUp(eventTimestamp: TimeInterval? = nil) {
        finishSpotting(at: spotTime(eventTimestamp: eventTimestamp, offset: spotEndOffset))
    }

    // MARK: Splitting

    /// Splits a title at `t`, leaving the minimum gap (half each side of the split point).
    /// The text is divided at the line break or word nearest the split.
    func splitTitle(_ id: UUID, at t: Double) {
        guard let s = doc.subtitle(id), !refuseIfLocked() else { return }
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
            let end = max(s.start + 0.3, t)
            let link = autoLink(start: s.start, end: end)
            doc.liveUpdate(id) { $0.end = end; $0.link = link }
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

enum SpotTimerStatus { case short, ok, near, over }

/// How far one jog step moves a title edge.
enum JogStep: String, CaseIterable, Identifiable {
    case frame, ms10, ms5, ms1
    var id: String { rawValue }
    var title: String {
        switch self {
        case .frame: return "1 frame"
        case .ms10: return "10 ms"
        case .ms5: return "5 ms"
        case .ms1: return "1 ms"
        }
    }
    func seconds(frame: Double) -> Double {
        switch self {
        case .frame: return frame
        case .ms10: return 0.010
        case .ms5: return 0.005
        case .ms1: return 0.001
        }
    }
}

extension AppModel {
    func setWaveBand(_ id: UUID, shown: Bool) {
        if shown {
            waveBands.insert(id)
            // The language you're on stays a band too. Otherwise it would fold back to a
            // slim lane the moment you click into the one you just opened.
            if let focused = video?.focusedTrackID { waveBands.insert(focused) }
        } else {
            waveBands.remove(id)
        }
        bump()
    }

    /// Every open language as a full band on the waveform, or only the focused one.
    var allWaveBands: Bool {
        get { openTracks.count > 1 && openTracks.allSatisfy { $0.id == video?.focusedTrackID || waveBands.contains($0.id) } }
        set {
            if newValue { waveBands.formUnion(openTracks.map(\.id)) } else { waveBands.subtract(openTracks.map(\.id)) }
            bump()
        }
    }
}
