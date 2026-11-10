import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine

/// The dialogs the editor can show.
enum SheetKind: Identifiable, Equatable {
    case newProject, projectSettings, newLanguage, importLanguage, export, openLink, shiftTitles
    var id: Self { self }
}

/// Projects, videos, languages, focus and saving.
extension AppModel {

    // MARK: Focus

    var focusedTrack: Track? { video?.track(video?.focusedTrackID) }
    var masterTrack: Track? { video?.master }
    var openTracks: [Track] { video?.openTracks ?? [] }

    /// The row holding the selected title, or the selected empty slot.
    var currentRowIndex: Int? {
        if let id = doc.selectedID, let i = rowOfSub[id] { return i }
        if let key = emptySlotRow { return rows.firstIndex { $0.key == key } }
        return nil
    }

    var selectedRowKey: UUID? { currentRowIndex.map { rows[$0].key } }

    func rowKey(ofSub id: UUID) -> UUID? { rowOfSub[id].map { rows[$0].key } }

    /// The 1-based row number shown on cards and waveform boxes.
    /// Each language is numbered on its own, in time order.
    func rowNumber(of id: UUID) -> Int? { numberOfSub[id] }

    /// Moves focus to a language, staying on the same row. Typing carries on in the new column.
    func focusTrack(_ id: UUID, edit: Bool? = nil) {
        guard let video, let track = video.track(id), video.openTrackIDs.contains(id) else { return }
        if track.id != focusedTrack?.id { multiSelection = [] }
        let wasEditing = edit ?? (mainWindow?.firstResponder is NSTextView)
        let rowKey = selectedRowKey
        finishGesture()
        video.focusedTrackID = id
        doc = track.doc
        if let rowKey, let i = rows.firstIndex(where: { $0.key == rowKey }) {
            if let s = rows[i].cells[id] {
                emptySlotRow = nil
                track.doc.selectedID = s.id
                if wasEditing { focusRequest = s.id }
            } else {
                track.doc.selectedID = nil
                emptySlotRow = rowKey
                if wasEditing { mainWindow?.makeFirstResponder(nil) }
            }
            cardScrollTarget = rowKey
        }
        bump()
    }

    /// ⌘L / ⇧⌘L: the next / previous open language, wrapping around.
    func focusAdjacentTrack(_ delta: Int) {
        guard let video, let current = video.focusedTrackID,
              let i = video.openTrackIDs.firstIndex(of: current), video.openTrackIDs.count > 1 else { return }
        let n = video.openTrackIDs.count
        focusTrack(video.openTrackIDs[((i + delta) % n + n) % n])
    }

    /// ⌘1–⌘9.
    func focusTrack(atColumn index: Int) {
        guard let video, video.openTrackIDs.indices.contains(index) else { return }
        focusTrack(video.openTrackIDs[index])
    }

    private func finishGesture() {
        if isSpotting { spotUp() }
        doc.commitLive()
    }

    // MARK: Rows, links and change tracking

    /// Hooks a language's titles into rows, locks, undo and autosave.
    func attach(_ track: Track) {
        track.doc.playheadTime = { [weak self] in self?.clock.time ?? 0 }
        track.doc.onChange = { [weak self, weak track] in
            guard let self, let track else { return }
            self.trackChanged(track)
        }
        track.doc.onUndoStep = { [weak self, weak track] in
            guard let self, let track else { return }
            self.undoOrder.append(track.id)
            self.redoOrder.removeAll()
        }
        let watcher = track.doc.$selectedID.sink { [weak self] id in
            if id != nil { self?.emptySlotRow = nil }
        }
        selectionWatchers.append(watcher)
    }

    private func trackChanged(_ track: Track) {
        if let video, !isSyncingLocks, track.id == video.masterTrackID || track.locked {
            enforceLocks(in: video)
        }
        scheduleRefresh()
        scheduleAutosave()
    }

    /// Rebuilds the rows on the next run-loop turn (once, however many changes came in).
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.rebuildRows()
        }
    }

    func rebuildRows() {
        guard let video else { rows = []; rowOfSub = [:]; bump(); return }
        let built = RowBuilder.rows(for: video, tracks: video.openTracks)
        var map: [UUID: Int] = [:]
        for (i, row) in built.enumerated() { for s in row.cells.values { map[s.id] = i } }
        rowOfSub = map
        var numbers: [UUID: Int] = [:]
        for track in video.tracks {
            for (i, s) in track.doc.subtitles.sorted(by: { $0.start < $1.start }).enumerated() { numbers[s.id] = i + 1 }
        }
        numberOfSub = numbers
        if built != rows { rows = built }
        if let key = emptySlotRow, !built.contains(where: { $0.key == key }) { emptySlotRow = nil }
        updateCardColumnWidth()
        bump()
    }

    func bump() { revision &+= 1 }

    /// The width a card column needs to show every title's lines at full size, as over the
    /// picture: the widest line plus the card's padding (240 to 440 points). Used when the
    /// pane opens; narrower than this, the text shrinks to keep the same lines.
    func updateCardColumnWidth() {
        var longest: [String] = []
        for track in openTracks {
            for s in track.doc.subtitles {
                for line in Markup.plain(s.text).split(separator: "\n") where line.count > 20 {
                    longest.append(String(line))
                }
            }
        }
        // Measure only the longest lines by character count; the widest is among them.
        let font = NSFont.systemFont(ofSize: CardView.baseFontSize, weight: .medium)
        let widest = longest.sorted { $0.count > $1.count }.prefix(40)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let width = min(440, max(240, ceil(widest) + 44))
        if abs(width - cardColumnMinWidth) > 0.5 { cardColumnMinWidth = width }
    }

    /// The narrowest a column gets: where the widest line has shrunk to half size.
    var cardColumnFloor: CGFloat { max(150, ((cardColumnMinWidth - 44) * 0.5 + 44).rounded()) }

    /// The card pane can't be dragged narrower than its columns at their narrowest, so the
    /// columns always fit side by side and the scroll bar stays in view. The picture side
    /// (control bar and waveform) always keeps at least 620 points.
    var cardPaneMinWidth: CGFloat {
        let count = CGFloat(max(1, openTracks.count))
        let needed = count * cardColumnFloor + (count - 1) * 8 + 24
        guard let window = mainWindow?.contentView?.bounds.width, window > 0 else { return max(300, needed) }
        return max(300, min(needed, window - 640))
    }

    /// Locked languages always have exactly the master's titles and timings; text is kept by link.
    func enforceLocks(in video: VideoItem) {
        guard let master = video.master else { return }
        isSyncingLocks = true
        defer { isSyncingLocks = false }
        for track in video.tracks where track.locked && track.id != master.id {
            var byLink: [UUID: Subtitle] = [:]
            for s in track.doc.subtitles { if let l = s.link { byLink[l] = s } }
            let synced = master.doc.subtitles.map { m in
                Subtitle(id: byLink[m.id]?.id ?? UUID(), start: m.start, end: m.end,
                         text: byLink[m.id]?.text ?? "", link: m.id)
            }
            track.doc.syncReplace(synced)
        }
    }

    /// In a language other than the master: the master title a new title at this time belongs to,
    /// if that master title has no partner in this language yet.
    func autoLink(start: Double, end: Double) -> UUID? {
        guard let video, let track = focusedTrack, let master = video.master, track.id != master.id else { return nil }
        let taken = Set(track.doc.subtitles.compactMap(\.link))
        let probe = Subtitle(start: start, end: end)
        return RowBuilder.linkByOverlap([probe], master: master.doc.subtitles, skip: taken).first?.link
    }

    /// Double-clicking an empty slot (or typing / Return on it): creates a title there with the
    /// row's timing (the master's, or the first language present) and links it.
    func createInRow(_ key: UUID, text: String = "") {
        guard let video, let track = focusedTrack, !refuseIfLocked(),
              let row = rows.first(where: { $0.key == key }), row.cells[track.id] == nil else { return }
        let reference = row.cells[video.masterTrackID] ?? row.cells.values.sorted { $0.start < $1.start }.first
        guard let ref = reference else { return }
        let isMaster = track.id == video.masterTrackID
        let link: UUID? = isMaster ? nil : row.cells[video.masterTrackID]?.id
        let id = doc.add(start: ref.start, end: ref.end, text: text, link: link)
        if isMaster {
            // The translations in this row now have a master title to belong to.
            for other in video.tracks where other.id != track.id {
                if let cell = row.cells[other.id], cell.link == nil || cell.link == row.key {
                    other.doc.syncReplace(other.doc.subtitles.map { s in
                        var s = s
                        if s.id == cell.id { s.link = id }
                        return s
                    })
                }
            }
        }
        emptySlotRow = nil
        focusRequest = id
    }

    // MARK: Undo across languages

    /// ⌘Z undoes the last change in whichever language it was made, and goes there.
    func undo() {
        doc.commitLive()
        while let id = undoOrder.popLast() {
            guard let track = video?.track(id), track.doc.canUndo else { continue }
            if video?.openTrackIDs.contains(id) == false { video?.openTrackIDs.append(id) }
            if focusedTrack?.id != id { focusTrack(id, edit: false) }
            let before = track.doc.subtitles
            track.doc.undo()
            redoOrder.append(id)
            revealChange(before: before, after: track.doc.subtitles)
            return
        }
        let before = doc.subtitles
        doc.undo()
        revealChange(before: before, after: doc.subtitles)
    }

    func redo() {
        doc.commitLive()
        while let id = redoOrder.popLast() {
            guard let track = video?.track(id), track.doc.canRedo else { continue }
            if video?.openTrackIDs.contains(id) == false { video?.openTrackIDs.append(id) }
            if focusedTrack?.id != id { focusTrack(id, edit: false) }
            let before = track.doc.subtitles
            track.doc.redo()
            undoOrder.append(id)
            revealChange(before: before, after: track.doc.subtitles)
            return
        }
        let before = doc.subtitles
        doc.redo()
        revealChange(before: before, after: doc.subtitles)
    }

    /// After undo or redo (while paused): take the playhead to what changed, so you see what
    /// the undo did. A title that came back or was retimed is selected at its start; when a
    /// title was removed, the playhead parks half a second before where it began.
    private func revealChange(before: [Subtitle], after: [Subtitle]) {
        guard !clock.isPlaying, hasMedia else { return }
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let touched = after.filter { old[$0.id] != $0 }
        let removed = before.filter { new[$0.id] == nil }
        if let first = touched.min(by: { $0.start < $1.start }),
           removed.allSatisfy({ $0.start >= first.start - 0.001 }) {
            doc.selectedID = first.id
            seek(first.start)
            cardScrollTarget = first.id
        } else if let gone = removed.min(by: { $0.start < $1.start }) {
            let t = max(0, gone.start - 0.5)
            doc.selectedID = nil
            seek(t)
            cardScrollTarget = after.last(where: { $0.start <= gone.start })?.id ?? after.first?.id
        }
    }

    // MARK: Creating and opening projects

    func createProject(name: String, folder: URL, video videoURL: URL?, settings: ProjectSettings,
                       subtitleFiles: [(url: URL, language: Language)] = [], extraLanguages: [Language] = []) {
        let clean = ProjectStore.sanitize(name).isEmpty ? "Untitled" : ProjectStore.sanitize(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            showError("Couldn't create the folder \(folder.lastPathComponent)", error.localizedDescription)
            return
        }
        var fileURL = folder.appendingPathComponent("\(clean).\(ProjectStore.fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = folder.appendingPathComponent("\(clean) \(n).\(ProjectStore.fileExtension)")
            n += 1
        }
        let master = Track(language: settings.masterLanguage)
        let item = VideoItem(name: videoURL.map { $0.deletingPathExtension().lastPathComponent } ?? "Video 1",
                             url: videoURL, master: master)
        let project = Project(name: clean, settings: settings, videos: [item], fileURL: fileURL)
        load(project, currentVideoID: item.id)
        saveProject()
        // The file in the master language fills the master first; every other file then
        // becomes its own language, matched to the master by time. Languages asked for
        // without a file start blank from the master's timing.
        let masterFile = subtitleFiles.first { $0.language == settings.masterLanguage }
        let others = subtitleFiles.filter { $0.url != masterFile?.url }
        let covered = Set(subtitleFiles.map(\.language) + [settings.masterLanguage])
        let extras = extraLanguages.filter { !covered.contains($0) }
        // If another project is opened while the files are still being read, stop: the
        // remaining files must not land in that other project.
        let projectID = project.id
        let finish: () -> Void = { [weak self] in
            guard let self, self.project?.id == projectID else { return }
            self.importFiles(others, into: projectID) { [weak self] in
                guard let self, self.project?.id == projectID else { return }
                for lang in extras { self.addLanguage(lang, locked: false, copyText: false) }
                self.focusTrack(master.id, edit: false)
                self.saveProject()
                if subtitleFiles.count > 1 { self.flash("Imported \(subtitleFiles.count) subtitle files") }
            }
        }
        if let masterFile {
            readSubtitleFile(masterFile.url) { [weak self] subs in
                guard self?.project?.id == projectID else { return }
                master.doc.replaceAll(subs)
                master.doc.selectedID = nil
                self?.rebuildRows()
                self?.flash("Loaded \(subs.count) titles into \(master.language.name)")
                finish()
            }
        } else {
            finish()
        }
    }

    /// Imports subtitle files one after another (each matched to the master by time).
    private func importFiles(_ files: [(url: URL, language: Language)], into projectID: UUID,
                             then done: @escaping () -> Void) {
        guard project?.id == projectID else { return }
        guard let first = files.first else { done(); return }
        importLanguage(from: first.url, as: first.language) { [weak self] in
            self?.importFiles(Array(files.dropFirst()), into: projectID, then: done)
        }
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectStore.fileExtension) ?? .json]
        panel.allowsMultipleSelection = false
        panel.directoryURL = ProjectStore.defaultProjectsFolder
        panel.roomy()
        if panel.runModal() == .OK, let url = panel.url { openProject(at: url, knownID: nil) }
    }

    func openRecent(_ recent: RecentProject) {
        if let path = recent.path {
            openProject(at: URL(fileURLWithPath: path), knownID: recent.id)
        } else if let local = ProjectStore.readLocalCopy(recent.id) {
            load(Project(local, fileURL: nil), currentVideoID: local.currentVideoID)
        }
    }

    /// Opens a project without ever blocking on iCloud: the original is read off the main thread
    /// with a timeout, and the local working copy is used when the original can't be reached.
    func openProject(at url: URL, knownID: UUID?) {
        guard confirmLeaveCurrentProject() else { return }
        loadingName = url.lastPathComponent
        let dataless = ProjectStore.isDataless(url)
        let known = knownID ?? recentProjects.first { $0.path == url.path }?.id
        Task {
            var original: ProjectFile?
            if !dataless {
                let reading = Self.offMain { () -> ProjectFile? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? ProjectStore.decode(data)
                }
                original = (await Self.value(of: reading, timeout: 8)) ?? nil
            }
            loadingName = nil
            let local = (known ?? original?.id).flatMap(ProjectStore.readLocalCopy)
            var chosen: ProjectFile?
            var note: String?
            switch (original, local) {
            case let (o?, l?):
                if l.modified.timeIntervalSince(o.modified) > 1 {
                    chosen = l
                    note = "Opened your local copy, which is newer than \(url.lastPathComponent). It will be saved back there."
                } else if o.modified.timeIntervalSince(l.modified) > 1, !sameContent(o, l) {
                    chosen = askWhichVersion(original: o, local: l, name: url.lastPathComponent)
                } else {
                    chosen = o
                }
            case let (o?, nil):
                chosen = o
            case let (nil, l?):
                chosen = l
                note = "\(url.lastPathComponent) is in iCloud and hasn't downloaded, so you're working from the local copy on this Mac. Your changes are safe and will be saved back once iCloud delivers the file."
                _ = Self.offMain { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
            case (nil, nil):
                if dataless {
                    ensureLocal(url) { [weak self] local in self?.openProject(at: local, knownID: known) }
                } else {
                    showError("Couldn't open \(url.lastPathComponent)",
                              "It isn't a KPTN.SUB project, or it couldn't be read.")
                }
                return
            }
            guard let file = chosen else { return }
            load(Project(file, fileURL: url), currentVideoID: file.currentVideoID)
            banner = note
        }
    }

    private func sameContent(_ a: ProjectFile, _ b: ProjectFile) -> Bool {
        var a = a, b = b
        a.modified = .distantPast
        b.modified = .distantPast
        return (try? ProjectStore.encode(a)) == (try? ProjectStore.encode(b))
    }

    private func askWhichVersion(original: ProjectFile, local: ProjectFile, name: String) -> ProjectFile {
        let alert = NSAlert()
        alert.messageText = "\(name) changed somewhere else"
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        alert.informativeText = "The file was saved \(f.string(from: original.modified)), after your last change on this Mac (\(f.string(from: local.modified))). Which version do you want?"
        alert.addButton(withTitle: "Use the File's Version")
        alert.addButton(withTitle: "Keep My Version")
        return alert.runModal() == .alertFirstButtonReturn ? original : local
    }

    /// Shows a project in the editor.
    /// `saveCurrent: false` when the open project is being thrown away on purpose (reload,
    /// restore), so it isn't written over the file that's about to be loaded.
    func load(_ project: Project, currentVideoID: UUID?, saveCurrent: Bool = true) {
        closeProject(save: saveCurrent)
        self.project = project
        for v in project.videos { v.tracks.forEach(attach) }
        showHome = false
        rememberProject()
        if let v = project.video(currentVideoID) ?? project.videos.first { switchVideo(v) }
    }

    /// Saves and closes the current project (nothing is lost: projects autosave).
    func closeProject(save: Bool = true) {
        guard project != nil else { return }
        finishGesture()
        if save { saveProject() } else { autosaveTask?.cancel(); pendingOriginalWrite = nil }
        previewUntilReset()
        focusRequest = nil
        mainWindow?.makeFirstResponder(nil)
        engine.unload()
        clock.isPlaying = false
        clock.time = 0
        audio.clear()
        videoURL = nil
        selectionWatchers.removeAll()
        undoOrder.removeAll()
        redoOrder.removeAll()
        project = nil
        video = nil
        showProjectView = false
        multiSelection = []
        editingTimecode = false
        pendingPreview = nil
        doc = SubtitleDocument()
        rows = []
        rowOfSub = [:]
        emptySlotRow = nil
        banner = nil
    }

    func goHome() {
        guard !showHome else { return }
        closeProject()
        showHome = true
    }

    private func confirmLeaveCurrentProject() -> Bool {
        // Projects autosave, so leaving never loses work.
        true
    }

    // MARK: Saving

    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveProject()
        }
    }

    /// Writes the local copy straight away (always on this Mac), then the original off the
    /// main thread, so a stalled iCloud never freezes the app.
    /// `wait`: also write the project file before returning (quitting), instead of in the
    /// background.
    func saveProject(announce: Bool = false, wait: Bool = false) {
        guard let project else { return }
        autosaveTask?.cancel()
        guard persists else { return }
        let file = project.file(currentVideoID: video?.id)
        guard let data = try? ProjectStore.encode(file) else { return }
        do {
            try ProjectStore.writeLocalCopy(data, id: project.id)
        } catch {
            banner = "Couldn't save the local copy: \(error.localizedDescription)"
        }
        if Date().timeIntervalSince(lastBackup) > 300 {
            lastBackup = Date()
            ProjectStore.writeBackup(data, id: project.id)
        }
        for v in project.videos { v.tracks.forEach { $0.doc.markSaved() } }
        guard let url = project.fileURL else { return }
        if ProjectStore.isDataless(url) {
            banner = "\(url.lastPathComponent) is waiting on iCloud, so changes are being kept in the local copy on this Mac for now."
            return
        }
        if wait {
            // Quitting: nothing may be left for later. (A file waiting on iCloud was skipped above.)
            pendingOriginalWrite = nil
            try? data.write(to: url, options: .atomic)
            return
        }
        // One write at a time. A save that arrives meanwhile is kept and written next, so the
        // project file always ends up with the latest state.
        guard !originalWriteInFlight else {
            pendingOriginalWrite = (data, url)
            return
        }
        writeOriginal(data, to: url, announce: announce)
    }

    private func writeOriginal(_ data: Data, to url: URL, announce: Bool) {
        originalWriteInFlight = true
        let writing = Self.offMain { () -> String? in
            do { try data.write(to: url, options: .atomic); return nil }
            catch { return error.localizedDescription }
        }
        Task {
            let result = await Self.value(of: writing, timeout: 10)
            originalWriteInFlight = false
            if let next = pendingOriginalWrite {
                pendingOriginalWrite = nil
                writeOriginal(next.data, to: next.url, announce: false)
                return
            }
            switch result {
            case .some(nil):
                if banner?.contains("local copy") == true { banner = nil }
                if announce { flash("Saved \(url.lastPathComponent)") }
            case .some(let message?):
                banner = "Couldn't save \(url.lastPathComponent) (\(message)). Your work is safe in the local copy."
            case nil:
                banner = "Saving \(url.lastPathComponent) is taking a long time (iCloud?). Your work is safe in the local copy."
            }
        }
    }

    // MARK: Recent projects

    func loadRecentProjects() {
        if let data = UserDefaults.standard.data(forKey: "recentProjects"),
           let list = try? JSONDecoder().decode([RecentProject].self, from: data) { recentProjects = list }
    }

    private func rememberProject() {
        guard let project else { return }
        let entry = RecentProject(id: project.id, name: project.name, path: project.fileURL?.path, opened: Date(),
                                  videoCount: project.videos.count,
                                  languages: Array(Set(project.videos.flatMap { $0.tracks.map(\.language.code) })).sorted())
        recentProjects.removeAll { $0.id == project.id }
        recentProjects.insert(entry, at: 0)
        if recentProjects.count > 20 { recentProjects.removeLast(recentProjects.count - 20) }
        storeRecentProjects()
    }

    func removeRecent(_ recent: RecentProject) {
        recentProjects.removeAll { $0.id == recent.id }
        storeRecentProjects()
    }

    private func storeRecentProjects() {
        guard persists else { return }
        if let data = try? JSONEncoder().encode(recentProjects) {
            UserDefaults.standard.set(data, forKey: "recentProjects")
        }
    }

    // MARK: Videos

    func switchVideo(_ v: VideoItem) {
        guard project != nil else { return }
        finishGesture()
        if video != nil { saveProject() }
        undoOrder.removeAll()
        redoOrder.removeAll()
        video = v
        multiSelection = []
        let focused = v.track(v.focusedTrackID) ?? v.master ?? v.tracks.first
        if let focused {
            v.focusedTrackID = focused.id
            if !v.openTrackIDs.contains(focused.id) { v.openTrackIDs.insert(focused.id, at: 0) }
            doc = focused.doc
        }
        emptySlotRow = nil
        enforceLocks(in: v)
        rebuildRows()
        engine.unload()
        audio.clear()
        videoURL = nil
        clock.time = 0
        if let url = v.url {
            if let found = findMissingVideo(v) {
                if found != url { v.url = found; saveProject() }
                openVideo(found)
            }
        }
        rememberProject()
    }

    /// True when a video's file isn't on this Mac (a link never counts as missing).
    func videoFileMissing(_ v: VideoItem) -> Bool {
        guard let url = v.url, url.isFileURL else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    var currentVideoMissing: Bool { video.map(videoFileMissing) ?? false }

    /// The video's file, or a file of the same name next to the project (handy when a
    /// project and its video are copied to another Mac together). Nil when neither exists.
    func findMissingVideo(_ v: VideoItem) -> URL? {
        guard let url = v.url else { return nil }
        if !url.isFileURL || FileManager.default.fileExists(atPath: url.path) { return url }
        if let folder = project?.fileURL?.deletingLastPathComponent() {
            let candidate = folder.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Points a video at a different file (a new edit, or a moved or lost file). Keeps every title.
    func replaceVideo(_ v: VideoItem, with url: URL) {
        v.url = url
        if v.name.hasPrefix("Video ") { v.name = url.deletingPathExtension().lastPathComponent }
        if v === video { switchVideo(v) } else { bump() }
        saveProject()
    }

    func replaceVideoPanel(for v: VideoItem? = nil) {
        guard let target = v ?? video else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose the video file for \(target.name). Its titles stay as they are."
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .audio]
        panel.directoryURL = project?.fileURL?.deletingLastPathComponent()
        panel.roomy()
        if panel.runModal() == .OK, let url = panel.url { replaceVideo(target, with: url) }
    }

    func showProjectOverview() {
        guard project != nil else { return }
        finishGesture()
        if engine.isPlaying { engine.pause() }
        saveProject()
        showProjectView = true
    }

    func openVideoFromOverview(_ v: VideoItem) {
        showProjectView = false
        if v !== video { switchVideo(v) }
    }

    /// File ▸ Reload Project from File: re-reads the saved project file, ignoring this Mac's
    /// working copy. What's open now is kept as a backup first.
    func reloadProjectFromFile() {
        guard let project, let url = project.fileURL else {
            flash("This project has no project file to reload from.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Reload \(project.name) from its project file?"
        alert.informativeText = "What's open now is replaced by \(url.lastPathComponent). A backup of the current state is kept first (File ▸ Restore from Backup…)."
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let data = try? ProjectStore.encode(project.file(currentVideoID: video?.id)) {
            ProjectStore.writeBackup(data, id: project.id)
        }
        let current = video?.id
        ensureLocal(url) { [weak self] local in
            guard let self else { return }
            do {
                let data = try Data(contentsOf: local)
                let file = try ProjectStore.decode(data)
                self.load(Project(file, fileURL: url), currentVideoID: current ?? file.currentVideoID, saveCurrent: false)
                try? ProjectStore.writeLocalCopy(data, id: file.id)
                self.flash("Reloaded from \(url.lastPathComponent)")
            } catch {
                self.showError("Couldn't reload \(url.lastPathComponent)", error.localizedDescription)
            }
        }
    }

    /// File ▸ Restore from Backup…: picks one of the automatic backups and makes it the project.
    func restoreFromBackupPanel() {
        guard let project else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a backup of \(project.name). Newest backups have the latest dates in their names."
        panel.directoryURL = ProjectStore.backupFolder(project.id)
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectStore.fileExtension) ?? .json]
        panel.roomy()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let file = try ProjectStore.decode(data)
            if let current = try? ProjectStore.encode(project.file(currentVideoID: video?.id)) {
                ProjectStore.writeBackup(current, id: project.id)
            }
            let keepURL = project.fileURL
            load(Project(file, fileURL: keepURL), currentVideoID: video?.id ?? file.currentVideoID, saveCurrent: false)
            saveProject(announce: false)
            flash("Restored the backup from \(url.deletingPathExtension().lastPathComponent)")
        } catch {
            showError("Couldn't restore that backup", error.localizedDescription)
        }
    }

    func addVideoPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .audio]
        panel.allowsMultipleSelection = false
        panel.roomy()
        if panel.runModal() == .OK, let url = panel.url { addVideo(url) }
    }

    /// Adds a video (file or link) to the project, with an empty master language, and shows it.
    /// Without a project, starts a new one with this video.
    func addVideo(_ url: URL) {
        guard let project else {
            newProjectVideo = url
            sheet = .newProject
            return
        }
        // A video with no file yet takes this one.
        if let v = video, v.url == nil {
            v.url = url
            if v.name.hasPrefix("Video ") { v.name = url.deletingPathExtension().lastPathComponent }
            switchVideo(v)
            return
        }
        let master = Track(language: project.settings.masterLanguage)
        attach(master)
        let item = VideoItem(name: url.deletingPathExtension().lastPathComponent, url: url, master: master)
        project.videos.append(item)
        switchVideo(item)
        saveProject()
    }

    func renameVideo(_ v: VideoItem) {
        if let name = askForText("Rename video", value: v.name), !name.isEmpty {
            v.name = name
            bump()
            saveProject()
        }
    }

    func removeVideo(_ v: VideoItem) {
        guard let project, project.videos.count > 1 else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(v.name) from the project?"
        alert.informativeText = "Its titles in every language are removed too. The video file itself isn't touched. A backup of the project is kept in the KPTN.SUB backups folder."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let data = try? ProjectStore.encode(project.file(currentVideoID: video?.id)) {
            ProjectStore.writeBackup(data, id: project.id)
        }
        project.videos.removeAll { $0.id == v.id }
        if video?.id == v.id, let first = project.videos.first { switchVideo(first) }
        saveProject()
    }

    // MARK: Languages

    /// New Language from Master: the master's timecodes, blank (or with its text copied), free or locked.
    func addLanguage(_ language: Language, locked: Bool, copyText: Bool) {
        guard let video, let master = video.master else { return }
        let subs = master.doc.subtitles.map {
            Subtitle(start: $0.start, end: $0.end, text: copyText ? $0.text : "", link: $0.id)
        }
        let track = Track(language: language, locked: locked, subtitles: subs)
        attach(track)
        video.tracks.append(track)
        video.openTrackIDs.append(track.id)
        rebuildRows()
        focusTrack(track.id, edit: false)
        saveProject()
        flash("Added \(language.name): \(subs.count) titles from \(master.language.name)")
    }

    func importLanguagePanel() {
        let panel = NSOpenPanel()
        let types: [UTType?] = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt"), .plainText]
        panel.allowedContentTypes = types.compactMap { $0 }
        panel.roomy()
        if panel.runModal() == .OK, let url = panel.url {
            pendingImport = url
            sheet = .importLanguage
        }
    }

    /// Imports a subtitle file as a language. Into an empty language of the same kind it fills
    /// that language; otherwise it becomes a new, free language, linked to the master by time.
    func importLanguage(from url: URL, as language: Language, then done: (() -> Void)? = nil) {
        readSubtitleFile(url) { [weak self] subs in
            defer { done?() }
            guard let self, let video = self.video else { return }
            let empty = video.tracks.first { $0.language == language && $0.doc.subtitles.isEmpty }
            let isMaster = empty?.id == video.masterTrackID
            let master = video.master?.doc.subtitles ?? []
            let linked = isMaster ? subs : RowBuilder.linkByOverlap(subs, master: master)
            let track: Track
            if let empty {
                track = empty
                track.locked = false
                track.doc.replaceAll(linked)
            } else {
                track = Track(language: language, subtitles: linked)
                self.attach(track)
                video.tracks.append(track)
            }
            track.doc.selectedID = nil
            if !video.openTrackIDs.contains(track.id) { video.openTrackIDs.append(track.id) }
            if isMaster { self.enforceLocks(in: video) }
            self.rebuildRows()
            self.focusTrack(track.id, edit: false)
            self.saveProject()
            let matched = linked.filter { $0.link != nil }.count
            self.flash(isMaster ? "Loaded \(subs.count) titles into \(language.name)"
                                : "Imported \(subs.count) \(language.name) titles; \(matched) matched to the master")
        }
    }

    func setLocked(_ track: Track, _ locked: Bool) {
        guard let video, track.id != video.masterTrackID, track.locked != locked else { return }
        if locked {
            let unlinked = track.doc.subtitles.filter { s in
                s.link == nil || !(video.master?.doc.subtitles.contains { $0.id == s.link } ?? false)
            }
            let alert = NSAlert()
            alert.messageText = "Lock \(track.language.name) to \(video.master?.language.name ?? "the master")?"
            alert.informativeText = "Its titles take the master's timings exactly, and only text can be edited."
                + (unlinked.isEmpty ? "" : " \(unlinked.count) titles with no partner in the master will be removed (a backup is kept).")
            alert.addButton(withTitle: "Lock")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if !unlinked.isEmpty, let project, let data = try? ProjectStore.encode(project.file(currentVideoID: video.id)) {
                ProjectStore.writeBackup(data, id: project.id)
            }
        }
        track.locked = locked
        enforceLocks(in: video)
        rebuildRows()
        saveProject()
    }

    /// Makes another language the master, re-pointing every link so rows stay together.
    func setMaster(_ track: Track) {
        guard let video, let old = video.master, old.id != track.id else { return }
        // Old master title → new master title, from the new master's links.
        var map: [UUID: UUID] = [:]
        for s in track.doc.subtitles { if let l = s.link { map[l] = s.id } }
        isSyncingLocks = true
        track.locked = false
        track.doc.syncReplace(track.doc.subtitles.map { var s = $0; s.link = nil; return s })
        old.doc.syncReplace(old.doc.subtitles.map { var s = $0; s.link = map[s.id]; return s })
        for other in video.tracks where other.id != track.id && other.id != old.id {
            other.doc.syncReplace(other.doc.subtitles.map { var s = $0; s.link = s.link.flatMap { map[$0] }; return s })
        }
        isSyncingLocks = false
        video.masterTrackID = track.id
        enforceLocks(in: video)
        rebuildRows()
        saveProject()
        flash("\(track.language.name) is now the master")
    }

    func closeColumn(_ track: Track) {
        guard let video, video.openTrackIDs.count > 1, let i = video.openTrackIDs.firstIndex(of: track.id) else { return }
        let wasFocused = video.focusedTrackID == track.id
        video.openTrackIDs.remove(at: i)
        if wasFocused { focusTrack(video.openTrackIDs[max(0, i - 1)], edit: false) }
        rebuildRows()
        saveProject()
    }

    func openColumn(_ track: Track) {
        guard let video, !video.openTrackIDs.contains(track.id) else { return }
        video.openTrackIDs.append(track.id)
        rebuildRows()
        focusTrack(track.id, edit: false)
        saveProject()
    }

    func moveColumn(_ track: Track, by delta: Int) {
        guard let video, let i = video.openTrackIDs.firstIndex(of: track.id) else { return }
        let j = i + delta
        guard video.openTrackIDs.indices.contains(j) else { return }
        video.openTrackIDs.swapAt(i, j)
        bump()
        saveProject()
    }

    func deleteLanguage(_ track: Track) {
        guard let video, let project, track.id != video.masterTrackID else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(track.language.name) from \(video.name)?"
        alert.informativeText = "Its \(track.doc.subtitles.count) titles are removed. A backup of the project is kept in the KPTN.SUB backups folder."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let data = try? ProjectStore.encode(project.file(currentVideoID: video.id)) {
            ProjectStore.writeBackup(data, id: project.id)
        }
        if video.focusedTrackID == track.id { focusTrack(video.masterTrackID, edit: false) }
        video.tracks.removeAll { $0.id == track.id }
        video.openTrackIDs.removeAll { $0 == track.id }
        undoOrder.removeAll { $0 == track.id }
        redoOrder.removeAll { $0 == track.id }
        rebuildRows()
        saveProject()
    }

    func setOverrides(_ track: Track, maxCPS: Double?? = nil, maxChars: Int?? = nil) {
        if let maxCPS { track.maxCPS = maxCPS }
        if let maxChars { track.maxCharsPerLine = maxChars }
        bump()
        saveProject()
    }

    func applySettings(_ settings: ProjectSettings, name: String) {
        guard let project else { return }
        project.settings = settings
        if !name.isEmpty { project.name = name }
        rememberProject()
        bump()
        saveProject()
    }

    // MARK: Export

    struct ExportItem { let name: String; let data: Data }

    func exportItems(allLanguages: Bool, allVideos: Bool, format: ExportFormat) -> [ExportItem] {
        guard let project, let video else { return [] }
        let s = project.settings
        let videos = allVideos ? project.videos : [video]
        var items: [ExportItem] = []
        for v in videos {
            let tracks = allLanguages ? v.tracks : [v.track(v.focusedTrackID) ?? v.tracks[0]]
            for t in tracks where !t.doc.subtitles.isEmpty || !allLanguages {
                let base = s.namingPattern
                    .replacingOccurrences(of: "{video}", with: ProjectStore.sanitize(v.name))
                    .replacingOccurrences(of: "{lang}", with: t.language.code)
                    .replacingOccurrences(of: "{project}", with: ProjectStore.sanitize(project.name))
                let data = SubtitleFormats.data(t.doc.subtitles, format: format, bom: s.utf8BOM, crlf: s.crlf)
                items.append(ExportItem(name: "\(base).\(format.rawValue)", data: data))
            }
        }
        return items
    }

    /// Writes the files: a save panel for one file, a folder choice for several.
    func runExport(allLanguages: Bool, allVideos: Bool, format: ExportFormat) {
        let items = exportItems(allLanguages: allLanguages, allVideos: allVideos, format: format)
        guard !items.isEmpty else { flash("Nothing to export yet."); return }
        if items.count == 1 {
            let panel = NSSavePanel()
            panel.title = "Export Subtitles"
            panel.prompt = "Export"
            panel.allowedContentTypes = [format.type]
            panel.nameFieldStringValue = items[0].name
            panel.roomy()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            write(items[0].data, to: url)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Export \(items.count) Files"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.roomy()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let existing = items.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.name).path) }
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace \(existing.count) existing file\(existing.count == 1 ? "" : "s")?"
            alert.informativeText = existing.prefix(6).map(\.name).joined(separator: "\n")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var written = 0
        for item in items where write(item.data, to: folder.appendingPathComponent(item.name), quiet: true) { written += 1 }
        flash("Exported \(written) file\(written == 1 ? "" : "s") to \(folder.lastPathComponent)")
    }

    @discardableResult
    private func write(_ data: Data, to url: URL, quiet: Bool = false) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            if !quiet { flash("Exported \(url.lastPathComponent)") }
            return true
        } catch {
            showError("Couldn't save \(url.lastPathComponent)", error.localizedDescription)
            return false
        }
    }

    // MARK: Drag and drop

    func handleDrop(_ urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == ProjectStore.fileExtension {
                openProject(at: url, knownID: nil)
            } else if ["srt", "vtt"].contains(ext) {
                guard project != nil else {
                    flash("Create or open a project first, then drop the subtitle file to import it.")
                    continue
                }
                pendingImport = url
                sheet = .importLanguage
            } else if url.isFileURL, ["mkv", "webm", "avi", "wmv", "flv", "ogv"].contains(ext) {
                flash("\(url.lastPathComponent) can't be played by this build yet. MP4, MOV and M4V can.")
            } else if url.isFileURL, !(UTType(filenameExtension: ext)?.conforms(to: .audiovisualContent) ?? false) {
                flash("\(url.lastPathComponent) isn't a video, a subtitle file or a project.")
            } else if project == nil || showProjectView {
                addVideo(url)
            } else if let v = video {
                // In the editor a dropped video replaces this one's file (new videos are
                // added from the project view).
                let alert = NSAlert()
                alert.messageText = "Use \(url.lastPathComponent) for \(v.name)?"
                alert.informativeText = "The video file is replaced and every title is kept. To add another video to the project, use the project view (PROJECT in the top strip)."
                alert.addButton(withTitle: "Replace Video")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { replaceVideo(v, with: url) }
            }
        }
    }

    // MARK: Small helpers

    func askForText(_ title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespaces) : nil
    }
}

// MARK: Line breaks

extension AppModel {
    /// After typing in a card: if the title is too long for one line and has no line break
    /// of yours, break it by the style-guide rules. Your own breaks are never touched.
    /// `rebalance`: the lines were wrapped for you while typing; even them out now.
    func autoBreak(_ id: UUID, rebalance: Bool = false) {
        guard autoLineBreaks, let track = video?.tracks.first(where: { $0.doc.subtitle(id) != nil }),
              let sub = track.doc.subtitle(id) else { return }
        guard rebalance || !sub.text.contains("\n") else { return }
        let rules = preset(for: track)
        guard rebalance || Markup.plain(sub.text).count > rules.maxCharsPerLine else { return }
        let broken = LineBreaker.breakLines(sub.text, maxChars: rules.maxCharsPerLine,
                                            maxLines: rules.maxLines, language: track.language.code)
        if broken != sub.text { track.doc.setText(id, broken) }
    }

    /// While typing: as soon as a line runs past the limit, the title is broken again by the
    /// rules (a word moves down, like in a word processor). Nil when every line fits.
    /// A space just typed is kept, so the next word doesn't stick to the last one.
    func liveBreak(_ text: String, track: Track) -> String? {
        guard autoLineBreaks else { return nil }
        let rules = preset(for: track)
        let lines = Markup.plain(text).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).count > rules.maxCharsPerLine }) else { return nil }
        var broken = LineBreaker.breakLines(text, maxChars: rules.maxCharsPerLine,
                                            maxLines: rules.maxLines, language: track.language.code)
        if text.hasSuffix(" ") { broken += " " }
        return broken
    }

    /// Title ▸ Re-break All Lines: every title in the focused language, in one undo step.
    func rebreakAll() {
        guard let track = focusedTrack else { return }
        let rules = preset(for: track)
        var changed = 0
        track.doc.perform { subs in
            for i in subs.indices {
                let broken = LineBreaker.breakLines(subs[i].text, maxChars: rules.maxCharsPerLine,
                                                    maxLines: rules.maxLines, language: track.language.code)
                if broken != subs[i].text { subs[i].text = broken; changed += 1 }
            }
        }
        flash(changed == 0 ? "\(track.language.name): every title already breaks by the rules"
                           : "\(track.language.name): re-broke \(changed) titles (⌘Z to undo)")
    }

    /// After a paste: break the whole title by the rules, ignoring line breaks that came
    /// with the pasted text.
    func autoBreakAfterPaste(_ id: UUID) {
        guard autoLineBreaks, let track = video?.tracks.first(where: { $0.doc.subtitle(id) != nil }),
              let sub = track.doc.subtitle(id) else { return }
        let rules = preset(for: track)
        let broken = LineBreaker.breakLines(sub.text, maxChars: rules.maxCharsPerLine,
                                            maxLines: rules.maxLines, language: track.language.code)
        if broken != sub.text { track.doc.setText(id, broken) }
    }

    /// Title ▸ Re-break Lines: re-breaks the selected title from scratch.
    func rebreakSelected() {
        guard let track = focusedTrack, let sub = doc.selected else { return }
        let rules = preset(for: track)
        let broken = LineBreaker.breakLines(sub.text, maxChars: rules.maxCharsPerLine,
                                            maxLines: rules.maxLines, language: track.language.code)
        if broken != sub.text { doc.setText(sub.id, broken) }
    }
}

// MARK: Several titles at once

extension AppModel {
    func toggleMulti(_ id: UUID) {
        if multiSelection.isEmpty, let current = doc.selectedID, current != id { multiSelection.insert(current) }
        if multiSelection.contains(id) { multiSelection.remove(id) } else { multiSelection.insert(id) }
        doc.selectedID = multiSelection.contains(id) ? id : multiSelection.first
        bump()
    }

    func addToMulti(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        multiSelection.formUnion(ids)
        if doc.selectedID == nil { doc.selectedID = ids.first }
        bump()
    }

    func selectAllTitles() {
        multiSelection = Set(doc.subtitles.map(\.id))
        bump()
    }

    func clearMulti() {
        guard !multiSelection.isEmpty else { return }
        multiSelection = []
        bump()
    }

    /// Title ▸ Shift Titles…: moves titles by `offset` seconds (negative = earlier).
    /// `onlySelected` uses the group picked on the waveform (or the selected title).
    /// Locked languages follow their master automatically.
    func shiftTitles(by offset: Double, onlySelected: Bool, allLanguages: Bool) {
        guard let video, offset != 0 else { return }
        let picked: Set<UUID> = multiSelection.isEmpty ? Set([doc.selectedID].compactMap { $0 }) : multiSelection
        if onlySelected && picked.isEmpty { return }
        let tracks = allLanguages ? video.tracks.filter { !$0.locked || $0.id == video.masterTrackID }
                                  : [focusedTrack].compactMap { $0 }
        if !allLanguages, refuseIfLocked() { return }
        for track in tracks {
            let isFocused = track.id == focusedTrack?.id
            track.doc.perform { subs in
                for i in subs.indices where !onlySelected || (isFocused && picked.contains(subs[i].id)) {
                    let length = subs[i].duration
                    subs[i].start = max(0, subs[i].start + offset)
                    subs[i].end = subs[i].start + length
                }
            }
        }
        enforceLocks(in: video)
        flash(String(format: "Moved titles %@%.3f s", offset > 0 ? "+" : "", offset))
    }

    /// Reads "+1.5", "-0.25", or a timecode "-00:00:01:12" (frames at the project rate).
    func parseOffset(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces)
        var sign = 1.0
        if t.hasPrefix("-") { sign = -1; t.removeFirst() } else if t.hasPrefix("+") { t.removeFirst() }
        if t.contains(":") {
            let parts = t.split(separator: ":").map { Double($0) }
            guard parts.allSatisfy({ $0 != nil }), (2...4).contains(parts.count) else { return nil }
            let v = parts.map { $0! }
            var seconds = 0.0
            switch v.count {
            case 4: seconds = v[0] * 3600 + v[1] * 60 + v[2] + v[3] * frameDuration
            case 3: seconds = v[0] * 60 + v[1] + v[2] * frameDuration
            default: seconds = v[0] * 60 + v[1]
            }
            return sign * seconds
        }
        return Double(t.replacingOccurrences(of: ",", with: ".")).map { sign * $0 }
    }
}

