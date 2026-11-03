import SwiftUI
import AppKit

/// Top right: the video with the current title drawn over it.
struct VideoPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var doc: SubtitleDocument
    @ObservedObject var clock: PlayheadClock

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Picture", color: Theme.periwinkle) {
                if let url = model.videoURL {
                    Text(url.lastPathComponent)
                        .font(Theme.label(11, .medium))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            ZStack(alignment: .bottom) {
                Color.black
                if model.hasMedia {
                    EngineSurface(engine: model.engine)
                } else {
                    VStack(spacing: 10) {
                        ConsoleLabel(text: "Awaiting picture", color: Theme.periwinkle, size: 12)
                        Text("Drop a video here or press ⌘O")
                            .font(Theme.label(13, .regular))
                            .foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let text = overlayText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 22, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2, x: 0, y: 1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                        .padding(.bottom, 28)
                        .padding(.horizontal, 40)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .bottom], 10)
        }
        .background(Theme.panel)
    }

    /// While playing: whatever is on screen. While paused: the selected title if
    /// the playhead is inside it (so you see it as you type), else what's on screen.
    private var overlayText: String? {
        let t = clock.time
        if !clock.isPlaying, let sel = doc.selected, sel.start <= t, t < sel.end { return sel.text }
        return doc.active(at: t)?.text
    }
}

/// Hosts whatever view the playback engine provides.
struct EngineSurface: NSViewRepresentable {
    let engine: PlaybackEngine

    func makeNSView(context: Context) -> NSView {
        engine.makeVideoView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
