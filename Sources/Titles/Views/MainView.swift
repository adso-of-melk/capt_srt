import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Card pane on the left; video top right; title bar and waveform bottom right.
struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var doc: SubtitleDocument
    @State private var urlText = ""

    var body: some View {
        Group {
            if model.showHome {
                HomeView(model: model)
            } else {
                editor
            }
        }
        .background(Theme.background)
        .background(WindowAccessor { model.mainWindow = $0 })
        .preferredColorScheme(.dark)
        .tint(Theme.amber)
        .navigationTitle(model.showHome ? "Titles" : model.windowTitle)
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
            return !urls.isEmpty
        }
        .sheet(isPresented: $model.showURLSheet) {
            OpenURLSheet(text: $urlText) { string in
                model.showURLSheet = false
                model.openURLString(string)
            } cancel: {
                model.showURLSheet = false
            }
        }
    }

    private var editor: some View {
        HSplitView {
            CardPane(model: model, doc: doc)
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)

            VSplitView {
                VideoPane(model: model, doc: doc, clock: model.clock)
                    .frame(minHeight: 240)
                VStack(spacing: 0) {
                    TitleBar(model: model, clock: model.clock, audio: model.audio)
                    WaveformPane(model: model, doc: doc, clock: model.clock, audio: model.audio)
                }
                .frame(minHeight: 170, idealHeight: 240)
            }
            .frame(minWidth: 560)
        }
    }
}

private struct OpenURLSheet: View {
    @Binding var text: String
    let open: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneHeader(title: "Open video link", color: Theme.periwinkle)
                .padding(.horizontal, -12)
            Text("A direct link to a video file (https://…/film.mp4) or an HLS stream (.m3u8).")
                .font(Theme.label(12, .regular))
                .foregroundStyle(Theme.textDim)
            TextField("https://", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { open(text) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Open") { open(text) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ConsoleButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.panel)
    }
}

/// Reports the NSWindow hosting this view.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { onWindow(window) }
    }
}
