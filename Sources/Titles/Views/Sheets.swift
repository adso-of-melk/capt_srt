import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// All the editor's dialogs, chosen by `model.sheet`.
struct SheetHost: View {
    @ObservedObject var model: AppModel
    let kind: SheetKind

    var body: some View {
        Group {
            switch kind {
            case .newProject: NewProjectSheet(model: model)
            case .projectSettings: ProjectSettingsSheet(model: model)
            case .newLanguage: LanguageSheet(model: model, importURL: nil)
            case .importLanguage: LanguageSheet(model: model, importURL: model.pendingImport)
            case .export: ExportSheet(model: model)
            case .openLink: OpenLinkSheet(model: model)
            case .shiftTitles: ShiftTitlesSheet(model: model)
            case .languageOptions:
                if let track = model.video?.track(model.languageOptionsID) {
                    LanguageOptionsSheet(model: model, track: track)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.amber)
    }
}

private struct SheetHeader: View {
    let title: String
    var color: Color = Theme.amber
    var body: some View {
        PaneHeader(title: title, color: color).padding(.horizontal, -12)
    }
}

// MARK: - New project

struct ExtraLanguage: Identifiable {
    let id = UUID()
    var language: Language
}

/// A subtitle file picked in New Project, and the language it's in.
struct SubtitleFilePick: Identifiable {
    let id = UUID()
    let url: URL
    var language: Language
}

struct NewProjectSheet: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var folder = ProjectStore.defaultProjectsFolder
    @State private var video: URL?
    @State private var subtitleFiles: [SubtitleFilePick] = []
    @State private var settings = ProjectSettings()
    @State private var videoLink = ""
    @State private var extraLanguages: [ExtraLanguage] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "New project")
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Tražeći nju"))
                LabeledContent("Saved in") {
                    HStack {
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textDim)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                LabeledContent("Video") {
                    HStack {
                        Text(video?.lastPathComponent ?? "None yet (you can add videos later)")
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textDim)
                        Button("Choose…") { chooseVideo() }
                    }
                }
                if video == nil {
                    TextField("Or a video link", text: $videoLink, prompt: Text("https://…/film.mp4 or .m3u8"))
                }
                LanguagePicker(title: "Master language", selection: $settings.masterLanguage)
                ForEach($extraLanguages) { $extra in
                    HStack {
                        LanguagePicker(title: "Also", selection: $extra.language)
                        let id = extra.id
                        Button { extraLanguages.removeAll { $0.id == id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .help("Don't add this language")
                    }
                }
                Button("Add Another Language") {
                    let used = Set([settings.masterLanguage] + extraLanguages.map(\.language))
                    let next = ["en", "hr", "de", "fr", "es", "it", "sl", "sr"].map(Language.named)
                        .first { !used.contains($0) } ?? Language.named("en")
                    extraLanguages.append(ExtraLanguage(language: next))
                }
                LabeledContent("Existing subtitles") {
                    HStack {
                        Text(subtitleFiles.isEmpty ? "None (optional .srt or .vtt, one per language)"
                                                   : "\(subtitleFiles.count) file\(subtitleFiles.count == 1 ? "" : "s")")
                            .foregroundStyle(Theme.textDim)
                        Button(subtitleFiles.isEmpty ? "Choose…" : "Add More…") { chooseSubtitles() }
                    }
                }
                ForEach($subtitleFiles) { $file in
                    HStack {
                        Text(file.url.lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LanguagePicker(title: "", selection: $file.language)
                            .labelsHidden()
                            .frame(width: 190)
                        if file.language == settings.masterLanguage {
                            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.peach)
                                .help("This file fills the master language")
                        }
                        let id = file.id
                        Button { subtitleFiles.removeAll { $0.id == id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .help("Don't import this file")
                    }
                }
                StandardFields(settings: $settings)
            }
            .formStyle(.grouped)
            HStack {
                Text("Projects autosave. A local copy is kept on this Mac, so iCloud can't block your work.")
                    .font(Theme.label(11, .regular)).foregroundStyle(Theme.textFaint)
                Spacer()
                Button("Cancel") { model.sheet = nil; model.newProjectVideo = nil }.keyboardShortcut(.cancelAction)
                    .buttonStyle(ConsoleButtonStyle(secondary: true))
                Button("Create Project") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ConsoleButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 600, height: 700)
        .background(Theme.panel)
        .onAppear {
            if let v = model.newProjectVideo {
                video = v
                if name.isEmpty { name = v.deletingPathExtension().lastPathComponent }
            }
        }
    }

    private func create() {
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? (video?.deletingPathExtension().lastPathComponent ?? "Untitled") : name
        model.sheet = nil
        model.newProjectVideo = nil
        var videoURL = video
        let link = videoLink.trimmingCharacters(in: .whitespacesAndNewlines)
        if videoURL == nil, !link.isEmpty, let url = URL(string: link),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") { videoURL = url }
        model.createProject(name: finalName, folder: folder, video: videoURL, settings: settings,
                            subtitleFiles: subtitleFiles.map { ($0.url, $0.language) },
                            extraLanguages: extraLanguages.map(\.language))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.roomy()
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .audio]
        panel.roomy()
        if panel.runModal() == .OK, let url = panel.url {
            video = url
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        }
    }

    private func chooseSubtitles() {
        let panel = NSOpenPanel()
        let types: [UTType?] = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt"), .plainText]
        panel.allowedContentTypes = types.compactMap { $0 }
        // ⌘- or Shift-click several files; open the panel again to add files from other folders.
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.roomy()
        guard panel.runModal() == .OK else { return }
        let known = Set(subtitleFiles.map { $0.url.standardizedFileURL })
        for url in panel.urls where !known.contains(url.standardizedFileURL) {
            let lang = LanguageGuess.language(of: url) ?? settings.masterLanguage
            subtitleFiles.append(SubtitleFilePick(url: url, language: lang))
        }
        // The master is filled from one of the files: if none is in the master language yet,
        // the first file's language becomes the master (you can change it above).
        if let first = subtitleFiles.first, !subtitleFiles.contains(where: { $0.language == settings.masterLanguage }) {
            settings.masterLanguage = first.language
        }
        if name.isEmpty, let first = subtitleFiles.first {
            name = first.url.deletingPathExtension().lastPathComponent
        }
    }
}

// MARK: - Project settings

struct ProjectSettingsSheet: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var settings = ProjectSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Project settings")
            Form {
                TextField("Name", text: $name)
                LanguagePicker(title: "Master language for new videos", selection: $settings.masterLanguage)
                StandardFields(settings: $settings, expanded: true)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                    .buttonStyle(ConsoleButtonStyle(secondary: true))
                Button("Save") {
                    model.applySettings(settings, name: name)
                    model.sheet = nil
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ConsoleButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 600, height: 620)
        .background(Theme.panel)
        .onAppear {
            name = model.project?.name ?? ""
            settings = model.project?.settings ?? ProjectSettings()
        }
    }
}

/// The standard picker, with every rule under Advanced.
struct StandardFields: View {
    @Binding var settings: ProjectSettings
    @State var expanded = false

    var body: some View {
        Section {
            Picker("Standard", selection: Binding(
                get: { settings.standard.id },
                set: { id in if let p = TimingPreset.all.first(where: { $0.id == id }) { settings.standard = p } }
            )) {
                ForEach(TimingPreset.all) { Text($0.name).tag($0.id) }
                if !TimingPreset.all.contains(where: { $0.id == settings.standard.id }) {
                    Text("Custom").tag(settings.standard.id)
                }
            }
            Text(settings.standard.summary).font(Theme.label(11, .regular)).foregroundStyle(Theme.textDim)
            DisclosureGroup("Advanced", isExpanded: $expanded) {
                Stepper(value: rule(\.maxCPS), in: 8...30, step: 1) {
                    LabeledContent("Max reading speed", value: "\(Int(settings.standard.maxCPS)) CPS")
                }
                Stepper(value: rule(\.maxCharsPerLine), in: 12...60) {
                    LabeledContent("Max characters per line", value: "\(settings.standard.maxCharsPerLine)")
                }
                Stepper(value: rule(\.maxLines), in: 1...4) {
                    LabeledContent("Max lines", value: "\(settings.standard.maxLines)")
                }
                Stepper(value: rule(\.minDuration), in: 0.3...3, step: 0.1) {
                    LabeledContent("Min duration", value: String(format: "%.2f s", settings.standard.minDuration))
                }
                Stepper(value: rule(\.maxDuration), in: 2...15, step: 0.5) {
                    LabeledContent("Max duration", value: String(format: "%.1f s", settings.standard.maxDuration))
                }
                Stepper(value: rule(\.minGapFrames), in: 0...12) {
                    LabeledContent("Min gap", value: "\(settings.standard.minGapFrames) frames")
                }
                Picker("Frame rate", selection: $settings.frameRate) {
                    Text("From the video").tag(Double?.none)
                    ForEach([23.976, 24, 25, 29.97, 30, 50, 59.94, 60], id: \.self) { Text(String(format: "%g fps", $0)).tag(Double?.some($0)) }
                }
                Picker("Start timecode", selection: $settings.startTimecode) {
                    Text("00:00:00:00").tag(0.0)
                    Text("01:00:00:00").tag(3600.0)
                    Text("10:00:00:00").tag(36000.0)
                }
                Picker("Show times as", selection: $settings.timecodeDisplay) {
                    ForEach(TimecodeDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Export format", selection: $settings.exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("UTF-8 with byte-order mark (for older players)", isOn: $settings.utf8BOM)
                Toggle("Windows line endings (CRLF)", isOn: $settings.crlf)
                TextField("File names", text: $settings.namingPattern, prompt: Text("{video}.{lang}"))
                Text("{video} is the video's name, {lang} the language code, {project} the project's name.")
                    .font(Theme.label(10, .regular)).foregroundStyle(Theme.textFaint)
            }
        }
    }

    /// Editing any rule makes the standard Custom.
    private func rule<V>(_ path: WritableKeyPath<TimingPreset, V>) -> Binding<V> {
        Binding(
            get: { settings.standard[keyPath: path] },
            set: { value in
                settings.standard[keyPath: path] = value
                settings.standard.id = "custom"
                settings.standard.name = "Custom"
            }
        )
    }
}

struct LanguagePicker: View {
    let title: String
    @Binding var selection: Language

    var body: some View {
        Picker(title, selection: $selection) {
            if !Language.common.contains(selection) {
                Text("\(selection.name) (\(selection.code))").tag(selection)
            }
            ForEach(Language.common) { Text("\($0.name)  ·  \($0.code)").tag($0) }
        }
    }
}

// MARK: - Language options

/// Everything about how one language is handled: which language it is, master and lock,
/// its own reading limits, and spell check. Changes apply with Done.
struct LanguageOptionsSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var track: Track
    @State private var o: LanguageOptions?

    var body: some View {
        let isMaster = model.video?.masterTrackID == track.id
        let standard = model.project?.settings.standard ?? .general
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "\(track.language.name) options", color: Theme.teal)
            if let binding = Binding($o) {
                form(binding, isMaster: isMaster, standard: standard)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                    .buttonStyle(ConsoleButtonStyle(secondary: true))
                Button("Done") {
                    model.sheet = nil
                    if let o { model.applyLanguageOptions(track, o) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ConsoleButtonStyle(color: Theme.teal))
                .disabled(o?.language.code.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            }
        }
        .padding(20)
        .frame(width: 560, height: 640)
        .background(Theme.panel)
        .onAppear { if o == nil { o = LanguageOptions(track, isMaster: isMaster) } }
    }

    @ViewBuilder
    private func form(_ o: Binding<LanguageOptions>, isMaster: Bool, standard: TimingPreset) -> some View {
        let v = o.wrappedValue
        let words = (model.project?.settings.spellingWords[track.language.code] ?? [])
            .filter { !v.removedWords.contains($0) }
        Form {
            Section("Language") {
                LanguagePicker(title: "Language", selection: o.language)
                TextField("Name", text: o.language.name)
                TextField("Code", text: o.language.code)
                Text("Spell check and line breaking follow the language. Exported files are named with the code: \(model.video?.name ?? "Film").\(v.language.code).srt")
                    .font(Theme.label(11, .regular)).foregroundStyle(Theme.textDim)
                if let video = model.video,
                   video.tracks.contains(where: { $0.id != track.id && $0.language.code == v.language.code }) {
                    Text("\(video.name) already has \(v.language.name) in another column; both will export to the same file name.")
                        .font(Theme.label(11, .regular)).foregroundStyle(Theme.amber)
                }
            }
            Section("Master and timing") {
                if isMaster {
                    LabeledContent("Master", value: "This is the master language")
                } else {
                    Toggle("Make this the master language", isOn: o.makeMaster)
                    if !v.makeMaster {
                        Picker("Timing", selection: o.locked) {
                            Text("Free: its own timing, edited independently").tag(false)
                            Text("Locked: always the master's timing, text only").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                    }
                }
            }
            Section("Limits for this language") {
                Picker("Reading speed", selection: o.maxCPS) {
                    Text("Project standard (\(Int(standard.maxCPS)) CPS)").tag(Double?.none)
                    ForEach([10.0, 12, 13, 15, 17, 20, 25], id: \.self) { Text("\(Int($0)) CPS").tag(Double?.some($0)) }
                }
                Picker("Characters per line", selection: o.maxChars) {
                    Text("Project standard (\(standard.maxCharsPerLine))").tag(Int?.none)
                    ForEach([13, 16, 23, 32, 37, 39, 42, 47], id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
                Picker("Lines", selection: o.maxLines) {
                    Text("Project standard (\(standard.maxLines))").tag(Int?.none)
                    ForEach([1, 2, 3], id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
            }
            Section("Spelling") {
                Toggle("Check spelling in this language", isOn: o.spellCheck)
                Text(model.spellingStatus(for: v.language))
                    .font(Theme.label(11, .regular)).foregroundStyle(Theme.textDim)
                if !model.spellCheckOn {
                    Text("Spell check is off for every language (Edit ▸ Check Spelling).")
                        .font(Theme.label(11, .regular)).foregroundStyle(Theme.amber)
                }
                if words.isEmpty {
                    Text("No project words yet. Right-click a word in a card ▸ Add to Project Words.")
                        .font(Theme.label(11, .regular)).foregroundStyle(Theme.textFaint)
                } else {
                    ForEach(words, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button { o.wrappedValue.removedWords.insert(word) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .help("Remove from this project's words")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - New / import language

struct LanguageSheet: View {
    @ObservedObject var model: AppModel
    let importURL: URL?
    @State private var language = Language.named("hr")
    @State private var locked = false
    @State private var copyText = false

    var body: some View {
        let master = model.masterTrack
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: importURL == nil ? "New language from master" : "Import language", color: Theme.teal)
            Form {
                if let importURL {
                    LabeledContent("File", value: importURL.lastPathComponent)
                }
                LanguagePicker(title: "Language", selection: $language)
                if importURL == nil {
                    LabeledContent("Copies timecodes from", value: master.map { "\($0.language.name) (master)" } ?? "—")
                    Picker("Timing", selection: $locked) {
                        Text("Free: its own timing, edited independently").tag(false)
                        Text("Locked: always the master's timing, text only").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    Toggle("Copy the master's text too (for adapting between close languages)", isOn: $copyText)
                } else {
                    Text("Titles are matched to the master by time, so translations line up side by side. If the project already has an empty \(language.name), the file fills it.")
                        .font(Theme.label(11, .regular)).foregroundStyle(Theme.textDim)
                }
            }
            .formStyle(.grouped)
            if importURL == nil, let video = model.video, video.tracks.contains(where: { $0.language == language }) {
                Text("\(video.name) already has \(language.name). This adds a second one.")
                    .font(Theme.label(11, .regular)).foregroundStyle(Theme.amber)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil; model.pendingImport = nil }.keyboardShortcut(.cancelAction)
                    .buttonStyle(ConsoleButtonStyle(secondary: true))
                Button(importURL == nil ? "Add Language" : "Import") {
                    model.sheet = nil
                    if let importURL {
                        model.pendingImport = nil
                        model.importLanguage(from: importURL, as: language)
                    } else {
                        model.addLanguage(language, locked: locked, copyText: copyText)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ConsoleButtonStyle(color: Theme.teal))
                .disabled(importURL == nil && master == nil)
            }
        }
        .padding(20)
        .frame(width: 540, height: importURL == nil ? 380 : 300)
        .background(Theme.panel)
        .onAppear {
            // Suggest the first common language this video doesn't have yet.
            let have = Set(model.video?.tracks.map(\.language.code) ?? [])
            if importURL != nil, let empty = model.video?.tracks.first(where: { $0.doc.subtitles.isEmpty }) {
                language = empty.language
            } else if have.contains(language.code),
                      let next = Language.common.first(where: { !have.contains($0.code) }) {
                language = next
            }
        }
    }
}

// MARK: - Export

struct ExportSheet: View {
    @ObservedObject var model: AppModel
    @State private var allLanguages = false
    @State private var allVideos = false
    @State private var format: ExportFormat = .srt

    var body: some View {
        let items = model.exportItems(allLanguages: allLanguages, allVideos: allVideos, format: format)
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Export")
            Form {
                Picker("Languages", selection: $allLanguages) {
                    Text("This language (\(model.focusedTrack?.language.name ?? "—"))").tag(false)
                    Text("All languages").tag(true)
                }
                .pickerStyle(.radioGroup)
                if (model.project?.videos.count ?? 0) > 1 {
                    Picker("Videos", selection: $allVideos) {
                        Text("This video").tag(false)
                        Text("All videos").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                }
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent(items.count == 1 ? "File" : "\(items.count) files") {
                    Text(items.prefix(4).map(\.name).joined(separator: "\n") + (items.count > 4 ? "\n…" : ""))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textDim)
                        .multilineTextAlignment(.trailing)
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("File names, encoding and line endings are set in Project Settings.")
                    .font(Theme.label(11, .regular)).foregroundStyle(Theme.textFaint)
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                    .buttonStyle(ConsoleButtonStyle(secondary: true))
                Button("Export…") {
                    model.sheet = nil
                    let (a, v, f) = (allLanguages, allVideos, format)
                    // Once the sheet has gone, so the file panel opens on its own, full size.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        model.runExport(allLanguages: a, allVideos: v, format: f)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ConsoleButtonStyle())
                .disabled(items.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540, height: 400)
        .background(Theme.panel)
        .onAppear { format = model.project?.settings.exportFormat ?? .srt }
    }
}

// MARK: - Video link

struct OpenLinkSheet: View {
    @ObservedObject var model: AppModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "Add video link", color: Theme.periwinkle)
            Text("A direct link to a video file (https://…/film.mp4) or an HLS stream (.m3u8).")
                .font(Theme.label(12, .regular))
                .foregroundStyle(Theme.textDim)
            TextField("https://", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { open() }
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                    .buttonStyle(ConsoleButtonStyle(secondary: true))
                Button("Add") { open() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ConsoleButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.panel)
    }

    private func open() {
        model.sheet = nil
        let t = text
        DispatchQueue.main.async { model.openURLString(t) }
    }
}

// MARK: - Shift titles

struct ShiftTitlesSheet: View {
    @ObservedObject var model: AppModel
    @State private var offset = ""
    @State private var scope = 0          // 0 = selected, 1 = all in this language
    @State private var allLanguages = false

    var body: some View {
        let picked = model.multiSelection.isEmpty ? (model.doc.selectedID == nil ? 0 : 1) : model.multiSelection.count
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "Shift titles")
            Text("Move titles earlier or later. Seconds (+1.5, -0.25) or a timecode (-00:00:01:12).")
                .font(Theme.label(12, .regular)).foregroundStyle(Theme.textDim)
            TextField("Offset", text: $offset, prompt: Text("+1.0"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { apply() }
            Picker("Which titles", selection: $scope) {
                Text(picked == 1 ? "The selected title" : "The \(picked) selected titles").tag(0)
                Text("Every title in \(model.focusedTrack?.language.name ?? "this language")").tag(1)
            }
            .pickerStyle(.radioGroup)
            .disabled(picked == 0)
            if scope == 1 {
                Toggle("All languages (locked ones follow their master)", isOn: $allLanguages)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                    .buttonStyle(ConsoleButtonStyle(secondary: true))
                Button("Shift") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ConsoleButtonStyle())
                    .disabled(model.parseOffset(offset) == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.panel)
        .onAppear { if picked == 0 { scope = 1 } }
    }

    private func apply() {
        guard let value = model.parseOffset(offset) else { return }
        model.sheet = nil
        model.shiftTitles(by: value, onlySelected: scope == 0, allLanguages: scope == 1 && allLanguages)
    }
}


extension NSSavePanel {
    /// File panels open big enough to browse comfortably, and can be resized.
    func roomy() {
        styleMask.insert(.resizable)
        let screen = (NSApp.mainWindow?.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        contentMinSize = NSSize(width: min(640, screen.width * 0.6), height: contentMinSize.height)
        if self is NSOpenPanel || isExpanded {
            setContentSize(NSSize(width: min(900, screen.width * 0.7), height: min(580, screen.height * 0.7)))
        }
    }
}
