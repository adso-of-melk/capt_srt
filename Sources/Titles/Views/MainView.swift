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
                // Card pane | divider | picture, divider, waveform. Both dividers are our own (see
                // PaneDivider), so they can be grabbed anywhere along them and always move.
                GeometryReader { geo in
                    let total = geo.size.width
                    let height = geo.size.height
                    let d = PaneDivider.thickness
                    let paneWidth = model.cardPaneWidth(in: total, divider: d)
                    let waveHeight = model.waveformPaneHeight(in: height, divider: d)
                    HStack(spacing: 0) {
                        CardPane(model: model, doc: doc)
                            .frame(width: paneWidth)
                        PaneDivider(
                            size: paneWidth,
                            resize: { model.setCardPaneWidth($0, in: total, divider: d) },
                            reset: { model.cardPaneWidth = 0 })
                            .frame(width: d)
                        VStack(spacing: 0) {
                            VideoPane(model: model, doc: doc, clock: model.clock)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            PaneDivider(
                                axis: .horizontal,
                                size: waveHeight,
                                resize: { model.setWaveformPaneHeight($0, in: height, divider: d) },
                                reset: { model.waveformPaneHeight = 0 })
                                .frame(height: d)
                            VStack(spacing: 0) {
                                TitleBar(model: model, clock: model.clock, audio: model.audio)
                                WaveformPane(model: model, doc: doc, clock: model.clock, audio: model.audio)
                            }
                            .frame(height: waveHeight)
                        }
                        .frame(minWidth: AppModel.pictureMinWidth, maxWidth: .infinity)
                    }
                    .frame(width: total, height: height, alignment: .topLeading)
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
        // Opening or closing a language resizes the card pane to fit the languages.
        .onChange(of: model.openTracks.count) { _, _ in
            withAnimation(.easeOut(duration: 0.2)) { model.openColumnsChanged() }
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

/// The line between two panes: an 8-point strip, grabbable anywhere along it, with the resize
/// cursor over all of it. Drag to resize the pane; double-click to put it back to its usual
/// size. AppKit, so nothing in the panes beside it can take the mouse. Upright (`.vertical`)
/// between the card pane and the picture, sizing the card pane on its left; lying flat
/// (`.horizontal`) between the picture and the waveform, sizing the waveform below it.
struct PaneDivider: NSViewRepresentable {
    static let thickness: CGFloat = 8
    /// Which way the line runs.
    var axis: Axis = .vertical
    /// The size of the pane it resizes now: the card pane's width, or the waveform's height.
    let size: CGFloat
    /// The size asked for while dragging.
    let resize: (CGFloat) -> Void
    let reset: () -> Void

    func makeNSView(context: Context) -> PaneDividerView { PaneDividerView() }

    func updateNSView(_ v: PaneDividerView, context: Context) {
        if v.axis != axis {
            v.axis = axis
            v.window?.invalidateCursorRects(for: v)
            v.needsDisplay = true
        }
        v.paneSize = size
        v.resize = resize
        v.reset = reset
    }

    /// The pane's new size for a drag from `start` to `now` (window points: x grows to the
    /// right, y upwards). Both panes grow as the line moves away from them: the card pane on
    /// its left as it goes right, the waveform below it as it goes up.
    static func dragged(from start: CGFloat, to now: CGFloat, size: CGFloat) -> CGFloat {
        size + now - start
    }
}

final class PaneDividerView: NSView {
    var axis: Axis = .vertical
    var paneSize: CGFloat = 0
    var resize: ((CGFloat) -> Void)?
    var reset: (() -> Void)?
    private var dragFrom: (at: CGFloat, size: CGFloat)?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    private var cursor: NSCursor { axis == .vertical ? .resizeLeftRight : .resizeUpDown }
    private func along(_ event: NSEvent) -> CGFloat {
        axis == .vertical ? event.locationInWindow.x : event.locationInWindow.y
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { if dragFrom == nil { hovering = false } }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragFrom = nil
            reset?()
            return
        }
        dragFrom = (along(event), paneSize)
        hovering = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = dragFrom else { return }
        cursor.set()
        resize?(PaneDivider.dragged(from: from.at, to: along(event), size: from.size))
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
        if axis == .vertical {
            CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height).fill()
        } else {
            CGRect(x: 0, y: (bounds.height - w) / 2, width: bounds.width, height: w).fill()
        }
    }
}
