import SwiftUI

/// QC mode's bar across the top of the editor, under the top strip: a "yellow alert" light,
/// one chip per kind of issue (how many titles of the focused language have it; click to
/// look for it or not), previous / next issue, the automatic fixes, and a close button.
struct QCBar: View {
    @ObservedObject var model: AppModel
    /// The focused language's titles, so the counts follow every change.
    @ObservedObject var doc: SubtitleDocument

    var body: some View {
        let counts = model.qcCounts()
        HStack(spacing: 8) {
            AlertLight()
            ConsoleLabel(text: "QC", color: Theme.alert, size: 11)
            if let track = model.focusedTrack {
                Text(track.language.name)
                    .font(Theme.label(11, .semibold))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .fixedSize()
            }
            Rectangle().fill(Theme.alert.opacity(0.35)).frame(width: 1, height: 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(QCIssue.allCases) { issue in
                        KindChip(issue: issue, count: counts[issue] ?? 0, on: model.qcKinds.contains(issue)) {
                            if model.qcKinds.contains(issue) { model.qcKinds.remove(issue) } else { model.qcKinds.insert(issue) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.nextIssue(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.alert)
                .help("Previous issue (Shift-Tab)")
            Button { model.nextIssue(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.alert)
                .help("Next issue (Tab)")
            Menu {
                Button("Extend Selected Titles to Fit Reading Speed  (⌥⌘E)") { model.extendToFitReadingSpeed(all: false) }
                Button("Extend All Titles to Fit Reading Speed") { model.extendToFitReadingSpeed(all: true) }
                Divider()
                Button("Widen Selected Gaps to the Minimum") { model.fixGaps(all: false, close: false) }
                Button("Widen All Gaps to the Minimum") { model.fixGaps(all: true, close: false) }
                Button("Close Short Gaps (Under ½ s) to the Minimum") { model.fixGaps(all: true, close: true) }
            } label: {
                Text("FIX").font(Theme.label(11, .bold)).tracking(1.2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .foregroundStyle(Theme.alert)
            .help("Automatic fixes for the selected titles, or for all of them (one undo each)")
            Button { model.qcMode = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
                .help("Leave QC mode (⌘K)")
        }
        .font(.system(size: 11, weight: .bold))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.alertPanel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.alert.opacity(0.55)).frame(height: 1) }
    }
}

/// One kind of issue in the QC bar: its name and count. Ticked (looked for): filled.
private struct KindChip: View {
    let issue: QCIssue
    let count: Int
    let on: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text(issue.label.uppercased()).tracking(0.8)
                Text("\(count)").font(Theme.mono(10, .bold))
            }
            .font(Theme.label(10, .bold))
            .foregroundStyle(on ? Theme.background : Theme.textDim)
            .padding(.horizontal, 7)
            .frame(height: 17)
            .background(Capsule().fill(on ? Theme.alert.opacity(count > 0 ? 1 : 0.45) : Color.clear))
            .overlay(Capsule().stroke(on ? Color.clear : Theme.textFaint, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(issue.help): \(count) title\(count == 1 ? "" : "s"). " + (on ? "Click to skip these." : "Click to look for these."))
    }
}

/// The "yellow alert" light: a small capsule that slowly pulses while QC mode is on.
private struct AlertLight: View {
    @State private var bright = false

    var body: some View {
        Capsule()
            .fill(Theme.alert)
            .frame(width: 22, height: 10)
            .opacity(bright ? 1 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}
