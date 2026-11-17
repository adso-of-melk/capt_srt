import Foundation

/// What a drop of videos and subtitle files will become: each video with the files matched
/// to it, and the files nothing was found for. Shown in the "New project from files" dialog,
/// where any of it can be changed before the project is made.
struct ImportPlan: Sendable {
    struct Target: Identifiable, Sendable, Equatable {
        let id: UUID
        var name: String
        var url: URL?
        /// A video already in the project (adding to it), not a new one.
        var existingID: UUID?
        var duration: Double?
    }

    struct File: Identifiable, Sendable {
        let id: UUID
        let url: URL
        var language: Language
        /// Neither its name nor its text said which language it's in.
        var languageGuessed: Bool
        var target: UUID?
        var reason: FileMatcher.Reason?
        /// Files timed alike (the same cut, in other languages) share a group.
        let group: Int
        let subtitles: [Subtitle]
    }

    var targets: [Target]
    var files: [File]
    /// Adding to the open project; false: a new project.
    var intoProject: Bool
    /// Files that couldn't be read or aren't supported, by name.
    var skipped: [String]
    var masterLanguage: Language
    var name: String

    func files(of target: UUID?) -> [File] { files.filter { $0.target == target } }

    /// Moves a file to another video (nil: leave it out). Files timed like it that were only
    /// placed by timing or length go with it: they belong to the same cut.
    mutating func move(_ fileID: UUID, to target: UUID?, withGroup: Bool) {
        guard let i = files.firstIndex(where: { $0.id == fileID }) else { return }
        let from = files[i].target, group = files[i].group
        for k in files.indices {
            let same = k == i || (withGroup && files[k].group == group && files[k].target == from
                                  && (files[k].reason.map { [.timing, .length].contains($0) } ?? (from == nil)))
            guard same else { continue }
            files[k].target = target
            files[k].reason = target == nil ? nil : .moved
        }
    }

    /// The other files that `move(_:to:withGroup: true)` would take along.
    func groupMates(of fileID: UUID) -> [File] {
        guard let f = files.first(where: { $0.id == fileID }) else { return [] }
        return files.filter {
            $0.id != fileID && $0.group == f.group && $0.target == f.target
                && ($0.reason.map { [.timing, .length].contains($0) } ?? (f.target == nil))
        }
    }

    // MARK: Building

    struct ReadFile: Sendable {
        let url: URL
        let subtitles: [Subtitle]
        /// From its name, or its text; nil if neither says.
        let language: Language?
    }

    /// Matches the files and suggests a name and a master language.
    /// `existing`: the open project's videos, when adding to it.
    static func make(videos: [(url: URL, duration: Double?)], existing: [Target] = [], subtitles: [ReadFile],
                     skipped: [String] = [], defaultMaster: Language, intoProject: Bool) -> ImportPlan {
        var targets = existing
        for v in videos {
            targets.append(Target(id: UUID(), name: v.url.deletingPathExtension().lastPathComponent,
                                  url: v.url, existingID: nil, duration: v.duration))
        }
        let subFiles = subtitles.map {
            FileMatcher.SubFile(name: $0.url.deletingPathExtension().lastPathComponent,
                                folder: $0.url.deletingLastPathComponent().path, subtitles: $0.subtitles)
        }
        let matchVideos = targets.map { t in
            FileMatcher.Video(id: t.id, name: t.url?.deletingPathExtension().lastPathComponent ?? t.name,
                              folder: t.url.flatMap { $0.isFileURL ? $0.deletingLastPathComponent().path : nil },
                              duration: t.duration)
        }
        let matches = FileMatcher.match(videos: matchVideos, subs: subFiles)
        var files: [File] = []
        for (i, read) in subtitles.enumerated() {
            let m = matches[subFiles[i].id]
            files.append(File(id: subFiles[i].id, url: read.url, language: read.language ?? defaultMaster,
                              languageGuessed: read.language == nil, target: m?.video, reason: m?.reason,
                              group: m?.group ?? i, subtitles: read.subtitles))
        }

        // No videos at all: each set of files timed alike becomes a video of its own, its
        // file to be found later.
        if targets.isEmpty, !intoProject {
            var byGroup: [Int: [Int]] = [:]
            for (i, f) in files.enumerated() { byGroup[f.group, default: []].append(i) }
            let ordered = byGroup.values.sorted { a, b in
                let ea = FileMatcher.episode(in: files[a[0]].url.lastPathComponent)?.number ?? Int.max
                let eb = FileMatcher.episode(in: files[b[0]].url.lastPathComponent)?.number ?? Int.max
                if ea != eb { return ea < eb }
                return files[a[0]].url.lastPathComponent.localizedStandardCompare(files[b[0]].url.lastPathComponent) == .orderedAscending
            }
            for (n, members) in ordered.enumerated() {
                let names = members.map { FileMatcher.displayStem(files[$0].url.deletingPathExtension().lastPathComponent) }
                let target = Target(id: UUID(), name: FileMatcher.commonName(names) ?? "Video \(n + 1)",
                                    url: nil, existingID: nil, duration: nil)
                targets.append(target)
                for i in members {
                    files[i].target = target.id
                    files[i].reason = members.count > 1 ? .timing : .single
                }
            }
        }

        // The master language: the usual one if every video has a file in it, otherwise
        // the language most videos have.
        var master = defaultMaster
        let filled = targets.filter { t in files.contains { $0.target == t.id } }
        if !filled.isEmpty, !filled.allSatisfy({ t in files.contains { $0.target == t.id && $0.language == defaultMaster } }) {
            var count: [Language: Int] = [:]
            for t in filled {
                for lang in Set(files.filter { $0.target == t.id }.map(\.language)) { count[lang, default: 0] += 1 }
            }
            if let best = count.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key.name > $1.key.name }) {
                master = best.key
            }
        }

        let videoNames = targets.map(\.name)
        let name = FileMatcher.commonName(videoNames).map(FileMatcher.readable) ?? videoNames.first
            ?? subtitles.first.map { FileMatcher.displayStem($0.url.deletingPathExtension().lastPathComponent) } ?? "Untitled"

        var plan = ImportPlan(targets: targets, files: files, intoProject: intoProject, skipped: skipped,
                              masterLanguage: master, name: name)
        plan.sortFiles()
        return plan
    }

    /// Within each video: the master language first, then by language name, then file name.
    mutating func sortFiles() {
        let master = masterLanguage
        files.sort { a, b in
            if (a.language == master) != (b.language == master) { return a.language == master }
            if a.language.name != b.language.name { return a.language.name < b.language.name }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
    }
}
