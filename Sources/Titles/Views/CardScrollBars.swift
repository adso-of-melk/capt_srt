import SwiftUI
import Combine
@testable import TitlesCore

/// Where the title pane is scrolled to, for its own scroll bars. (The system's are hidden:
/// the up-down one belonged to the cards, which scroll sideways as a whole, so with many
/// languages it sat off to the right, out of view.) Kept apart from the pane, so scrolling
/// redraws only the bars.
@MainActor
final class CardScrollTracker: ObservableObject {
    typealias Metrics = CardScrollMetrics

    /// A click or drag on a bar: the row (or column) to scroll to, and where it should end up.
    struct Request {
        var id: UUID
        var anchor: UnitPoint
    }

    /// The cards, up and down.
    @Published private(set) var rows = Metrics()
    /// The languages, sideways.
    @Published private(set) var columns = Metrics()
    /// Lit up while scrolling (wheel, Tab, the cards following the playhead), for a moment after.
    @Published private(set) var lit = false
    /// Rows to scroll to, from the up-down bar.
    let rowRequests = PassthroughSubject<Request, Never>()
    private var fade: Task<Void, Never>?

    func setRows(offset: CGFloat? = nil, content: CGFloat? = nil, viewport: CGFloat? = nil) {
        var m = rows
        if let offset { m.offset = offset }
        if let content { m.content = content }
        if let viewport { m.viewport = viewport }
        guard m != rows else { return }
        let moved = abs(m.offset - rows.offset) > 0.5
        rows = m
        if moved { light() }
    }

    func setColumns(_ m: Metrics) {
        guard m != columns else { return }
        let moved = abs(m.offset - columns.offset) > 0.5
        columns = m
        if moved { light() }
    }

    /// Lights the bars, and fades them back a little over a second after the last call.
    func light() {
        if !lit { lit = true }
        fade?.cancel()
        fade = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.lit = false
        }
    }

    /// The row to scroll to for a point on the up-down bar (`fraction`: 0 at the top of the
    /// bar's travel, 1 at the bottom), given how much of the list is in view.
    static func rowTarget(fraction: CGFloat, count: Int, share: CGFloat) -> (index: Int, anchor: UnitPoint)? {
        guard count > 0 else { return nil }
        if fraction >= 0.999 { return (count - 1, .bottom) }
        let room = max(0, CGFloat(count) * (1 - share))
        let index = Int((room * max(0, fraction)).rounded())
        return (min(count - 1, max(0, index)), .top)
    }
}

/// How far one of the title pane's scroll views is scrolled, and how much there is.
struct CardScrollMetrics: Equatable, Sendable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var viewport: CGFloat = 0
    var overflows: Bool { content > viewport + 1 }
    /// 0 scrolled to the start, 1 to the end.
    var position: CGFloat { overflows ? min(1, max(0, offset / (content - viewport))) : 0 }
    /// How much of the whole is in view.
    var share: CGFloat { content > 0 ? min(1, max(0, viewport / content)) : 1 }
}

/// The scroll offsets reported from inside the pane's scroll views.
struct CardRowsScrollKey: PreferenceKey {
    static let defaultValue = CardScrollMetrics()
    static func reduce(value: inout CardScrollMetrics, nextValue: () -> CardScrollMetrics) {
        value = nextValue()
    }
}

struct CardRowsViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct CardColumnsScrollKey: PreferenceKey {
    static let defaultValue = CardScrollMetrics()
    static func reduce(value: inout CardScrollMetrics, nextValue: () -> CardScrollMetrics) {
        value = nextValue()
    }
}

/// How the bars look: a thin dim line at rest, wider and brighter under the pointer or while
/// dragged, lit while the pane scrolls.
private enum BarLook {
    static func thickness(active: Bool) -> CGFloat { active ? 8 : 3 }
    static func track(active: Bool) -> Color { Theme.rule.opacity(active ? 0.8 : 0.45) }
    static func thumb(active: Bool, lit: Bool) -> Color {
        Theme.periwinkle.opacity(active ? 0.8 : (lit ? 0.6 : 0.3))
    }
}

/// The title pane's up-down scroll bar, on the pane's right edge, always there: it shows
/// where you are in the film. Click or drag anywhere on it to go there.
struct CardScrollBarV: View {
    /// Its strip, which can be pointed at; the bar is drawn at its right.
    static let width: CGFloat = 12

    @ObservedObject var tracker: CardScrollTracker
    let rows: [CardRow]
    @State private var hover = false
    @State private var dragging = false
    @State private var lastRequest: UUID?

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let m = tracker.rows
            let active = hover || dragging
            let bar = BarLook.thickness(active: active)
            let right: CGFloat = 2
            let thumbH = min(h, max(24, h * m.share))
            let thumbY = (h - thumbH) * m.position
            Canvas { ctx, size in
                let x = size.width - right - bar
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: bar, height: size.height), cornerRadius: bar / 2),
                         with: .color(BarLook.track(active: active)))
                if m.overflows {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: thumbY, width: bar, height: thumbH), cornerRadius: bar / 2),
                             with: .color(BarLook.thumb(active: active, lit: tracker.lit)))
                }
            }
            .frame(width: Self.width, height: h)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        scroll(toY: v.location.y, height: h, thumbHeight: thumbH)
                    }
                    .onEnded { _ in
                        dragging = false
                        lastRequest = nil
                    }
            )
            .animation(.easeOut(duration: 0.15), value: active)
            .animation(.easeOut(duration: 0.4), value: tracker.lit)
            .help("Where you are in the titles. Click or drag to go there.")
        }
        .frame(width: Self.width)
    }

    private func scroll(toY y: CGFloat, height h: CGFloat, thumbHeight: CGFloat) {
        guard tracker.rows.overflows else { return }
        let fraction = (y - thumbHeight / 2) / max(1, h - thumbHeight)
        guard let target = CardScrollTracker.rowTarget(fraction: fraction, count: rows.count, share: tracker.rows.share)
        else { return }
        let id = rows[target.index].key
        guard id != lastRequest else { return }
        lastRequest = id
        tracker.rowRequests.send(.init(id: id, anchor: target.anchor))
    }
}

/// The title pane's sideways scroll bar, along its bottom edge, when the languages don't all
/// fit. Click or drag to go there.
struct CardScrollBarH: View {
    static let height: CGFloat = 12

    @ObservedObject var tracker: CardScrollTracker
    /// The open languages, in order.
    let columnIDs: [UUID]
    /// Scrolls the pane to a language's column.
    let scrollTo: (UUID, UnitPoint) -> Void
    @State private var hover = false
    @State private var dragging = false
    @State private var lastRequest: UUID?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let m = tracker.columns
            let active = hover || dragging
            let bar = BarLook.thickness(active: active)
            let bottom: CGFloat = 2
            let thumbW = min(w, max(30, w * m.share))
            let thumbX = (w - thumbW) * m.position
            Canvas { ctx, size in
                let y = size.height - bottom - bar
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: bar), cornerRadius: bar / 2),
                         with: .color(BarLook.track(active: active)))
                ctx.fill(Path(roundedRect: CGRect(x: thumbX, y: y, width: thumbW, height: bar), cornerRadius: bar / 2),
                         with: .color(BarLook.thumb(active: active, lit: tracker.lit)))
            }
            .frame(width: w, height: Self.height)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        scroll(toX: v.location.x, width: w, thumbWidth: thumbW)
                    }
                    .onEnded { _ in
                        dragging = false
                        lastRequest = nil
                    }
            )
            .animation(.easeOut(duration: 0.15), value: active)
            .animation(.easeOut(duration: 0.4), value: tracker.lit)
            .help("More languages to the side. Click or drag to see them.")
        }
        .frame(height: Self.height)
    }

    private func scroll(toX x: CGFloat, width w: CGFloat, thumbWidth: CGFloat) {
        guard !columnIDs.isEmpty, tracker.columns.overflows else { return }
        let fraction = (x - thumbWidth / 2) / max(1, w - thumbWidth)
        guard let target = CardScrollTracker.rowTarget(fraction: fraction, count: columnIDs.count,
                                                       share: tracker.columns.share) else { return }
        let id = columnIDs[target.index]
        guard id != lastRequest else { return }
        lastRequest = id
        scrollTo(id, target.anchor == .bottom ? .trailing : .leading)
    }
}
