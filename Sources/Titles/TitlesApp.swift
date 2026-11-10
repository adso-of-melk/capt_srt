import SwiftUI
import AppKit

@main
struct TitlesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("KPTN.SUB", id: "main") {
            MainView(model: model, doc: model.doc)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear { appDelegate.attach(model) }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { TitlesCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var input: InputController?
    private weak var model: AppModel?
    /// Files opened from Finder before the window (and model) were ready.
    private var pendingOpen: [URL] = []

    /// Double-clicked .kptnsub files, and anything dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if let model { model.handleDrop(urls) } else { pendingOpen += urls }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched from `swift run` so the app gets a Dock icon and focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    @MainActor
    func attach(_ model: AppModel) {
        guard input == nil else { return }
        self.model = model
        if !pendingOpen.isEmpty {
            let urls = pendingOpen
            pendingOpen = []
            DispatchQueue.main.async { model.handleDrop(urls) }
        }
        let controller = InputController(model: model)
        controller.install()
        input = controller
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting: the last edits (autosave waits a moment after each change) are written now.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let model else { return }
            model.doc.commitLive()
            model.saveProject(wait: true)
        }
    }
}

struct TitlesCommands: Commands {
    @ObservedObject var model: AppModel

    private var noProject: Bool { model.showHome || model.project == nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") {
                model.newProjectVideo = nil
                model.sheet = .newProject
            }
            .keyboardShortcut("n")
            Button("Open Project…") { model.openProjectPanel() }
                .keyboardShortcut("o")
            Divider()
            Group {
                Button("Project Videos") { model.showProjectOverview() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Add Video…") { model.showProjectOverview(); model.addVideoPanel() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Add Video Link…") { model.showProjectOverview(); model.sheet = .openLink }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Button(model.currentVideoMissing ? "Locate Video File…" : "Replace Video File…") { model.replaceVideoPanel() }
                    .disabled(model.video == nil)
            }
            .disabled(noProject)
            Divider()
            Button("Back to Home") { model.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(noProject)
        }
        CommandGroup(replacing: .saveItem) {
            Group {
                Button("Save") { model.saveProject(announce: true) }
                    .keyboardShortcut("s")
                Button("Export…") { model.sheet = .export }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Reload Project from File…") { model.reloadProjectFromFile() }
                Button("Restore from Backup…") { model.restoreFromBackupPanel() }
                Divider()
                Button("Project Settings…") { model.sheet = .projectSettings }
                    .keyboardShortcut(",", modifiers: [.command, .option])
            }
            .disabled(noProject)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undo() }
                .keyboardShortcut("z")
                .disabled(noProject)
            Button("Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(noProject)
        }
        CommandGroup(after: .toolbar) {
            Toggle("All Languages on the Waveform", isOn: Binding(get: { model.allWaveBands }, set: { model.allWaveBands = $0 }))
                .disabled(model.openTracks.count < 2)
            Toggle("Text Only", isOn: $model.textOnly)
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(noProject)
        }
        CommandMenu("Language") {
            Group {
                Button("Next Language") { model.focusAdjacentTrack(1) }
                    .keyboardShortcut("l")
                Button("Previous Language") { model.focusAdjacentTrack(-1) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                ForEach(Array(model.openTracks.prefix(9).enumerated()), id: \.element.id) { i, track in
                    Button(columnTitle(track)) { model.focusTrack(atColumn: i) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Divider()
                Button("New Language from Master…") { model.sheet = .newLanguage }
                Button("Import Language…") { model.importLanguagePanel() }
                if let track = model.focusedTrack {
                    Divider()
                    if track.id != model.masterTrack?.id {
                        Button(track.locked ? "Unlock \(track.language.name)" : "Lock \(track.language.name) to Master") {
                            model.setLocked(track, !track.locked)
                        }
                        Button("Make \(track.language.name) the Master") { model.setMaster(track) }
                    }
                    if model.openTracks.count > 1 {
                        Button("Close \(track.language.name) Column") { model.closeColumn(track) }
                    }
                }
            }
            .disabled(noProject)
        }
        CommandMenu("Title") {
            Group {
                Button("Play / Pause  (⇧Space)") { model.togglePlay() }
                Button("Split at Playhead  (or ⌘-click a box)") { model.splitAtPlayhead() }
                    .keyboardShortcut("b")
                Button("Delete Title  (⌫ when not typing)") { model.deleteSelected() }
                Button("Re-break Lines") { model.rebreakSelected() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Button("Re-break All Lines in \(model.focusedTrack?.language.name ?? "This Language")") { model.rebreakAll() }
                    .keyboardShortcut("b", modifiers: [.command, .option, .shift])
                Button("Shift Titles…") { model.sheet = .shiftTitles }
                    .keyboardShortcut("t", modifiers: [.command, .option])
            }
            .disabled(noProject)
            Toggle("Break Long Lines Automatically", isOn: $model.autoLineBreaks)
            Divider()
            Toggle("Replay Title After Jog or Nudge", isOn: $model.replayAfterJog)
            Toggle("Replay Title After Drag-Resize", isOn: $model.replayAfterResize)
            Divider()
            Picker("Spotting Mode", selection: $model.spotMode) {
                ForEach(SpotMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Follow Playhead", isOn: $model.followPlayhead)
            Toggle("Trackpad Swipe Over the Selected Title Adjusts Its Edges", isOn: $model.swipeOverTitleAdjusts)
        }
    }

    private func columnTitle(_ track: Track) -> String {
        var t = track.language.name
        if track.id == model.masterTrack?.id { t += "  ★" }
        if track.locked { t += "  (locked)" }
        if track.id == model.focusedTrack?.id { t = "✓ " + t }
        return t
    }
}
