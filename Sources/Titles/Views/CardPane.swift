import SwiftUI
import AppKit
import UniformTypeIdentifiers
@testable import TitlesCore

/// Left pane: one column of cards per open language, side by side. Linked titles share a
/// row, and a language with no title in a row shows an empty slot, so rows always line up.
/// This is the only place text is edited.
struct CardPane: View {
    @ObservedObject var model: AppModel
    /// The focused language's titles.
    @ObservedObject var doc: SubtitleDocument
    /// Where the pane is scrolled to, for its own scroll bars. Held, not observed, so
    /// scrolling redraws only the bars.
    @State private var scroll = CardScrollTracker()
    private static let rowsSpace = "cardRows"
    /// The list's own points, from its top (rows don't move in it as it scrolls).
    private static let listSpace = "cardList"
    /// The language bars above the cards (26 points and their padding).
    private static let headerRowHeight: CGFloat = 38

    var body: some View {
        let tracks = model.openTracks
        VStack(spacing: 0) {
            PaneHeader(title: model.qcMode ? "Titles · QC" : "Titles", color: model.qcMode ? Theme.alert : Theme.amber) {
                Chip(text: "\(model.rows.count)", color: Theme.peach)
                Button {
                    model.textOnly.toggle()
                } label: {
                    Image(systemName: model.textOnly ? "rectangle.split.2x1" : "text.alignleft")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .help(model.textOnly ? "Show the picture and waveform (⇧⌘T)" : "Text only: hide the picture and waveform (⇧⌘T)")
            }
            FindBarSlot(find: model.find)
            GeometryReader { geo in
                let gap: CGFloat = 8
                let count = CGFloat(max(1, tracks.count))
                // Columns share the pane; narrower than full size, the text shrinks instead.
                let width = AppModel.cardColumnWidth(pane: geo.size.width, count: tracks.count,
                                                     floor: model.cardColumnFloor, gap: gap)
                let total = width * count + gap * (count - 1) + 24
                let overflows = total > geo.size.width + 1
                let viewport = geo.size.width
                let lastStop = ColumnStops.last(count: tracks.count, width: width, gap: gap, viewport: viewport)
                ScrollViewReader { hProxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(spacing: 0) {
                            // Where sideways scrolling stops: a marker every column along, so a
                            // whole language always ends up at the left edge (ColumnStops).
                            HStack(spacing: 0) {
                                ForEach(0..<max(1, tracks.count), id: \.self) { k in
                                    Color.clear.frame(width: width + gap, height: 0).id(ColumnStopID(index: k))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 0)
                            HStack(spacing: gap) {
                                ForEach(tracks) { track in
                                    LanguageHeader(model: model, track: track, width: width, gap: gap)
                                        .id(track.id)
                                        .zIndex(model.draggingColumn == track.id ? 1 : 0)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .overlay(alignment: .trailing) {
                                AddLanguageMenu(model: model).padding(.trailing, 14)
                            }
                            rowsList(tracks: tracks, width: width, gap: gap)
                        }
                        .frame(width: max(total, geo.size.width), height: geo.size.height, alignment: .top)
                    }
                    // Another language focused (⌘L, a click): bring its column into view,
                    // still with a whole column at the left edge.
                    .onChange(of: model.video?.focusedTrackID) { _, id in
                        guard overflows, let id, let index = tracks.firstIndex(where: { $0.id == id }) else { return }
                        let stop = ColumnStops.revealing(index, from: scroll.columnStop,
                                                         fit: ColumnStops.fitting(width: width, gap: gap, viewport: viewport),
                                                         last: lastStop)
                        guard stop != scroll.columnStop else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            scroll.setColumnStop(stop)
                            hProxy.scrollTo(ColumnStopID(index: stop), anchor: .leading)
                        }
                    }
                    // Sideways scrolling over the pane (wheel, trackpad): a whole column at a time.
                    .onReceive(model.columnSteps) { move in
                        guard overflows else { return }
                        withAnimation(.easeInOut(duration: 0.28)) {
                            guard let stop = scroll.stepColumns(move: move, last: lastStop) else { return }
                            hProxy.scrollTo(ColumnStopID(index: stop), anchor: .leading)
                        }
                    }
                    // Wider or narrower columns, or fewer of them: the same language stays at
                    // the left edge (as far as the last one allows), exactly lined up.
                    .onChange(of: width) { _, _ in
                        let stop = overflows ? min(scroll.columnStop, lastStop) : 0
                        scroll.setColumnStop(stop, light: false)
                        hProxy.scrollTo(ColumnStopID(index: stop), anchor: .leading)
                    }
                    .onChange(of: lastStop) { _, _ in
                        let stop = overflows ? min(scroll.columnStop, lastStop) : 0
                        scroll.setColumnStop(stop, light: false)
                        hProxy.scrollTo(ColumnStopID(index: stop), anchor: .leading)
                    }
                    // Our own scroll bars, on the pane's edges whichever way it's scrolled.
                    .overlay(alignment: .topTrailing) {
                        CardScrollBarV(tracker: scroll, rows: model.rows) { model.fastScrolling = $0 }
                            .padding(.top, Self.headerRowHeight)
                            .padding(.bottom, overflows ? CardScrollBarH.height : 0)
                    }
                    .overlay(alignment: .bottom) {
                        if overflows {
                            CardScrollBarH(tracker: scroll, lastStop: lastStop,
                                           share: min(1, viewport / max(1, total))) { stop in
                                withAnimation(.easeOut(duration: 0.15)) {
                                    scroll.setColumnStop(stop)
                                    hProxy.scrollTo(ColumnStopID(index: stop), anchor: .leading)
                                }
                            }
                            .padding(.trailing, CardScrollBarV.width)
                        }
                    }
                }
            }
            // For sideways scrolling a column at a time (see InputController).
            .background(WindowFrameReporter { model.cardPaneFrame = $0 })
        }
        .background(model.qcMode ? Theme.alertPanel : Theme.panel)
    }

    @ViewBuilder
    private func rowsList(tracks: [Track], width: CGFloat, gap: CGFloat) -> some View {
        let focusedID = model.video?.focusedTrackID
        let selectedRow = model.selectedRowKey
        let overlaps = doc.overlappingIDs
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.key) { index, row in
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(tracks) { track in
                                                // Only the focused language is highlighted, so it's always clear
                                // which language a change goes to.
                                cell(row: row, number: index + 1, track: track, width: width, isFocusedColumn: track.id == focusedID,
                                     inSelectedRow: row.key == selectedRow && track.id == focusedID, overlaps: overlaps)
                                    .frame(width: width)
                            }
                        }
                        // Where the row is, for the cards' flow with the film (see CardFlow).
                        .background(GeometryReader { g in
                            Color.clear.preference(key: CardRowFramesKey.self,
                                                   value: [row.key: g.frame(in: .named(Self.listSpace))])
                        })
                        .id(row.key)
                    }
                    if model.rows.isEmpty { EmptyCards(hasMedia: model.hasMedia, locked: model.focusedIsLocked) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 2)
                .coordinateSpace(.named(Self.listSpace))
                .background(GeometryReader { g in
                    Color.clear.preference(key: CardRowsScrollKey.self,
                                           value: CardScrollMetrics(offset: -g.frame(in: .named(Self.rowsSpace)).minY,
                                                                    content: g.size.height))
                })
                // Watches the scroll view itself, for the scroll bar (see RowsScrollObserver).
                .background(RowsScrollObserver(tracker: scroll, model: model))
            }
            .coordinateSpace(.named(Self.rowsSpace))
            .background(GeometryReader { g in
                Color.clear.preference(key: CardRowsViewportKey.self, value: g.size.height)
            })
            .onPreferenceChange(CardRowsScrollKey.self) { m in
                MainActor.assumeIsolated { scroll.setRowsFromLayout(offset: m.offset, content: m.content) }
            }
            .onPreferenceChange(CardRowsViewportKey.self) { h in
                MainActor.assumeIsolated { scroll.setRowsFromLayout(viewport: h) }
            }
            .onPreferenceChange(CardRowFramesKey.self) { frames in
                MainActor.assumeIsolated { scroll.rowFrames = frames }
            }
            // A click or drag on the scroll bar.
            .onReceive(scroll.rowRequests) { request in
                proxy.scrollTo(request.id, anchor: request.anchor)
            }
            .onChange(of: doc.selectedID) { _, id in
                guard let id, let key = model.rowKey(ofSub: id) else { return }
                // Following the playhead: the cards flow with the film, frame by frame (see
                // CardFlow), or (that turned off, or the title not laid out yet) a slow, eased
                // glide. Picked by hand (click, Tab): straight there.
                let follow = model.clock.isPlaying
                if follow, scroll.flowTakesOver(glide: model.glideDuration(to: id)) { return }
                withAnimation(follow ? .easeInOut(duration: model.glideDuration(to: id)) : .easeOut(duration: 0.15)) {
                    proxy.scrollTo(key, anchor: .center)
                }
            }
            .onChange(of: model.cardScrollTarget) { _, id in
                guard let id else { return }
                let key = model.rowKey(ofSub: id) ?? id
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(key, anchor: .center) }
                // Clear it so the same target scrolls again next time.
                model.cardScrollTarget = nil
            }
        }
    }

    @ViewBuilder
    private func cell(row: CardRow, number: Int, track: Track, width: CGFloat, isFocusedColumn: Bool,
                      inSelectedRow: Bool, overlaps: Set<UUID>) -> some View {
        // Another language's column steps back (see StepBack).
        let back = model.columnStepsBack(track.id)
        if let sub = row.cells[track.id] {
            let fast = model.fastScrolling && !(isFocusedColumn && doc.selectedID == sub.id)
            CardView(
                model: model,
                track: track,
                sub: sub,
                number: model.rowNumber(of: sub.id) ?? number,
                isSelected: isFocusedColumn && doc.selectedID == sub.id,
                inGroup: isFocusedColumn && model.multiSelection.count > 1 && model.multiSelection.contains(sub.id),
                inSelectedRow: inSelectedRow,
                isOverlapping: isFocusedColumn && overlaps.contains(sub.id),
                // While the scroll bar is dragged, cards come in light (no issue tags or
                // spelling marks) so the list keeps up; they fill in when it's let go.
                qcMarks: fast ? nil : model.visibleQCMarks(of: sub, in: track, overlapping: overlaps),
                qcMuted: !isFocusedColumn,
                // QC mode's outline and dimming are for the language being checked.
                qcLook: model.qcMode && isFocusedColumn,
                preset: model.preset(for: track),
                compact: model.openTracks.count > 1,
                width: width,
                light: fast,
                stepBack: back
            )
            .modifier(StepBack(on: back, desaturates: false))
        } else {
            EmptySlot(isSelected: isFocusedColumn && model.emptySlotRow == row.key && doc.selectedID == nil,
                      inSelectedRow: inSelectedRow, locked: track.locked,
                      italic: isFocusedColumn && model.italicNext == row.key)
                .onTapGesture(count: 2) {
                    if model.video?.focusedTrackID != track.id { model.focusTrack(track.id, edit: false) }
                    model.createInRow(row.key)
                }
                .onTapGesture {
                    if model.video?.focusedTrackID != track.id { model.focusTrack(track.id, edit: false) }
                    model.focusRequest = nil
                    model.mainWindow?.makeFirstResponder(nil)
                    model.doc.selectedID = nil
                    model.emptySlotRow = row.key
                    model.seek(row.time)
                }
                .modifier(StepBack(on: back))
        }
    }
}

/// A card takes words dragged out of the card being typed in (see AppModel.dropText):
/// they move there, or are copied with Option or into another language.
private struct TextDropTarget: DropDelegate {
    let model: AppModel
    let track: Track
    let id: UUID
    @Binding var hovering: Bool

    func validateDrop(info: DropInfo) -> Bool { model.acceptsTextDrop(on: id) }
    func dropEntered(info: DropInfo) { hovering = model.acceptsTextDrop(on: id) }
    func dropExited(info: DropInfo) { hovering = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Always "copy" to the card the words came from: the move is done here, in one undo
        // step, and the card mustn't take the words out a second time.
        DropProposal(operation: .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        hovering = false
        return model.dropText(on: id, in: track, copy: NSEvent.modifierFlags.contains(.option))
    }
}

/// Card texts as shown, already worked out (see CardView.decoratedText).
@MainActor
private enum DecoratedTexts {
    struct Key: Hashable {
        let text: String
        let language: String
        let spelling: Int
        let found: [NSRange]
        let current: Int?
    }
    static var known: [Key: AttributedString] = [:]
}

/// Text sizes the cards have already worked out (see CardView.fittingSize).
@MainActor
private enum FittingSizes {
    struct Key: Hashable {
        let text: String
        let width: CGFloat
    }
    static var known: [Key: CGFloat] = [:]
}

/// "Italics on" for an empty title: what's typed or pasted into it next is italic (⌘I: off).
private struct ItalicBadge: View {
    var body: some View {
        Text("I")
            .font(.system(size: 10, weight: .heavy).italic())
            .foregroundStyle(Theme.background)
            .frame(width: 16, height: 14)
            .background(Capsule().fill(Theme.peach))
            .help("Italics on: what you type or paste here is italic. ⌘I turns it off.")
    }
}

/// Shown on the card you're typing in: Esc takes the cursor out, and then ⌘I, ⌘V and Tab
/// work on whole titles.
private struct EscHint: View {
    var body: some View {
        Text("esc")
            .font(Theme.mono(8.5, .semibold))
            .foregroundStyle(Theme.textDim.opacity(0.8))
            .padding(.horizontal, 5)
            .frame(height: 11)
            .background(Capsule().fill(Theme.panelRaised))
            .overlay(Capsule().stroke(Theme.textFaint.opacity(0.6), lineWidth: 0.75))
            .help("Esc leaves the text. Then ⌘I makes the whole title italic, ⌘V pastes at its end, and Tab moves on without the cursor.")
    }
}

/// A row where this language has no title yet. Double-click (or select it and type) to create one.
private struct EmptySlot: View {
    let isSelected: Bool
    let inSelectedRow: Bool
    let locked: Bool
    var italic = false
    @State private var hover = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(isSelected ? Theme.amber : (inSelectedRow ? Theme.amber.opacity(0.35) : Theme.rule),
                    style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: [4, 4]))
            .background(RoundedRectangle(cornerRadius: 10).fill(hover || isSelected ? Theme.panelRaised.opacity(0.35) : .clear))
            .overlay {
                if hover || isSelected {
                    Text(locked ? "Locked" : "Double-click to add")
                        .font(Theme.label(11, .medium))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .overlay(alignment: .topTrailing) {
                if italic { ItalicBadge().padding(6) }
            }
            .frame(minHeight: 84)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// The header above a language column: name, master star, lock, menu and close.
/// The coloured cap before a language's name. Hover it and it turns into a close button.
private struct ColumnCap: View {
    let color: Color
    let canClose: Bool
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        ZStack {
            Capsule().fill(hover && canClose ? Theme.red : color)
            if hover && canClose {
                Image(systemName: "xmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(Theme.background)
            }
        }
        .frame(width: 16, height: 10)
        .contentShape(Rectangle().inset(by: -4))
        .onHover { hover = $0 }
        .onTapGesture { if canClose { close() } }
        .help(canClose ? "Close this column (nothing is deleted)" : "")
    }
}

private struct LanguageHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var track: Track
    let width: CGFloat
    var gap: CGFloat = 8
    /// Dragging the bar sideways reorders the columns.
    @State private var dragX: CGFloat = 0
    /// How far the bar's own place has moved since the drag began (the columns swap as it goes).
    @State private var slotShift: CGFloat = 0

    var body: some View {
        let isFocused = model.video?.focusedTrackID == track.id
        let isMaster = model.video?.masterTrackID == track.id
        let index = (model.video?.openTrackIDs.firstIndex(of: track.id) ?? 0) + 1
        HStack(spacing: 6) {
            ColumnCap(color: isFocused ? Theme.amber : Theme.periwinkle.opacity(0.6),
                      canClose: (model.video?.openTrackIDs.count ?? 0) > 1) { model.closeColumn(track) }
            Text(track.language.name.uppercased())
                .font(Theme.label(10, .bold))
                .tracking(1.4)
                .foregroundStyle(isFocused ? Theme.amber : Theme.textDim)
                .lineLimit(1)
            Text(track.language.code)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.textFaint)
            if isMaster { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Theme.peach).help("Master language") }
            if track.locked { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Theme.lilac).help("Locked to the master's timing") }
            Spacer(minLength: 4)
            if index <= 9 {
                Text("⌘\(index)").font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
            }
            Menu {
                LanguageMenuItems(model: model, track: track)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(isFocused ? Theme.amber.opacity(0.12) : Theme.panelRaised.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isFocused ? Theme.amber.opacity(0.8) : Theme.rule, lineWidth: 1))
        // The language being worked in: an amber rail under its bar, as the waveform marks
        // the selected title in amber.
        .overlay(alignment: .bottom) {
            if isFocused && (model.video?.openTrackIDs.count ?? 0) > 1 {
                Capsule().fill(Theme.amber).frame(height: 2).padding(.horizontal, 12).offset(y: 5)
            }
        }
        .modifier(StepBack(on: model.columnStepsBack(track.id)))
        .contentShape(Rectangle())
        .offset(x: dragX)
        // The bar being dragged jumps to its new place as the columns swap (its offset makes
        // up the difference, so it stays under the pointer); the rest slide.
        .transaction { t in if model.draggingColumn == track.id { t.animation = nil } }
        .shadow(color: .black.opacity(dragX == 0 ? 0 : 0.5), radius: 6, y: 2)
        .onTapGesture { model.focusTrack(track.id, edit: false) }
        // Drag the bar left or right to move the column there (as Move Column Left / Right).
        // Once it's half way over its neighbour, the two swap there and then (the cards slide
        // across, and a Force Touch trackpad gives a tick), with the bar still under the pointer.
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in
                    model.draggingColumn = track.id
                    let ids = model.video?.openTrackIDs ?? []
                    guard let here = ids.firstIndex(of: track.id) else { return }
                    let x = value.translation.width - slotShift
                    let to = AppModel.columnDropIndex(from: here, offset: x, step: width + gap, count: ids.count)
                    if to != here {
                        withAnimation(.easeOut(duration: 0.18)) { model.moveColumn(track, to: to) }
                        slotShift += CGFloat(to - here) * (width + gap)
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    dragX = value.translation.width - slotShift
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.18)) { dragX = 0 }
                    slotShift = 0
                    model.draggingColumn = nil
                }
        )
        .help("Drag to move the column; click to work in this language")
        .contextMenu { LanguageMenuItems(model: model, track: track) }
    }
}

/// A language column that isn't in focus steps back: its colours duller (purples toward
/// slate) and a third of the way toward the pane's background, text included. The focused
/// column keeps its full colours.
struct StepBack: ViewModifier {
    let on: Bool
    /// False: the view takes the colour out itself (a card, whose CPS and CPL chips keep a
    /// little more of theirs: `rimSaturation`).
    var desaturates = true
    static let saturation = 0.4
    /// Warning chips in another language's column (and rims on its waveform boxes): a smidge
    /// more of their colour than the rest, so red still reads as red.
    static let rimSaturation = 0.6
    static let opacity = 0.7

    func body(content: Content) -> some View {
        content
            .saturation(on && desaturates ? Self.saturation : 1)
            .opacity(on ? Self.opacity : 1)
            .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// The per-language menu (header ellipsis and right-click).
struct LanguageMenuItems: View {
    @ObservedObject var model: AppModel
    @ObservedObject var track: Track

    var body: some View {
        let isMaster = model.video?.masterTrackID == track.id
        Button("Language Options…") { model.showLanguageOptions(track) }
        Divider()
        if !isMaster {
            Button(track.locked ? "Unlock from Master" : "Lock to Master") { model.setLocked(track, !track.locked) }
            Button("Make This the Master") { model.setMaster(track) }
            Divider()
        }
        Button("Move Column Left") { model.moveColumn(track, by: -1) }
        Button("Move Column Right") { model.moveColumn(track, by: 1) }
        Button("Close Column") { model.closeColumn(track) }
        if !isMaster {
            Divider()
            Button("Delete Language…") { model.deleteLanguage(track) }
        }
    }
}

/// "Duplicate Language": a copy of a language with all its titles. One language: a plain
/// item; several: a submenu to choose which.
struct DuplicateLanguageItems: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let tracks = model.video?.tracks ?? []
        if tracks.count == 1, let only = tracks.first {
            Button("Duplicate \(only.language.name)") { model.duplicateLanguage(only) }
        } else if !tracks.isEmpty {
            Menu("Duplicate Language") {
                ForEach(tracks) { track in
                    Button("\(track.language.name)  ·  \(track.language.code)") { model.duplicateLanguage(track) }
                }
            }
        }
    }
}

/// "+" at the end of the language headers: reopen a closed language, or add one.
private struct AddLanguageMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let closed = (model.video?.tracks ?? []).filter { !(model.video?.openTrackIDs.contains($0.id) ?? true) }
        Menu {
            if !closed.isEmpty {
                Section("Show") {
                    ForEach(closed) { track in
                        Button(track.language.name) { model.openColumn(track) }
                    }
                }
            }
            Button("New Language from Master…") { model.sheet = .newLanguage }
            Button("Import Language…") { model.importLanguagePanel() }
            DuplicateLanguageItems(model: model)
        } label: {
            Image(systemName: "plus.circle.fill").font(.system(size: 14)).foregroundStyle(Theme.teal)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show or add a language")
    }
}

private struct EmptyCards: View {
    let hasMedia: Bool
    let locked: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConsoleLabel(text: hasMedia ? "No titles yet" : "No video yet", color: Theme.peach, size: 11)
            Text(hasMedia
                 ? "Drag across the waveform to create a title, or play the video and hold ↓ while someone speaks. Or import a subtitle file with the + above."
                 : "Add a video with File ▸ Add Video… (⌥⌘N), or drop one onto the window. You can also import a subtitle file with the + above.")
                .font(Theme.label(13, .regular))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Theme.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

struct CardView: View {
    static let baseFontSize: CGFloat = 15

    /// The largest size (up to 15 pt, down to half of that) at which the longest line fits
    /// on one line. Remembered, since every card on screen asks each time it's drawn.
    @MainActor
    static func fittingSize(for text: String, width: CGFloat) -> CGFloat {
        let key = FittingSizes.Key(text: text, width: width)
        if let known = FittingSizes.known[key] { return known }
        let size = measuredFittingSize(for: text, width: width)
        if FittingSizes.known.count > 4000 { FittingSizes.known.removeAll(keepingCapacity: true) }
        FittingSizes.known[key] = size
        return size
    }

    private static func measuredFittingSize(for text: String, width: CGFloat) -> CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) as NSString }
        func widest(at size: CGFloat) -> CGFloat {
            let font = NSFont.systemFont(ofSize: size, weight: .medium)
            return lines.map { $0.size(withAttributes: [.font: font]).width }.max() ?? 0
        }
        let full = widest(at: baseFontSize)
        guard full > 0, width > 20, full > width else { return baseFontSize }
        let smallest = baseFontSize * 0.5
        var size = max(smallest, (baseFontSize * width / full * 2).rounded(.down) / 2)
        // Small text is spaced a little wider than large text, so a size worked out in
        // proportion can still be a touch too wide: step down until the line really fits.
        while size > smallest, widest(at: size) > width { size -= 0.5 }
        return size
    }

    /// The title as it shows on a card: formatted, misspelled words underlined in red,
    /// Find's matches in teal (the current one stronger). Ranges are in the visible text.
    static func decorated(_ text: String, misspelled: [NSRange], matches: [NSRange], current: Int?) -> AttributedString {
        var a = Markup.attributed(text)
        for r in misspelled {
            if let range = Range(r, in: a) { a[range].underlineStyle = Text.LineStyle(pattern: .dot, color: Theme.red) }
        }
        for (k, r) in matches.enumerated() {
            if let range = Range(r, in: a) { a[range].backgroundColor = Theme.teal.opacity(k == current ? 0.6 : 0.25) }
        }
        return a
    }

    /// One way of laying out the header strip (see the `ViewThatFits` in `body`).
    @ViewBuilder
    private func header(cps: TimingStatus, dur: TimingStatus, line: TimingStatus, size: CGFloat,
                        cpsWord: Bool, showTime: Bool) -> some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(Theme.label(12, .heavy))
                .foregroundStyle(Theme.background)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 26)
                .padding(.vertical, 2)
                .background(Capsule().fill(isSelected ? Theme.amber : Theme.periwinkle.opacity(0.75)))
                .onTapGesture(count: 2) {
                    if model.video?.focusedTrackID != track.id { model.focusTrack(track.id, edit: false) }
                    model.playTitle(sub.id)
                }
                .help("Double-click to play this title")
            if showTime {
                Text(model.tc(sub.start))
                    .font(Theme.mono(size))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .fixedSize()
                if !compact {
                    Text("→").font(Theme.mono(size)).foregroundStyle(Theme.textFaint)
                    Text(model.tc(sub.end))
                        .font(Theme.mono(size))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if track.locked { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Theme.lilac) }
            Spacer(minLength: 4)
            if isOverlapping { Chip(text: "OVERLAP", color: Theme.lilac, size: size).fixedSize() }
            // Another language's column: CPL and CPS stay in the quiet blue of its cards,
            // with only a rim in the warning colour, so they nudge without shouting.
            if line == .bad {
                if qcMuted {
                    Chip.muted("\(preset.longestLine(sub)) CPL", status: line, size: size)
                        .fixedSize()
                } else {
                    Chip(text: "\(preset.longestLine(sub)) CPL", color: Theme.status(line), filled: true, size: size)
                        .fixedSize()
                }
            }
            if !compact {
                Chip(text: String(format: "%.2fs", sub.duration), color: qcMuted ? Theme.periwinkle : Theme.status(dur), size: size)
                    .fixedSize()
            }
            Group {
                if qcMuted {
                    Chip.muted(String(format: cpsWord ? "%.1f CPS" : "%.1f", sub.cps), status: cps, size: size)
                } else {
                    Chip(text: String(format: cpsWord ? "%.1f CPS" : "%.1f", sub.cps), color: Theme.status(cps),
                         filled: cps == .bad, size: size)
                }
            }
            .fixedSize()
            .help(String(format: "%.2f characters per second (max %g)", sub.cps, preset.maxCPS))
        }
    }

    /// The card's text as shown, remembered until the text, the spelling dictionaries or
    /// Find's highlights change (every card on screen asks each time it's drawn).
    private func decoratedText() -> AttributedString {
        let spell = model.checksSpelling(track)
        let found = model.find.highlights(in: sub.id)
        let key = DecoratedTexts.Key(text: sub.text, language: spell ? track.language.code : "",
                                     spelling: spell ? SpellService.shared.version : -1,
                                     found: found.ranges, current: found.current)
        if let known = DecoratedTexts.known[key] { return known }
        let misspelled = spell ? SpellService.shared.misspelled(in: Markup.plain(sub.text), language: track.language.code) : []
        let a = Self.decorated(sub.text, misspelled: misspelled, matches: found.ranges, current: found.current)
        if DecoratedTexts.known.count > 3000 { DecoratedTexts.known.removeAll(keepingCapacity: true) }
        DecoratedTexts.known[key] = a
        return a
    }

    @ObservedObject var model: AppModel
    let track: Track
    let sub: Subtitle
    let number: Int
    let isSelected: Bool
    /// One of several titles picked together (Shift-click), e.g. to join them.
    var inGroup = false
    let inSelectedRow: Bool
    let isOverlapping: Bool
    /// This title's issues (of the kinds looked for), shown on a tag on the card's edge; nil
    /// when it shows none (the title being typed in).
    var qcMarks: Set<QCIssue>? = nil
    /// Another language's column: the tag in the quiet blue of an unfocused card.
    var qcMuted = false
    /// QC mode: titles with an issue get a yellow outline and the rest step back.
    var qcLook = false
    let preset: TimingPreset
    let compact: Bool
    /// The card's width, so the text can shrink to keep the on-screen line breaks.
    let width: CGFloat
    /// Drawn quickly (the scroll bar is being dragged): no spelling marks.
    var light = false
    /// Another language's column (see StepBack): the card takes the colour out of itself,
    /// leaving its CPS and CPL chips a little more (`StepBack.rimSaturation`).
    var stepBack = false
    /// Words dragged from another card are over this one.
    @State private var textDropHover = false

    /// The title's text as it is now (the row can lag a moment behind typing). Made here, not
    /// handed in as a binding: a binding made of closures is never "the same" to SwiftUI, so
    /// every card on screen was redrawn whenever anything changed (each time the playhead
    /// reached a title, say), which made the picture stutter.
    private var text: String { track.doc.subtitle(sub.id)?.text ?? sub.text }

    private var textBinding: Binding<String> {
        let doc = track.doc, id = sub.id, owner = self.model
        return Binding(get: { doc.subtitle(id)?.text ?? "" },
                       set: {
                           doc.setText(id, $0)
                           owner.typed(in: id)
                       })
    }

    var body: some View {
        let cps = preset.cpsStatus(sub)
        let dur = preset.durationStatus(sub)
        let line = preset.lineStatus(sub)
        let accent = isSelected || inGroup ? Theme.amber : (inSelectedRow ? Theme.amber.opacity(0.4) : Theme.rule)

        VStack(spacing: 0) {
            // Header strip: number, in/out times, duration, CPS. Always one line, so every
            // card's header is the same height: narrower cards get smaller chips, then the CPS
            // chip without the word, then no timecode (it's on the waveform and in the title bar).
            ViewThatFits(in: .horizontal) {
                header(cps: cps, dur: dur, line: line, size: 10, cpsWord: true, showTime: true)
                header(cps: cps, dur: dur, line: line, size: 9, cpsWord: true, showTime: true)
                header(cps: cps, dur: dur, line: line, size: 9, cpsWord: false, showTime: true)
                header(cps: cps, dur: dur, line: line, size: 9, cpsWord: false, showTime: false)
            }
            .saturation(stepBack ? StepBack.rimSaturation : 1)
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 5)

            // Title box: the text, centred, styled like it appears over the video.
            // Only the selected card is editable, so no other card can keep a stale
            // text selection or cursor.
            // Lines break exactly where they do on screen: when a line is too wide for the
            // card, the text shrinks instead of wrapping (down to 55 %, then it wraps).
            // Edited formatted, as it looks: italics show as italics, never as <i> tags.
            let fontSize = Self.fittingSize(for: Markup.plain(isSelected ? text : sub.text), width: width - 40)
            Group {
                if isSelected {
                    TitleEditor(
                        text: textBinding,
                        fontSize: fontSize,
                        focusNow: model.focusRequest == sub.id,
                        onFocusTaken: { if model.focusRequest != nil { model.focusRequest = nil } },
                        onEndEditing: { rebalance in
                            model.autoBreak(sub.id, rebalance: rebalance)
                            track.doc.endTextCoalescing()
                        },
                        liveBreak: { model.liveBreak($0, track: track) },
                        startItalic: model.italicNext == sub.id,
                        onStartItalicUsed: { if model.italicNext == sub.id { model.italicNext = nil } },
                        spellLanguage: model.checksSpelling(track) ? track.language.code : nil,
                        findHighlight: model.find.editorHighlight(for: sub.id),
                        onLearn: { model.learnWord($0, language: track.language.code) },
                        onProjectWord: { model.addProjectWord($0, language: track.language.code) },
                        onEmptiedItalic: { model.italicNext = sub.id },
                        onCursor: { model.textCursor($0, in: sub.id) },
                        onDragText: { piece, rest in
                            model.beginTextDrag(from: sub.id, track: track, piece: piece, rest: rest)
                        }
                    )
                    // A fresh editor for each title, so nothing of the last one carries over.
                    .id(sub.id)
                } else {
                    Text(sub.text.isEmpty ? AttributedString(" ") : (light ? Markup.attributed(sub.text) : decoratedText()))
                        .frame(maxWidth: .infinity)
                }
            }
                .font(.system(size: fontSize, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.text)
                .lineLimit(1...8)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, minHeight: 48)
                .saturation(stepBack ? StepBack.saturation : 1)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.45)))
                .overlay(alignment: .topTrailing) {
                    // An empty title that will be italic when you type or paste into it.
                    if model.italicNext == sub.id, Markup.plain(isSelected ? text : sub.text).isEmpty {
                        ItalicBadge().padding(4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // While the cursor is in the card: a small key on the box's lower edge,
                    // in the padding below the text, so it never covers a line.
                    if isSelected, model.cursorIn == sub.id {
                        EscHint().offset(x: -8, y: 5.5)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Theme.panelRaised : Theme.panelRaised.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isOverlapping && !isSelected ? Theme.lilac.opacity(0.7)
                            : (qcLook && qcMarks?.isEmpty == false && !isSelected && !inGroup ? Theme.alert.opacity(0.7) : accent),
                        lineWidth: isSelected ? 1.5 : 1)
        )
        .overlay(alignment: .leading) {
            // Left status cap, like a console indicator.
            Capsule()
                .fill(Theme.status(preset.status(sub)))
                .saturation(stepBack ? StepBack.saturation : 1)
                .frame(width: 3)
                .padding(.vertical, 10)
                .offset(x: -1.5)
        }
        // What's wrong with this title (in QC mode or not), on a tag that hangs on the card's
        // lower edge. It takes no room of its own: a card is exactly as tall with a tag as
        // without, so the list keeps its place and scrolls evenly. Click it for the fixes.
        .overlay(alignment: .bottomLeading) {
            if let marks = qcMarks, !marks.isEmpty {
                QCTagMenu(model: model, track: track, sub: sub, marks: marks, muted: qcMuted)
                    .saturation(stepBack ? StepBack.saturation : 1)
                    // Room on the right for the "esc" key on the text box's edge.
                    .frame(maxWidth: max(60, width - 76), alignment: .leading)
                    .padding(.leading, 12)
                    .offset(y: QCTag.height / 2)
            }
        }
        // QC mode: titles with nothing to fix step back.
        .opacity(qcLook && qcMarks?.isEmpty == true && !isSelected && !inGroup ? 0.45 : 1)
        // Stepping back (or forward) fades as the column's opacity does (see StepBack).
        .animation(.easeOut(duration: 0.15), value: stepBack)
        // Words dragged out of the card being typed in can be dropped here (AppModel.dropText).
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.amber, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                .opacity(textDropHover ? 1 : 0)
                .allowsHitTesting(false)
        )
        .onDrop(of: [UTType.utf8PlainText, UTType.plainText],
                delegate: TextDropTarget(model: model, track: track, id: sub.id, hovering: $textDropHover))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            let flags = NSEvent.modifierFlags
            // Shift-click: every title from the selected one to this one (to join them, say).
            // ⌘-click: this one in or out of the group.
            if flags.contains(.shift) || flags.contains(.command), !isSelected,
               model.video?.focusedTrackID == track.id, model.doc.selectedID != nil {
                if flags.contains(.shift) { model.selectRange(to: sub.id) } else { model.toggleMulti(sub.id) }
                return
            }
            // Clicking a card focuses its language, selects it, takes the playhead to its
            // start, and puts the cursor at the end of its text.
            if model.video?.focusedTrackID != track.id { model.focusTrack(track.id, edit: false) }
            model.clearMulti()
            model.select(sub.id, seekToStart: true)
            model.focusRequest = sub.id
        })
        .contextMenu {
            Button("Play Title") {
                focusColumn()
                model.playTitle(sub.id)
            }
            if inGroup, model.canJoin {
                Button("Join \(model.multiSelection.count) Titles  (⌘J)") { model.joinSelected() }
            }
            Divider()
            Button("Delete Title  (⌃⌫)") {
                focusColumn()
                model.clearMulti()
                model.select(sub.id)
                model.deleteSelected()
            }
        }
    }

    /// This card's language becomes the one being edited (menus act on the focused language).
    private func focusColumn() {
        if model.video?.focusedTrackID != track.id { model.focusTrack(track.id, edit: false) }
    }
}

/// QC mode: the kinds of issue a title has, on a small yellow-alert tag.
struct QCTag: View {
    /// Shorter than the space between two cards, half of it hangs below the card.
    static let height: CGFloat = 13
    let marks: Set<QCIssue>
    /// A language that isn't focused: blue, like its cards' number pills, not yellow.
    var muted = false

    /// The kinds in the QC bar's order: "CPS · GAP".
    static func text(_ marks: Set<QCIssue>) -> String {
        QCIssue.allCases.filter(marks.contains).map { $0.label.uppercased() }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 7))
            Text(Self.text(marks))
                .font(Theme.label(8.5, .bold))
                .tracking(0.8)
                .lineLimit(1)
        }
        .foregroundStyle(Theme.background)
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .background(Capsule().fill(muted ? Theme.periwinkle.opacity(0.75) : Theme.alert))
    }
}

/// A title's issue tag as a button: click it for what's wrong, in words, and the fixes
/// that apply (each for this title alone, one undo step).
private struct QCTagMenu: View {
    @ObservedObject var model: AppModel
    let track: Track
    let sub: Subtitle
    let marks: Set<QCIssue>
    var muted = false

    var body: some View {
        let fixes = QCFix.fixes(for: marks)
        Menu {
            Text(model.describe(marks, of: sub, in: track))
            if !fixes.isEmpty { Divider() }
            ForEach(fixes) { fix in
                Button(fix.label) {
                    if model.video?.focusedTrackID != track.id { model.focusTrack(track.id, edit: false) }
                    model.applyQCFix(fix, to: sub.id)
                }
                // A language locked to the master keeps the master's timing.
                .disabled(track.locked && fix.changesTiming)
            }
        } label: {
            QCTag(marks: marks, muted: muted)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(model.describe(marks, of: sub, in: track) + ". Click for fixes.")
    }
}

/// Shows the Find bar above the cards while Find is open.
private struct FindBarSlot: View {
    @ObservedObject var find: FindController

    var body: some View {
        if find.isShown { FindBar(find: find) }
    }
}

/// Find and Replace, above the cards: ⌘F, ⌥⌘F; Return finds the next, ⌘G / ⇧⌘G next and
/// previous, Esc closes it.
private struct FindBar: View {
    @ObservedObject var find: FindController
    @FocusState private var field: Field?
    private enum Field { case query, replacement }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    find.showsReplace.toggle()
                } label: {
                    Image(systemName: find.showsReplace ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .help(find.showsReplace ? "Hide Replace" : "Show Replace (⌥⌘F)")
                TextField("Find", text: $find.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($field, equals: .query)
                    .onSubmit { find.next() }
                Text(find.countText)
                    .font(Theme.mono(10))
                    .foregroundStyle(find.matches.isEmpty && !find.query.isEmpty ? Theme.red : Theme.textDim)
                    .lineLimit(1)
                    .fixedSize()
                Button { find.previous() } label: { Image(systemName: "chevron.up") }
                    .help("Previous (⇧⌘G)")
                Button { find.next() } label: { Image(systemName: "chevron.down") }
                    .help("Next (⌘G, or Return)")
                Button { find.close() } label: { Image(systemName: "xmark") }
                    .help("Close (Esc)")
            }
            if find.showsReplace {
                HStack(spacing: 6) {
                    Color.clear.frame(width: 12, height: 1)
                    TextField("Replace with", text: $find.replacement)
                        .textFieldStyle(.roundedBorder)
                        .focused($field, equals: .replacement)
                        .onSubmit { find.replaceCurrent() }
                    Button("Replace") { find.replaceCurrent() }
                        .disabled(find.matches.isEmpty)
                        .help("Replace this one and go to the next")
                    Button("All") { _ = find.replaceAll() }
                        .disabled(find.matches.isEmpty)
                        .help("Replace every match (one undo per language)")
                }
            }
            HStack(spacing: 10) {
                Color.clear.frame(width: 2, height: 1)
                Picker("", selection: $find.scope) {
                    ForEach(FindScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Toggle("Match Case", isOn: $find.matchCase)
                Toggle("Whole Word", isOn: $find.wholeWord)
                Spacer(minLength: 0)
            }
            .toggleStyle(.checkbox)
        }
        .controlSize(.small)
        .font(Theme.label(11, .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panelRaised.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
        .onAppear { field = .query }
        .onChange(of: find.focusTick) { _, _ in field = .query }
    }
}
