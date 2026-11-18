import SwiftUI
import AppKit
import UniformTypeIdentifiers
@testable import TitlesCore

/// Top strip above everything. Card pane on the left; video top right; title bar and
/// waveform bottom right. Text Only mode keeps just the cards and a slim transport.
struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var doc: SubtitleDocument

    var body: some View {
        Group {
            if model.showHome || model.project == nil {
                HomeView(model: model)
            } else if model.showProjectView, let project = model.project {
                ProjectView(model: model, project: project)
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
            if model.qcMode {
                QCBar(model: model, doc: doc)
            }
            if let text = model.banner {
                BannerView(text: text) { model.banner = nil }
            }
            if model.currentVideoMissing {
                MissingVideoBanner(model: model)
            }
            if model.textOnly {
                VStack(spacing: 0) {
                    CardPane(model: model, doc: doc)
                    SlimTransport(model: model, clock: model.clock)
                }
            } else {
                // Card pane | divider | picture and waveform. The divider is our own (see
                // PaneDivider), so it can be grabbed anywhere along its width and always moves.
                GeometryReader { geo in
                    let total = geo.size.width
                    let paneWidth = model.cardPaneWidth(in: total, divider: PaneDivider.thickness)
                    HStack(spacing: 0) {
                        CardPane(model: model, doc: doc)
                            .frame(width: paneWidth)
                        PaneDivider(
                            width: paneWidth,
                            resize: { model.setCardPaneWidth($0, in: total, divider: PaneDivider.thickness) },
                            reset: { model.cardPaneWidth = 0 })
                            .frame(width: PaneDivider.thickness)
                        VSplitView {
                            VideoPane(model: model, doc: doc, clock: model.clock)
                                .frame(minHeight: 240)
                            VStack(spacing: 0) {
                                TitleBar(model: model, clock: model.clock, audio: model.audio)
                                WaveformPane(model: model, doc: doc, clock: model.clock, audio: model.audio)
                            }
                            .frame(minHeight: 170, idealHeight: 260)
                        }
                        .frame(minWidth: AppModel.pictureMinWidth, maxWidth: .infinity)
                    }
                    .frame(width: total, height: geo.size.height, alignment: .topLeading)
                }
            }
        }
        // QC mode: a thin "yellow alert" frame round the panes (the picture keeps its colours).
        .overlay {
            if model.qcMode {
                Rectangle()
                    .strokeBorder(Theme.alert.opacity(0.5), lineWidth: 1.5)
                    .padding(.top, 30)
                    .allowsHitTesting(false)
            }
        }
        // A new project opens with the card pane at its usual width.
        .onChange(of: model.project?.id) { _, _ in model.cardPaneWidth = 0 }
        .onChange(of: model.openTracks.count) { old, new in
            if new > old { model.widenCardPaneForColumns(divider: PaneDivider.thickness) }
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

/// The line between the card pane and the picture: an 8-point strip, grabbable anywhere along
/// it, with the resize cursor over all of it. Drag to resize the card pane; double-click to put
/// it back to its usual width. AppKit, so nothing in the panes beside it can take the mouse.
struct PaneDivider: NSViewRepresentable {
    static let thickness: CGFloat = 8
    /// The card pane's width now.
    let width: CGFloat
    /// The width asked for while dragging.
    let resize: (CGFloat) -> Void
    let reset: () -> Void

    func makeNSView(context: Context) -> PaneDividerView { PaneDividerView() }

    func updateNSView(_ v: PaneDividerView, context: Context) {
        v.paneWidth = width
        v.resize = resize
        v.reset = reset
    }
}

final class PaneDividerView: NSView {
    var paneWidth: CGFloat = 0
    var resize: ((CGFloat) -> Void)?
    var reset: (() -> Void)?
    private var dragFrom: (x: CGFloat, width: CGFloat)?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { if dragFrom == nil { hovering = false } }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragFrom = nil
            reset?()
            return
        }
        dragFrom = (event.locationInWindow.x, paneWidth)
        hovering = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = dragFrom else { return }
        NSCursor.resizeLeftRight.set()
        resize?(from.width + event.locationInWindow.x - from.x)
    }

    override func mouseUp(with event: NSEvent) {
        dragFrom = nil
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        hovering = inside
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        bounds.fill()
        // A hairline at rest; brighter and wider while hovered or dragged.
        let active = hovering || dragFrom != nil
        let w: CGFloat = active ? 2 : 1
        (active ? Palette.amber.withAlphaComponent(0.8) : Palette.rule).setFill()
        CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height).fill()
    }
}
