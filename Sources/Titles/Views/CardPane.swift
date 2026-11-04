import SwiftUI
import AppKit

/// Left pane: one title-box-shaped card per subtitle, in order, numbered.
/// This is the only place text is edited.
struct CardPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var doc: SubtitleDocument
    @FocusState private var focused: UUID?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Titles", color: Theme.amber) {
                Chip(text: "\(doc.subtitles.count)", color: Theme.peach)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        let overlaps = doc.overlappingIDs
                        ForEach(Array(doc.subtitles.enumerated()), id: \.element.id) { index, sub in
                            CardView(
                                model: model,
                                sub: sub,
                                number: index + 1,
                                isSelected: doc.selectedID == sub.id,
                                isOverlapping: overlaps.contains(sub.id),
                                preset: model.preset,
                                text: Binding(
                                    get: { doc.subtitle(sub.id)?.text ?? "" },
                                    set: { doc.setText(sub.id, $0) }
                                ),
                                focused: $focused
                            )
                            .id(sub.id)
                        }
                        if doc.subtitles.isEmpty { EmptyCards(hasMedia: model.hasMedia) }
                    }
                    .padding(12)
                }
                .onChange(of: doc.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(Theme.panel)
        .onChange(of: model.focusRequest) { _, id in
            // Already focused by a click inside the field: leave the cursor where it was put.
            if focused == id { return }
            // Slight delay so a just-created card exists before it takes focus.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                if focused != model.focusRequest { focused = model.focusRequest }
                // Put the text cursor at the end instead of selecting everything.
                try? await Task.sleep(nanoseconds: 30_000_000)
                if model.focusRequest != nil,
                   let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    let end = (editor.string as NSString).length
                    editor.setSelectedRange(NSRange(location: end, length: 0))
                }
            }
        }
        .onChange(of: focused) { old, id in
            if let id {
                if model.focusRequest != id { model.focusRequest = id }
                doc.selectedID = id
            } else if model.focusRequest == old {
                // Focus really left the card (not a hand-over to another card via Tab).
                model.focusRequest = nil
            }
        }
    }
}

private struct EmptyCards: View {
    let hasMedia: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConsoleLabel(text: hasMedia ? "No titles yet" : "No video loaded", color: Theme.peach, size: 11)
            Text(hasMedia
                 ? "Drag across the waveform to create a title, or play the video and hold ↓ while someone speaks."
                 : "Drop a video (and optionally an .srt) onto the window, or press ⌘O.")
                .font(Theme.label(13, .regular))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Theme.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

struct CardView: View {
    @ObservedObject var model: AppModel
    let sub: Subtitle
    let number: Int
    let isSelected: Bool
    let isOverlapping: Bool
    let preset: TimingPreset
    @Binding var text: String
    var focused: FocusState<UUID?>.Binding

    var body: some View {
        let cps = preset.cpsStatus(sub)
        let dur = preset.durationStatus(sub)
        let accent = isSelected ? Theme.amber : Theme.rule

        VStack(spacing: 0) {
            // Header strip: number, in/out times, duration, CPS.
            HStack(spacing: 6) {
                Text("\(number)")
                    .font(Theme.label(12, .heavy))
                    .foregroundStyle(Theme.background)
                    .frame(minWidth: 26)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(isSelected ? Theme.amber : Theme.periwinkle.opacity(0.75)))
                Text(Timecode.srt(sub.start))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textDim)
                Text("→").font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                Text(Timecode.srt(sub.end))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textDim)
                Spacer(minLength: 4)
                if isOverlapping { Chip(text: "OVERLAP", color: Theme.lilac) }
                Chip(text: String(format: "%.2fs", sub.duration), color: Theme.status(dur))
                Chip(text: String(format: "%.1f CPS", sub.cps), color: Theme.status(cps), filled: cps == .bad)
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 5)

            // Title box: the text, centred, styled like it appears over the video.
            // Only the selected card is editable, so no other card can keep a stale
            // text selection or cursor.
            Group {
                if isSelected {
                    TextField("Type the title…", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused(focused, equals: sub.id)
                } else {
                    Text(sub.text.isEmpty ? " " : sub.text)
                        .frame(maxWidth: .infinity)
                }
            }
                .font(.system(size: 15, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.text)
                .lineLimit(1...4)
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
            // Clicking a card selects it and puts the cursor at the end of its text.
            model.select(sub.id, seekToStart: !isSelected)
            model.focusRequest = sub.id
        })
    }
}
