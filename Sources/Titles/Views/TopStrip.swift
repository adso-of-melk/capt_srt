import SwiftUI

/// The slim strip across the top of the editor: Home, the project and its videos, and the name.
struct TopStrip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            HomeButton { model.goHome() }
            if let project = model.project {
                Text(project.name)
                    .font(Theme.label(12, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Rectangle().fill(Theme.rule).frame(width: 1, height: 14)
                VideoSwitcher(model: model, project: project)
            }
            Spacer(minLength: 12)
            if let name = model.loadingName {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    ConsoleLabel(text: model.isDownloadingFromICloud ? "Waiting for iCloud" : "Opening",
                                 color: Theme.teal, size: 9)
                    Text(name).font(Theme.label(10, .medium)).foregroundStyle(Theme.textDim).lineLimit(1)
                    if model.isDownloadingFromICloud {
                        Button("Cancel") { model.cancelICloudWait() }.buttonStyle(.link).font(Theme.label(10, .semibold))
                    }
                }
            }
            Wordmark()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }
}

/// "KPTN.SUB" in the right-hand corner, with a small console cap.
struct Wordmark: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("KPTN.SUB")
                .font(Theme.label(11, .heavy))
                .tracking(3)
                .foregroundStyle(Theme.peach)
                .fixedSize()
            Capsule().fill(Theme.amber).frame(width: 18, height: 8)
            Capsule().fill(Theme.periwinkle).frame(width: 8, height: 8)
        }
    }
}

/// The current video, and a menu to switch, add, rename or remove videos.
private struct VideoSwitcher: View {
    @ObservedObject var model: AppModel
    @ObservedObject var project: Project

    var body: some View {
        Menu {
            ForEach(project.videos) { v in
                Button {
                    model.switchVideo(v)
                } label: {
                    if v.id == model.video?.id { Label(v.name, systemImage: "checkmark") } else { Text(v.name) }
                }
            }
            Divider()
            Button("Add Video…") { model.addVideoPanel() }
            Button("Add Video Link…") { model.sheet = .openLink }
            if let v = model.video {
                Divider()
                Button("Rename “\(v.name)”…") { model.renameVideo(v) }
                if project.videos.count > 1 {
                    Button("Remove “\(v.name)” from Project…") { model.removeVideo(v) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "film").font(.system(size: 10))
                Text(model.video?.name ?? "No video")
                    .font(Theme.label(11, .medium))
                    .lineLimit(1)
                if project.videos.count > 1 {
                    Text("\(project.videos.count)").font(Theme.mono(9)).foregroundStyle(Theme.textFaint)
                }
            }
            .foregroundStyle(Theme.textDim)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch video, or add another one to the project")
    }
}

/// Leaves the project for the home screen (projects autosave, so nothing is lost).
struct HomeButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2").font(.system(size: 9, weight: .bold))
                Text("HOME").font(Theme.label(9, .bold)).tracking(1.4)
            }
            .foregroundStyle(hover ? Theme.background : Theme.teal)
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(hover ? Theme.teal : Theme.teal.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.teal.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Back to the home screen (⇧⌘H)")
    }
}

/// A one-line notice under the top strip.
struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.slash").font(.system(size: 11)).foregroundStyle(Theme.amber)
            Text(text).font(Theme.label(11, .medium)).foregroundStyle(Theme.text).lineLimit(2)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.amber.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.amber.opacity(0.3)).frame(height: 1) }
    }
}

/// Text Only mode: a single line with play, the time and the current row, so translators
/// can still hear each line without the picture or waveform.
struct SlimTransport: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: PlayheadClock

    var body: some View {
        HStack(spacing: 12) {
            Capsule().fill(Theme.amber).frame(width: 30, height: 18)
                .overlay(Image(systemName: clock.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.background))
                .onTapGesture { model.togglePlay() }
                .help("Play / pause (Shift+Space)")
            Text(model.tc(clock.time)).font(Theme.mono(13, .semibold)).foregroundStyle(Theme.peach).fixedSize()
            if let i = model.currentRowIndex {
                ConsoleLabel(text: "Row \(i + 1) of \(model.rows.count)", size: 9)
            }
            Spacer()
            ConsoleLabel(text: "Text only · ⇧⌘T to show picture", color: Theme.textFaint, size: 9)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.panelRaised)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }
}
