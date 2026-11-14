import SwiftUI
import AppKit

/// The project's videos at a glance. New videos are added here (not in the editor);
/// each video can be opened, given a different file, renamed or removed.
struct ProjectView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var project: Project

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HomeButton { model.goHome() }
                Text(project.name).font(Theme.label(12, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Wordmark()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    ConsoleLabel(text: "Project", color: Theme.teal, size: 10)
                    Text(project.name).font(Theme.label(26, .heavy)).foregroundStyle(Theme.peach)
                    Text(project.fileURL?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Not saved to a file")
                        .font(Theme.label(11, .regular)).foregroundStyle(Theme.textFaint)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Add Video…") { model.addVideoPanel() }
                    .buttonStyle(ConsoleButtonStyle())
                Button("Add Video Link…") { model.sheet = .openLink }
                    .buttonStyle(ConsoleButtonStyle(color: Theme.periwinkle, secondary: true))
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 14)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    ForEach(project.videos) { v in
                        VideoCard(model: model, video: v, isCurrent: v === model.video)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .background(Theme.background)
    }
}

private struct VideoCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var video: VideoItem
    let isCurrent: Bool
    @State private var hover = false

    var body: some View {
        let missing = model.videoFileMissing(video) && model.findMissingVideo(video) == nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "film").foregroundStyle(isCurrent ? Theme.amber : Theme.periwinkle)
                Text(video.name).font(Theme.label(15, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                if isCurrent { Chip(text: "OPEN", color: Theme.amber) }
            }
            HStack(spacing: 6) {
                if missing {
                    Chip(text: "FILE MISSING", color: Theme.red, filled: true)
                } else if let url = video.url {
                    Chip(text: url.isFileURL ? "FILE" : "LINK", color: Theme.teal)
                    Text(url.isFileURL ? url.lastPathComponent : (url.host ?? url.absoluteString))
                        .font(Theme.label(11, .regular)).foregroundStyle(Theme.textDim)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Chip(text: "NO VIDEO", color: Theme.textDim)
                }
            }
            HStack(spacing: 6) {
                ForEach(video.tracks) { track in
                    Chip(text: "\(track.language.code.uppercased()) \(track.doc.subtitles.count)",
                         color: track.id == video.masterTrackID ? Theme.peach : Theme.periwinkle)
                }
            }
            HStack(spacing: 8) {
                Button("Open") { model.openVideoFromOverview(video) }
                    .buttonStyle(ConsoleButtonStyle())
                Button(missing ? "Locate…" : "Replace File…") { model.replaceVideoPanel(for: video) }
                    .buttonStyle(ConsoleButtonStyle(color: missing ? Theme.red : Theme.periwinkle, secondary: true))
                Spacer()
                Menu {
                    Button("Rename…") { model.renameVideo(video) }
                    if (model.project?.videos.count ?? 0) > 1 {
                        Button("Remove from Project…") { model.removeVideo(video) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Theme.panelRaised : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isCurrent ? Theme.amber.opacity(0.7) : Theme.rule, lineWidth: 1))
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { model.openVideoFromOverview(video) }
    }
}

/// Under the top strip when the open video's file isn't on this Mac.
struct MissingVideoBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "film.stack").font(.system(size: 11)).foregroundStyle(Theme.red)
            Text("The video for \(model.video?.name ?? "this video") isn't on this Mac (\(model.video?.url?.lastPathComponent ?? "")). Your titles are safe.")
                .font(Theme.label(11, .medium)).foregroundStyle(Theme.text).lineLimit(2)
            Spacer()
            Button("Locate…") { model.replaceVideoPanel() }
                .buttonStyle(ConsoleButtonStyle(color: Theme.red))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.red.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.red.opacity(0.3)).frame(height: 1) }
    }
}
