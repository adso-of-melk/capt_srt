import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine

/// The dialogs the editor can show.
enum SheetKind: Identifiable, Equatable {
    case newProject, projectSettings, newLanguage, importLanguage, export, openLink
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
    func rowNumber(of id: UUID) -> Int? { rowOfSub[id].map { $0 + 1 } }

    /// Moves focus to a language, staying on the same row. Typing carries on in the new column.
    func focusTrack(_ id: UUID, edit: Bool? = nil) {
        guard let video, let track = video.track(id), video.openTrackIDs.contains(id) else { return }
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
        if built != rows { rows = built }
        if let key = emptySlotRow, !built.contains(where: { $0.key == key }) { emptySlotRow = nil }
        bump()
    }

    func bump() { revision &+= 1 }

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
            track.doc.undo()
            redoOrder.append(id)
            return
        }
        doc.undo()
    }

    func redo() {
        doc.commitLive()
        while let id = redoOrder.popLast() {
            guard let track = video?.track(id), track.doc.canRedo else { continue }
            if video?.openTrackIDs.contains(id) == false { video?.openTrackIDs.append(id) }
            if focusedTrack?.id != id { focusTrack(id, edit: false) }
            track.doc.redo()
            undoOrder.append(id)
            return
        }
        doc.redo()
    }

    // MARK: Creating and opening projects

    func createProject(name: String, folder: URL, video videoURL: URL?, settings: ProjectSettings, subtitles: URL?) {
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
        if let subtitles {
            readSubtitleFile(subtitles) { [weak self] subs in
                master.doc.replaceAll(subs)
                master.doc.selectedID = nil
                self?.flash("Loaded \(subs.count) titles into \(master.language.name)")
                self?.saveProject()
            }
        }
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectStore.fileExtension) ?? .json]
        panel.allowsMultipleSelection = false
        panel.directoryURL = ProjectStore.defaultProjectsFolder
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
    func load(_ project: Project, currentVideoID: UUID?) {
        closeProject()
        self.project = project
        for v in project.videos { v.tracks.forEach(attach) }
        showHome = false
        rememberProject()
        if let v = project.video(currentVideoID) ?? project.videos.first { switchVideo(v) }
    }

    /// Saves and closes the current project (nothing is lost: projects autosave).
    func closeProject() {
        guard project != nil else { return }
        saveProject()
        finishGesture()
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
    func saveProject(announce: Bool = false) {
        guard let project else { return }
        autosaveTask?.cancel()
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
        guard !originalWriteInFlight else { return }
        originalWriteInFlight = true
        let writing = Self.offMain { () -> String? in
            do { try data.write(to: url, options: .atomic); return nil }
            catch { return error.localizedDescription }
        }
        Task {
            let result = await Self.value(of: writing, timeout: 10)
            originalWriteInFlight = false
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
        if let url = v.url { openVideo(url) }
        rememberProject()
    }

    func addVideoPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .audio]
        panel.allowsMultipleSelection = false
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
        if panel.runModal() == .OK, let url = panel.url {
            pendingImport = url
            sheet = .importLanguage
        }
    }

    /// Imports a subtitle file as a language. Into an empty language of the same kind it fills
    /// that language; otherwise it becomes a new, free language, linked to the master by time.
    func importLanguage(from url: URL, as language: Language) {
        readSubtitleFile(url) { [weak self] subs in
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
            } else {
                addVideo(url)
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
