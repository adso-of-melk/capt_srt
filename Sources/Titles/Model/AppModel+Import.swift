import AppKit
import AVFoundation
import UniformTypeIdentifiers
@testable import TitlesCore

/// Dropping files and folders on the window: videos, subtitle files and projects.
extension AppModel {

    static let subtitleExtensions: Set<String> = ["srt", "vtt"]
    /// Videos this build can't play yet.
    static let unplayableExtensions: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "ogv"]

    /// The files in what was dropped: folders are opened (and the folders in them), hidden
    /// files are skipped. In name order, so episodes come in order.
    nonisolated static func expandFolders(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard url.isFileURL, fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                  url.pathExtension.lowercased() != ProjectStore.fileExtension else {
                out.append(url)
                continue
            }
            guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var found: [URL] = []
            for case let file as URL in walker {
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                found.append(file)
            }
            out += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return out
    }

    func handleDrop(_ urls: [URL]) {
        let droppedFolder = urls.contains { $0.isFileURL && $0.hasDirectoryPath }
        let files = Self.expandFolders(urls)
        if let projectFile = files.first(where: { $0.pathExtension.lowercased() == ProjectStore.fileExtension }) {
            openProject(at: projectFile, knownID: nil)
            return
        }
        var videos: [URL] = [], subtitles: [URL] = [], notes: [String] = [], skipped: [String] = []
        for url in files {
            let ext = url.pathExtension.lowercased()
            if Self.subtitleExtensions.contains(ext) {
                subtitles.append(url)
            } else if url.isFileURL, Self.unplayableExtensions.contains(ext) {
                notes.append("\(url.lastPathComponent) can't be played by this build yet. MP4, MOV and M4V can.")
                skipped.append(url.lastPathComponent)
            } else if !url.isFileURL || (UTType(filenameExtension: ext)?.conforms(to: .audiovisualContent) ?? false) {
                videos.append(url)
            } else if !droppedFolder {
                // Inside a dropped folder, other files (notes, pictures) are passed over quietly.
                notes.append("\(url.lastPathComponent) isn't a video, a subtitle file or a project.")
                skipped.append(url.lastPathComponent)
            }
        }
        guard !videos.isEmpty || !subtitles.isEmpty else {
            flash(notes.first ?? "There's no video or subtitle file in what was dropped.")
            return
        }

        if project == nil || showHome {
            // One video alone: the usual New Project dialog. Anything more: matched up first.
            if videos.count == 1, subtitles.isEmpty { addVideo(videos[0]); return }
            prepareImport(videos: videos, subtitles: subtitles, skipped: skipped, intoProject: false)
        } else if showProjectView {
            if videos.count == 1, subtitles.isEmpty { addVideo(videos[0]); return }
            prepareImport(videos: videos, subtitles: subtitles, skipped: skipped, intoProject: true)
        } else {
            if videos.isEmpty, subtitles.count == 1 {
                pendingImport = subtitles[0]
                sheet = .importLanguage
            } else if videos.count == 1, subtitles.isEmpty, let v = video {
                // In the editor a dropped video replaces this one's file (new videos are
                // added from the project view).
                let alert = NSAlert()
                alert.messageText = "Use \(videos[0].lastPathComponent) for \(v.name)?"
                alert.informativeText = "The video file is replaced and every title is kept. To add another video to the project, use the project view (PROJECT in the top strip)."
                alert.addButton(withTitle: "Replace Video")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { replaceVideo(v, with: videos[0]) }
            } else {
                // New videos are added in the project view, so go there to add them.
                if !videos.isEmpty { showProjectOverview() }
                prepareImport(videos: videos, subtitles: subtitles, skipped: skipped, intoProject: true)
            }
        }
    }

    /// Files dropped on one video's card in the project view: subtitle files (or folders of
    /// them) go into that video; anything else is handled as a drop on the window.
    func dropFiles(_ urls: [URL], onto video: VideoItem) {
        let files = Self.expandFolders(urls)
        let subtitles = files.filter { Self.subtitleExtensions.contains($0.pathExtension.lowercased()) }
        let droppedFolder = urls.contains { $0.isFileURL && $0.hasDirectoryPath }
        // A folder may hold notes or pictures too; loose files must all be subtitle files.
        guard !subtitles.isEmpty, droppedFolder || subtitles.count == files.count,
              project?.videos.contains(where: { $0 === video }) == true else {
            handleDrop(urls)
            return
        }
        prepareImport(videos: [], subtitles: subtitles, skipped: [], intoProject: true, onto: video.id)
    }

    /// Reads the subtitle files and the videos' lengths (off the main thread), matches them,
    /// and shows the result to be checked.
    /// `onto`: a video in the project that every file goes into (dropped on its card). Then
    /// the files go straight in, and the dialog only opens if a language couldn't be told.
    func prepareImport(videos: [URL], subtitles: [URL], skipped: [String], intoProject: Bool, onto: UUID? = nil) {
        let existing: [ImportPlan.Target] = intoProject ? (project?.videos ?? []).map {
            ImportPlan.Target(id: UUID(), name: $0.name, url: $0.url, existingID: $0.id, duration: nil)
        } : []
        let master = intoProject ? (project?.settings.masterLanguage ?? ProjectSettings().masterLanguage)
                                 : ProjectSettings().masterLanguage
        let projectID = project?.id
        if !subtitles.isEmpty {
            flash("Reading \(subtitles.count) subtitle file\(subtitles.count == 1 ? "" : "s")…")
        }
        Task { [weak self] in
            var read: [ImportPlan.ReadFile] = []
            var skipped = skipped
            for url in subtitles {
                let job = Self.offMain { () -> ImportPlan.ReadFile? in
                    guard let subs = try? SubtitleFormats.read(url: url), !subs.isEmpty else { return nil }
                    return ImportPlan.ReadFile(url: url, subtitles: subs, language: LanguageGuess.language(of: url))
                }
                switch await Self.value(of: job, timeout: 30) {
                case let file??: read.append(file)
                default: skipped.append(url.lastPathComponent)
                }
            }
            var lengths: [URL: Double] = [:]
            for url in videos + existing.compactMap(\.url) where lengths[url] == nil {
                let job = Task.detached { await Self.mediaDuration(url) }
                if case let seconds?? = await Self.value(of: job, timeout: 5) { lengths[url] = seconds }
            }
            guard let self else { return }
            // Another project was opened (or this one closed) meanwhile: drop it.
            guard self.project?.id == projectID || !intoProject else { return }
            let targets = existing.map { t -> ImportPlan.Target in
                var t = t
                t.duration = t.url.flatMap { lengths[$0] }
                return t
            }
            var plan = ImportPlan.make(videos: videos.map { ($0, lengths[$0]) }, existing: targets, subtitles: read,
                                       skipped: skipped, defaultMaster: master, intoProject: intoProject)
            // Files that neither names nor timing placed (or only their length): listen to the
            // videos and match the files by where people speak.
            if onto == nil, plan.hasUnsureFiles, plan.targets.count > 1 {
                let heard = await self.listen(to: plan.targets.compactMap(\.url))
                guard self.project?.id == projectID || !intoProject else {
                    self.statusMessage = nil
                    return
                }
                if !heard.isEmpty {
                    plan = ImportPlan.make(videos: videos.map { ($0, lengths[$0]) }, existing: targets, subtitles: read,
                                           skipped: skipped, defaultMaster: master, intoProject: intoProject, speech: heard)
                }
            }
            guard !plan.files.isEmpty || !videos.isEmpty else {
                self.flash("None of the subtitle files could be read.")
                return
            }
            if let onto, let target = plan.targets.first(where: { $0.existingID == onto }) {
                for i in plan.files.indices {
                    plan.files[i].target = target.id
                    plan.files[i].reason = .dropped
                }
                if !plan.files.contains(where: \.languageGuessed) {
                    self.statusMessage = nil
                    self.addToProject(plan)
                    if !plan.skipped.isEmpty { self.banner = "Couldn't read " + plan.skipped.joined(separator: ", ") + "." }
                    return
                }
            }
            self.statusMessage = nil
            self.importPlan = plan
            self.sheet = .dropImport
        }
    }

    /// When people speak in each video file (the ones whose sound can be read). Each video
    /// is listened to once; a long one takes a few seconds.
    func listen(to urls: [URL]) async -> [URL: FileMatcher.Speech] {
        var unique: [URL] = []
        for url in urls where url.isFileURL && !unique.contains(url) { unique.append(url) }
        var heard: [URL: FileMatcher.Speech] = [:]
        let toListen = unique.filter { speechHeard[$0] == nil }
        for (n, url) in unique.enumerated() {
            if let known = speechHeard[url] {
                heard[url] = known
                continue
            }
            let position = (toListen.firstIndex(of: url) ?? n) + 1
            showStatus("Listening to video \(position) of \(toListen.count) to match the subtitle files by speech…")
            let job = Task.detached { await SpeechListener.speech(url: url) }
            if case let speech?? = await Self.value(of: job, timeout: 240) {
                heard[url] = speech
                speechHeard[url] = speech
            }
        }
        return heard
    }

    /// A video's length in seconds, if it can be read.
    nonisolated static func mediaDuration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(d)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    // MARK: Making the project

    /// One video with its files: the file in the master language fills the master (or the
    /// first file, if none is in it); every other file becomes a language matched to it by time.
    func videoItem(for target: ImportPlan.Target, files: [ImportPlan.File], master language: Language) -> VideoItem {
        let masterFile = files.first { $0.language == language } ?? files.first
        let masterSubs = masterFile?.subtitles ?? []
        let master = Track(language: masterFile?.language ?? language, subtitles: masterSubs)
        let item = VideoItem(name: target.name, url: target.url, master: master)
        let masterTitles = master.doc.subtitles
        for f in files where f.id != masterFile?.id {
            let track = Track(language: f.language, subtitles: RowBuilder.linkByOverlap(f.subtitles, master: masterTitles))
            item.tracks.append(track)
            item.openTrackIDs.append(track.id)
        }
        item.focusedTrackID = master.id
        return item
    }

    /// The new project a plan makes (not opened or saved yet). Videos with neither a file nor
    /// any subtitles are left out.
    func buildProject(from plan: ImportPlan, name: String, settings: ProjectSettings, fileURL: URL?) -> Project {
        var videos = plan.targets.compactMap { t -> VideoItem? in
            let files = plan.files(of: t.id)
            guard !files.isEmpty || t.url != nil else { return nil }
            return videoItem(for: t, files: files, master: settings.masterLanguage)
        }
        if videos.isEmpty {
            videos = [VideoItem(name: "Video 1", url: nil, master: Track(language: settings.masterLanguage))]
        }
        return Project(name: name, settings: settings, videos: videos, fileURL: fileURL)
    }

    func createProject(from plan: ImportPlan, name: String, folder: URL, settings: ProjectSettings) {
        guard let file = newProjectFile(name: name, folder: folder) else { return }
        let project = buildProject(from: plan, name: file.name, settings: settings, fileURL: file.url)
        load(project, currentVideoID: project.videos.first?.id)
        saveProject()
        let used = plan.files.filter { $0.target != nil }.count
        if project.videos.count > 1 { showProjectOverview() }
        flash("Made \(file.name): \(project.videos.count) video\(project.videos.count == 1 ? "" : "s"), \(used) subtitle file\(used == 1 ? "" : "s")")
        if let first = project.videos.first { first.tracks.forEach { noteShortGaps(in: $0) } }
    }

    /// Adds what a plan holds to the open project: new videos with their languages, and new
    /// languages for the videos already in it (an empty language of the same kind is filled).
    func addToProject(_ plan: ImportPlan) {
        guard let project else { return }
        var addedVideos = 0, addedFiles = 0
        var filledVideos: [String] = []
        for t in plan.targets {
            let files = plan.files(of: t.id)
            if let id = t.existingID {
                guard let v = project.video(id) else { continue }
                // An empty master is filled first, so the others can be matched to it. With no
                // file in its language, it takes the first file's language (a video added on
                // its own has an empty master in the project's usual language).
                if let m = v.master, m.doc.subtitles.isEmpty, !files.isEmpty,
                   !files.contains(where: { $0.language == m.language }), let first = files.first {
                    m.language = first.language
                }
                let masterLanguage = v.master?.language
                for f in files.sorted(by: { ($0.language == masterLanguage) && ($1.language != masterLanguage) }) {
                    addFile(f, to: v)
                    addedFiles += 1
                }
                if !files.isEmpty { filledVideos.append(v.name) }
            } else {
                guard !files.isEmpty || t.url != nil else { continue }
                let item = videoItem(for: t, files: files, master: project.settings.masterLanguage)
                item.tracks.forEach(attach)
                project.videos.append(item)
                addedVideos += 1
                addedFiles += files.count
            }
        }
        rebuildRows()
        bump()
        saveProject()
        var parts: [String] = []
        if addedVideos > 0 { parts.append("\(addedVideos) video\(addedVideos == 1 ? "" : "s")") }
        if addedFiles > 0 { parts.append("\(addedFiles) subtitle file\(addedFiles == 1 ? "" : "s")") }
        if addedVideos == 0, filledVideos.count == 1 {
            flash("Added \(addedFiles) subtitle file\(addedFiles == 1 ? "" : "s") to \(filledVideos[0])")
        } else {
            flash(parts.isEmpty ? "Nothing was added." : "Added " + parts.joined(separator: " and "))
        }
    }

    /// One subtitle file into a video already in the project.
    private func addFile(_ f: ImportPlan.File, to v: VideoItem) {
        let empty = v.tracks.first { $0.language == f.language && $0.doc.subtitles.isEmpty }
        let isMaster = empty != nil && empty?.id == v.masterTrackID
        let linked = isMaster ? f.subtitles : RowBuilder.linkByOverlap(f.subtitles, master: v.master?.doc.subtitles ?? [])
        let track: Track
        if let empty {
            track = empty
            track.locked = false
            track.doc.replaceAll(linked)
        } else {
            track = Track(language: f.language, subtitles: linked)
            attach(track)
            v.tracks.append(track)
        }
        track.doc.selectedID = nil
        if !v.openTrackIDs.contains(track.id) { v.openTrackIDs.append(track.id) }
        if isMaster { enforceLocks(in: v) }
        noteShortGaps(in: track)
    }
}
