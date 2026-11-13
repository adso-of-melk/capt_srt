import SwiftUI
import AppKit

/// Left pane: one column of cards per open language, side by side. Linked titles share a
/// row, and a language with no title in a row shows an empty slot, so rows always line up.
/// This is the only place text is edited.
struct CardPane: View {
    @ObservedObject var model: AppModel
    /// The focused language's titles.
    @ObservedObject var doc: SubtitleDocument

    var body: some View {
        let tracks = model.openTracks
        VStack(spacing: 0) {
            PaneHeader(title: "Titles", color: Theme.amber) {
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
                let usable = geo.size.width - 24 - gap * (count - 1)
                // Columns share the pane; narrower than full size, the text shrinks instead.
                let width = max(model.cardColumnFloor, usable / count)
                let total = width * count + gap * (count - 1) + 24
                ScrollViewReader { hProxy in
                    ScrollView(.horizontal, showsIndicators: total > geo.size.width + 1) {
                        VStack(spacing: 0) {
                            HStack(spacing: gap) {
                                ForEach(tracks) { track in
                                    LanguageHeader(model: model, track: track, width: width)
                                        .id(track.id)
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
                    .onChange(of: model.video?.focusedTrackID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { hProxy.scrollTo(id) }
                    }
                }
            }
        }
        .background(Theme.panel)
    }

    @ViewBuilder
    private func rowsList(tracks: [Track], width: CGFloat, gap: CGFloat) -> some View {
        let focusedID = model.video?.focusedTrackID
        let selectedRow = model.selectedRowKey
        let overlaps = doc.overlappingIDs
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
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
                        .id(row.key)
                    }
                    if model.rows.isEmpty { EmptyCards(hasMedia: model.hasMedia, locked: model.focusedIsLocked) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 2)
            }
            .onChange(of: doc.selectedID) { _, id in
                guard let id, let key = model.rowKey(ofSub: id) else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(key, anchor: .center) }
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
        if let sub = row.cells[track.id] {
            CardView(
                model: model,
                track: track,
                sub: sub,
                number: model.rowNumber(of: sub.id) ?? number,
                isSelected: isFocusedColumn && doc.selectedID == sub.id,
                inSelectedRow: inSelectedRow,
                isOverlapping: isFocusedColumn && overlaps.contains(sub.id),
                preset: model.preset(for: track),
                compact: model.openTracks.count > 1,
                width: width,
                text: Binding(
                    get: { track.doc.subtitle(sub.id)?.text ?? "" },
                    set: { track.doc.setText(sub.id, $0) }
                )
            )
        } else {
            EmptySlot(isSelected: isFocusedColumn && model.emptySlotRow == row.key && doc.selectedID == nil,
                      inSelectedRow: inSelectedRow, locked: track.locked)
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
        }
    }
}

/// A row where this language has no title yet. Double-click (or select it and type) to create one.
private struct EmptySlot: View {
    let isSelected: Bool
    let inSelectedRow: Bool
    let locked: Bool
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
        .contentShape(Rectangle())
        .onTapGesture { model.focusTrack(track.id, edit: false) }
        .contextMenu { LanguageMenuItems(model: model, track: track) }
    }
}

/// The per-language menu (header ellipsis and right-click).
struct LanguageMenuItems: View {
    @ObservedObject var model: AppModel
    @ObservedObject var track: Track

    var body: some View {
        let isMaster = model.video?.masterTrackID == track.id
        if !isMaster {
            Button(track.locked ? "Unlock from Master" : "Lock to Master") { model.setLocked(track, !track.locked) }
            Button("Make This the Master") { model.setMaster(track) }
            Divider()
        }
        Picker("Reading Speed", selection: Binding(
            get: { track.maxCPS ?? 0 },
            set: { model.setOverrides(track, maxCPS: .some($0 == 0 ? nil : $0)) }
        )) {
            Text("Project standard").tag(0.0)
            ForEach([12.0, 13, 15, 17, 20, 25], id: \.self) { Text("\(Int($0)) CPS").tag($0) }
        }
        Picker("Characters per Line", selection: Binding(
            get: { track.maxCharsPerLine ?? 0 },
            set: { model.setOverrides(track, maxChars: .some($0 == 0 ? nil : $0)) }
        )) {
            Text("Project standard").tag(0)
            ForEach([16, 23, 32, 37, 39, 42, 47], id: \.self) { Text("\($0)").tag($0) }
        }
        Divider()
        Text(model.spellingStatus(for: track.language))
        Divider()
        Button("Move Column Left") { model.moveColumn(track, by: -1) }
        Button("Move Column Right") { model.moveColumn(track, by: 1) }
        Button("Close Column") { model.closeColumn(track) }
        if !isMaster {
            Divider()
            Button("Delete Language…") { model.deleteLanguage(track) }
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
    /// on one line.
    static func fittingSize(for text: String, width: CGFloat) -> CGFloat {
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

    private func decoratedText() -> AttributedString {
        let misspelled = model.spellCheckOn
            ? SpellService.shared.misspelled(in: Markup.plain(sub.text), language: track.language.code) : []
        let found = model.find.highlights(in: sub.id)
        return Self.decorated(sub.text, misspelled: misspelled, matches: found.ranges, current: found.current)
    }

    @ObservedObject var model: AppModel
    let track: Track
    let sub: Subtitle
    let number: Int
    let isSelected: Bool
    let inSelectedRow: Bool
    let isOverlapping: Bool
    let preset: TimingPreset
    let compact: Bool
    /// The card's width, so the text can shrink to keep the on-screen line breaks.
    let width: CGFloat
    @Binding var text: String

    var body: some View {
        let cps = preset.cpsStatus(sub)
        let dur = preset.durationStatus(sub)
        let line = preset.lineStatus(sub)
        let accent = isSelected ? Theme.amber : (inSelectedRow ? Theme.amber.opacity(0.4) : Theme.rule)

        VStack(spacing: 0) {
            // Header strip: number, in/out times, duration, CPS.
            HStack(spacing: 6) {
                Text("\(number)")
                    .font(Theme.label(12, .heavy))
                    .foregroundStyle(Theme.background)
                    .frame(minWidth: 26)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(isSelected ? Theme.amber : Theme.periwinkle.opacity(0.75)))
                    .onTapGesture(count: 2) {
                        if model.video?.focusedTrackID != track.id { model.focusTrack(track.id, edit: false) }
                        model.playTitle(sub.id)
                    }
                    .help("Double-click to play this title")
                Text(model.tc(sub.start))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                if !compact {
                    Text("→").font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                    Text(model.tc(sub.end))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
                if track.locked { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Theme.lilac) }
                Spacer(minLength: 4)
                if isOverlapping { Chip(text: "OVERLAP", color: Theme.lilac) }
                if line == .bad { Chip(text: "\(preset.longestLine(sub)) CPL", color: Theme.status(line), filled: true) }
                if !compact { Chip(text: String(format: "%.2fs", sub.duration), color: Theme.status(dur)) }
                Chip(text: String(format: "%.1f CPS", sub.cps), color: Theme.status(cps), filled: cps == .bad)
            }
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
                        text: $text,
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
                        spellLanguage: model.spellCheckOn ? track.language.code : nil,
                        findHighlight: model.find.editorHighlight(for: sub.id),
                        onLearn: { model.learnWord($0, language: track.language.code) },
                        onProjectWord: { model.addProjectWord($0, language: track.language.code) }
                    )
                    // A fresh editor for each title, so nothing of the last one carries over.
                    .id(sub.id)
                } else {
                    Text(sub.text.isEmpty ? AttributedString(" ") : decoratedText())
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
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.45)))
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Theme.panelRaised : Theme.panelRaised.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isOverlapping && !isSelected ? Theme.lilac.opacity(0.7) : accent,
                        lineWidth: isSelected ? 1.5 : 1)
        )
        .overlay(alignment: .leading) {
            // Left status cap, like a console indicator.
            Capsule()
                .fill(Theme.status(preset.status(sub)))
                .frame(width: 3)
                .padding(.vertical, 10)
                .offset(x: -1.5)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            // Clicking a card focuses its language, selects it, takes the playhead to its
            // start, and puts the cursor at the end of its text.
            if model.video?.focusedTrackID != track.id { model.focusTrack(track.id, edit: false) }
            model.select(sub.id, seekToStart: true)
            model.focusRequest = sub.id
        })
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
