import SwiftUI
import AppKit

/// The start screen: start a project, open one, or pick up a recent one where you left off.
struct HomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            // Left: name and the ways in
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Capsule().fill(Theme.amber).frame(width: 46, height: 16)
                        Capsule().fill(Theme.periwinkle).frame(width: 18, height: 16)
                    }
                    Text("KPTN.SUB")
                        .font(Theme.label(38, .heavy))
                        .tracking(5)
                        .foregroundStyle(Theme.peach)
                    ConsoleLabel(text: "Subtitle editor", color: Theme.textDim, size: 11)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HomeAction(title: "New Project…", shortcut: "⌘N", color: Theme.amber) {
                        model.newProjectVideo = nil
                        model.sheet = .newProject
                    }
                    HomeAction(title: "Open Project…", shortcut: "⌘O", color: Theme.periwinkle) { model.openProjectPanel() }
                }

                Text("One project per film. It holds the film's videos and every language. You can also drop a video or a .kptnsub file onto this window.")
                    .font(Theme.label(12, .regular))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                if let name = model.loadingName {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        ConsoleLabel(text: model.isDownloadingFromICloud ? "Waiting for iCloud" : "Opening",
                                     color: Theme.teal, size: 10)
                        Text(name)
                            .font(Theme.label(12, .medium))
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if model.isDownloadingFromICloud {
                            Button("Cancel") { model.cancelICloudWait() }
                                .buttonStyle(.link)
                                .font(Theme.label(11, .semibold))
                        }
                    }
                }
            }
            .padding(40)
            .frame(width: 380, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.panel)

            Rectangle().fill(Theme.rule).frame(width: 1)

            // Right: recent films
            VStack(spacing: 0) {
                PaneHeader(title: "Recent projects", color: Theme.teal)
                    .padding(.top, 14)
                if model.recentProjects.isEmpty {
                    VStack(spacing: 8) {
                        ConsoleLabel(text: "Nothing here yet", color: Theme.peach, size: 11)
                        Text("Projects you create or open appear here.")
                            .font(Theme.label(13, .regular))
                            .foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.recentProjects) { recent in
                                RecentRow(recent: recent) { model.openRecent(recent) }
                                    .contextMenu {
                                        Button("Open") { model.openRecent(recent) }
                                        if let path = recent.path {
                                            Button("Show in Finder") {
                                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                            }
                                        }
                                        Divider()
                                        Button("Remove from List") { model.removeRecent(recent) }
                                    }
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
    }
}

private struct HomeAction: View {
    let title: String
    let shortcut: String
    let color: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Capsule().fill(color).frame(width: 6, height: 18)
                Text(title)
                    .font(Theme.label(14, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(shortcut)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 12)
            .frame(width: 280, height: 38)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Theme.panelRaised : Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(hover ? 0.8 : 0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct RecentRow: View {
    let recent: RecentProject
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Capsule().fill(hover ? Theme.amber : Theme.rule).frame(width: 6, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(recent.name)
                        .font(Theme.label(14, .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(Theme.label(11, .regular))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(recent.opened, format: .relative(presentation: .named))
                    .font(Theme.label(11, .medium))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Theme.panelRaised : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(recent.path ?? recent.name)
    }

    private var detail: String {
        let videos = recent.videoCount == 1 ? "1 video" : "\(recent.videoCount) videos"
        let langs = recent.languages.isEmpty ? "no languages yet" : recent.languages.joined(separator: " · ")
        return "\(videos) · \(langs)"
    }
}
