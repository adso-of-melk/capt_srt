import SwiftUI
import AppKit

@main
struct TitlesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Titles", id: "main") {
            MainView(model: model, doc: model.doc)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear { appDelegate.attach(model) }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { TitlesCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var input: InputController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched from `swift run` so the app gets a Dock icon and focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    @MainActor
    func attach(_ model: AppModel) {
        guard input == nil else { return }
        let controller = InputController(model: model)
        controller.install()
        input = controller
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct TitlesCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Video…") { model.openVideoPanel() }
                .keyboardShortcut("o")
            Button("Open Video Link…") { model.showURLSheet = true }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Button("Open Subtitles…") { model.openSubtitlesPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.save() }
                .keyboardShortcut("s")
            Button("Save As…") { model.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Export WebVTT…") { model.exportVTT() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.doc.undo() }
                .keyboardShortcut("z")
            Button("Redo") { model.doc.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Title") {
            Button("Play / Pause") { model.togglePlay() }
            Button("Delete Title  (⌫ when not typing)") { model.deleteSelected() }
            Divider()
            Picker("Spotting Mode", selection: $model.spotMode) {
                ForEach(SpotMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Timing Preset", selection: presetBinding) {
                ForEach(TimingPreset.all) { Text($0.name).tag($0.id) }
            }
            Toggle("Follow Playhead", isOn: $model.followPlayhead)
        }
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { model.preset.id },
            set: { id in model.preset = TimingPreset.all.first { $0.id == id } ?? .general }
        )
    }
}
