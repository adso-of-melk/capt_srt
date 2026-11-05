import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Top strip above everything. Card pane on the left; video top right; title bar and
/// waveform bottom right. Text Only mode keeps just the cards and a slim transport.
struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var doc: SubtitleDocument

    var body: some View {
        Group {
            if model.showHome || model.project == nil {
                HomeView(model: model)
            } else {
                editor
            }
        }
        .background(Theme.background)
        .background(WindowAccessor { window in
            let first = model.mainWindow == nil
            model.mainWindow = window
            if first { Self.sizeToFit(window) }
        })
        .preferredColorScheme(.dark)
        .tint(Theme.amber)
        .navigationTitle(model.showHome ? "KPTN.SUB" : model.windowTitle)
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
            return !urls.isEmpty
        }
        .sheet(item: $model.sheet) { kind in
            SheetHost(model: model, kind: kind)
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            TopStrip(model: model)
            if let text = model.banner {
                BannerView(text: text) { model.banner = nil }
            }
            if model.textOnly {
                VStack(spacing: 0) {
                    CardPane(model: model, doc: doc)
                    SlimTransport(model: model, clock: model.clock)
                }
            } else {
                HSplitView {
                    CardPane(model: model, doc: doc)
                        .frame(minWidth: 340, idealWidth: 460, maxWidth: .infinity)

                    VSplitView {
                        VideoPane(model: model, doc: doc, clock: model.clock)
                            .frame(minHeight: 240)
                        VStack(spacing: 0) {
                            TitleBar(model: model, clock: model.clock, audio: model.audio)
                            WaveformPane(model: model, doc: doc, clock: model.clock, audio: model.audio)
                        }
                        .frame(minHeight: 170, idealHeight: 260)
                    }
                    .frame(minWidth: 620)
                }
            }
        }
    }

    /// Opens the window wide enough that no label in the title bar or headers wraps.
    private static func sizeToFit(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let want = NSSize(width: min(1480, visible.width), height: min(940, visible.height))
        var frame = window.frame
        guard frame.width < want.width || frame.height < want.height else { return }
        frame.size = NSSize(width: max(frame.width, want.width), height: max(frame.height, want.height))
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(frame, display: true, animate: false)
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
