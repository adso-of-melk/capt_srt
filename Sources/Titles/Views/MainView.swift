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
                        .frame(minWidth: 340, idealWidth: 360, maxWidth: .infinity)
                        .overlay(alignment: .trailing) { DividerGrip(model: model, width: 7) }

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
                    .overlay(alignment: .leading) { DividerGrip(model: model, width: 4) }
                }
                .onAppear { sizeCardPane() }
            }
        }
        .onChange(of: model.project?.id) { _, _ in sizeCardPane() }
        .onChange(of: model.openTracks.count) { old, new in
            if new > old { widenCardPaneForColumns(new) }
        }
    }

    /// Adding a language: widen the card pane so every column fits (about 240 pt each),
    /// keeping at least 620 pt for the picture and waveform. Never narrows it.
    private func widenCardPaneForColumns(_ count: Int) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let content = model.mainWindow?.contentView,
                  let split = Self.firstSideBySideSplit(in: content),
                  let pane = split.subviews.first else { return }
            let needed = CGFloat(count) * 240 + CGFloat(max(0, count - 1)) * 8 + 24
            let limit = split.bounds.width - 620 - split.dividerThickness
            let target = min(needed, limit)
            guard target > pane.frame.width + 1 else { return }
            split.setPosition(target, ofDividerAt: 0)
        }
    }

    /// Opens the card pane at a quarter of the window (at least its minimum width). Drag the
    /// divider to widen it for more languages.
    private func sizeCardPane() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let window = model.mainWindow, let content = window.contentView,
                  let split = Self.firstSideBySideSplit(in: content) else { return }
            let width = max(340, (split.bounds.width * 0.25).rounded())
            split.setPosition(width, ofDividerAt: 0)
        }
    }

    static func firstSideBySideSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.isVertical, split.subviews.count >= 2 { return split }
        for sub in view.subviews {
            if let found = firstSideBySideSplit(in: sub) { return found }
        }
        return nil
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

/// A wider, invisible grab zone on each side of the card pane's divider, so it's easy to
/// catch. Dragging it moves the divider.
private struct DividerGrip: View {
    @ObservedObject var model: AppModel
    let width: CGFloat
    @State private var startPosition: CGFloat?
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside && !hovering { NSCursor.resizeLeftRight.push() }
                if !inside && hovering { NSCursor.pop() }
                hovering = inside
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard let content = model.mainWindow?.contentView,
                              let split = MainView.firstSideBySideSplit(in: content),
                              let pane = split.subviews.first else { return }
                        if startPosition == nil { startPosition = pane.frame.width }
                        split.setPosition((startPosition ?? 0) + value.translation.width, ofDividerAt: 0)
                    }
                    .onEnded { _ in startPosition = nil }
            )
    }
}
