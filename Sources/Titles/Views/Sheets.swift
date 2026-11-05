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

struct NewProjectSheet: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var folder = ProjectStore.defaultProjectsFolder
    @State private var video: URL?
    @State private var subtitles: URL?
    @State private var settings = ProjectSettings()

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
                LanguagePicker(title: "Master language", selection: $settings.masterLanguage)
                LabeledContent("Existing subtitles") {
                    HStack {
                        Text(subtitles?.lastPathComponent ?? "None (optional .srt or .vtt)")
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textDim)
                        Button("Choose…") { chooseSubtitles() }
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
                Button("Create Project") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ConsoleButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 600, height: 640)
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
        model.createProject(name: finalName, folder: folder, video: video, settings: settings, subtitles: subtitles)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .audio]
        if panel.runModal() == .OK, let url = panel.url {
            video = url
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        }
    }

    private func chooseSubtitles() {
        let panel = NSOpenPanel()
        let types: [UTType?] = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt"), .plainText]
        panel.allowedContentTypes = types.compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url { subtitles = url }
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
                Button("Export…") {
                    model.sheet = nil
                    let (a, v, f) = (allLanguages, allVideos, format)
                    DispatchQueue.main.async { model.runExport(allLanguages: a, allVideos: v, format: f) }
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
