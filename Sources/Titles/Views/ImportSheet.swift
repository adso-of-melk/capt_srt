import SwiftUI
import AppKit

/// Videos and subtitle files dropped together: each video with the files matched to it, and
/// why. Languages can be changed, files moved between videos (menu or drag) or left out,
/// before the project is made (or the files added to the open one).
struct DropImportSheet: View {
    @ObservedObject var model: AppModel
    @State private var plan: ImportPlan
    @State private var name: String
    @State private var folder = ProjectStore.defaultProjectsFolder
    @State private var settings: ProjectSettings

    init(model: AppModel, plan: ImportPlan) {
        self.model = model
        _plan = State(initialValue: plan)
        _name = State(initialValue: plan.name)
        var s = model.project.map { plan.intoProject ? $0.settings : ProjectSettings() } ?? ProjectSettings()
        if !plan.intoProject { s.masterLanguage = plan.masterLanguage }
        _settings = State(initialValue: s)
    }

    var body: some View {
        let unmatched = plan.files(of: nil)
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: plan.intoProject ? "Add files to \(model.project?.name ?? "the project")" : "New project from files")
            Form {
                if !plan.intoProject {
                    Section {
                        TextField("Name", text: $name)
                        LabeledContent("Saved in") {
                            HStack {
                                Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textDim)
                                Button("Choose…") { chooseFolder() }
                            }
                        }
                        LanguagePicker(title: "Master language", selection: $settings.masterLanguage)
                    }
                    StandardFields(settings: $settings)
                }
                ForEach(plan.targets) { target in
                    let files = plan.files(of: target.id)
                    if !files.isEmpty || target.url != nil {
                        Section {
                            if files.isEmpty {
                                Text(target.existingID == nil ? "No subtitle files: the video comes in with an empty \(settings.masterLanguage.name)."
                                                              : "Nothing new for this video.")
                                    .font(Theme.label(11, .regular)).foregroundStyle(Theme.textFaint)
                                    .dropDestination(for: String.self) { ids, _ in drop(ids, on: target.id) }
                            }
                            ForEach(files) { file in row(file, master: masterFileID(of: target)) }
                        } header: {
                            header(target, files: files)
                                .dropDestination(for: String.self) { ids, _ in drop(ids, on: target.id) }
                        }
                    }
                }
                if !unmatched.isEmpty {
                    Section {
                        ForEach(unmatched) { file in row(file, master: nil) }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "questionmark.folder").foregroundStyle(Theme.amber)
                            Text("NOT MATCHED").font(Theme.label(11, .bold)).foregroundStyle(Theme.amber)
                            Text("Left out unless you move them to a video (menu or drag).")
                                .font(Theme.label(11, .regular)).foregroundStyle(Theme.textDim)
                        }
                        .dropDestination(for: String.self) { ids, _ in drop(ids, on: nil) }
                    }
                }
                if !plan.skipped.isEmpty {
                    Section("Not used") {
                        Text(plan.skipped.joined(separator: ", "))
                            .font(Theme.label(11, .regular)).foregroundStyle(Theme.textDim)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            HStack(alignment: .firstTextBaseline) {
                Text(summary).font(Theme.label(11, .regular)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") {
                    model.sheet = nil
                    model.importPlan = nil
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(ConsoleButtonStyle(secondary: true))
                Button(plan.intoProject ? "Add to Project" : "Create Project") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ConsoleButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 760, height: 780)
        .background(Theme.panel)
        .onChange(of: settings.masterLanguage) { _, new in
            plan.masterLanguage = new
            plan.sortFiles()
        }
    }

    // MARK: Parts

    private func header(_ target: ImportPlan.Target, files: [ImportPlan.File]) -> some View {
        let counts = Dictionary(grouping: files, by: \.language).filter { $0.value.count > 1 }
        return HStack(spacing: 8) {
            Image(systemName: target.url == nil ? "film.stack" : "film").foregroundStyle(Theme.periwinkle)
            Text(target.name).font(Theme.label(12, .bold)).foregroundStyle(Theme.text)
                .lineLimit(1).truncationMode(.middle)
            if target.existingID != nil {
                Chip(text: "IN PROJECT", color: Theme.textDim)
            } else if target.url == nil {
                Chip(text: "NO VIDEO FILE YET", color: Theme.textDim)
                    .help("Find the video later: the project view's Locate Video.")
            }
            if let twice = counts.keys.sorted(by: { $0.name < $1.name }).first {
                Text("\(counts[twice]?.count ?? 2) × \(twice.name)")
                    .font(Theme.label(11, .regular)).foregroundStyle(Theme.amber)
                    .help("More than one file in this language: each becomes a language of its own.")
            }
            Spacer()
            if let d = target.duration {
                Text(Self.clock(d)).font(Theme.mono(11)).foregroundStyle(Theme.textDim)
                    .help("The video's length")
            }
            Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                .font(Theme.label(11, .regular)).foregroundStyle(Theme.textDim)
        }
    }

    private func row(_ file: ImportPlan.File, master: UUID?) -> some View {
        HStack(spacing: 8) {
            Text(file.url.lastPathComponent)
                .lineLimit(1).truncationMode(.middle)
                .help(file.url.path)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let reason = file.reason, let chip = reason.chip {
                Chip(text: chip, color: reason.isGuess ? Theme.amber : Theme.teal)
                    .help(reason.explanation)
            }
            if file.id == master {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.peach)
                    .help("This file fills the video's master language")
            }
            if file.languageGuessed {
                Image(systemName: "questionmark.circle").foregroundStyle(Theme.amber)
                    .help("Neither its name nor its text said which language it is. Check it.")
            }
            LanguagePicker(title: "", selection: languageBinding(file.id))
                .labelsHidden()
                .frame(width: 180)
            moveMenu(file)
        }
        .contentShape(Rectangle())
        .draggable(file.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in drop(ids, on: file.target) }
    }

    private func moveMenu(_ file: ImportPlan.File) -> some View {
        let mates = plan.groupMates(of: file.id)
        let others = plan.targets.filter { $0.id != file.target && (plan.files(of: $0.id).count > 0 || $0.url != nil) }
        return Menu {
            Section("Move to") {
                ForEach(others) { t in
                    Button(t.name) { plan.move(file.id, to: t.id, withGroup: false) }
                }
            }
            if !mates.isEmpty {
                Section("Move with the \(mates.count) file\(mates.count == 1 ? "" : "s") timed like it to") {
                    ForEach(others) { t in
                        Button(t.name) { plan.move(file.id, to: t.id, withGroup: true) }
                    }
                }
            }
            if file.target != nil {
                Divider()
                Button("Leave Out") { plan.move(file.id, to: nil, withGroup: false) }
            }
        } label: {
            Image(systemName: "arrow.left.arrow.right")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .frame(width: 28)
        .help("Move to another video, or leave out")
    }

    // MARK: Actions

    private var summary: String {
        let total = plan.files.count
        let placed = plan.files.filter { $0.target != nil }.count
        let guesses = plan.files.filter { $0.target != nil && $0.reason?.isGuess == true }.count
        let videos = plan.targets.filter { $0.existingID == nil && ($0.url != nil || !plan.files(of: $0.id).isEmpty) }.count
        var parts: [String] = []
        if videos > 0 { parts.append("\(videos) \(plan.intoProject ? "new " : "")video\(videos == 1 ? "" : "s")") }
        parts.append("\(placed) of \(total) subtitle file\(total == 1 ? "" : "s") matched")
        if guesses > 0 { parts.append("\(guesses) by length only: check \(guesses == 1 ? "it" : "those")") }
        return parts.joined(separator: " · ")
    }

    /// The file that fills a new video's master language (none is marked for a video
    /// already in the project).
    private func masterFileID(of target: ImportPlan.Target) -> UUID? {
        guard target.existingID == nil else { return nil }
        let files = plan.files(of: target.id)
        return (files.first { $0.language == settings.masterLanguage } ?? files.first)?.id
    }

    private func languageBinding(_ id: UUID) -> Binding<Language> {
        Binding(
            get: { plan.files.first { $0.id == id }?.language ?? settings.masterLanguage },
            set: { new in
                guard let i = plan.files.firstIndex(where: { $0.id == id }) else { return }
                plan.files[i].language = new
                plan.files[i].languageGuessed = false
            })
    }

    private func drop(_ ids: [String], on target: UUID?) -> Bool {
        let moving = ids.compactMap(UUID.init(uuidString:)).filter { id in plan.files.contains { $0.id == id } }
        for id in moving where plan.files.first(where: { $0.id == id })?.target != target {
            plan.move(id, to: target, withGroup: false)
        }
        return !moving.isEmpty
    }

    private func finish() {
        let chosen = plan
        model.sheet = nil
        model.importPlan = nil
        if chosen.intoProject {
            model.addToProject(chosen)
        } else {
            let clean = name.trimmingCharacters(in: .whitespaces)
            model.createProject(from: chosen, name: clean.isEmpty ? chosen.name : clean, folder: folder, settings: settings)
        }
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

    /// 1:02:03 or 44:12.
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
